(*****************************************************************************)
(*                                                                           *)
(* Open Source License                                                       *)
(* Copyright (c) 2023 Nomadic Labs <contact@nomadic-labs.com>                *)
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

open Ethereum_types

(** [chunks bytes size] returns [Bytes.length bytes / size] chunks of size
    [size]. *)
let chunks bytes size =
  let n = Bytes.length bytes in
  assert (n mod size = 0) ;
  let nb = n / size in
  let rec collect i acc =
    if i = nb then acc
    else
      let chunk = Bytes.sub_string bytes (i * size) size in
      collect (i + 1) (chunk :: acc)
  in
  collect 0 [] |> List.rev

module Durable_storage_path = struct
  let accounts = "/eth_accounts"

  let balance = "/balance"

  let nonce = "/nonce"

  let account_path (Address s) = accounts ^ "/" ^ s

  let balance_path address = account_path address ^ balance

  let nonce_path address = account_path address ^ nonce

  let number = "/number"

  let transactions = "/transactions"

  module Block = struct
    let blocks = "/evm/blocks"

    type number = Current | Nth of Z.t

    let number_to_string = function
      | Current -> "current"
      | Nth i -> Z.to_string i

    let transactions block_number =
      blocks ^ "/" ^ number_to_string block_number ^ transactions

    let current_number = blocks ^ "/current" ^ number
  end
end

