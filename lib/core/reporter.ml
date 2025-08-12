open Bwd
open Util
open Dim
open Asai.Diagnostic
open Format
open Energy

(* In order to display terms and suchlike in Asai messages, we utilize a double indirection.  Firstly, displaying a term requires "unparsing" it to a parse tree and then printing the parse tree, but parse trees and unparsing aren't defined until the Parser library, which is loaded after Core.  (Displaying a value additionally requires reading it back into a term, which is defined later in Core.)  For this reason, we introduce a wrapper type "printable" that can contain a term, value, etc.  Since terms and values haven't been defined yet in this file, we make "printable" an extensible variant, so they can be added later (in the module Printable) after they are defined.  (They also have to be bundled with their context.) *)

type printable = ..

type printable +=
  | PUnit : printable
  | PInt : int -> printable
  | PString : string -> printable
  | PConstant of Constant.t
  | PMeta : ('x, 'b, 's) Meta.t -> printable
  | PField : 'i Field.t -> printable
  | PConstr : Constr.t -> printable

(* The function that actually does the work of printing a "printable" will be defined in Parser.Unparse.  But we need to be able to "call" that function in this file to define "default_text" that converts structured messages to text.  Thus, in this file we define a mutable global variable to contain that function, starting with a dummy function, and call its value to print "printable"s; then in Parser.Unparse we will set the value of that variable after defining the function it should contain. *)

(* In addition, in Asai messages are emitted by performing an effect or raising an exception that carries with it the data of a function of type "formatter -> unit", which is then called by the handler Reporter.run to format the message text as part of a larger display formatting.  This causes problems if we define our printing functions naively, since it means that any effects performed by the formatting function (such as looking up names in a Yuujinchou Scope) will take place in the context of the handler, not that where the message was invoked, and hence in the wrong scope.  To deal with this, we ensure that the printable values are converted to PPrint documents directly in "default_text", before they are passed to Asai. *)

let printer : (sort:[ `Type | `Function | `Other ] -> printable -> PPrint.document) ref =
  ref (fun ~sort:_ _ -> raise (Failure "print not set (hint: Parser.Unparse must be loaded)"))

let print ?(sort = `Other) pr = !printer ~sort pr

let print_to_string pr =
  let buf = Buffer.create 5 in
  PPrint.ToBuffer.pretty 1.0 70 buf (!printer ~sort:`Other pr);
  Buffer.contents buf

(* Now the function that Asai carries around is basically just PPrint.ToFormatter.pretty.  It's important to know exactly what this does, although it's not described precisely in the PPrint documentation: it converts all newlines to pp_force_newline and all spaces to pp_print_space.  Note that the latter is a break hint, allowing Format to break the line!  This is not what we want; the spaces in PPrint's output are supposed to be spaces, and only the newlines in PPrint's output should be newlines.  I think the only solution, short of modifying PPrint, is to surround it in a Format hbox, which causes all break hints to never split the line.  It does still respect force_newline, of course, so this should do what we want.  *)
let pp_printed ppf x =
  pp_open_hbox ppf ();
  PPrint.ToFormatter.pretty 1.0 (pp_get_margin ppf ()) ppf x;
  pp_close_box ppf ()

(* Some helpful printing functions *)

let string_of_dim0 dim =
  let str = string_of_dim dim in
  if str = "" then "0" else str

let record_or_codata : type s et. (s, et) eta -> string = function
  | Eta -> "record"
  | Noeta -> "codata"

(* Unequalities *)

module Unequal = struct
  type t =
    | Constants of Constant.t * Constant.t
    | Constrs of Constr.t * Constr.t
    | Metas : ('a1, 'b1, 's1) Meta.t * ('a2, 'b2, 's2) Meta.t -> t
    | Fields : 'i1 Field.t * 'i2 Field.t -> t
    | Variables of printable * printable
    | Terms of printable * printable
    | Heads of t

  let rec printables : t -> string * printable * printable = function
    | Constants (c1, c2) -> ("constants", PConstant c1, PConstant c2)
    | Constrs (c1, c2) -> ("constructors", PConstr c1, PConstr c2)
    | Metas (m1, m2) -> ("metavariables", PMeta m1, PMeta m2)
    | Fields (f1, f2) -> ("fields", PString (Field.to_string f1), PString (Field.to_string f2))
    | Variables (v1, v2) -> ("variables", v1, v2)
    | Terms (t1, t2) -> ("terms", t1, t2)
    | Heads p ->
        let str, p1, p2 = printables p in
        ("head " ^ str, p1, p2)
end

module Code = struct
  type t =
    | Parse_error : t
    | Encoding_error : t
    | Parsing_ambiguity : string list -> t
    | No_relative_precedence : string * string -> t
    | Invalid_variable : string list -> t
    | Invalid_numeral : string -> t
    | Invalid_constr : string -> t
    | Invalid_field : string -> t
    | Invalid_degeneracy : string -> t
    | Not_enough_lambdas : int -> t
    | Zero_dimensional_cube_abstraction : string -> t
    | Mismatched_dimensions_in_cube_abstraction : 'm D.t * 'n D.t -> t
    | Noncube_abstraction_in_higher_dimensional_match : 'n D.t -> t
    | Not_enough_arguments_to_function : t
    | Not_enough_arguments_to_instantiation : t
    | Type_not_fully_instantiated : string * 'n D.pos -> t
    | Instantiating_zero_dimensional_type : printable -> t
    | Unequal_synthesized_type : {
        expected : printable;
        got : printable;
        which : string option;
        why : Unequal.t;
      }
        -> t
    | Unequal_synthesized_boundary : {
        face : ('a, 'b) sface;
        got : printable;
        expected : printable;
        why : Unequal.t;
      }
        -> t
    | Not_enough_domains : 'a D.t -> t
    | Invalid_higher_function : string -> t
    | Invalid_nullary_application : t
    | Expected_nullary_application : t
    | Checking_tuple_at_degenerated_record : printable -> t
    | Missing_field_in_tuple : 'i Field.t * ('e, 'i, 'r) pbij option -> t
    | Missing_method_in_comatch : 'i Field.t * ('e, 'i, 'r) pbij option -> t
    | Extra_field_in_tuple : string option -> t
    | Extra_method_in_comatch : (string * string list) -> t
    | Invalid_field_in_tuple : t
    | Duplicate_field_in_tuple : string -> t
    | Duplicate_method_in_codata : 'i Field.t -> t
    | Duplicate_field_in_record : 'i Field.t -> t
    | Invalid_method_in_comatch : t
    | Duplicate_method_in_comatch : string * string list -> t
    | Missing_constructor_in_match : Constr.t -> t
    | Unnamed_variable_in_match : t
    | Checking_lambda_at_nonfunction : printable -> t
    | Checking_tuple_at_nonrecord : printable -> t
    | Choice_mismatch : printable -> t
    | Calc_error : printable -> t
    | Comatching_at_noncodata : printable -> t
    | Comatching_at_degenerated_codata : printable -> t
    | No_such_constructor :
        [ `Data of printable | `Nondata of printable | `Other of printable ] * Constr.t
        -> t
    | Wrong_number_of_arguments_to_constructor : Constr.t * int -> t
    | No_such_field :
        [ `Record of ('s, 'et) eta * printable
        | `Nonrecord of printable
        | `Other of printable
        | `Type of printable
        | `Degenerated_record of ('s, 'et) eta ]
        (* We don't require the i's to match, since that might be part of the error. *)
        * [ `Ins of 'i Field.t * ('n, 't, 'i2) insertion
          | `Pbij of 'i Field.t * ('n, 'i, 'r) pbij
          | `Strings of string * int list
          | `Int of int ]
        -> t
    | Wrong_dimension_of_field :
        ('s, 'et) eta
        * printable
        * [ `Field of 'i Field.t | `String of string ]
        * 'used_at D.t
        * 'intrinsic D.t
        * [ `Ins of ('n, 't, 'h) insertion | `Pbij of ('n, 'i2, 'r) pbij | `Ints of int list ]
        -> t
    | Invalid_field_suffix : printable * string * int list * 'evaluation D.t -> t
    | Missing_instantiation_constructor :
        Constr.t * [ `Constr of Constr.t | `Nonconstr of printable ]
        -> t
    | Unequal_indices : printable * printable * Unequal.t -> t
    | Unbound_variable : string * (string list * string list) list -> t
    | Ill_scoped_connection : t
    | Undefined_constant : printable -> t
    | Undefined_metavariable : printable -> t
    | Nonsynthesizing : string -> t
    | Low_dimensional_argument_of_degeneracy : { name : string; needed : 'a D.t; got : 'b D.t } -> t
    | Low_dimensional_type_of_degeneracy : { name : string; needed : 'a D.t; got : 'b D.t } -> t
    | Missing_argument_of_degeneracy : string -> t
    | Applying_nonfunction_nontype : printable * printable -> t
    | Unexpected_implicitness : [ `Implicit | `Explicit ] * string * string -> t
    | Insufficient_dimension : { needed : 'a D.t; got : 'b D.t; which : string } -> t
    | Unimplemented : string -> t
    | Deprecated : string -> t
    | Matching_datatype_has_degeneracy : printable -> t
    | Wrong_number_of_arguments_to_pattern : Constr.t * int -> t
    | Wrong_number_of_arguments_to_motive : int -> t
    | No_such_constructor_in_match : printable * Constr.t -> t
    | Duplicate_constructor_in_match : Constr.t -> t
    | Duplicate_constructor_in_data : Constr.t -> t
    | Matching_on_nondatatype : printable -> t
    | Matching_wont_refine : string * printable option -> t
    | Dimension_mismatch : string * 'a D.t * 'b D.t -> t
    | Invalid_variable_face : 'a D.t * ('n, 'm) sface -> t
    | Anomaly : string -> t
    | No_such_level : printable -> t
    | Redefining_constant : string list -> t
    | Invalid_constant_name : string list * string option -> t
    | Too_many_commands : t
    | Invalid_tightness : string -> t
    | Fixity_mismatch : t
    | Invalid_notation_pattern : string -> t
    | Invalid_notation_symbol : string -> t
    | Invalid_notation_head : string -> t
    | Duplicate_notation_variable : string -> t
    | Unused_notation_variable : string -> t
    | Notation_variable_used_twice : string -> t
    | Unbound_variable_in_notation : string list -> t
    | Head_already_has_notation : string -> t
    | Constant_assumed : { name : printable; parametric : bool; holes : int } -> t
    | Constant_defined : {
        names : printable list;
        discrete : bool;
        parametric : bool;
        holes : int;
      }
        -> t
    | Hole_solved : int -> t
    | Split_term : PPrint.document -> t
    | Notation_defined : string -> t
    | Show : string * printable -> t
    | Comment_end_in_string : t
    | Checking_canonical_at_nonuniverse : string * printable -> t
    | Bare_case_tree_construct : string -> t
    | Wrong_boundary_of_record : int -> t
    | Invalid_constructor_type : Constr.t * (string, Unequal.t) Either.t -> t
    | Missing_constructor_type : Constr.t -> t
    | Locked_variable : t
    | Locked_constant : printable -> t
    | Axiom_in_parametric_definition : printable -> t
    | Hole : string * printable -> t
    | No_open_holes : t
    | Open_holes : int -> t
    | Open_holes_remaining : [ `File of string | `String | `Stdin ] -> t
    | Quit : string option -> t
    | Synthesizing_recursion : printable -> t
    | Invalid_synthesized_type : string * printable -> t
    | Unrecognized_attribute : t
    | Invalid_degeneracy_action : string * 'nk D.t * 'n D.t -> t
    | Wrong_number_of_patterns : t
    | Inconsistent_patterns : t
    | Overlapping_patterns : t
    | No_remaining_patterns : t
    | Invalid_refutation : t
    | Duplicate_pattern_variable : string -> t
    | Type_expected : string * printable -> t
    | Circular_import : string list -> t
    | Loading_file : string -> t
    | File_loaded : string * [ `Compiled | `Source ] -> t
    | Library_has_extension : string -> t
    | Library_modified : string -> t
    | Directory_changed : string -> t
    | Invalid_filename : string -> t
    | No_such_file : string -> t
    | Cant_write_compiled_file : string -> t
    | Incompatible_flags : string * string -> t
    | Actions_in_compiled_file : string -> t
    | No_such_hole : int -> t
    | Invalid_split : [ `Term | `Goal ] * string -> t
    | Forbidden_interactive_command : string -> t
    | Not_enough_to_undo : t
    | Commands_undone : int -> t
    | Section_opened : string list -> t
    | Section_closed : string list -> t
    | Invalid_section_name : string list -> t
    | No_such_section : t
    | Display_set : string * string -> t
    | Option_set : string * string -> t
    | Break : t
    | Accumulated : string * t Asai.Diagnostic.t Bwd.t -> t
    | No_holes_allowed : [ `Command of string | `File of string | `Other of string ] -> t
    | Cyclic_term : t
    | Oracle_failed : string * printable -> t
    | Invalid_flags : t

  (* If an error is encountered during printing a term, we (meaning the function 'printer' to be defined in Parser.Unparse) call the function supplied by this reader effect and print it as "_UNPRINTABLE".  Usually this is a bug, but sometimes it can happen normally, particularly when accumulating errors: a term involved in a later error might be unprintable due to a previous error.  We make this a reader that supplies a function so that the function can be called at the point of *performing* the effect.  Thus, if we are not in the middle of displaying another message, there can be an outer handler for this effect that supplies the function "fatal", which is called at the point of performing the effect and is therefore inside any inner Reporter.run wrappers rather than the outermost one that just Exits. *)
  module PrintingErrorData = struct
    type nonrec t = t -> unit
  end

  module PrintingError = Algaeff.Reader.Make (PrintingErrorData)

  let () =
    PrintingError.register_printer (function `Read -> Some "unhandled PrintingError.read effect")

  (** The default severity of messages with a particular message code. *)
  let default_severity : t -> Asai.Diagnostic.severity = function
    | Parse_error -> Error
    | Encoding_error -> Error
    | Parsing_ambiguity _ -> Error
    | No_relative_precedence _ -> Error
    | Invalid_variable _ -> Error
    | Invalid_numeral _ -> Error
    | Invalid_constr _ -> Error
    | Invalid_field _ -> Error
    | Invalid_degeneracy _ -> Error
    | Not_enough_lambdas _ -> Error
    | Zero_dimensional_cube_abstraction _ -> Error
    | Mismatched_dimensions_in_cube_abstraction _ -> Error
    | Noncube_abstraction_in_higher_dimensional_match _ -> Error
    | Type_not_fully_instantiated _ -> Error
    | Unequal_synthesized_type _ -> Error
    | Unequal_synthesized_boundary _ -> Error
    | Not_enough_domains _ -> Error
    | Invalid_higher_function _ -> Error
    | Invalid_nullary_application -> Error
    | Expected_nullary_application -> Error
    | Checking_tuple_at_degenerated_record _ -> Error
    | Missing_field_in_tuple _ -> Error
    | Missing_method_in_comatch _ -> Error
    | Extra_field_in_tuple _ -> Error
    | Extra_method_in_comatch _ -> Error
    | Invalid_field_in_tuple -> Error
    | Duplicate_field_in_tuple _ -> Error
    | Duplicate_method_in_codata _ -> Error
    | Duplicate_field_in_record _ -> Error
    | Invalid_method_in_comatch -> Error
    | Duplicate_method_in_comatch _ -> Error
    | Missing_constructor_in_match _ -> Error
    | Unnamed_variable_in_match -> Error
    | Checking_lambda_at_nonfunction _ -> Error
    | Checking_tuple_at_nonrecord _ -> Error
    | Choice_mismatch _ -> Error
    | Calc_error _ -> Error
    | Comatching_at_noncodata _ -> Error
    | Comatching_at_degenerated_codata _ -> Error
    | No_such_constructor _ -> Error
    | Missing_instantiation_constructor _ -> Error
    | Unequal_indices _ -> Error
    | Unbound_variable _ -> Error
    | Ill_scoped_connection -> Error
    | Undefined_constant _ -> Bug
    | Undefined_metavariable _ -> Bug
    | No_such_field _ -> Error
    | Nonsynthesizing _ -> Error
    | Low_dimensional_argument_of_degeneracy _ -> Error
    | Low_dimensional_type_of_degeneracy _ -> Error
    | Missing_argument_of_degeneracy _ -> Error
    | Not_enough_arguments_to_function -> Error
    | Instantiating_zero_dimensional_type _ -> Error
    | Invalid_variable_face _ -> Error
    | Not_enough_arguments_to_instantiation -> Error
    | Applying_nonfunction_nontype _ -> Error
    | Unexpected_implicitness _ -> Error
    | Insufficient_dimension _ -> Error
    | Wrong_number_of_arguments_to_constructor _ -> Error
    | Unimplemented _ -> Error
    | Deprecated _ -> Warning
    | Matching_datatype_has_degeneracy _ -> Error
    | Wrong_number_of_arguments_to_pattern _ -> Error
    | Wrong_number_of_arguments_to_motive _ -> Error
    | No_such_constructor_in_match _ -> Error
    | Duplicate_constructor_in_match _ -> Error
    | Duplicate_constructor_in_data _ -> Error
    | Matching_on_nondatatype _ -> Error
    | Matching_wont_refine _ -> Hint
    | Dimension_mismatch _ -> Bug (* Sometimes Error? *)
    | Anomaly _ -> Bug
    | No_such_level _ -> Bug
    | Redefining_constant _ -> Warning
    | Invalid_constant_name _ -> Error
    | Too_many_commands -> Error
    | Invalid_tightness _ -> Error
    | Fixity_mismatch -> Error
    | Invalid_notation_pattern _ -> Error
    | Invalid_notation_symbol _ -> Error
    | Invalid_notation_head _ -> Error
    | Duplicate_notation_variable _ -> Error
    | Unused_notation_variable _ -> Error
    | Notation_variable_used_twice _ -> Error
    | Unbound_variable_in_notation _ -> Error
    | Head_already_has_notation _ -> Warning
    | Constant_assumed _ -> Info
    | Constant_defined _ -> Info
    | Notation_defined _ -> Info
    | Show _ -> Info
    | Comment_end_in_string -> Warning
    | Checking_canonical_at_nonuniverse _ -> Error
    | Bare_case_tree_construct _ -> Hint
    | Wrong_boundary_of_record _ -> Error
    | Invalid_constructor_type _ -> Error
    | Missing_constructor_type _ -> Error
    | Locked_variable -> Error
    | Locked_constant _ -> Error
    | Axiom_in_parametric_definition _ -> Error
    | Hole _ -> Info
    | No_open_holes -> Info
    | Open_holes _ -> Warning
    | Open_holes_remaining _ -> Error
    | Quit _ -> Info
    | Synthesizing_recursion _ -> Error
    | Invalid_synthesized_type _ -> Error
    | Unrecognized_attribute -> Error
    | Invalid_degeneracy_action _ -> Bug
    | Wrong_number_of_patterns -> Error
    | Inconsistent_patterns -> Error
    | Overlapping_patterns -> Error
    | No_remaining_patterns -> Bug
    | Invalid_refutation -> Error
    | Duplicate_pattern_variable _ -> Error
    | Type_expected _ -> Error
    | Circular_import _ -> Error
    | Loading_file _ -> Info
    | File_loaded _ -> Info
    | Library_has_extension _ -> Warning
    | Library_modified _ -> Error
    | Directory_changed _ -> Info
    | Invalid_filename _ -> Error
    | No_such_file _ -> Error
    | Cant_write_compiled_file _ -> Warning
    | Incompatible_flags _ -> Warning
    | Actions_in_compiled_file _ -> Warning
    | No_such_hole _ -> Error
    | Invalid_split _ -> Error
    | Hole_solved _ -> Info
    | Split_term _ -> Info
    | Forbidden_interactive_command _ -> Error
    | Not_enough_to_undo -> Error
    | Commands_undone _ -> Info
    | Section_opened _ -> Info
    | Section_closed _ -> Info
    | Invalid_section_name _ -> Error
    | No_such_section -> Error
    | Display_set _ -> Info
    | Option_set _ -> Info
    | Break -> Error
    | Accumulated _ -> Error
    | No_holes_allowed _ -> Error
    | Wrong_dimension_of_field _ -> Error
    | Invalid_field_suffix _ -> Error
    | Cyclic_term -> Error
    | Oracle_failed _ -> Error
    | Invalid_flags -> Error

  (** A short, concise, ideally Google-able string representation for each message code. *)
  let short_code : t -> string = function
    (* Usually bugs *)
    | Anomaly _ -> "E0000"
    | No_such_level _ -> "E0001"
    | Accumulated (_msg, _errs) -> "E0002"
    | Invalid_degeneracy_action _ -> "E0003"
    (* Past and future features *)
    | Unimplemented _ -> "E0100"
    | Deprecated _ -> "E0110"
    (* Parse errors *)
    | Parse_error -> "E0200"
    | Parsing_ambiguity _ -> "E0201"
    | Invalid_variable _ -> "E0202"
    | Invalid_field _ -> "E0203"
    | Invalid_constr _ -> "E0204"
    | Invalid_numeral _ -> "E0205"
    | Invalid_degeneracy _ -> "E0206"
    | No_relative_precedence _ -> "E0207"
    | Unrecognized_attribute -> "E0208"
    | Comment_end_in_string -> "E0250"
    | Cyclic_term -> "E0280"
    | Encoding_error -> "E0299"
    (* Scope errors *)
    | Unbound_variable _ -> "E0300"
    | Undefined_constant _ -> "E0301"
    | Undefined_metavariable _ -> "E0302"
    | Ill_scoped_connection -> "E0303"
    | Locked_variable -> "E0310"
    | Locked_constant _ -> "E0311"
    | Axiom_in_parametric_definition _ -> "E0312"
    (* Bidirectional typechecking and case trees *)
    | Nonsynthesizing _ -> "E0400"
    | Unequal_synthesized_type _ -> "E0401"
    | Synthesizing_recursion _ -> "E0402"
    | Bare_case_tree_construct _ -> "H0403"
    | Invalid_synthesized_type _ -> "E0404"
    | Type_expected _ -> "E0405"
    (* Dimensions *)
    | Dimension_mismatch _ -> "E0500"
    | Not_enough_lambdas _ -> "E0501"
    | Not_enough_arguments_to_function -> "E0502"
    | Not_enough_arguments_to_instantiation -> "E0503"
    | Type_not_fully_instantiated _ -> "E0504"
    | Instantiating_zero_dimensional_type _ -> "E0505"
    | Invalid_variable_face _ -> "E0506"
    | Zero_dimensional_cube_abstraction _ -> "E0508"
    | Mismatched_dimensions_in_cube_abstraction _ -> "E0509"
    | Noncube_abstraction_in_higher_dimensional_match _ -> "E0510"
    | Invalid_flags -> "E0511"
    (* Degeneracies *)
    | Missing_argument_of_degeneracy _ -> "E0600"
    | Low_dimensional_argument_of_degeneracy _ -> "E0601"
    | Low_dimensional_type_of_degeneracy _ -> "E0602"
    (* Function-types *)
    | Checking_lambda_at_nonfunction _ -> "E0700"
    | Applying_nonfunction_nontype _ -> "E0701"
    | Unexpected_implicitness _ -> "E0702"
    | Insufficient_dimension _ -> "E0703"
    | Unequal_synthesized_boundary _ -> "E0704"
    | Not_enough_domains _ -> "E0705"
    | Invalid_higher_function _ -> "E0706"
    | Invalid_nullary_application -> "E0707"
    | Expected_nullary_application -> "E0708"
    (* Record fields *)
    | No_such_field _ -> "E0800"
    | Wrong_dimension_of_field _ -> "E0801"
    | Invalid_field_suffix _ -> "E0802"
    (* Tuples *)
    | Checking_tuple_at_nonrecord _ -> "E0900"
    | Checking_tuple_at_degenerated_record _ -> "E0901"
    | Missing_field_in_tuple _ -> "E0902"
    | Extra_field_in_tuple _ -> "E0903"
    | Duplicate_field_in_tuple _ -> "E0904"
    | Invalid_field_in_tuple -> "E0905"
    (* Datatype constructors *)
    | No_such_constructor _ -> "E1000"
    | Wrong_number_of_arguments_to_constructor _ -> "E1001"
    | Missing_instantiation_constructor _ -> "E1002"
    | Unequal_indices _ -> "E1003"
    (* Matches *)
    (* - Match variable *)
    | Unnamed_variable_in_match -> "E1100"
    | Matching_wont_refine _ -> "E1101"
    (* - Match type *)
    | Matching_on_nondatatype _ -> "E1200"
    | Matching_datatype_has_degeneracy _ -> "E1201"
    (* - Match branches *)
    | Missing_constructor_in_match _ -> "E1300"
    | No_such_constructor_in_match _ -> "E1301"
    | Duplicate_constructor_in_match _ -> "E1302"
    | Wrong_number_of_arguments_to_pattern _ -> "E1303"
    | Duplicate_pattern_variable _ -> "E1304"
    | Wrong_number_of_patterns -> "E1305"
    | Inconsistent_patterns -> "E1306"
    | Overlapping_patterns -> "E1307"
    | No_remaining_patterns -> "E1308"
    | Invalid_refutation -> "E1309"
    (* - Match motive *)
    | Wrong_number_of_arguments_to_motive _ -> "E1400"
    (* Comatches *)
    | Comatching_at_noncodata _ -> "E1400"
    | Comatching_at_degenerated_codata _ -> "E1401"
    | Missing_method_in_comatch _ -> "E1402"
    | Extra_method_in_comatch _ -> "E1403"
    | Duplicate_method_in_comatch _ -> "E1404"
    | Invalid_method_in_comatch -> "E1405"
    (* Canonical types *)
    | Checking_canonical_at_nonuniverse _ -> "E1500"
    | Duplicate_field_in_record _ -> "E1501"
    | Duplicate_method_in_codata _ -> "E1502"
    | Duplicate_constructor_in_data _ -> "E1503"
    | Wrong_boundary_of_record _ -> "E1504"
    | Invalid_constructor_type _ -> "E1505"
    | Missing_constructor_type _ -> "E1506"
    (* Tactics *)
    | Choice_mismatch _ -> "E1600"
    | Calc_error _ -> "E1601"
    (* Commands *)
    | Too_many_commands -> "E2000"
    | Forbidden_interactive_command _ -> "E2001"
    | No_holes_allowed _ -> "E2002"
    (* def *)
    | Redefining_constant _ -> "E2100"
    | Invalid_constant_name _ -> "E2101"
    (* notation *)
    | Invalid_tightness _ -> "E2200"
    | Invalid_notation_symbol _ -> "E2201"
    | Invalid_notation_pattern _ -> "E2202"
    | Fixity_mismatch -> "E2203"
    | Duplicate_notation_variable _ -> "E2204"
    | Invalid_notation_head _ -> "E2205"
    | Unused_notation_variable _ -> "E2206"
    | Notation_variable_used_twice _ -> "E2207"
    | Unbound_variable_in_notation _ -> "E2208"
    | Head_already_has_notation _ -> "E2209"
    (* import *)
    | Circular_import _ -> "E2300"
    | Library_has_extension _ -> "W2301"
    | Invalid_filename _ -> "E2302"
    | Incompatible_flags _ -> "W2303"
    | No_such_file _ -> "E2304"
    | Cant_write_compiled_file _ -> "W2305"
    | Library_modified _ -> "E2306"
    (* chdir *)
    | Directory_changed _ -> "I2310"
    (* echo *)
    | Actions_in_compiled_file _ -> "W2400"
    (* undo *)
    | Not_enough_to_undo -> "E2500"
    (* section *)
    | No_such_section -> "E2600"
    | Invalid_section_name _ -> "E2601"
    (* oracles *)
    | Oracle_failed _ -> "E3000"
    (* Interactive proof *)
    | Open_holes _ -> "W3000"
    | No_such_hole _ -> "E3001"
    | Open_holes_remaining _ -> "E3002"
    | Hole _ -> "I3003"
    | No_open_holes -> "I3004"
    | Invalid_split _ -> "I3005"
    (* Command progress and success *)
    | Constant_defined _ -> "I0000"
    | Constant_assumed _ -> "I0001"
    | Notation_defined _ -> "I0002"
    | Loading_file _ -> "I0003"
    | File_loaded _ -> "I0004"
    | Hole_solved _ -> "I0005"
    | Commands_undone _ -> "I0006"
    | Section_opened _ -> "I0007"
    | Section_closed _ -> "I0008"
    | Split_term _ -> "I0009"
    | Option_set _ -> "I0100"
    | Display_set _ -> "I0101"
    (* Control of execution *)
    | Quit _ -> "I0200"
    | Break -> "E0201"
    (* Debugging *)
    | Show _ -> "I9999"

  let debug_printing = true

  let rec default_text (err : t) : text =
    (* We notice printing errors that occur while formatting this message, and later report them as part of the message. *)
    let printing_errors = ref Emp in
    let msg =
      PrintingError.run ~env:(fun d -> printing_errors := Snoc (!printing_errors, d)) @@ fun () ->
      match err with
      | Accumulated _ -> text "anomaly: multiple accumulated errors"
      | Parse_error -> text "parse error"
      | Encoding_error -> text "UTF-8 encoding error"
      | Parsing_ambiguity strs ->
          textf
            "@[<hv 2>potential ambiguity (one notation is a prefix of another). Notations involved:@ %a@]"
            (pp_print_list ~pp_sep:pp_print_space pp_print_string)
            strs
      | Invalid_variable str -> textf "invalid local variable name: %s" (String.concat "." str)
      | Invalid_field str -> textf "invalid field name: %s" str
      | Invalid_constr str -> textf "invalid constructor name: %s" str
      | Invalid_numeral str -> textf "invalid numeral: %s" str
      | Invalid_degeneracy str ->
          if str = "" then text "missing degeneracy" else textf "invalid degeneracy: %s" str
      | Invalid_variable_face (k, fa) ->
          textf "invalid face: variable of dimension %s has no face '%s'" (string_of_dim0 k)
            (string_of_sface fa)
      | No_relative_precedence (n1, n2) ->
          textf
            "notations \"%s\" and \"%s\" have no relative precedence or associativity; they can only be combined with parentheses"
            n1 n2
      | Not_enough_lambdas n ->
          textf "not enough non-cube variables for higher-dimensional abstraction: need %d more" n
      | Zero_dimensional_cube_abstraction str ->
          textf "cube abstraction not allowed for zero-dimensional %s" str
      | Mismatched_dimensions_in_cube_abstraction (m, n) ->
          textf "can't combine cube abstractions of different dimensions: %s ≠ %s"
            (string_of_dim0 m) (string_of_dim0 n)
      | Noncube_abstraction_in_higher_dimensional_match n ->
          textf "%s-dimensional match requires cube abstraction" (string_of_dim0 n)
      | Not_enough_arguments_to_function ->
          text "not enough arguments for a higher-dimensional function application"
      | Not_enough_arguments_to_instantiation ->
          text "not enough arguments to instantiate a higher-dimensional type"
      | Type_not_fully_instantiated (str, n) ->
          textf "type not fully instantiated in %s (need %s more dimensions)" str
            (string_of_dim0 (D.pos n))
      | Instantiating_zero_dimensional_type ty ->
          textf "@[<hv 0>can't apply/instantiate a zero-dimensional type@;<1 2>%a@]" pp_printed
            (print ~sort:`Type ty)
      | Unequal_synthesized_type { got; expected; which; why } ->
          let str, p1, p2 = Unequal.printables why in
          textf
            "@[<hv 0>term synthesized type@;<1 2>%a@ but is being checked against type@;<1 2>%a@ unequal %s:@;<1 2>%a@ does not equal@;<1 2>%a%a@]"
            pp_printed (print ~sort:`Type got) pp_printed (print ~sort:`Type expected) str
            pp_printed (print p1) pp_printed (print p2)
            (pp_print_option
               ~none:(fun _ () -> ())
               (fun ppf which -> fprintf ppf "@ (hint: %s boundaries are explicit)" which))
            which
      | Unequal_synthesized_boundary { face; got; expected; why } ->
          let str, p1, p2 = Unequal.printables why in
          textf
            "@[<hv 0>the %s-boundary synthesized type@;<1 2>%a@ but is being checked against type@;<1 2>%a@ unequal %s:@;<1 2>%a@ does not equal@;<1 2>%a@]"
            (string_of_sface face) pp_printed (print ~sort:`Type got) pp_printed
            (print ~sort:`Type expected) str pp_printed (print p1) pp_printed (print p2)
      | Not_enough_domains dim ->
          textf "not enough domains for an %s-dimensional function type" (string_of_dim0 dim)
      | Invalid_higher_function str -> textf "invalid higher function-type: %s" str
      | Invalid_nullary_application -> text "invalid nullary application"
      | Expected_nullary_application -> text "expected nullary application"
      | Checking_tuple_at_degenerated_record r ->
          textf "can't check a tuple against a record %a with a nonidentity degeneracy applied"
            pp_printed (print ~sort:`Type r)
      | Comatching_at_degenerated_codata r ->
          textf "can't comatch against a codatatype %a with a nonidentity degeneracy applied"
            pp_printed (print ~sort:`Type r)
      | Missing_field_in_tuple (f, _) ->
          textf "record field '%s' missing in tuple" (Field.to_string f)
      | Missing_method_in_comatch (f, p) ->
          textf "codata method '%s%s' missing in comatch" (Field.to_string f)
            (Option.fold ~none:"" ~some:string_of_pbij p)
      | Extra_field_in_tuple f -> (
          match f with
          | Some f -> textf "field '%s' in tuple doesn't occur in record type" f
          | None -> text "too many un-labeled fields in tuple")
      | Extra_method_in_comatch (f, p) ->
          textf "method '%s' in comatch doesn't occur in codata type" (Field.strings_to_string f p)
      | Invalid_field_in_tuple -> text "invalid field in tuple"
      | Invalid_method_in_comatch -> text "invalid method in comatch"
      | Duplicate_field_in_tuple f -> textf "record field '%s' appears more than once in tuple" f
      | Duplicate_method_in_comatch (f, p) ->
          textf "method '%s' appears more than once in comatch" (Field.strings_to_string f p)
      | Missing_constructor_in_match c ->
          textf "missing match clause for constructor %s" (Constr.to_string c)
      | Unnamed_variable_in_match -> text "unnamed match variable"
      | Checking_lambda_at_nonfunction ty ->
          textf "@[<hv 0>checking abstraction against non-function type@;<1 2>%a@]" pp_printed
            (print ~sort:`Type ty)
      | Checking_tuple_at_nonrecord ty ->
          textf "@[<hv 0>checking tuple against non-record type@;<1 2>%a@]" pp_printed
            (print ~sort:`Type ty)
      | Choice_mismatch ty ->
          textf "@[<hv 0>multi-choice term doesn't match type@;<1 2>%a@]" pp_printed
            (print ~sort:`Type ty)
      | Calc_error e -> textf "error in calc: %a" pp_printed (print e)
      | Comatching_at_noncodata ty ->
          textf "@[<hv 0>checking comatch against non-codata type@;<1 2>%a@]" pp_printed
            (print ~sort:`Type ty)
      | No_such_constructor (d, c) -> (
          match d with
          | `Data d ->
              textf "datatype %a has no constructor named %s" pp_printed (print ~sort:`Type d)
                (Constr.to_string c)
          | `Nondata d ->
              textf "non-datatype %a has no constructor named %s" pp_printed (print ~sort:`Type d)
                (Constr.to_string c)
          | `Other ty ->
              textf "@[<hv 0>non-datatype@;<1 2>%a@ has no constructor named %s@]" pp_printed
                (print ~sort:`Type ty) (Constr.to_string c))
      | Wrong_number_of_arguments_to_constructor (c, n) ->
          if n > 0 then
            textf "too many arguments to constructor %s (%d extra)" (Constr.to_string c) n
          else
            textf "not enough arguments to constructor %s (need %d more)" (Constr.to_string c)
              (abs n)
      | No_such_field (d, f) -> (
          let f =
            match f with
            | `Ins (f, p) -> Field.to_string f ^ string_of_ins p
            | `Pbij (f, p) -> Field.to_string f ^ string_of_pbij p
            | `Strings (str, ints) -> str ^ string_of_ins_ints ints
            | `Int n -> string_of_int n in
          match d with
          | `Record (eta, d) ->
              textf "%s type %a has no field named %s" (record_or_codata eta) pp_printed
                (print ~sort:`Type d) f
          | `Nonrecord d ->
              textf "non-record/codata type %a has no field named %s" pp_printed
                (print ~sort:`Type d) f
          | `Other tm -> textf "term %a has no field named %s" pp_printed (print tm) f
          | `Type tm ->
              textf "type %a has no field named %s (maybe turn off -parametric?)" pp_printed
                (print tm) f
          | `Degenerated_record eta ->
              let rc = record_or_codata eta in
              textf
                "%s type with a nonidentity degeneracy applied is no longer a %s, hence has no field named %s"
                rc rc f)
      | Wrong_dimension_of_field (eta, d, fld, used_at, intrinsic, err) ->
          let fldname =
            match fld with
            | `Field f -> Field.to_string f
            | `String s -> s in
          let err =
            match err with
            | `Ins p -> string_of_ins p
            | `Pbij p -> string_of_pbij p
            | `Ints ints -> string_of_ins_ints ints in
          let err = if err = "" then "empty suffix" else "suffix " ^ err in
          textf
            "@[<hv 0>field %s of %s type@;<1 2>%a@ has intrinsic dimension %s and used at dimension %s, can't have %s@]"
            fldname (record_or_codata eta) pp_printed (print ~sort:`Type d)
            (string_of_dim0 intrinsic) (string_of_dim0 used_at) err
      | Invalid_field_suffix (ty, f, p, evaldim) ->
          textf "invalid suffix %s for field %s of %s-dimensional type %a" (string_of_ins_ints p) f
            (string_of_dim0 evaldim) pp_printed (print ty)
      | Missing_instantiation_constructor (exp, got) ->
          let pp_got =
            match got with
            | `Nonconstr tm -> print tm
            | `Constr c -> print (PConstr c) in
          fun ppf ->
            fprintf ppf
              "@[<hv 0>instantiation arguments of datatype must be matching constructors:@ expected@;<1 2>%s@ but got@;<1 2>"
              (Constr.to_string exp);
            pp_printed ppf pp_got;
            pp_close_box ppf ()
      | Unequal_indices (t1, t2, why) ->
          let str, p1, p2 = Unequal.printables why in
          textf
            "@[<hv 0>index@;<1 2>%a@ of constructor application doesn't match the corresponding index@;<1 2>%a@ of datatype instance: unequal %s:@;<1 2>%a@ does not equal@;<1 2>%a@]"
            pp_printed (print t1) pp_printed (print t2) str pp_printed (print p1) pp_printed
            (print p2)
      | Unbound_variable (c, alt) -> (
          match alt with
          | [] -> textf "unbound variable: %s" c
          (* | [ (parts, fields) ] ->
                   textf "unbound variable: %s (hint: did you mean %s .%s ?)" c (String.concat "." parts)
                     (String.concat " ." fields) *)
          | _ ->
              textf "@[<v 0>unbound variable: %s (hint: did you mean one of:@;<1 2>%a@ ?)@]" c
                (pp_print_list
                   ~pp_sep:(fun ppf () -> pp_print_break ppf 1 2)
                   (fun ppf (p, f) ->
                     pp_print_string ppf (String.concat "." p);
                     pp_print_string ppf " .";
                     pp_print_list
                       ~pp_sep:(fun ppf () -> pp_print_string ppf " .")
                       pp_print_string ppf f))
                alt)
      (* The difference between "unbound variable" and "undefined constant" is that "undefined constant" is a BUG: it means a constant name was found in Scope, but its definition is missing from Global.  "Unbound variable" is the user error of writing a name that's NEITHER a local variable nor a constant in scope. *)
      | Undefined_constant c -> textf "undefined constant: %a" pp_printed (print c)
      | Undefined_metavariable v -> textf "undefined metavariable: %a" pp_printed (print v)
      | Nonsynthesizing pos -> textf "non-synthesizing term in synthesizing position (%s)" pos
      | Low_dimensional_argument_of_degeneracy { name; needed; got } ->
          textf
            "@[<hv 0>insufficient dimension for argument of degeneracy '%s':@  %s does not factor through %s@]"
            name (string_of_dim0 got) (string_of_dim0 needed)
      | Low_dimensional_type_of_degeneracy { name; needed; got } ->
          textf
            "@[<hv 0>insufficient dimension for expected type of degeneracy '%s':@  %s does not factor through %s@]"
            name (string_of_dim0 got) (string_of_dim0 needed)
      | Missing_argument_of_degeneracy deg -> textf "missing argument for degeneracy %s" deg
      | Applying_nonfunction_nontype (tm, ty) ->
          textf
            "@[<hv 0>attempt to apply/instantiate@;<1 2>%a@ of type@;<1 2>%a@ which is not a function-type or universe@]"
            pp_printed (print tm) pp_printed (print ~sort:`Type ty)
      | Unexpected_implicitness (i, what, str) ->
          textf "unexpected %s %s: %s"
            (match i with
            | `Implicit -> "implicit"
            | `Explicit -> "explicit")
            what str
      | Insufficient_dimension { needed; got; which } ->
          textf
            "@[<hv 0>insufficient dimension of primary argument for %s:@ %s does not factor through %s@]"
            which (string_of_dim0 got) (string_of_dim0 needed)
      | Unimplemented str -> textf "unimplemented: %s" str
      | Deprecated str -> textf "deprecated: %s" str
      | Matching_datatype_has_degeneracy ty ->
          textf
            "@[<hv 0>can't match on element of datatype@;<1 2>%a@ that has a degeneracy applied@]"
            pp_printed (print ty)
      | Wrong_number_of_arguments_to_pattern (c, n) ->
          if n > 0 then
            textf "too many arguments to constructor %s in match pattern (%d extra)"
              (Constr.to_string c) n
          else
            textf "not enough arguments to constructor %s in match pattern (need %d more)"
              (Constr.to_string c) (abs n)
      | Wrong_number_of_arguments_to_motive n ->
          textf "wrong number of arguments for match motive: should be %d" n
      | No_such_constructor_in_match (d, c) ->
          textf "datatype %a being matched against has no constructor %s" pp_printed (print d)
            (Constr.to_string c)
      | Duplicate_constructor_in_match c ->
          textf "constructor %s appears twice in match" (Constr.to_string c)
      | Matching_on_nondatatype ty ->
          textf "@[<hv 0>can't match on variable belonging to non-datatype@;<1 2>%a@]" pp_printed
            (print ~sort:`Type ty)
      | Matching_wont_refine (msg, Some d) ->
          textf "@[<hv 0>match will not refine the goal or context (%s):@;<1 2>%a@]" msg pp_printed
            (print d)
      | Matching_wont_refine (msg, None) ->
          textf "match will not refine the goal or context (%s)" msg
      | Dimension_mismatch (op, a, b) ->
          textf "dimension mismatch in %s (%s ≠ %s)" op (string_of_dim0 a) (string_of_dim0 b)
      | Anomaly str -> textf "anomaly: %s" str
      | No_such_level i -> textf "@[<hov 2>no level variable@ %a@ in context@]" pp_printed (print i)
      | Redefining_constant name ->
          textf "redefining constant: %a" pp_printed (print (PString (String.concat "." name)))
      | Invalid_constant_name (name, why) ->
          textf "invalid constant name: %a%a" pp_printed
            (print (PString (String.concat "." name)))
            (pp_print_option ~none:(fun _ _ -> ()) (fun ppf -> fprintf ppf " (%s)"))
            why
      | Too_many_commands -> text "too many commands: enter one at a time"
      | Fixity_mismatch ->
          text
            "notation command doesn't match pattern (tightness must be omitted only for outfix notations)"
      | Invalid_notation_pattern str -> textf "invalid notation pattern: %s" str
      | Invalid_tightness str -> textf "invalid tightness: %s" str
      | Invalid_notation_symbol str -> textf "invalid notation symbol: %s" str
      | Invalid_notation_head str -> textf "invalid notation head: %s" str
      | Duplicate_notation_variable x -> textf "duplicate notation variable: '%s'" x
      | Unused_notation_variable x -> textf "unused notation variable: '%s'" x
      | Notation_variable_used_twice x -> textf "notation variable '%s' used twice" x
      | Unbound_variable_in_notation xs ->
          textf "unbound variable(s) in notation definition: %s" (String.concat ", " xs)
      | Head_already_has_notation name ->
          textf "replacing printing notation for %s (previous notation will still be parseable)"
            name
      | Constant_assumed { name; parametric; holes } ->
          let p = if parametric then "" else "nonparametric " in
          if holes > 1 then
            textf "%saxiom %a assumed, containing %d holes" p pp_printed (print name) holes
          else if holes = 1 then
            textf "%saxiom %a assumed, containing 1 hole" p pp_printed (print name)
          else textf "%saxiom %a assumed" p pp_printed (print name)
      | Constant_defined { names; discrete; parametric; holes } -> (
          (* Nonparametricity trumps discreteness *)
          let prefix =
            if parametric || Dim.Endpoints.internal () then if discrete then "discrete " else ""
            else "nonparametric " in
          match names with
          | [] -> textf "anomaly: no constant defined"
          | [ name ] ->
              if holes > 1 then
                textf "%sconstant %a defined, containing %d holes" prefix pp_printed (print name)
                  holes
              else if holes = 1 then
                textf "%sconstant %a defined, containing 1 hole" prefix pp_printed (print name)
              else textf "%sconstant %a defined" prefix pp_printed (print name)
          | _ ->
              (if holes > 1 then
                 textf "@[<v 2>%sconstants defined mutually, containing %d holes:@,%a@]" prefix
                   holes
               else if holes = 1 then
                 textf "@[<v 2>%sconstants defined mutually, containing 1 hole:@,%a@]" prefix
               else textf "@[<v 2>%sconstants defined mutually:@,%a@]" prefix)
                (fun ppf names -> pp_print_list (fun ppf name -> pp_printed ppf name) ppf names)
                (List.map (fun name -> print name) names))
      | Notation_defined name -> textf "notation %s defined" name
      | Show (str, x) -> textf "%s: %a" str pp_printed (print x)
      | Comment_end_in_string ->
          text "comment-end sequence `} in quoted string: cannot be commented out"
      | Checking_canonical_at_nonuniverse (tm, ty) ->
          textf "checking %s at non-universe %a" tm pp_printed (print ~sort:`Type ty)
      | Bare_case_tree_construct str ->
          textf "%s encountered outside case tree, wrapping in implicit let-binding" str
      | Duplicate_method_in_codata fld ->
          textf "duplicate method in codatatype: %s" (Field.to_string fld)
      | Duplicate_field_in_record fld ->
          textf "duplicate field in record type: %s" (Field.to_string fld)
      | Duplicate_constructor_in_data c ->
          textf "duplicate constructor in datatype: %s" (Constr.to_string c)
      | Wrong_boundary_of_record n ->
          if n > 0 then
            textf "too many variables in boundary of higher-dimensional record (%d extra)" n
          else
            textf "not enough variables in boundary of higher-dimensional record (need %d more)"
              (abs n)
      | Invalid_constructor_type (c, why) -> (
          match why with
          | Left str -> textf "invalid output type for constructor %s:@ %s" (Constr.to_string c) str
          | Right why ->
              let str, p1, p2 = Unequal.printables why in
              textf
                "invalid output type for constructor %s:@ unequal %s:@;<1 2>%a@ does not equal@;<1 2>%a"
                (Constr.to_string c) str pp_printed (print p1) pp_printed (print p2))
      | Missing_constructor_type c ->
          textf "missing type for constructor %s of indexed datatype" (Constr.to_string c)
      | Locked_variable -> text "variable not available inside external degeneracy"
      | Locked_constant a ->
          textf
            "constant %a is or uses a nonparametric axiom, can't appear inside an external degeneracy"
            pp_printed (print a)
      | Axiom_in_parametric_definition a ->
          textf
            "constant %a is or uses a nonparametric axiom, can't be used in a parametric command"
            pp_printed (print a)
      | Hole (n, ty) -> textf "@[<v 0>hole %s:@,%a@]" n pp_printed (print ty)
      | No_open_holes -> text "no open holes"
      | Open_holes n ->
          if n = 1 then text "there is 1 open hole" else textf "there are %d open holes" n
      | Open_holes_remaining src -> (
          match src with
          | `File name -> textf "file %s contains open holes" name
          | `Stdin -> textf "stdin contains open holes"
          | `String -> textf "command-line exec string contains open holes")
      | Quit (Some src) -> textf "execution of %s terminated by quit" src
      | Quit None -> text "execution terminated by quit"
      | Synthesizing_recursion c ->
          textf "for '%a' to be recursive, it must have a declared type" pp_printed (print c)
      | Invalid_synthesized_type (str, ty) ->
          textf "type %a synthesized by %s is invalid for entire term" pp_printed
            (print ~sort:`Type ty) str
      | Unrecognized_attribute -> textf "unrecognized attribute"
      | Invalid_degeneracy_action (str, nk, n) ->
          textf
            "invalid degeneracy action on %s: dimension '%s' doesn't factor through codomain '%s'"
            str (string_of_dim0 nk) (string_of_dim0 n)
      | Wrong_number_of_patterns -> text "wrong number of patterns for match"
      | Inconsistent_patterns -> text "inconsistent patterns in match"
      | Overlapping_patterns -> text "overlapping patterns in match"
      | No_remaining_patterns -> text "no remaining patterns while parsing match"
      | Invalid_refutation -> text "invalid refutation: no discriminee has an empty type"
      | Duplicate_pattern_variable x ->
          textf "variable name '%s' used more than once in match patterns" x
      | Type_expected (str, got) ->
          textf "expected type while %s, got %a" str pp_printed (print got)
      | Circular_import files ->
          textf "circular imports:@,@[<v 2>%a@]"
            (pp_print_list
               ~pp_sep:(fun ppf () ->
                 pp_print_cut ppf ();
                 pp_print_string ppf "imports ")
               pp_print_string)
            files
      | Loading_file file -> textf "loading file: %s" file
      | File_loaded (file, `Compiled) -> textf "file loaded: %s (compiled)" file
      | File_loaded (file, `Source) -> textf "file loaded: %s (source)" file
      | Library_has_extension file -> textf "putative library name '%s' has extension" file
      | Invalid_filename file -> textf "filename '%s' does not have 'ny' extension" file
      | Library_modified file ->
          textf
            "library '%s'@ was@ already@ loaded@ in@ this@ session@ but@ has@ been@ modified@ since@ then:@ you@ must@ restart@ Narya@ to@ reload@ it"
            file
      | Directory_changed dir -> textf "current directory changed to@ %s" dir
      | No_such_file file -> textf "error opening file: %s" file
      | Cant_write_compiled_file file -> textf "can't write compiled file: %s" file
      | Incompatible_flags (file, flags) ->
          textf "file '%s' was compiled with incompatible flags %s, recompiling" file flags
      | Actions_in_compiled_file file ->
          textf "not re-executing echo/synth/show commands when loading compiled file %s" file
      | No_such_hole i -> textf "no open hole numbered %d" i
      | Invalid_split (which, str) ->
          textf "invalid split: %s belongs to a %s"
            (match which with
            | `Goal -> "goal"
            | `Term -> "term")
            str
      | Hole_solved h ->
          if h > 1 then textf "hole solved, containing %d new holes" h
          else if h = 1 then text "hole solved, containing 1 new hole"
          else text "hole solved"
      | Split_term t -> textf "@[<v 2>split successful, hole could be solved by:@;%a@]" pp_printed t
      | Forbidden_interactive_command cmd ->
          textf "command '%s' only allowed in interactive mode" cmd
      | Not_enough_to_undo -> text "not enough commands to undo"
      | Commands_undone n -> if n = 1 then text "1 command undone" else textf "%d commands undone" n
      | Section_opened prefix -> textf "section %s opened" (String.concat "." prefix)
      | Section_closed prefix -> textf "section %s closed" (String.concat "." prefix)
      | Display_set (setting, str) -> textf "display set %s to %s" setting str
      | Option_set (setting, str) -> textf "option set %s to %s" setting str
      | No_such_section -> text "no section here to end"
      | Invalid_section_name name -> textf "invalid section name: %s" (String.concat "." name)
      | Break -> text "user interrupt"
      | No_holes_allowed str -> (
          match str with
          | `Command cmd -> textf "command '%s' cannot contain holes" cmd
          | `File file -> textf "imported file '%s' cannot contain holes" file
          | `Other where -> textf "%s cannot contain holes" where)
      | Ill_scoped_connection -> text "ill-scoped connection"
      | Cyclic_term -> text "cycle in graphical term"
      | Oracle_failed (str, tm) -> textf "oracle failed: %s: %a" str pp_printed (print tm)
      | Invalid_flags -> text "invalid combination of command-line flags" in
    match !printing_errors with
    | Emp -> msg
    | Snoc _ ->
        if debug_printing then
          textf
            "@[<v 0>%t@;@;displaying this error encountered one or more terms that are unprintable; errors encountered were:@;%a@]"
            msg
            (pp_print_list (fun ppf x -> default_text x ppf))
            (Bwd.to_list !printing_errors)
        else
          textf
            "@[<v 0>%t@;@;(displaying this error encountered one or more terms that are unprintable,@ probably due to previous errors.@ If there are no other errors, this is probably a bug; please report it.)@]"
            msg
