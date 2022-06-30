val instr :
  Lwt_io.output_channel ->
  Ast.instr Lazy_vector.Int32Vector.t Lazy_vector.Int32Vector.t ->
  int ->
  Ast.instr ->
  unit Lwt.t

val func :
  Lwt_io.output_channel ->
  Ast.instr Lazy_vector.Int32Vector.t Lazy_vector.Int32Vector.t ->
  int ->
  Ast.func ->
  unit Lwt.t

val module_ : Lwt_io.output_channel -> int -> Ast.module_ -> unit Lwt.t

val script :
  Lwt_io.output_channel ->
  int ->
  [`Textual | `Binary] ->
  Script.script ->
  unit Lwt.t