module RPC = struct
  open Tezos_rpc
  open Path

  let smart_rollup_address =
    Service.get_service
      ~description:"Smart rollup address"
      ~query:Query.empty
      ~output:(Data_encoding.Fixed.bytes 20)
      (open_root / "global" / "smart_rollup_address")

  type state_value_query = {key : string}

  let state_value_query : state_value_query Tezos_rpc.Query.t =
    let open Tezos_rpc.Query in
    query (fun key -> {key})
    |+ field "key" Tezos_rpc.Arg.string "" (fun t -> t.key)
    |> seal

  let durable_state_value =
    Tezos_rpc.Service.get_service
      ~description:
        "Retrieve value by key from PVM durable storage. PVM state is taken \
         with respect to the specified block level. Value returned in hex \
         format."
      ~query:state_value_query
      ~output:Data_encoding.(option bytes)
      (open_root / "global" / "block" / "head" / "durable" / "wasm_2_0_0"
     / "value")

  let batcher_injection =
    Tezos_rpc.Service.post_service
      ~description:"Inject messages in the batcher's queue"
      ~query:Tezos_rpc.Query.empty
      ~input:
        Data_encoding.(
          def "messages" ~description:"Messages to inject" (list string))
      ~output:
        Data_encoding.(
          def
            "message_hashes"
            ~description:"Hashes of injected L2 messages"
            (list string))
      (open_root / "local" / "batcher" / "injection")

  let call_service ~base ?(media_types = Media_type.all_media_types) =
    Tezos_rpc_http_client_unix.RPC_client_unix.call_service media_types ~base

  let smart_rollup_address base =
    let open Lwt_result_syntax in
    let*! answer =
      call_service
        ~base
        ~media_types:[Media_type.octet_stream]
        smart_rollup_address
        ()
        ()
        ()
    in
    match answer with
    | Ok address -> return (Bytes.to_string address)
    | Error tztrace ->
        failwith
          "Failed to communicate with %a, because %a"
          Uri.pp
          base
          pp_print_trace
          tztrace

  let balance base address =
    let open Lwt_result_syntax in
    let key = Durable_storage_path.balance_path address in
    let+ answer = call_service ~base durable_state_value () {key} () in
    match answer with
    | Some bytes ->
        Bytes.to_string bytes |> Z.of_bits |> Ethereum_types.quantity_of_z
    | None -> Ethereum_types.Qty Z.zero

  let nonce base address =
    let open Lwt_result_syntax in
    let key = Durable_storage_path.nonce_path address in
    let+ answer = call_service ~base durable_state_value () {key} () in
    match answer with
    | Some bytes ->
        Bytes.to_string bytes |> Z.of_bits |> Ethereum_types.quantity_of_z
    | None -> Ethereum_types.Qty Z.zero

  let inject_raw_transaction base tx =
    let open Lwt_result_syntax in
    let tx = Hex.of_string tx |> Hex.show in
    (* The injection's service returns a notion of L2 message hash (defined
       by the rollup node) used to track the message's injection in the batcher.
       We do not wish to follow the message's inclusion, and thus, ignore
       the resulted hash. *)
    let* _answer = call_service ~base batcher_injection () () [tx] in
    return_unit

  exception Invalid_block_structure of string

  let block_number base n =
    let open Lwt_result_syntax in
    match n with
    (* This avoids an unecessary service call in case we ask a block's number
       with an already expected/known block number [n]. *)
    | Durable_storage_path.Block.Nth i ->
        return @@ Ethereum_types.Block_height i
    | Durable_storage_path.Block.Current -> (
        let key = Durable_storage_path.Block.current_number in
        let+ answer = call_service ~base durable_state_value () {key} () in
        match answer with
        | Some bytes ->
            Ethereum_types.Block_height (Bytes.to_string bytes |> Z.of_bits)
        | None ->
            raise
            @@ Invalid_block_structure
                 "Unexpected [None] value for [current_number]'s [answer]")

  let transactions ~full_transaction_object ~number base =
    let open Lwt_result_syntax in
    if full_transaction_object then
      failwith "Full transaction objects are not supported yet"
    else
      let key_transactions = Durable_storage_path.Block.transactions number in
      let+ transactions_answer =
        call_service ~base durable_state_value () {key = key_transactions} ()
      in
      match transactions_answer with
      | Some bytes ->
          let chunks = chunks bytes Ethereum_types.transaction_hash_size in
          List.map (fun bytes -> Hash Hex.(of_string bytes |> show)) chunks
      | None ->
          raise
          @@ Invalid_block_structure
               "Unexpected [None] value for [block.transactions]"

  let block ~full_transaction_object ~number base =
    let open Lwt_result_syntax in
    let* transactions = transactions ~full_transaction_object ~number base in
    let* number = block_number base number in
    return
      {
        number = Some number;
        hash = Some (Ethereum_types.Block_hash "");
        parent = Ethereum_types.Block_hash "";
        nonce = Ethereum_types.Hash "";
        sha3Uncles = Ethereum_types.Hash "";
        logsBloom = None;
        transactionRoot = Ethereum_types.Hash "";
        stateRoot = Ethereum_types.Hash "";
        receiptRoot = Ethereum_types.Hash "";
        (* We need the following dummy value otherwise eth-cli will complain
           that miner's address is not a valid Ethereum address. *)
        miner = Ethereum_types.Hash "6471A723296395CF1Dcc568941AFFd7A390f94CE";
        difficulty = Ethereum_types.Qty Z.zero;
        totalDifficulty = Ethereum_types.Qty Z.zero;
        extraData = "";
        size = Ethereum_types.Qty Z.zero;
        gasLimit = Ethereum_types.Qty Z.zero;
        gasUsed = Ethereum_types.Qty Z.zero;
        timestamp = Ethereum_types.Qty Z.zero;
        transactions;
        uncles = [];
      }

  let current_block base ~full_transaction_object =
    block
      ~full_transaction_object
      ~number:Durable_storage_path.Block.Current
      base

  let current_block_number base () =
    block_number base Durable_storage_path.Block.Current

  let nth_block base ~full_transaction_object n =
    block
      ~full_transaction_object
      ~number:Durable_storage_path.Block.(Nth n)
      base
end

module type S = sig
  val smart_rollup_address : string tzresult Lwt.t

  val balance : Ethereum_types.address -> Ethereum_types.quantity tzresult Lwt.t

  val nonce : Ethereum_types.address -> Ethereum_types.quantity tzresult Lwt.t

  val inject_raw_transaction : string -> unit tzresult Lwt.t

  val current_block :
    full_transaction_object:bool -> Ethereum_types.block tzresult Lwt.t

  val current_block_number : unit -> Ethereum_types.block_height tzresult Lwt.t

  val nth_block :
    full_transaction_object:bool -> Z.t -> Ethereum_types.block tzresult Lwt.t
end

module Make (Base : sig
  val base : Uri.t
end) : S = struct
  let smart_rollup_address = RPC.smart_rollup_address Base.base

  let balance = RPC.balance Base.base

  let nonce = RPC.nonce Base.base

  let inject_raw_transaction = RPC.inject_raw_transaction Base.base

  let current_block = RPC.current_block Base.base

  let current_block_number = RPC.current_block_number Base.base

  let nth_block = RPC.nth_block Base.base
end