end

include Asai.StructuredReporter.Make (Code)
open Code

(* Don't try to set the 'message' field of an Asai.Diagnostic.t directly, since the 'explanation' field was already computed from it.  Use this function instead.  See https://github.com/RedPRL/asai/issues/189. *)
let with_message d message =
  let explanation = Asai.Range.locate_opt d.explanation.loc (Code.default_text message) in
  { d with message; explanation }

let struct_at_degenerated_type : type s et. (s, et) eta -> printable -> Code.t =
 fun eta name ->
  match eta with
  | Eta -> Checking_tuple_at_degenerated_record name
  | Noeta -> Comatching_at_degenerated_codata name

let extra_field_in_struct : type s et. (s, et) eta -> string * string list -> Code.t =
 fun eta fld ->
  match eta with
  | Eta -> Extra_field_in_tuple (Some (fst fld))
  | Noeta -> Extra_method_in_comatch fld

let duplicate_field_in_struct : type s et. (s, et) eta -> string * string list -> Code.t =
 fun eta fld ->
  match eta with
  | Eta -> Duplicate_field_in_tuple (fst fld)
  | Noeta -> Duplicate_method_in_comatch (fst fld, snd fld)

let missing_field_in_struct : type s et i n r.
    (s, et) eta -> ?pbij:(n, i, r) pbij -> i Field.t -> Code.t =
 fun eta ?pbij fld ->
  match eta with
  | Eta -> Missing_field_in_tuple (fld, pbij)
  | Noeta -> Missing_method_in_comatch (fld, pbij)

let struct_at_nonrecord : type s et. (s, et) eta -> printable -> Code.t =
 fun eta p ->
  match eta with
  | Eta -> Checking_tuple_at_nonrecord p
  | Noeta -> Comatching_at_noncodata p

let ( <|> ) : type a. a option -> Code.t -> a =
 fun x e ->
  match x with
  | Some x -> x
  | None -> fatal e

(* After a fatal error, we allow continuing to typecheck other parts of the term that don't depend on that error and reporting any additional errors they produce.  This is handled by a special "Accumulated" error that encapsulates a backwards list of diagnostics.  When displaying this error, we instead descend into its list, recursively, and display all the constituent errors. *)

module Terminal = Asai.Tty.Make (Code)

let rec display ?use_ansi ?output ?(empty_ok = false) (d : Code.t Asai.Diagnostic.t) =
  match d.message with
  | Accumulated (why, Emp) when not empty_ok ->
      Terminal.display ?use_ansi ?output
        (with_message d (Anomaly ("unexpected empty error accumulation: " ^ why)))
  | Accumulated (_name, msgs) ->
      Mbwd.miter (fun [ e ] -> display ?use_ansi ?output ~empty_ok:true e) [ msgs ]
  | _ -> try_with ~fatal:(fun _ -> ()) @@ fun () -> Terminal.display ?use_ansi ?output d

(* We also may need to extract an accumulated singleton, for testing purposes. *)
let rec unaccumulate (c : Code.t) : Code.t =
  match c with
  | Accumulated (_, Snoc (Emp, c)) -> unaccumulate c.message
  | c -> c

(* Re-raise one diagnostic, if given, otherwise another. *)
let fatal_or d e =
  match d with
  | Some d -> fatal_diagnostic d
  | None -> fatal e

type dim_err = { make : 'a 'b. needed:'a D.t -> got:'b D.t -> Code.t }

let low_dim_arg_err (name : string) : dim_err =
  { make = (fun ~needed ~got -> Low_dimensional_argument_of_degeneracy { name; needed; got }) }

let low_dim_ty_err (name : string) : dim_err =
  { make = (fun ~needed ~got -> Low_dimensional_type_of_degeneracy { name; needed; got }) }

let anomaly_dim_err str : dim_err =
  {
    make =
      (fun ~needed ~got ->
        let _ = (needed, got) in
        Anomaly str);
  }
