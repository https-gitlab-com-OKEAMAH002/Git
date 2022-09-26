(*****************************************************************************)
(*                                                                           *)
(* Open Source License                                                       *)
(* Copyright (c) 2018 Dynamic Ledger Solutions, Inc. <contact@tezos.com>     *)
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

type chain_status =
  | Active_main of Tezos_crypto.Chain_id.t
  | Active_test of {
      chain : Tezos_crypto.Chain_id.t;
      protocol : Tezos_crypto.Protocol_hash.t;
      expiration_date : Time.Protocol.t;
    }
  | Stopping of Tezos_crypto.Chain_id.t

let chain_status_encoding =
  let open Data_encoding in
  union
    ~tag_size:`Uint8
    [
      case
        (Tag 0)
        ~title:"Main"
        (obj1 (req "chain_id" Tezos_crypto.Chain_id.encoding))
        (function Active_main chain_id -> Some chain_id | _ -> None)
        (fun chain_id -> Active_main chain_id);
      case
        (Tag 1)
        ~title:"Test"
        (obj3
           (req "chain_id" Tezos_crypto.Chain_id.encoding)
           (req "test_protocol" Tezos_crypto.Protocol_hash.encoding)
           (req "expiration_date" Time.Protocol.encoding))
        (function
          | Active_test {chain; protocol; expiration_date} ->
              Some (chain, protocol, expiration_date)
          | _ -> None)
        (fun (chain, protocol, expiration_date) ->
          Active_test {chain; protocol; expiration_date});
      case
        (Tag 2)
        ~title:"Stopping"
        (obj1 (req "stopping" Tezos_crypto.Chain_id.encoding))
        (function Stopping chain_id -> Some chain_id | _ -> None)
        (fun chain_id -> Stopping chain_id);
    ]

module S = struct
  open Data_encoding

  let path = Tezos_rpc.Path.(root / "monitor")

  let bootstrapped =
    Tezos_rpc.Service.get_service
      ~description:
        "Wait for the node to have synchronized its chain with a few peers \
         (configured by the node's administrator), streaming head updates that \
         happen during the bootstrapping process, and closing the stream at \
         the end. If the node was already bootstrapped, returns the current \
         head immediately."
      ~query:Tezos_rpc.Query.empty
      ~output:
        (obj2
           (req "block" Tezos_crypto.Block_hash.encoding)
           (req "timestamp" Time.Protocol.encoding))
      Tezos_rpc.Path.(path / "bootstrapped")

  let valid_blocks_query =
    let open Tezos_rpc.Query in
    query (fun protocols next_protocols chains ->
        object
          method protocols = protocols

          method next_protocols = next_protocols

          method chains = chains
        end)
    |+ multi_field "protocol" Tezos_crypto.Protocol_hash.rpc_arg (fun t ->
           t#protocols)
    |+ multi_field "next_protocol" Tezos_crypto.Protocol_hash.rpc_arg (fun t ->
           t#next_protocols)
    |+ multi_field "chain" Chain_services.chain_arg (fun t -> t#chains)
    |> seal

  let valid_blocks =
    Tezos_rpc.Service.get_service
      ~description:
        "Monitor all blocks that are successfully validated by the node, \
         disregarding whether they were selected as the new head or not."
      ~query:valid_blocks_query
      ~output:
        (merge_objs
           (obj2
              (req "chain_id" Tezos_crypto.Chain_id.encoding)
              (req "hash" Tezos_crypto.Block_hash.encoding))
           Block_header.encoding)
      Tezos_rpc.Path.(path / "valid_blocks")

  let heads_query =
    let open Tezos_rpc.Query in
    query (fun next_protocols ->
        object
          method next_protocols = next_protocols
        end)
    |+ multi_field "next_protocol" Tezos_crypto.Protocol_hash.rpc_arg (fun t ->
           t#next_protocols)
    |> seal

  let heads =
    Tezos_rpc.Service.get_service
      ~description:
        "Monitor all blocks that are successfully validated by the node and \
         selected as the new head of the given chain."
      ~query:heads_query
      ~output:
        (merge_objs
           (obj1 (req "hash" Tezos_crypto.Block_hash.encoding))
           Block_header.encoding)
      Tezos_rpc.Path.(path / "heads" /: Chain_services.chain_arg)

  let protocols =
    Tezos_rpc.Service.get_service
      ~description:
        "Monitor all economic protocols that are retrieved and successfully \
         loaded and compiled by the node."
      ~query:Tezos_rpc.Query.empty
      ~output:Tezos_crypto.Protocol_hash.encoding
      Tezos_rpc.Path.(path / "protocols")

  (* DEPRECATED: use [version] from "version_services" instead. *)
  let commit_hash =
    Tezos_rpc.Service.get_service
      ~description:"DEPRECATED: use `version` instead."
      ~query:Tezos_rpc.Query.empty
      ~output:string
      Tezos_rpc.Path.(path / "commit_hash")

  let active_chains =
    Tezos_rpc.Service.get_service
      ~description:
        "Monitor every chain creation and destruction. Currently active chains \
         will be given as first elements"
      ~query:Tezos_rpc.Query.empty
      ~output:(Data_encoding.list chain_status_encoding)
      Tezos_rpc.Path.(path / "active_chains")
end

open Tezos_rpc.Context

let bootstrapped ctxt = make_streamed_call S.bootstrapped ctxt () () ()

let valid_blocks ctxt ?(chains = [`Main]) ?(protocols = [])
    ?(next_protocols = []) () =
  make_streamed_call
    S.valid_blocks
    ctxt
    ()
    (object
       method chains = chains

       method protocols = protocols

       method next_protocols = next_protocols
    end)
    ()

let heads ctxt ?(next_protocols = []) chain =
  make_streamed_call
    S.heads
    ctxt
    ((), chain)
    (object
       method next_protocols = next_protocols
    end)
    ()

let protocols ctxt = make_streamed_call S.protocols ctxt () () ()

let commit_hash ctxt = make_call S.commit_hash ctxt () () ()

let active_chains ctxt = make_streamed_call S.active_chains ctxt () () ()
