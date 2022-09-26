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

open Tezos_rpc.Context

type chain_status =
  | Active_main of Tezos_crypto.Chain_id.t
  | Active_test of {
      chain : Tezos_crypto.Chain_id.t;
      protocol : Tezos_crypto.Protocol_hash.t;
      expiration_date : Time.Protocol.t;
    }
  | Stopping of Tezos_crypto.Chain_id.t

val bootstrapped :
  #streamed ->
  ((Tezos_crypto.Block_hash.t * Time.Protocol.t) Lwt_stream.t * stopper)
  tzresult
  Lwt.t

val valid_blocks :
  #streamed ->
  ?chains:Chain_services.chain list ->
  ?protocols:Tezos_crypto.Protocol_hash.t list ->
  ?next_protocols:Tezos_crypto.Protocol_hash.t list ->
  unit ->
  (((Tezos_crypto.Chain_id.t * Tezos_crypto.Block_hash.t) * Block_header.t)
   Lwt_stream.t
  * stopper)
  tzresult
  Lwt.t

val heads :
  #streamed ->
  ?next_protocols:Tezos_crypto.Protocol_hash.t list ->
  Chain_services.chain ->
  ((Tezos_crypto.Block_hash.t * Block_header.t) Lwt_stream.t * stopper) tzresult
  Lwt.t

val protocols :
  #streamed ->
  (Tezos_crypto.Protocol_hash.t Lwt_stream.t * stopper) tzresult Lwt.t

val commit_hash : #simple -> string tzresult Lwt.t

val active_chains :
  #streamed -> (chain_status list Lwt_stream.t * stopper) tzresult Lwt.t

module S : sig
  val bootstrapped :
    ( [`GET],
      unit,
      unit,
      unit,
      unit,
      Tezos_crypto.Block_hash.t * Time.Protocol.t )
    Tezos_rpc.Service.t

  val valid_blocks :
    ( [`GET],
      unit,
      unit,
      < chains : Chain_services.chain list
      ; next_protocols : Tezos_crypto.Protocol_hash.t list
      ; protocols : Tezos_crypto.Protocol_hash.t list >,
      unit,
      (Tezos_crypto.Chain_id.t * Tezos_crypto.Block_hash.t) * Block_header.t )
    Tezos_rpc.Service.t

  val heads :
    ( [`GET],
      unit,
      unit * Chain_services.chain,
      < next_protocols : Tezos_crypto.Protocol_hash.t list >,
      unit,
      Tezos_crypto.Block_hash.t * Block_header.t )
    Tezos_rpc.Service.t

  val protocols :
    ( [`GET],
      unit,
      unit,
      unit,
      unit,
      Tezos_crypto.Protocol_hash.t )
    Tezos_rpc.Service.t

  val commit_hash : ([`GET], unit, unit, unit, unit, string) Tezos_rpc.Service.t

  val active_chains :
    ([`GET], unit, unit, unit, unit, chain_status list) Tezos_rpc.Service.t
end
