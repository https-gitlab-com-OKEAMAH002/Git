(*****************************************************************************)
(*                                                                           *)
(* Open Source License                                                       *)
(* Copyright (c) 2022 Nomadic Labs, <contact@nomadic-labs.com>               *)
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

open Batcher_worker_types
module Message_queue = Hash_queue.Make (L2_message.Hash) (L2_message)

module Batcher_events = Batcher_events.Declare (struct
  let worker_name = "batcher"
end)

module L2_batched_message = struct
  type t = {content : string; l1_hash : Injector.Inj_operation.hash}
end

module Batched_messages = Hash_queue.Make (L2_message.Hash) (L2_batched_message)

type status = Pending_batch | Batched of Injector.Inj_operation.hash

type state = {
  node_ctxt : Node_context.ro;
  signer : Signature.public_key_hash;
  conf : Configuration.batcher;
  messages : Message_queue.t;
  batched : Batched_messages.t;
  mutable simulation_ctxt : Simulation.t option;
  mutable plugin : (module Protocol_plugin_sig.S);
}

let message_size s =
  (* Encoded as length of s on 4 bytes + s *)
  4 + String.length s

let inject_batch state (l2_messages : L2_message.t list) =
  let open Lwt_result_syntax in
  let messages = List.map L2_message.content l2_messages in
  let operation = L1_operation.Add_messages {messages} in
  let* l1_hash =
    Injector.check_and_add_pending_operation
      state.node_ctxt.config.mode
      ~source:state.signer
      operation
  in
  let+ l1_hash =
    match l1_hash with
    | Some l1_hash -> return l1_hash
    | None ->
        let op = Injector.Inj_operation.make operation in
        return op.hash
  in
  List.iter
    (fun msg ->
      let content = L2_message.content msg in
      let hash = L2_message.hash msg in
      Batched_messages.replace state.batched hash {content; l1_hash})
    l2_messages

let inject_batches state = List.iter_es (inject_batch state)

let max_batch_size {conf; plugin; _} =
  let module Plugin = (val plugin) in
  Option.value
    conf.max_batch_size
    ~default:Plugin.Batcher_constants.protocol_max_batch_size

let get_batches state ~only_full =
  let ( current_rev_batch,
        current_batch_size,
        current_batch_elements,
        full_batches ) =
    Message_queue.fold
      (fun msg_hash
           message
           ( current_rev_batch,
             current_batch_size,
             current_batch_elements,
             full_batches ) ->
        let size = message_size (L2_message.content message) in
        let new_batch_size = current_batch_size + size in
        let new_batch_elements = current_batch_elements + 1 in
        if
          new_batch_size <= max_batch_size state
          && new_batch_elements <= state.conf.max_batch_elements
        then
          (* We can add the message to the current batch because we are still
             within the bounds. *)
          ( (msg_hash, message) :: current_rev_batch,
            new_batch_size,
            new_batch_elements,
            full_batches )
        else
          (* The batch augmented with the message would be too big but it is
             below the limit without it. We finalize the current batch and
             create a new one for the message. NOTE: Messages in the queue are
             always < [state.conf.max_batch_size] because {!on_register} only
             accepts those. *)
          let batch = List.rev current_rev_batch in
          ([(msg_hash, message)], size, 1, batch :: full_batches))
      state.messages
      ([], 0, 0, [])
  in
  let batches =
    if
      (not only_full)
      || current_batch_size >= state.conf.min_batch_size
         && current_batch_elements >= state.conf.min_batch_elements
    then
      (* We have enough to make a batch with the last non-full batch. *)
      List.rev current_rev_batch :: full_batches
    else full_batches
  in
  List.fold_left
    (fun (batches, to_remove) -> function
      | [] -> (batches, to_remove)
      | batch ->
          let msg_hashes, batch = List.split batch in
          let to_remove = List.rev_append msg_hashes to_remove in
          (batch :: batches, to_remove))
    ([], [])
    batches

let produce_batches state ~only_full =
  let open Lwt_result_syntax in
  let batches, to_remove = get_batches state ~only_full in
  match batches with
  | [] -> return_unit
  | _ ->
      let* () = inject_batches state batches in
      let*! () =
        Batcher_events.(emit batched)
          (List.length batches, List.length to_remove)
      in
      List.iter
        (fun tr_hash -> Message_queue.remove state.messages tr_hash)
        to_remove ;
      return_unit

