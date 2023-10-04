(*****************************************************************************)
(*                                                                           *)
(* Open Source License                                                       *)
(* Copyright (c) 2023 Nomadic Labs, <contact@nomadic-labs.com>               *)
(*                                                                           *)
(* Permission is hereby granted, free of charge, to any person obtaining a   *)
(* copy of this software and associated documentation files (the "Software"),*)
(* to deal in the Software without restriction, including without limitation *)
(* the rights to use, copy, modify, merge, publish, distribute, sublicense,  *)
(* and/or sell copies of the Software, and to permit persons to whom the     *)
(* Software is furnished to do so, subject to the following conditions:      *)
(*                                                                           *)
(* The above copyright notice and this permission notice shall be included   *)
(* in all copies or substantial portions of the Software.                    *)
(*                                                                           *)
(* THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR*)
(* IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,  *)
(* FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL   *)
(* THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER*)
(* LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING   *)
(* FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER       *)
(* DEALINGS IN THE SOFTWARE.                                                 *)
(*                                                                           *)
(*****************************************************************************)

open Legacy_monad_globals
open Lwt_result_syntax
open Tezos_shell_services
open Tezos_client_017_PtNairob
open Tezos_baking_017_PtNairob
open Tezos_protocol_017_PtNairob
open Protocol
open Alpha_context

(** Sync node *)

class wrap_silent_memory_client (t : Client_context.full) :
  Protocol_client_context.full =
  object
    inherit Protocol_client_context.wrap_full t

    method! message : type a. (a, unit) Client_context.lwt_format -> a =
      fun x -> Format.kasprintf (fun _msg -> Lwt.return_unit) x

    method! last_modification_time _ = return_some 0.

    (* We rely on the client's cache mechanism to store in memory the
       extracted delegate keys. *)
    method! load _ ~default _ = return default

    method! write _ _ _ = return_unit

    method! with_lock f = f ()
  end

