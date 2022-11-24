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

(** Testing
    -------
    Component:  Protocol (smart contract rollup inbox)
    Invocation: dune exec src/proto_alpha/lib_protocol/test/unit/main.exe \
                -- test "^\[Unit\] sc rollup inbox$"
    Subject:    These unit tests check the off-line inbox implementation for
                smart contract rollups
*)
open Protocol

let lift k = Environment.wrap_tzresult k

let lift_lwt k = Lwt.map Environment.wrap_tzresult k

module Merkelized_payload_hashes =
  Alpha_context.Sc_rollup.Inbox_merkelized_payload_hashes

module Message = Alpha_context.Sc_rollup.Inbox_message
module Inbox = Alpha_context.Sc_rollup.Inbox
open Alpha_context

let assert_equal_payload ~__LOC__ found (expected : Message.serialized) =
  Assert.equal_string
    ~loc:__LOC__
    (Message.unsafe_to_string expected)
    (Message.unsafe_to_string found)

let assert_equal_payload_hash ~__LOC__ found expected =
  Assert.equal
    ~loc:__LOC__
    Message.Hash.equal
    "Protocol hashes aren't equal"
    Message.Hash.pp
    expected
    found

let assert_merkelized_payload ~__LOC__ ~payload_hash ~index found =
  let open Lwt_result_syntax in
  let found_payload_hash = Merkelized_payload_hashes.get_payload_hash found in
  let found_index = Merkelized_payload_hashes.get_index found in
  let* () =
    assert_equal_payload_hash ~__LOC__ found_payload_hash payload_hash
  in
  Assert.equal_z ~loc:__LOC__ found_index index

let assert_equal_merkelized_payload ~__LOC__ ~found ~expected =
  let payload_hash = Merkelized_payload_hashes.get_payload_hash expected in
  let index = Merkelized_payload_hashes.get_index expected in
  assert_merkelized_payload ~__LOC__ ~payload_hash ~index found

let assert_inbox_proof_error expected_msg result =
  Assert.error ~loc:__LOC__ result (function
      | Environment.Ecoproto_error (Sc_rollup_inbox_repr.Inbox_proof_error msg)
        ->
          expected_msg = msg
      | _ -> false)

let gen_payload_size = QCheck2.Gen.(1 -- 10)

let gen_payload_string =
  let open QCheck2.Gen in
  string_size gen_payload_size

let gen_payload =
  let open QCheck2.Gen in
  let+ payload = gen_payload_string in
  Message.unsafe_of_string payload

let gen_payloads =
  let open QCheck2.Gen in
  list_size (2 -- 50) gen_payload

let gen_index payloads =
  let open QCheck2.Gen in
  let max_index = List.length payloads - 1 in
  let+ index = 0 -- max_index in
  Z.of_int index

let gen_payloads_and_index =
  let open QCheck2.Gen in
  let* payloads = gen_payloads in
  let* index = gen_index payloads in
  return (payloads, index)

