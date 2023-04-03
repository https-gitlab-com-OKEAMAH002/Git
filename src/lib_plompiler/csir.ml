(*****************************************************************************)
(*                                                                           *)
(* MIT License                                                               *)
(* Copyright (c) 2022 Nomadic Labs <contact@nomadic-labs.com>                *)
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

let nb_wires_arch = 5

module Scalar = struct
  include Bls12_381.Fr

  type scalar = t

  let mone = negate one

  let string_of_scalar x =
    if eq x (of_string "-1") then "-1"
    else if eq x (of_string "-2") then "-2"
    else
      let s = to_string x in
      if String.length s > 3 then "h" ^ string_of_int (Z.hash (to_z x)) else s

  let equal a b = Bytes.equal (to_bytes a) (to_bytes b)

  (* TODO https://gitlab.com/nomadic-labs/privacy-team/-/issues/183
     Duplicated in plonk/bls.ml *)
  let t : t Repr.t =
    Repr.(map (bytes_of (`Fixed size_in_bytes)) of_bytes_exn to_bytes)
end

(* If multiple tables are used, they all need to have the same number of wires,
   so any smaller one will be padded. *)
module Table : sig
  type t [@@deriving repr]

  val empty : t

  val size : t -> int

  type entry = {
    a : Scalar.t;
    b : Scalar.t;
    c : Scalar.t;
    d : Scalar.t;
    e : Scalar.t;
  }

  type partial_entry = {
    a : Scalar.t option;
    b : Scalar.t option;
    c : Scalar.t option;
    d : Scalar.t option;
    e : Scalar.t option;
  }

  val mem : entry -> t -> bool

  val find : partial_entry -> t -> entry option

  val to_list : t -> Scalar.t array list

  val of_list : Scalar.t array list -> t
end = struct
  (* Rows are variables, columns are entries in the table.
     If the table is full it would be |domain|^#variables e.g. 2^5=32
     Example OR gate:
     [
       [|0; 0; 1; 1|] ;
       [|0; 1; 0; 1|] ;
       [|0; 1; 1; 1|] ;
       [|0; 0; 0; 0|] ;
       [|0; 0; 0; 0|] ;
     ]
  *)
  type entry = {
    a : Scalar.t;
    b : Scalar.t;
    c : Scalar.t;
    d : Scalar.t;
    e : Scalar.t;
  }

  type partial_entry = {
    a : Scalar.t option;
    b : Scalar.t option;
    c : Scalar.t option;
    d : Scalar.t option;
    e : Scalar.t option;
  }

  type t = Scalar.t array array [@@deriving repr]

  let empty = [||]

  let size table = Array.length table.(0)

  (* Function returning the first table corresponding to the input partial entry.
     A partial entry is found on the table at row i if it coincides
     with the table values in all specified (i.e., not None) columns *)
  let find_entry_i : partial_entry -> t -> int -> entry option =
   fun pe table i ->
    let match_partial_entry o s =
      Option.(value ~default:true @@ map (Scalar.eq s) o)
    in
    if
      match_partial_entry pe.a table.(0).(i)
      && match_partial_entry pe.b table.(1).(i)
      && match_partial_entry pe.c table.(2).(i)
    then
      Some
        {
          a = table.(0).(i);
          b = table.(1).(i);
          c = table.(2).(i);
          d = table.(3).(i);
          e = table.(4).(i);
        }
    else None

  let find pe table =
    (* TODO make it a binary search *)
    let sz = size table in
    let rec aux i =
      match i with
      | 0 -> find_entry_i pe table 0
      | _ ->
          let o = find_entry_i pe table i in
          if Option.is_some o then o else aux (i - 1)
    in
    aux (sz - 1)

  let mem : entry -> t -> bool =
   fun entry table ->
    match
      find
        {
          a = Some entry.a;
          b = Some entry.b;
          c = Some entry.c;
          d = Some entry.d;
          e = Some entry.e;
        }
        table
    with
    | Some _ -> true
    | None -> false

  let to_list table =
    Format.printf "\n%i %i\n" (Array.length table) (Array.length table.(0)) ;
    Array.to_list table

  let of_list table = Array.of_list table
end

let table_or =
  Table.of_list
    Scalar.
      [
        [|zero; zero; one; one|];
        [|zero; one; zero; one|];
        [|zero; one; one; one|];
        [|zero; zero; zero; zero|];
        [|zero; zero; zero; zero|];
      ]

module Tables = Map.Make (String)

let table_registry = Tables.add "or" table_or Tables.empty

module CS = struct
  let q_list ?q_table ~qc ~ql ~qr ~qo ~qd ~qe ~qlg ~qrg ~qog ~qdg ~qeg ~qm ~qx2b
      ~qx5a ~qx5c ~qecc_ws_add ~qecc_ed_add ~qecc_ed_cond_add ~qbool ~qcond_swap
      ~q_anemoi ~q_plookup () =
    let base =
      [
        ("qc", qc);
        ("ql", ql);
        ("qr", qr);
        ("qo", qo);
        ("qd", qd);
        ("qe", qe);
        ("qlg", qlg);
        ("qrg", qrg);
        ("qog", qog);
        ("qdg", qdg);
        ("qeg", qeg);
        ("qm", qm);
        ("qx2b", qx2b);
        ("qx5a", qx5a);
        ("qx5c", qx5c);
        ("qecc_ws_add", qecc_ws_add);
        ("qecc_ed_add", qecc_ed_add);
        ("qecc_ed_cond_add", qecc_ed_cond_add);
        ("qbool", qbool);
        ("qcond_swap", qcond_swap);
        ("q_anemoi", q_anemoi);
        ("q_plookup", q_plookup);
      ]
    in
    Option.(map (fun q -> ("q_table", q)) q_table |> to_list) @ base

  type selector_tag =
    | Linear
    | Arithmetic
    | ThisConstr
    | NextConstr
    | WireA
    | WireB
    | WireC
    | WireD
    | WireE
  [@@deriving repr]

  let all_selectors =
    q_list
      ~qc:[ThisConstr; Arithmetic]
      ~ql:[ThisConstr; Linear; Arithmetic; WireA]
      ~qr:[ThisConstr; Linear; Arithmetic; WireB]
      ~qo:[ThisConstr; Linear; Arithmetic; WireC]
      ~qd:[ThisConstr; Linear; Arithmetic; WireD]
      ~qe:[ThisConstr; Linear; Arithmetic; WireE]
      ~qlg:[NextConstr; Linear; Arithmetic; WireA]
      ~qrg:[NextConstr; Linear; Arithmetic; WireB]
      ~qog:[NextConstr; Linear; Arithmetic; WireC]
      ~qdg:[NextConstr; Linear; Arithmetic; WireD]
      ~qeg:[NextConstr; Linear; Arithmetic; WireE]
      ~qm:[ThisConstr; Arithmetic; WireA; WireB]
      ~qx2b:[ThisConstr; Arithmetic; WireB]
      ~qx5a:[ThisConstr; Arithmetic; WireA]
      ~qx5c:[ThisConstr; Arithmetic; WireC]
      ~qecc_ws_add:[ThisConstr; NextConstr; WireA; WireB; WireC]
      ~qecc_ed_add:[ThisConstr; NextConstr; WireA; WireB; WireC]
      ~qecc_ed_cond_add:
        [ThisConstr; NextConstr; WireA; WireB; WireC; WireD; WireE]
      ~qbool:[ThisConstr; WireA]
      ~qcond_swap:[ThisConstr; WireA; WireB; WireC; WireD; WireE]
      ~q_anemoi:[ThisConstr; NextConstr; WireB; WireC; WireD; WireE]
      ~q_plookup:[ThisConstr; WireA; WireB; WireC; WireD; WireE]
      ~q_table:[ThisConstr; WireA; WireB; WireC; WireD; WireE]
      ()

  let selectors_with_tags tags =
    List.filter
      (fun (_, sel_tags) -> List.for_all (fun t -> List.mem t sel_tags) tags)
      all_selectors
    |> List.map fst

  let this_constr_selectors = selectors_with_tags [ThisConstr]

  let next_constr_selectors = selectors_with_tags [NextConstr]

  let this_constr_linear_selectors = selectors_with_tags [ThisConstr; Linear]

  let next_constr_linear_selectors = selectors_with_tags [NextConstr; Linear]

  let arithmetic_selectors = selectors_with_tags [Arithmetic]

  type raw_constraint = {
    a : int;
    b : int;
    c : int;
    d : int;
    e : int;
    sels : (string * Scalar.t) list;
    precomputed_advice : (string * Scalar.t) list;
    label : string list;
  }
  [@@deriving repr]

  type gate = raw_constraint array [@@deriving repr]

  type t = gate list [@@deriving repr]

  let new_constraint ~a ~b ~c ?(d = 0) ?(e = 0) ?qc ?ql ?qr ?qo ?qd ?qe ?qlg
      ?qrg ?qog ?qdg ?qeg ?qm ?qx2b ?qx5a ?qx5c ?qecc_ws_add ?qecc_ed_add
      ?qecc_ed_cond_add ?qbool ?qcond_swap ?q_anemoi ?q_plookup ?q_table
      ?(precomputed_advice = []) ?(labels = []) label =
    let sels =
      List.filter_map
        (fun (l, x) -> Option.bind x (fun c -> Some (l, c)))
        (q_list
           ~qc
           ~ql
           ~qr
           ~qo
           ~qd
           ~qe
           ~qlg
           ~qrg
           ~qog
           ~qdg
           ~qeg
           ~qm
           ~qx2b
           ~qx5a
           ~qx5c
           ~qecc_ws_add
           ~qecc_ed_add
           ~qecc_ed_cond_add
           ~qbool
           ~qcond_swap
           ~q_anemoi
           ~q_plookup
           ~q_table
           ())
    in
    {a; b; c; d; e; sels; precomputed_advice; label = label :: labels}

  let get_sel sels s =
    match List.find_opt (fun (x, _) -> s = x) sels with
    | None -> Scalar.zero
    | Some (_, c) -> c

  let to_string_raw_constraint {a; b; c; d; e; sels; precomputed_advice; label}
      : string =
    let pp_sel (s, c) = s ^ ":" ^ Scalar.string_of_scalar c in
    let selectors = String.concat " " (List.map pp_sel sels) in
    let precomputed_advice =
      String.concat " " (List.map pp_sel precomputed_advice)
    in
    Format.sprintf
      "a:%i b:%i c:%i d:%i e:%i %s | %s [%s]"
      a
      b
      c
      d
      e
      selectors
      precomputed_advice
      (String.concat " ; " label)

  let to_string_gate g =
    String.concat "\n" @@ Array.to_list @@ Array.map to_string_raw_constraint g

  let to_string cs =
    List.fold_left (fun acc con -> acc ^ to_string_gate con ^ "\n\n") "" cs

  let is_linear_raw_constr constr =
    let linear_selectors =
      ("qc" :: this_constr_linear_selectors) @ next_constr_linear_selectors
    in
    let is_linear_sel (s, _q) = List.mem s linear_selectors in
    List.for_all is_linear_sel constr.sels

  let rename_wires_constr ~rename constr =
    {
      constr with
      a = rename constr.a;
      b = rename constr.b;
      c = rename constr.c;
      d = rename constr.d;
      e = rename constr.e;
    }

  let rename_wires ~rename gate = Array.map (rename_wires_constr ~rename) gate

  let is_arithmetic_raw_constr constr =
    let is_arithmetic_sel (s, _q) = List.mem s arithmetic_selectors in
    List.for_all is_arithmetic_sel constr.sels

  let boolean_raw_constr constr =
    if
      constr.sels = [("ql", Scalar.mone); ("qm", Scalar.one)]
      && constr.a = constr.b
    then Some constr.a
    else None

  let used_selectors gate i =
    let this_sels = gate.(i).sels in
    let prev_sels = if i = 0 then [] else gate.(i - 1).sels in
    List.filter (fun (s, _) -> List.mem s this_constr_selectors) this_sels
    @ List.filter (fun (s, _) -> List.mem s next_constr_selectors) prev_sels

  let wires_of_constr_i gate i =
    let a_selectors = selectors_with_tags [WireA] in
    let b_selectors = selectors_with_tags [WireB] in
    let c_selectors = selectors_with_tags [WireC] in
    let d_selectors = selectors_with_tags [WireD] in
    let e_selectors = selectors_with_tags [WireE] in
    let intersect names = List.exists (fun (s, _q) -> List.mem s names) in
    let sels = used_selectors gate i in
    (* We treat qecc_ed_cond_add exceptionally until we have a better interface
       on unused wires *)
    let relax =
      List.map fst sels = ["qecc_ed_cond_add"] && gate.(i).sels = []
    in
    let a_selectors = if relax then [] else a_selectors in
    let b_selectors = if relax then [] else b_selectors in
    let c_selectors = if relax then [] else c_selectors in
    (* We treat q_anemoi exceptionally until we have a better interface
       on unused wires *)
    let relax = List.map fst sels = ["q_anemoi"] && gate.(i).sels = [] in
    let a_selectors = if relax then [] else a_selectors in
    let b_selectors = if relax then [] else b_selectors in
    let c_selectors = if relax then [] else c_selectors in
    List.map2
      (fun wsels w -> if intersect wsels sels then w else -1)
      [a_selectors; b_selectors; c_selectors; d_selectors; e_selectors]
      [gate.(i).a; gate.(i).b; gate.(i).c; gate.(i).d; gate.(i).e]

  let gate_wires gate =
    List.init (Array.length gate) (wires_of_constr_i gate)
    |> List.concat |> List.sort_uniq Int.compare
    |> List.filter (fun x -> x >= 0)

  (* the relationship of this function wrt is_linear_raw_constr is a bit weird *)
  let linear_terms constr =
    if not @@ is_linear_raw_constr constr then
      raise @@ Invalid_argument "constraint is non-linear"
    else
      List.map
        (fun (sel_name, coeff) ->
          match sel_name with
          | "qc" -> (coeff, -1)
          | "ql" -> (coeff, constr.a)
          | "qr" -> (coeff, constr.b)
          | "qo" -> (coeff, constr.c)
          | "qd" -> (coeff, constr.d)
          | "qe" -> (coeff, constr.e)
          | _ -> assert false)
        constr.sels
      |> List.filter (fun (q, _) -> not @@ Scalar.is_zero q)

  let mk_linear_constr (wires, sels) =
    match wires with
    | [a; b; c; d; e] ->
        {a; b; c; d; e; sels; precomputed_advice = []; label = ["linear"]}
    | _ -> assert false

  let mk_bool_constr wire =
    {
      a = wire;
      b = 0;
      c = 0;
      d = 0;
      e = 0;
      sels = [("qbool", Scalar.one)];
      precomputed_advice = [];
      label = ["bool"];
    }

  let raw_constraint_equal c1 c2 =
    c1.a = c2.a && c1.b = c2.b && c1.c = c2.c && c1.d = c2.d && c1.e = c2.e
    && c1.label = c2.label
    && List.for_all2
         (fun (name, coeff) (name', coeff') ->
           name = name' && Scalar.eq coeff coeff')
         c1.sels
         c2.sels
end