let simulate state simulation_ctxt (messages : L2_message.t list) =
  let open Lwt_result_syntax in
  let module Plugin = (val state.plugin) in
  let*? ext_messages =
    List.map_e
      (fun m -> Plugin.Inbox.serialize_external_message (L2_message.content m))
      messages
  in
  let+ simulation_ctxt, _ticks =
    Simulation.simulate_messages simulation_ctxt ext_messages
  in
  simulation_ctxt

let on_register state (messages : string list) =
  let open Lwt_result_syntax in
  let module Plugin = (val state.plugin) in
  let max_size_msg =
    min
      (Plugin.Batcher_constants.message_size_limit
     + 4 (* We add 4 because [message_size] adds 4. *))
      (max_batch_size state)
  in
  let*? messages =
    List.mapi_e
      (fun i message ->
        if message_size message > max_size_msg then
          error_with "Message %d is too large (max size is %d)" i max_size_msg
        else Ok (L2_message.make message))
      messages
  in
  let* () =
    if not state.conf.simulate then return_unit
    else
      match state.simulation_ctxt with
      | None -> failwith "Simulation context of batcher not initialized"
      | Some simulation_ctxt ->
          let+ simulation_ctxt = simulate state simulation_ctxt messages in
          state.simulation_ctxt <- Some simulation_ctxt
  in
  let*! () = Batcher_events.(emit queue) (List.length messages) in
  let hashes =
    List.map
      (fun message ->
        let msg_hash = L2_message.hash message in
        Message_queue.replace state.messages msg_hash message ;
        msg_hash)
      messages
  in
  let+ () = produce_batches state ~only_full:true in
  hashes

let on_new_head state head =
  let open Lwt_result_syntax in
  (* Produce batches first *)
  let* () = produce_batches state ~only_full:false in
  let* simulation_ctxt =
    Simulation.start_simulation ~reveal_map:None state.node_ctxt head
  in
  (* TODO: https://gitlab.com/tezos/tezos/-/issues/4224
     Replay with simulation may be too expensive *)
  let+ simulation_ctxt, failing =
    if not state.conf.simulate then return (simulation_ctxt, [])
    else
      (* Re-simulate one by one *)
      Message_queue.fold_es
        (fun msg_hash msg (simulation_ctxt, failing) ->
          let*! result = simulate state simulation_ctxt [msg] in
          match result with
          | Ok simulation_ctxt -> return (simulation_ctxt, failing)
          | Error _ -> return (simulation_ctxt, msg_hash :: failing))
        state.messages
        (simulation_ctxt, [])
  in
  state.simulation_ctxt <- Some simulation_ctxt ;
  (* Forget failing messages *)
  List.iter (Message_queue.remove state.messages) failing

let init_batcher_state plugin node_ctxt ~signer (conf : Configuration.batcher) =
  {
    node_ctxt;
    signer;
    conf;
    messages = Message_queue.create 100_000 (* ~ 400MB *);
    batched = Batched_messages.create 100_000 (* ~ 400MB *);
    simulation_ctxt = None;
    plugin;
  }

module Types = struct
  type nonrec state = state

  type parameters = {
    node_ctxt : Node_context.ro;
    plugin : (module Protocol_plugin_sig.S);
    signer : Signature.public_key_hash;
    conf : Configuration.batcher;
  }
end

module Name = struct
  (* We only have a single batcher in the node *)
  type t = unit

  let encoding = Data_encoding.unit

  let base = Batcher_events.Worker.section @ ["worker"]

  let pp _ _ = ()

  let equal () () = true
end

module Worker = Worker.MakeSingle (Name) (Request) (Types)

type worker = Worker.infinite Worker.queue Worker.t

module Handlers = struct
  type self = worker

  let on_request :
      type r request_error.
      worker -> (r, request_error) Request.t -> (r, request_error) result Lwt.t
      =
   fun w request ->
    let state = Worker.state w in
    match request with
    | Request.Register messages ->
        protect @@ fun () -> on_register state messages
    | Request.New_head head -> protect @@ fun () -> on_new_head state head

  type launch_error = error trace

  let on_launch _w () Types.{node_ctxt; plugin; signer; conf} =
    let open Lwt_result_syntax in
    let state = init_batcher_state plugin node_ctxt ~signer conf in
    return state

  let on_error (type a b) _w st (r : (a, b) Request.t) (errs : b) :
      unit tzresult Lwt.t =
    let open Lwt_result_syntax in
    let request_view = Request.view r in
    let emit_and_return_errors errs =
      let*! () =
        Batcher_events.(emit Worker.request_failed) (request_view, st, errs)
      in
      return_unit
    in
    match r with
    | Request.Register _ -> emit_and_return_errors errs
    | Request.New_head _ -> emit_and_return_errors errs

  let on_completion _w r _ st =
    match Request.view r with
    | Request.View (Register _ | New_head _) ->
        Batcher_events.(emit Worker.request_completed_debug) (Request.view r, st)

  let on_no_request _ = Lwt.return_unit

  let on_close _w = Lwt.return_unit