let gen_payloads_and_two_index =
  let open QCheck2.Gen in
  let* payloads = gen_payloads in
  let* index = gen_index payloads in
  let* index' = gen_index payloads in
  return (payloads, index, index')

let gen_list_of_messages ?(inbox_creation_level = 0) ~max_level () =
  Sc_rollup_helpers.gen_messages_for_levels
    ~start_level:inbox_creation_level
    ~max_level
    gen_payload_string

let gen_inclusion_proof_inputs ?inbox_creation_level ?(max_level = 15) () =
  let open QCheck2.Gen in
  let* list_of_messages =
    gen_list_of_messages ?inbox_creation_level ~max_level ()
  in
  let list_of_inputs =
    Sc_rollup_helpers.list_of_inputs_from_list_of_messages list_of_messages
  in
  let* index = 0 -- (List.length list_of_inputs - 2) in
  let level = Raw_level.of_int32_exn (Int32.of_int index) in
  return (list_of_inputs, level)

let gen_proof_inputs ?inbox_creation_level ?max_level () =
  let open QCheck2.Gen in
  let* list_of_inputs, level =
    gen_inclusion_proof_inputs ?inbox_creation_level ?max_level ()
  in
  let level_index = Int32.to_int @@ Raw_level.to_int32 level in
  let inputs_at_level =
    WithExceptions.Option.get ~loc:__LOC__
    @@ List.nth list_of_inputs level_index
  in
  let* message_counter = 0 -- (List.length inputs_at_level - 1) in
  return (list_of_inputs, level, Z.of_int message_counter)

let fill_merkelized_payload history payloads =
  let open Lwt_result_syntax in
  let* first, payloads =
    match payloads with
    | x :: xs -> return (x, xs)
    | [] -> failwith "empty payloads"
  in
  let*? history, merkelized_payload =
    lift @@ Merkelized_payload_hashes.genesis history first
  in
  Lwt.return @@ lift
  @@ List.fold_left_e
       (fun (history, payloads) payload ->
         Merkelized_payload_hashes.add_payload history payloads payload)
       (history, merkelized_payload)
       payloads

let construct_merkelized_payload_hashes payloads =
  let history = Merkelized_payload_hashes.History.empty ~capacity:1000L in
  fill_merkelized_payload history payloads

module Node_inbox = struct
  type t = {
    inbox : Inbox.t;
    history : Inbox.History.t;
    level_tree_histories : Sc_rollup_helpers.level_tree_histories;
  }

  let new_inbox level =
    {
      inbox = Inbox.Internal_for_tests.dumb_init level;
      history = Inbox.History.empty ~capacity:10000L;
      level_tree_histories = Sc_rollup_helpers.Level_tree_histories.empty;
    }

  let fill_inbox inbox ~shift_level list_of_inputs =
    let open Result_syntax in
    let* level_tree_histories, history, inbox =
      Sc_rollup_helpers.fill_inbox
        ~inbox:inbox.inbox
        ~shift_level
        inbox.history
        inbox.level_tree_histories
        list_of_inputs
    in
    return {inbox; level_tree_histories; history}

  let construct_inbox ~inbox_creation_level list_of_inputs =
    let open Result_syntax in
    let* level_tree_histories, history, inbox =
      Sc_rollup_helpers.construct_inbox
        ~inbox_creation_level
        ~with_histories:true
        list_of_inputs
    in
    return {inbox; level_tree_histories; history}
end

module Protocol_inbox = struct
  let new_inbox level = Inbox.Internal_for_tests.dumb_init level

  let fill_inbox inbox ~shift_level list_of_inputs =
    let open Result_syntax in
    let* _level_tree_histories, _history, inbox =
      Sc_rollup_helpers.fill_inbox
        ~inbox
        ~shift_level
        ~with_level_tree_history:false
        (Inbox.History.empty ~capacity:0L)
        Sc_rollup_helpers.Level_tree_histories.empty
        list_of_inputs
    in
    return inbox

  let add_new_level inbox messages =
    let next_level = Raw_level.succ @@ Sc_rollup.Inbox.inbox_level inbox in
    let messages = Sc_rollup_helpers.wrap_messages next_level messages in
    let inputs =
      Sc_rollup_helpers.list_of_inputs_from_list_of_messages [messages]
    in
    fill_inbox ~shift_level:next_level inbox inputs

  let add_new_empty_level inbox =
    let next_level = Raw_level.succ @@ Sc_rollup.Inbox.inbox_level inbox in
    let empty_level =
      Sc_rollup_helpers.(
        list_of_inputs_from_list_of_messages @@ [make_empty_level next_level])
    in
    fill_inbox ~shift_level:next_level inbox empty_level

  let construct_inbox ~inbox_creation_level list_of_inputs =
    let open Result_syntax in
    let* _level_tree_histories, _history, inbox =
      Sc_rollup_helpers.construct_inbox
        ~inbox_creation_level
        ~with_histories:false
        list_of_inputs
    in
    return inbox
end

let test_merkelized_payload_hashes_history payloads =
  let open Lwt_result_syntax in
  let nb_payloads = List.length payloads in
  let* history, merkelized_payloads =
    construct_merkelized_payload_hashes payloads
  in
  let* () =
    Assert.equal_z
      ~loc:__LOC__
      (Z.of_int nb_payloads)
      (Z.succ (Merkelized_payload_hashes.get_index merkelized_payloads))
  in
  List.iteri_es
    (fun index (expected_payload : Message.serialized) ->
      let expected_payload_hash =
        Message.hash_serialized_message expected_payload
      in
      let found_merkelized_payload =
        WithExceptions.Option.get ~loc:__LOC__
        @@ Merkelized_payload_hashes.Internal_for_tests.find_predecessor_payload
             history
             ~index:(Z.of_int index)
             merkelized_payloads
      in
      let found_payload_hash =
        Merkelized_payload_hashes.get_payload_hash found_merkelized_payload
      in
      assert_equal_payload_hash
        ~__LOC__
        found_payload_hash
        expected_payload_hash)
    payloads

let test_merkelized_payload_hashes_proof (payloads, index) =
  let open Lwt_result_syntax in
  let* history, merkelized_payload =
    construct_merkelized_payload_hashes payloads
  in
  let ( Merkelized_payload_hashes.
          {merkelized = target_merkelized_payload; payload = proof_payload},
        proof ) =
    WithExceptions.Option.get ~loc:__LOC__
    @@ Merkelized_payload_hashes.produce_proof history ~index merkelized_payload
  in
  let payload : Message.serialized =
    WithExceptions.Option.get ~loc:__LOC__ @@ List.nth payloads (Z.to_int index)
  in
  let payload_hash = Message.hash_serialized_message payload in
  let* () = assert_equal_payload ~__LOC__ proof_payload payload in
  let* () =
    assert_merkelized_payload
      ~__LOC__
      ~index
      ~payload_hash
      target_merkelized_payload
  in
  let*? proof_ancestor_merkelized, proof_current_merkelized =
    lift @@ Merkelized_payload_hashes.verify_proof proof
  in
  let* () =
    assert_equal_merkelized_payload
      ~__LOC__
      ~found:proof_ancestor_merkelized
      ~expected:target_merkelized_payload
  in
  let* () =
    assert_equal_merkelized_payload
      ~__LOC__
      ~found:proof_current_merkelized
      ~expected:merkelized_payload
  in
  return_unit

let test_inclusion_proof_production (list_of_inputs, level) =
  let open Lwt_result_syntax in
  let inbox_creation_level = Raw_level.root in
  let*? node_inbox =
    Node_inbox.construct_inbox ~inbox_creation_level list_of_inputs
  in
  let*? node_inbox_history, node_inbox_snapshot =
    lift @@ Inbox.form_history_proof node_inbox.history node_inbox.inbox
  in
  let*? proof, node_old_level_messages =
    lift
    @@ Inbox.Internal_for_tests.produce_inclusion_proof
         node_inbox_history
         node_inbox_snapshot
         level
  in
  let*? proto_inbox =
    Protocol_inbox.construct_inbox ~inbox_creation_level list_of_inputs
  in
  (* we add a level only to archive the latest message *)
  let*? proto_inbox = Protocol_inbox.add_new_empty_level proto_inbox in
  let proto_inbox_snapshot = Inbox.take_snapshot proto_inbox in
  let*? found_old_levels_messages =
    lift @@ Inbox.verify_inclusion_proof proof proto_inbox_snapshot
  in
  Assert.equal
    ~loc:__LOC__
    Inbox.equal_history_proof
    "snapshot is the same in the proto and node"
    Inbox.pp_history_proof
    node_old_level_messages
    found_old_levels_messages

let test_inclusion_proof_verification (list_of_inputs, level) =
  let open Lwt_result_syntax in
  let inbox_creation_level = Raw_level.root in
  let*? node_inbox =
    Node_inbox.construct_inbox ~inbox_creation_level list_of_inputs
  in
  let*? node_inbox_history, node_inbox_snapshot =
    lift @@ Inbox.form_history_proof node_inbox.history node_inbox.inbox
  in
  let*? proof, _node_old_level_messages =
    lift
    @@ Inbox.Internal_for_tests.produce_inclusion_proof
         node_inbox_history
         node_inbox_snapshot
         level
  in
  let*? proto_inbox =
    Protocol_inbox.construct_inbox ~inbox_creation_level list_of_inputs
  in
  (* This snapshot is not the same one as node_inbox_snapshot because the
     node_inbox_snapshot includes the current_level_proof. *)
  let proto_inbox_snapshot = Inbox.take_snapshot proto_inbox in
  let result =
    lift @@ Inbox.verify_inclusion_proof proof proto_inbox_snapshot
  in
  assert_inbox_proof_error "invalid inclusion proof" result

let test_inbox_proof_production (list_of_inputs, level, message_counter) =
  let open Lwt_result_syntax in
  let inbox_creation_level = Raw_level.root in
  (* We begin with a Node inbox so we can produce a proof. *)
  let exp_message =
    Sc_rollup_helpers.first_after
      ~shift_level:inbox_creation_level
      list_of_inputs
      level
      message_counter
  in
  let*? node_inbox =
    Node_inbox.construct_inbox ~inbox_creation_level list_of_inputs
  in
  let*? node_inbox_history, node_inbox_snapshot =
    lift @@ Inbox.form_history_proof node_inbox.history node_inbox.inbox
  in
  let* proof, input =
    lift_lwt
    @@ Inbox.produce_proof
         ~get_level_tree_history:
           (Sc_rollup_helpers.get_level_tree_history
              node_inbox.level_tree_histories)
         node_inbox_history
         node_inbox_snapshot
         (level, message_counter)
  in
  (* We now switch to a protocol inbox built from the same messages for
     verification. *)
  let*? proto_inbox =
    Protocol_inbox.construct_inbox ~inbox_creation_level list_of_inputs
  in
  let*? proto_inbox = Protocol_inbox.add_new_empty_level proto_inbox in
  let proto_inbox_snapshot = Inbox.take_snapshot proto_inbox in
  let* () =
    Assert.equal
      ~loc:__LOC__
      Inbox.equal_history_proof
      "snapshot is the same in the proto and node"
      Inbox.pp_history_proof
      node_inbox_snapshot
      proto_inbox_snapshot
  in
  let*? v_input =
    lift
    @@ Inbox.verify_proof (level, message_counter) proto_inbox_snapshot proof
  in
  let* () =
    Assert.equal
      ~loc:__LOC__
      (Option.equal Sc_rollup.inbox_message_equal)
      "Input returns by the production is the expected one."
      (Format.pp_print_option Sc_rollup.pp_inbox_message)
      input
      v_input
  in
  Assert.equal
    ~loc:__LOC__
    (Option.equal Sc_rollup.inbox_message_equal)
    "Input returns by the verification is the expected one."
    (Format.pp_print_option Sc_rollup.pp_inbox_message)
    exp_message
    v_input

let test_inbox_proof_verification (list_of_inputs, level, message_counter) =
  let open Lwt_result_syntax in
  let inbox_creation_level = Raw_level.root in
  (* We begin with a Node inbox so we can produce a proof. *)
  let*? node_inbox =
    Node_inbox.construct_inbox ~inbox_creation_level list_of_inputs
  in
  let get_level_tree_history =
    Sc_rollup_helpers.get_level_tree_history node_inbox.level_tree_histories
  in
  let*? node_inbox_history, node_inbox_snapshot =
    lift @@ Inbox.form_history_proof node_inbox.history node_inbox.inbox
  in
  let* proof, _input =
    lift_lwt
    @@ Inbox.produce_proof
         ~get_level_tree_history
         node_inbox_history
         node_inbox_snapshot
         (level, message_counter)
  in
  (* We now switch to a protocol inbox built from the same messages for
     verification. *)
  let*? proto_inbox =
    Protocol_inbox.construct_inbox ~inbox_creation_level list_of_inputs
  in
  (* This snapshot is not the same one as node_inbox_snapshot because the
     node_inbox_snapshot includes the current_level_proof. *)
  let proto_inbox_snapshot = Inbox.take_snapshot proto_inbox in
  let* () =
    let result =
      lift
      @@ Inbox.verify_proof (level, message_counter) proto_inbox_snapshot proof
    in
    assert_inbox_proof_error "invalid inclusion proof" result
  in
  let*? proto_inbox = Protocol_inbox.add_new_empty_level proto_inbox in
  let proto_inbox_snapshot = Inbox.take_snapshot proto_inbox in
  let invalid_message_counter =
    if Z.(equal message_counter zero) then Z.succ message_counter
    else Z.pred message_counter
  in
  let* () =
    let result =
      lift
      @@ Inbox.verify_proof
           (level, invalid_message_counter)
           proto_inbox_snapshot
           proof
    in
    assert_inbox_proof_error "found index in message_proof is incorrect" result
  in
  return_unit

let merkelized_payload_hashes_tests =
  [
    Tztest.tztest_qcheck2
      ~count:1000
      ~name:"Merkelized messages: Add messages then retrieve them from history."
      gen_payloads
      test_merkelized_payload_hashes_history;
    Tztest.tztest_qcheck2
      ~count:1000
      ~name:"Merkelized messages: Produce proof and verify its validity."
      gen_payloads_and_index
      test_merkelized_payload_hashes_proof;
  ]

let inbox_tests =
  [
    Tztest.tztest_qcheck2
      ~count:1000
      ~name:"produce inclusion proof and verifies it."
      (gen_inclusion_proof_inputs ())
      test_inclusion_proof_production;
    Tztest.tztest_qcheck2
      ~count:1000
      ~name:"negative test of inclusion proof."
      (gen_inclusion_proof_inputs ())
      test_inclusion_proof_verification;
    Tztest.tztest_qcheck2
      ~count:1000
      ~name:"produce inbox proof and verifies it."
      (gen_proof_inputs ())
      test_inbox_proof_production;
    Tztest.tztest_qcheck2
      ~count:1000
      ~name:"negative test of inbox proof."
      (gen_proof_inputs ())
      test_inbox_proof_verification;
  ]

let tests =
  merkelized_payload_hashes_tests @ inbox_tests
  @ Test_sc_rollup_inbox_legacy.tests
