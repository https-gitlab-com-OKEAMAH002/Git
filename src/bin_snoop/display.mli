(*****************************************************************************)
(*                                                                           *)
(* Open Source License                                                       *)
(* Copyright (c) 2020 Nomadic Labs. <contact@nomadic-labs.com>               *)
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

(** [plot_target] specifies where to display the plot. *)
type plot_target =
  | Save
      (** Save to file in .pdf format. Filename is automatically generated
          following the scheme: "{bench-name}_{model-name}_{kind}.pdf"
          where 'kind' is the type of plot:
          - "emp" corresponds to the raw empirical data (workload vs time)
          - "validation" corresponds to the data and predicted execution time
            projected in the feature space of the model
          - "emp-validation" corresponds to the raw empirical data and
            predicted execution time. *)
  | Show  (** Display to screen (requires Qt) *)

type empirical_plot =
  | Empirical_plot_full  (** Plots the full empirical data *)
  | Empirical_plot_quantiles of float list
      (** Plots the specified quantiles.
          Quantiles must be included in the [[0;1]] interval. *)

(** [options] specifies some display parameters. *)
type options = {
  save_directory : string;
      (** Specify where to save figures. Defaults to [Filename.temp_dir_name]. *)
  point_size : float;
      (** Specifies the size of points for scatter plots.
          Defaults to [0.5] *)
  qt_target_pixel_size : (int * int) option;
      (** Specifies the size, in pixels, of the window in which plots are performed.
          If set to [None], selected automatically by gnuplot. Defaults to
          [1920, 1080]. *)
  pdf_target_cm_size : (float * float) option;
      (** Specifies the size, in centimeters, of the image generated by gnuplot.
          If set to [None], selected automatically by gnuplot. [None] is the
          default. *)
  reduced_plot_verbosity : bool;
      (** If set (default), the tool will only systematically output validator plots.
          Other kinds of plots will be output conditionally on unspecified
          heuristics. *)
  plot_raw_workload : bool;
      (** If set to [true], plots histograms of raw timings for all measurements.
          Plots are produced in [save_directory].
          By default, set to [false] *)
  empirical_plot : empirical_plot;
      (** Specifies how to plot the empirical data *)
}

(** Encoding for options. *)
val options_encoding : options Data_encoding.t

(** Default options. See {!options} documentation. *)
val default_options : options

(** Performs the plot. Returns the list of files produced. *)
val perform_plot :
  measure:Measure.packed_measurement ->
  local_model_name:string ->
  problem:Inference.problem ->
  solution:Inference.solution ->
  plot_target:plot_target ->
  options:options ->
  string list
