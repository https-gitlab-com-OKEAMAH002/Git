(* Do not edit this file manually.
   This file was automatically generated from benchmark models
   If you wish to update a function in this file,
   a. update the corresponding model, or
   b. move the function to another module and edit it there. *)

[@@@warning "-33"]

module S = Saturation_repr
open S.Syntax

(* model carbonated_map/compare_int *)
(* 2.18333333333 *)
let cost_compare_int = S.safe_int 5

(* model carbonated_map/find *)
(* fun size -> (50. + ((log2 size) * 2.18333333333)) + ((log2 size) * 2.) *)
let cost_find size =
  let size = S.safe_int size in
  let w1 = log2 size in
  (w1 * S.safe_int 4) + (w1 lsr 3) + (w1 lsr 4) + S.safe_int 50

(* model carbonated_map/find_intercept *)
(* 50. *)
let cost_find_intercept = S.safe_int 50

(* model carbonated_map/fold *)
(* fun size -> 50. + (24. * size) *)
let cost_fold size =
  let size = S.safe_int size in
  (size * S.safe_int 24) + S.safe_int 50