end

let table = Worker.create_table Queue

let worker_promise, worker_waker = Lwt.task ()

let check_batcher_config (module Plugin : Protocol_plugin_sig.S)
    Configuration.{max_batch_size; _} =
  match max_batch_size with
  | Some m when m > Plugin.Batcher_constants.protocol_max_batch_size ->
      error_with
        "batcher.max_batch_size must be smaller than %d"
        Plugin.Batcher_constants.protocol_max_batch_size
  | _ -> Ok ()

let start plugin conf ~signer node_ctxt =
  let open Lwt_result_syntax in
  let*? () = check_batcher_config plugin conf in
  let node_ctxt = Node_context.readonly node_ctxt in
  let+ worker =
    Worker.launch table () {node_ctxt; plugin; signer; conf} (module Handlers)
  in
  Lwt.wakeup worker_waker worker

let init plugin conf ~signer node_ctxt =
  let open Lwt_result_syntax in
  match Lwt.state worker_promise with
  | Lwt.Return _ ->
      (* Worker already started, nothing to do. *)
      return_unit
  | Lwt.Fail exn ->
      (* Worker crashed, not recoverable. *)
      fail [Rollup_node_errors.No_batcher; Exn exn]
  | Lwt.Sleep ->
      (* Never started, start it. *)
      start plugin conf ~signer node_ctxt

(* This is a batcher worker for a single scoru *)
let worker =
  lazy
    (match Lwt.state worker_promise with
    | Lwt.Return worker -> Ok worker
    | Lwt.Fail _ | Lwt.Sleep ->
        Error (TzTrace.make Rollup_node_errors.No_batcher))

let active () =
  match Lwt.state worker_promise with
  | Lwt.Return _ -> true
  | Lwt.Fail _ | Lwt.Sleep -> false

let find_message hash =
  let open Result_syntax in
  let+ w = Lazy.force worker in
  let state = Worker.state w in
  Message_queue.find_opt state.messages hash

let get_queue () =
  let open Result_syntax in
  let+ w = Lazy.force worker in
  let state = Worker.state w in
  Message_queue.bindings state.messages

let handle_request_error rq =
  let open Lwt_syntax in
  let* rq in
  match rq with
  | Ok res -> return_ok res
  | Error (Worker.Request_error errs) -> Lwt.return_error errs
  | Error (Closed None) -> Lwt.return_error [Worker_types.Terminated]
  | Error (Closed (Some errs)) -> Lwt.return_error errs
  | Error (Any exn) -> Lwt.return_error [Exn exn]

let register_messages messages =
  let open Lwt_result_syntax in
  let*? w = Lazy.force worker in
  Worker.Queue.push_request_and_wait w (Request.Register messages)
  |> handle_request_error

let new_head b =
  let open Lwt_result_syntax in
  let w = Lazy.force worker in
  match w with
  | Error _ ->
      (* There is no batcher, nothing to do *)
      return_unit
  | Ok w ->
      Worker.Queue.push_request_and_wait w (Request.New_head b)
      |> handle_request_error

let shutdown () =
  let w = Lazy.force worker in
  match w with
  | Error _ ->
      (* There is no batcher, nothing to do *)
      Lwt.return_unit
  | Ok w -> Worker.shutdown w

let message_status state msg_hash =
  match Message_queue.find_opt state.messages msg_hash with
  | Some msg -> Some (Pending_batch, L2_message.content msg)
  | None -> (
      match Batched_messages.find_opt state.batched msg_hash with
      | Some {content; l1_hash} -> Some (Batched l1_hash, content)
      | None -> None)

let message_status msg_hash =
  let open Result_syntax in
  let+ w = Lazy.force worker in
  let state = Worker.state w in
  message_status state msg_hash
