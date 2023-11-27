(*****************************************************************************)
(*                                                                           *)
(* SPDX-License-Identifier: MIT                                              *)
(* Copyright (c) 2023 Nomadic Labs <contact@nomadic-labs.com>                *)
(*                                                                           *)
(*****************************************************************************)

(** [create transactions] creates a sequencer blueprint containing
    [transactions]. Returns the inputs to put in the inbox. *)
val create : transactions:string list -> string list