let load_client_context (cctxt : Protocol_client_context.full) =
  let open Lwt_result_syntax in
  let open Protocol_client_context in
  let* (b : Tezos_shell_services.Block_services.Proof.raw_context) =
    Alpha_block_services.Context.read
      cctxt
      ["active_delegate_with_one_roll"; "current"]
  in
  let rec get_pkhs (p : string -> Signature.Public_key_hash.t)
      (d : Tezos_shell_services.Block_services.Proof.raw_context) acc =
    match d with
    | Key _b -> assert false
    | Dir m ->
        String.Map.fold
          (function
            | "ed25519" ->
                get_pkhs (fun s ->
                    Signature.(
                      Ed25519 (Ed25519.Public_key_hash.of_hex_exn (`Hex s))))
            | "p256" ->
                get_pkhs (fun s ->
                    Signature.(P256 (P256.Public_key_hash.of_hex_exn (`Hex s))))
            | "secp256k1" ->
                get_pkhs (fun s ->
                    Signature.(
                      Secp256k1 (Secp256k1.Public_key_hash.of_hex_exn (`Hex s))))
            | s -> fun _v acc -> p s :: acc)
          m
          acc
    | _ -> assert false
  in
  let delegates = get_pkhs (fun _ -> assert false) b [] |> List.rev in
  let mk_unencrypted f x =
    Uri.of_string (Format.sprintf "unencrypted:%s" (f x))
  in
  let random_sk =
    let b = Bytes.create 32 in
    fun (pk : Signature.public_key) : Signature.secret_key ->
      let open Signature in
      let algo : algo =
        match pk with
        | Ed25519 _ -> Ed25519
        | Secp256k1 _ -> Secp256k1
        | P256 _ -> P256
        | _ -> assert false
      in
      let i = Random.bits () |> Int32.of_int in
      Bytes.set_int32_be b 0 i ;
      let _, _, sk = V_latest.generate_key ~algo ~seed:b () in
      sk
  in
  let* delegates =
    List.mapi_es
      (fun i pkh ->
        let alias = Format.sprintf "baker_%d" i in
        let* pk_opt =
          Alpha_services.Contract.manager_key cctxt (`Main, `Head 0) pkh
        in
        let pk = WithExceptions.Option.get ~loc:__LOC__ pk_opt in
        let pk_uri =
          WithExceptions.Result.get_ok ~loc:__LOC__
          @@ Client_keys.make_pk_uri
               (mk_unencrypted Signature.Public_key.to_b58check pk)
        in
        let sk_uri =
          WithExceptions.Result.get_ok ~loc:__LOC__
          @@ Client_keys.make_sk_uri
               (mk_unencrypted Signature.Secret_key.to_b58check (random_sk pk))
        in
        return (alias, pkh, pk, pk_uri, sk_uri))
      delegates
  in
  Client_keys.register_keys cctxt delegates

let get_delegates (cctxt : Protocol_client_context.full) =
  let proj_delegate (alias, public_key_hash, public_key, secret_key_uri) =
    {
      Baking_state.alias = Some alias;
      public_key_hash;
      public_key;
      secret_key_uri;
    }
  in
  let* keys = Client_keys.get_keys cctxt in
  let delegates = List.map proj_delegate keys in

  let* () =
    Tezos_signer_backends.Encrypted.decrypt_list
      cctxt
      (List.filter_map
         (function
           | {Baking_state.alias = Some alias; _} -> Some alias | _ -> None)
         delegates)
  in
  let delegates_no_duplicates = List.sort_uniq compare delegates in
  let*! () =
    if List.compare_lengths delegates delegates_no_duplicates <> 0 then
      cctxt#warning
        "Warning: the list of public key hash aliases contains duplicate \
         hashes, which are ignored"
    else Lwt.return ()
  in
  return delegates_no_duplicates

let get_current_proposal cctxt ?cache () =
  let* block_stream, block_stream_stopper =
    Node_rpc.monitor_heads cctxt ?cache ~chain:cctxt#chain ()
  in
  let*! stream_head = Lwt_stream.get block_stream in
  match stream_head with
  | Some current_head ->
      return (block_stream, current_head, block_stream_stopper)
  | None -> failwith "head stream unexpectedly ended"

let create_state cctxt ?synchronize ?monitor_node_mempool ~config
    ~current_proposal delegates =
  let open Lwt_result_syntax in
  let chain = cctxt#chain in
  let monitor_node_operations = monitor_node_mempool in
  let*! operation_worker =
    Operation_worker.create ?monitor_node_operations cctxt
  in
  Baking_scheduling.create_initial_state
    cctxt
    ?synchronize
    ~chain
    config
    operation_worker
    ~current_proposal
    delegates

let compute_current_round_duration round_durations
    ~(predecessor : Baking_state.block_info) round =
  let open Result_syntax in
  let* start =
    Round.timestamp_of_round
      round_durations
      ~predecessor_timestamp:predecessor.shell.timestamp
      ~predecessor_round:predecessor.round
      ~round
  in
  let start = Timestamp.to_seconds start in
  let* _end =
    Round.timestamp_of_round
      round_durations
      ~predecessor_timestamp:predecessor.shell.timestamp
      ~predecessor_round:predecessor.round
      ~round:(Round.succ round)
  in
  let _end = Timestamp.to_seconds _end in
  ok (Ptime.Span.of_int_s Int64.(sub _end start |> to_int))

let one_minute = Ptime.Span.of_int_s 60

let wait_next_block block_stream current_proposal =
  let open Baking_state in
  let open Lwt_syntax in
  Lwt.catch
    (fun () ->
      Lwt_unix.with_timeout 10. @@ fun () ->
      let* () =
        Lwt_stream.junk_while_s
          (fun proposal ->
            Lwt.return
              (Compare.Int32.(
                 current_proposal.block.shell.level = proposal.block.shell.level)
              && Round.(current_proposal.block.round = proposal.block.round)))
          block_stream
      in
      let* new_block_opt = Lwt_stream.get block_stream in
      WithExceptions.Option.get ~loc:__LOC__ new_block_opt |> Lwt.return)
    (function
      | Lwt_unix.Timeout ->
          Format.printf
            "Failed to receive expected block, continuing anyway...@." ;
          Lwt.return current_proposal
      | exn -> Lwt.fail exn)

let check_round_duration cctxt ?round_duration_target () =
  let open Lwt_result_syntax in
  let* param = Alpha_services.Constants.parametric cctxt (`Main, `Head 0) in
  match round_duration_target with
  | None ->
      let*? r =
        Period.mult 4l param.minimal_block_delay |> Environment.wrap_tzresult
      in
      let r = Period.to_seconds r |> Int64.to_int |> Ptime.Span.of_int_s in
      Format.printf "Default round duration target set to %a@." Ptime.Span.pp r ;
      return r
  | Some target ->
      let minimal_proto_period =
        Period.add param.delay_increment_per_round param.minimal_block_delay
        |> WithExceptions.Result.get_ok ~loc:__LOC__
      in
      let minimal_round_target =
        max 5L (Period.to_seconds minimal_proto_period) |> Int64.to_int
      in
      if target < minimal_round_target then
        failwith
          "Invalid round duration target, the minimal accepted round duration \
           target for this chain is %a"
          Ptime.Span.pp
          (Ptime.Span.of_int_s minimal_round_target)
      else return (Ptime.Span.of_int_s target)

let sync_node (cctxt : Client_context.full) ?round_duration_target () =
  let open Lwt_result_syntax in
  let*! () = Tezos_base_unix.Internal_event_unix.close () in
  let cctxt = new wrap_silent_memory_client cctxt in
  let* round_duration_target =
    check_round_duration cctxt ?round_duration_target ()
  in
  Format.printf "Loading faked delegate keys@." ;
  let* () = load_client_context cctxt in
  let* delegates = get_delegates cctxt in
  let* block_stream, current_proposal, stopper =
    get_current_proposal cctxt ()
  in
  let* is_pred_metadata_present =
    let*! r =
      Protocol_client_context.Alpha_block_services.metadata
        cctxt
        ~block:(`Hash (current_proposal.predecessor.hash, 0))
        ()
    in
    match r with Ok _protocols -> return_true | Error _err -> return_false
  in
  let* current_proposal =
    if not is_pred_metadata_present then (
      Format.printf
        "Predecessor's metadata are not present: baking a dummy block@." ;
      let* () =
        Baking_lib.bake cctxt ~minimal_timestamp:true ~force:true delegates
      in
      (* Waiting next block... *)
      let*! new_proposal = Lwt_stream.get block_stream in
      return (WithExceptions.Option.get ~loc:__LOC__ new_proposal))
    else return current_proposal
  in
  let config = Baking_configuration.make ~force:true () in
  let rec loop current_proposal =
    let* state = create_state cctxt ~config ~current_proposal delegates in
    let*? current_round_duration =
      Environment.wrap_tzresult
      @@ compute_current_round_duration
           state.global_state.round_durations
           ~predecessor:state.level_state.latest_proposal.predecessor
           state.round_state.current_round
    in
    Format.printf
      "Current head level: %ld, current head round: %a@."
      state.level_state.latest_proposal.block.shell.level
      Round.pp
      state.level_state.latest_proposal.block.round ;
    Format.printf
      "Current round %a. Duration: %a@."
      Round.pp
      state.round_state.current_round
      Ptime.Span.pp
      current_round_duration ;
    if Ptime.Span.(compare current_round_duration round_duration_target) > 0
    then (
      Format.printf
        "Current round duration is higher than %a, retrying...@."
        Ptime.Span.pp
        round_duration_target ;
      let pred_round =
        Result.value
          ~default:Round.zero
          (Round.pred state.round_state.current_round)
      in
      Format.printf "Proposing at previous round: %a@." Round.pp pred_round ;
      let* () =
        Baking_lib.repropose cctxt delegates ~force:true ~force_round:pred_round
      in
      let*! new_block = wait_next_block block_stream current_proposal in
      Format.printf "Baking at next level with minimal round@." ;
      let* () =
        Baking_lib.bake cctxt delegates ~force:true ~minimal_timestamp:true
      in
      let*! new_block = wait_next_block block_stream new_block in
      loop new_block)
    else (
      Format.printf
        "Current round duration is %a which is less than %a. Bakers may now be \
         started@."
        Ptime.Span.pp
        current_round_duration
        Ptime.Span.pp
        round_duration_target ;
      return_unit)
  in
  let* () = loop current_proposal in
  stopper () ;
  let*! () =
    Tezos_base_unix.Internal_event_unix.(
      init ~config:(make_with_defaults ()) ())
  in
  return_unit

(** Manager injector *)

module ManagerMap = Signature.Public_key_hash.Map
module ManagerSet = Signature.Public_key_hash.Set

type injected_operation = {
  original_hash : Operation_hash.t;
  modified_hash : Operation_hash.t;
}

type t = {
  last_injected_op_per_manager : injected_operation ManagerMap.t;
  operation_queues : (Operation_hash.t * packed_operation) Queue.t ManagerMap.t;
}

let pp_state fmt {last_injected_op_per_manager; operation_queues} =
  Format.fprintf
    fmt
    "%d injected operations pending, %d manager queues left"
    (ManagerMap.cardinal last_injected_op_per_manager)
    (ManagerMap.cardinal operation_queues)

let pp_initial_state fmt {operation_queues; _} =
  Format.(
    fprintf
      fmt
      "@[<v 2>%d manager queues:@ %a@]@."
      (ManagerMap.cardinal operation_queues)
      (pp_print_list ~pp_sep:pp_print_cut (fun fmt (manager, queue) ->
           Format.fprintf
             fmt
             "%a: %d"
             Signature.Public_key_hash.pp
             manager
             (Queue.length queue)))
      (ManagerMap.bindings operation_queues))

let init ~operations_file_path =
  Format.printf "Parsing operations file@." ;
  let op_encoding = Protocol.Alpha_context.Operation.encoding in
  let buffer = Bytes.create (10 * 1024 * 1024) (* 10mb *) in
  let*! ic = Lwt_io.open_file ~mode:Input operations_file_path in
  let rec loop acc =
    let*! op_len =
      Lwt.catch
        (fun () ->
          let*! op_len = Lwt_io.BE.read_int32 ic in
          let*! () =
            Lwt_io.read_into_exactly ic buffer 0 (Int32.to_int op_len)
          in
          Lwt.return_ok (`Op_len op_len))
        (function
          | End_of_file -> Lwt.return_ok `EOF
          | exn -> failwith "%s" (Printexc.to_string exn))
    in
    match op_len with
    | Error x -> Lwt.return_error x
    | Ok `EOF -> return (List.rev acc)
    | Ok (`Op_len op_len) ->
        let op =
          Data_encoding.Binary.of_bytes_exn
            op_encoding
            (Bytes.sub buffer 0 (Int32.to_int op_len))
        in
        loop (op :: acc)
  in
  let total = ref 0 in
  let* all_ops = loop [] in
  let*! () = Lwt_io.close ic in
  Format.printf "Loading operations file@." ;
  let rec loop
      (acc : (Operation_hash.t * packed_operation) Queue.t ManagerMap.t) :
      packed_operation list ->
      (Operation_hash.t * packed_operation) Queue.t ManagerMap.t = function
    | [] -> acc
    | ({
         protocol_data =
           Operation_data {contents = Single (Manager_operation {source; _}); _};
         _;
       } as op)
      :: r
    | ({
         protocol_data =
           Operation_data
             {contents = Cons (Manager_operation {source; _}, _); _};
         _;
       } as op)
      :: r ->
        incr total ;
        let oph = Operation.hash_packed op in
        let acc =
          ManagerMap.update
            source
            (function
              | None ->
                  let q = Queue.create () in
                  Queue.add (oph, op) q ;
                  Some q
              | Some q ->
                  Queue.add (oph, op) q ;
                  Some q)
            acc
        in
        loop acc r
    | _non_manager_op :: r -> loop acc r
  in
  let operation_queues = loop ManagerMap.empty all_ops in
  Format.printf "%d manager operations loaded@." !total ;
  return
    {
      last_injected_op_per_manager = Signature.Public_key_hash.Map.empty;
      operation_queues;
    }

let choose_new_operations state prohibited_managers n =
  (* Prioritize large operations queues *)
  let sorted_queues =
    ManagerMap.bindings state.operation_queues
    |> List.sort (fun (_, q) (_, q') ->
           Int.compare (Queue.length q') (Queue.length q))
  in
  let ops = ref [] in
  let cpt = ref 0 in
  let updated_operation_queues = ref state.operation_queues in
  let selected_ops =
    let exception End in
    try
      List.iter
        (fun (manager, op_q) ->
          if !cpt = n then raise End ;
          if not (ManagerSet.mem manager prohibited_managers) then
            match Queue.take_opt op_q with
            | Some op ->
                incr cpt ;
                ops := (manager, op) :: !ops
            | None ->
                updated_operation_queues :=
                  ManagerMap.remove manager !updated_operation_queues)
        sorted_queues ;
      !ops
    with End -> !ops
  in
  let state = {state with operation_queues = !updated_operation_queues} in
  (selected_ops, state)

let choose_and_inject_operations cctxt state prohibited_managers n =
  let* finalized_head = Shell_services.Blocks.hash cctxt ~block:(`Head 2) () in
  let cpt = ref 0 in
  let errors = ref 0 in
  let updated_state = ref state in
  let exception End in
  let* nb_injected, nb_erroneous, new_state =
    Lwt.catch
      (fun () ->
        let* () =
          ManagerMap.iter_es
            (fun manager op_q ->
              let* () = if !cpt = n then raise End else return_unit in
              if ManagerSet.mem manager prohibited_managers then return_unit
              else
                match Queue.take_opt op_q with
                | None ->
                    updated_state :=
                      {
                        !updated_state with
                        operation_queues =
                          ManagerMap.remove
                            manager
                            !updated_state.operation_queues;
                      } ;
                    return_unit
                | Some (original_hash, op) -> (
                    let modified_op =
                      {op with shell = {branch = finalized_head}}
                    in
                    let modified_hash = Operation.hash_packed modified_op in
                    let op = {modified_hash; original_hash} in
                    let*! injection_result =
                      Shell_services.Injection.operation
                        cctxt
                        (Data_encoding.Binary.to_bytes_exn
                           Operation.encoding
                           modified_op)
                    in
                    match injection_result with
                    | Ok _h ->
                        incr cpt ;
                        updated_state :=
                          {
                            !updated_state with
                            last_injected_op_per_manager =
                              ManagerMap.add
                                manager
                                op
                                !updated_state.last_injected_op_per_manager;
                          } ;
                        return_unit
                    | Error _err ->
                        incr errors ;
                        updated_state :=
                          {
                            !updated_state with
                            operation_queues =
                              ManagerMap.remove
                                manager
                                !updated_state.operation_queues;
                          } ;
                        return_unit))
            state.operation_queues
        in
        return (!cpt, !errors, !updated_state))
      (function
        | End -> return (!cpt, !errors, !updated_state) | exn -> Lwt.fail exn)
  in
  Format.printf
    "%d new manager operations injected, %d erroneous operation manager queues \
     discarded@."
    nb_injected
    nb_erroneous ;
  return (nb_injected, new_state)

let start_injector cctxt ~op_per_mempool ~operations_file_path =
  let* state = init ~operations_file_path in
  Format.printf "Starting injector@." ;
  let* head_stream, _stopper = Monitor_services.heads cctxt `Main in
  let block_stream =
    Lwt_stream.map_s
      (fun (bh, header) ->
        let*! opl =
          Protocol_client_context.Alpha_block_services.Operations
          .operations_in_pass
            cctxt
            ~metadata:`Always
            ~block:(`Hash (bh, 0))
            Operation_repr.manager_pass
        in
        let opl = WithExceptions.Result.get_ok ~loc:__LOC__ opl in
        Lwt.return (header, opl))
      head_stream
  in
  let*! current_head_opt = Lwt_stream.get block_stream in
  let ((header, _mopl) as _current_head) =
    WithExceptions.Option.get ~loc:__LOC__ current_head_opt
  in
  let current_level = header.shell.level in
  let rec loop state current_level =
    let*! r = Lwt_stream.get block_stream in
    match r with
    | None -> failwith "Head stream ended: lost connection with node?"
    | Some (header, _opll)
      when Compare.Int32.(header.shell.level <= current_level) ->
        (* reorg *)
        Format.printf "New head with non-increasing level: ignoring@." ;
        loop state current_level
    | Some (_header, mopl) as _new_head ->
        Format.printf
          "New increasing head received with %d included operations@."
          (List.length mopl) ;
        let* mempool =
          Protocol_client_context.Alpha_block_services.Mempool
          .pending_operations
            cctxt
            ~validated:true
            ~refused:false
            ~outdated:false
            ~branch_refused:false
            ~branch_delayed:false
            ~validation_passes:[Operation_repr.manager_pass]
            ()
        in
        let live_operations =
          Operation_hash.Set.(
            union
              (of_list
                 (List.map
                    fst
                    (Operation_hash.Map.bindings mempool.unprocessed)))
              (of_list (List.map fst mempool.validated)))
        in
        Format.printf
          "%d manager operations still live in the mempool@."
          (Operation_hash.Set.cardinal live_operations) ;
        let new_last_injected, prohibited_managers =
          let last_injected_op_per_manager =
            state.last_injected_op_per_manager
          in
          ManagerMap.fold
            (fun manager {modified_hash; _} (new_last_injected, acc) ->
              if Operation_hash.Set.mem modified_hash live_operations then
                (new_last_injected, ManagerSet.add manager acc)
              else (ManagerMap.remove manager new_last_injected, acc))
            last_injected_op_per_manager
            (last_injected_op_per_manager, ManagerSet.empty)
        in
        let state =
          {state with last_injected_op_per_manager = new_last_injected}
        in
        let nb_missing_operations =
          op_per_mempool
          - ManagerMap.cardinal state.last_injected_op_per_manager
        in
        Format.printf
          "Injecting %d new manager operations...@."
          nb_missing_operations ;
        let* nb_injected, state =
          choose_and_inject_operations
            cctxt
            state
            prohibited_managers
            nb_missing_operations
        in
        Format.printf "Current state: %a@." pp_state state ;
        (* Stop when there are not enough operations anymore to fill the mempool *)
        if nb_injected < nb_missing_operations then (
          Format.printf
            "Not enough operations left to fill the mempool up to %d. \
             Terminating.@."
            op_per_mempool ;
          return_unit)
        else loop state header.shell.level
  in
  loop state current_level

module Tool : Sigs.PROTO_TOOL = struct
  let sync_node = sync_node

  let start_injector = start_injector
end

let () = Sigs.register Protocol.hash (module Tool)