open Util
open Dim
include Energy

type 'a located = 'a Asai.Range.located

let locate_opt = Asai.Range.locate_opt
let locate_map f ({ value; loc } : 'a located) = locate_opt loc (f value)

(* Raw (unchecked) terms, using intrinsically well-scoped De Bruijn indices, and separated into synthesizing terms and checking terms.  These match the user-facing syntax rather than the internal syntax.  In particular, applications, abstractions, and pi-types are all unary, there is only one universe, and the only operator actions are refl (including Id) and sym. *)

(* We actually formulate a more general notion of raw term that is parametrized over a notion of "index".  Narya proper only uses ordinary type-level natural numbers as indices, but other frontends may need a notion of raw term that uses explicit names or something else.  Note that all raw terms clearly separate *variables* from *constants*, and the "resolution" process detailed below that transitions between them preserves this distinction.  Therefore, even raw terms that use "explicit names" should not be regarded as an "intermediate parsing step" before turning the names into indices, because a scope of local variables is already required to separate the variables from the constant names (since local variables can shadow global constants).  Instead it is better to think of them as more like the "values" in NbE which can be silently weakened to arbitrary contexts. *)

module type Indices = sig
  (* A 'name' is what labels a variable at the point of *binding*.  In named terms this carries semantic information; in indexed terms it is just annotation, with the semantic information carried by the change in the parametrizing type. *)
  type name

  (* There must be unnamed variables. *)
  val none : name

  (* These are how the parametrizing type changes with each bound variable. *)
  type 'a suc

  (* An 'index' is what labels a variable at the point of *use*. *)
  type 'a index

  (* A 'scope' represents the local variables available, usually as a list or vector of names.  This is only used as something to store with a Hole. *)
  type 'a scope

  (* We also allow embedding an arbitrary object. *)
  type 'a embed
end

(* This is the standard instantiation that uses type-level nats as De Bruijn indices. *)
module DeBruijnIndices = struct
  type name = string option

  let none : name = None

  type 'a index = 'a N.index
  type 'a suc = 'a N.suc
  type 'a scope = (name, 'a) Bwv.t
  type 'a embed = |
end

module rec Make : functor (I : Indices) -> sig
  type ('a, 'b, 'ab) bplus =
    | Zero : ('a, Fwn.zero, 'a) bplus
    | Suc : ('a I.suc, 'b, 'ab) bplus -> ('a, 'b Fwn.suc, 'ab) bplus

  val bplus_zero : ('a, Fwn.zero, 'ab) bplus -> ('a, 'ab) Eq.t
  val bplus_suc : ('a, 'b Fwn.suc, 'ab) bplus -> ('a I.suc, 'b, 'ab) bplus
  val bplus_right : ('a, 'b, 'ab) bplus -> 'b Fwn.t

  type ('a, 'b) has_bplus = Bplus : ('a, 'b, 'ab) bplus -> ('a, 'b) has_bplus

  val bplus : 'b Fwn.t -> ('a, 'b) has_bplus

  module Namevec : sig
    type (_, _, _) t =
      | [] : ('a, Fwn.zero, 'a) t
      | ( :: ) : I.name * ('a I.suc, 'b, 'ab) t -> ('a, 'b Fwn.suc, 'ab) t

    val length : ('a, 'b, 'ab) t -> 'b Fwn.t
    val bplus : ('a, 'b, 'ab) t -> ('a, 'b, 'ab) bplus
    val none : ('a, 'b, 'ab) bplus -> ('a, 'b, 'ab) t
    val of_vec : ('a, 'b, 'ab) bplus -> (I.name, 'b) Vec.t -> ('a, 'b, 'ab) t
  end

  type 'a index = 'a I.index * any_sface option

  module DomFam : sig
    type (_, _, _) t = DomFam : I.name * 'left Make(I).check located -> ('left, 'n, 'b) t
  end

  module DomCube : module type of struct
    include Icube (I) (DomFam)
  end

  type _ synth =
    | Var : 'a index -> 'a synth
    | Const : Constant.t -> 'a synth
    | Field : 'a synth located * [ `Name of string * int list | `Int of int ] -> 'a synth
    | Pi : I.name * 'a check located * 'a I.suc check located -> 'a synth
    | HigherPi : I.name * 'a synth located * 'a I.suc synth located -> 'a synth
    | InstHigherPi : 'n D.pos * ('a, 'n, unit, 'an) DomCube.t * 'an check located -> 'a synth
    | App :
        'a check located * 'a check option located * [ `Implicit | `Explicit ] located
        -> 'a synth
    | Asc : 'a check located * 'a check located -> 'a synth
    | AscLam : I.name located * 'a check located * 'a I.suc synth located -> 'a synth
    | UU : 'a synth
    | Let : I.name * 'a synth located * 'a I.suc check located -> 'a synth
    | Letrec : ('a, 'b, 'ab) tel * ('ab check located, 'b) Vec.t * 'ab check located -> 'a synth
    | Act : string located * ('m, 'n) deg * 'a check located option -> 'a synth
    | Match : {
        tm : 'a synth located;
        sort : [ `Implicit | `Explicit of 'a check located | `Nondep of int located ];
        branches : (Constr.t, 'a branch) Abwd.t;
        refutables : 'a refutables option;
        highers : bool ref located list;
      }
        -> 'a synth
    | Fail : Reporter.Code.t -> 'a synth
    | ImplicitSApp : 'a synth located * Asai.Range.t option * 'a synth located -> 'a synth
    | SFirst :
        ([ `Data of Constr.t list | `Codata of string list | `Any ] * 'a synth * bool) list
        * 'a synth option
        -> 'a synth
    | Calc : 'a synth located * ('a check located * 'a check located option) list -> 'a synth

  and _ check =
    | Synth : 'a synth -> 'a check
    | Lam : {
        name : I.name located;
        cube : [ `Cube of (D.wrapped * Asai.Range.t option) option ref | `Normal ] located;
        implicit : [ `Explicit | `Implicit ];
        dom : 'a check located option;
        body : 'a I.suc check located;
      }
        -> 'a check
    | Struct :
        ('s, 'et) eta
        * ((string * string list) option, [ `Normal | `Cube ] located * 'a check located) Abwd.t
        -> 'a check
    | Constr : Constr.t located * 'a check located list -> 'a check
    | Numeral : Q.t -> 'a check
    | Empty_co_match : 'a check
    | Data : (Constr.t, 'a dataconstr located) Abwd.t -> 'a check
    | Codata : (Field.wrapped, 'a codatafield) Abwd.t -> 'a check
    | Record : ('a, 'c, 'ac) Namevec.t located * ('ac, 'd, 'acd) tel * opacity -> 'a check
    | SelfRecord : (Field.wrapped, 'a codatafield) Abwd.t -> 'a check
    | Refute : 'a synth located list * [ `Explicit | `Implicit ] -> 'a check
    | Hole : {
        scope : 'a I.scope;
        loc : Asai.Range.t;
        li : No.interval;
        ri : No.interval;
        num : int ref;
      }
        -> 'a check
    | Realize : 'a check -> 'a check
    | ImplicitApp : 'a synth located * (Asai.Range.t option * 'a check located) list -> 'a check
    | Embed : 'a I.embed -> 'a check
    | First :
        ([ `Data of Constr.t list | `Codata of string list | `Any ] * 'a check * bool) list
        -> 'a check
    | Oracle : 'a check located -> 'a check
    | Weaken : 'a check * ('a I.suc, 'b) Eq.t -> 'b check

  and _ branch =
    | Branch :
        ('a, 'b, 'ab) Namevec.t located
        * [ `Normal of Asai.Range.t option | `Cube of bool ref located list ]
        * 'ab check located
        -> 'a branch

  and _ dataconstr = Dataconstr : ('a, 'b, 'ab) tel * 'ab check located option -> 'a dataconstr
  and _ codatafield = Codatafield : I.name * 'a I.suc check located -> 'a codatafield
  and 'a refutables = { refutables : 'b 'ab. ('a, 'b, 'ab) bplus -> 'ab synth located list }

  and (_, _, _) tel =
    | Emp : ('a, Fwn.zero, 'a) tel
    | Ext : I.name * 'a check located * ('a I.suc, 'b, 'ab) tel -> ('a, 'b Fwn.suc, 'ab) tel

  val fwn_of_tel : ('a, 'b, 'c) tel -> 'b Fwn.t
end =
functor
  (I : Indices)
  ->
  struct
    (* A version of Fwn.bplus operating on I-indices, using I.suc instead of N.suc. *)
    type ('a, 'b, 'ab) bplus =
      | Zero : ('a, Fwn.zero, 'a) bplus
      | Suc : ('a I.suc, 'b, 'ab) bplus -> ('a, 'b Fwn.suc, 'ab) bplus

    let bplus_zero : type a ab. (a, Fwn.zero, ab) bplus -> (a, ab) Eq.t = function
      | Zero -> Eq

    let bplus_suc : type a b ab. (a, b Fwn.suc, ab) bplus -> (a I.suc, b, ab) bplus = function
      | Suc ab -> ab

    let rec bplus_right : type a b ab. (a, b, ab) bplus -> b Fwn.t = function
      | Zero -> Zero
      | Suc ab -> Suc (bplus_right ab)

    type ('a, 'b) has_bplus = Bplus : ('a, 'b, 'ab) bplus -> ('a, 'b) has_bplus

    let rec bplus : type a b. b Fwn.t -> (a, b) has_bplus = function
      | Zero -> Bplus Zero
      | Suc b ->
          let (Bplus ab) = bplus b in
          Bplus (Suc ab)

    (* Here's a special kind of Vector of names that raises the parametrizing indices as we go, and also stores the bplus of the starting index with the length.  This simplifies things in a few places where otherwise we would have to store a bplus along with a vector of names to get the correct extended context length for bodies of terms under multiple binders. *)
    module Namevec = struct
      type (_, _, _) t =
        | [] : ('a, Fwn.zero, 'a) t
        | ( :: ) : I.name * ('a I.suc, 'b, 'ab) t -> ('a, 'b Fwn.suc, 'ab) t

      let rec length : type a b ab. (a, b, ab) t -> b Fwn.t = function
        | [] -> Zero
        | _ :: xs -> Suc (length xs)

      let rec bplus : type a b ab. (a, b, ab) t -> (a, b, ab) bplus = function
        | [] -> Zero
        | _ :: xs -> Suc (bplus xs)

      let rec none : type a b ab. (a, b, ab) bplus -> (a, b, ab) t =
       fun ab ->
        match bplus_right ab with
        | Zero ->
            let Eq = bplus_zero ab in
            []
        | Suc _ ->
            let ab = bplus_suc ab in
            I.none :: none ab

      let rec of_vec : type a b ab. (a, b, ab) bplus -> (I.name, b) Vec.t -> (a, b, ab) t =
       fun ab xs ->
        match (ab, xs) with
        | Zero, [] -> []
        | Suc ab, x :: xs -> x :: of_vec ab xs
    end

    (* A raw De Bruijn index is a well-scoped (backwards) natural number (or, more generally, an element of I.index) together with a possible face.  During typechecking we will verify that the face, if given, is applicable to the variable as a "cube variable", and compile the combination into a more strongly well-scoped kind of index. *)
    type 'a index = 'a I.index * any_sface option

    module DomFam = struct
      type (_, _, _) t = DomFam : I.name * 'left Make(I).check located -> ('left, 'n, 'b) t
    end

    module DomCube = Icube (I) (DomFam)

    (* Synthesizable raw terms *)
    type _ synth =
      | Var : 'a index -> 'a synth
      | Const : Constant.t -> 'a synth
      (* A field projection from a possibly-higher-coinductive type comes with a suffix that is a string of integers, denoting a partial bijection between n and m that is total on n.  This is the same as an injection from n to m, or equivalently an insertion of n into m∖l to produce m, where l = image(n). *)
      | Field : 'a synth located * [ `Name of string * int list | `Int of int ] -> 'a synth
      | Pi : I.name * 'a check located * 'a I.suc check located -> 'a synth
      | HigherPi : I.name * 'a synth located * 'a I.suc synth located -> 'a synth
      | InstHigherPi : 'n D.pos * ('a, 'n, unit, 'an) DomCube.t * 'an check located -> 'a synth
      (* The location of the implicitness flag is, in the implicit case, the location of the braces surrounding the implicit argument. *)
      | App :
          'a check located * 'a check option located * [ `Implicit | `Explicit ] located
          -> 'a synth
      | Asc : 'a check located * 'a check located -> 'a synth
      (* Abstraction with ascribed variable.  Currently can't be a cube or implicit.  *)
      | AscLam : I.name located * 'a check located * 'a I.suc synth located -> 'a synth
      | UU : 'a synth
      (* A Let can either synthesize or (sometimes) check.  It synthesizes only if its body also synthesizes, but we wait until typechecking type to look for that, so that if it occurs in a checking context the body can also be checking.  Thus, we make it a "synthesizing term".  The term being bound must also synthesize; the shorthand notation "let x : A := M" is expanded during parsing to "let x := M : A". *)
      | Let : I.name * 'a synth located * 'a I.suc check located -> 'a synth
      (* Letrec has a telescope of types, so that each can depend on the previous ones, and an equal-length vector of bound terms, all in the context extended by all the variables being bound, plus a body that is also in that context. *)
      | Letrec : ('a, 'b, 'ab) tel * ('ab check located, 'b) Vec.t * 'ab check located -> 'a synth
      (* An Act can also often check, but can also synthesizes if its body does.  *)
      | Act : string located * ('m, 'n) deg * 'a check located option -> 'a synth
      (* A Match can also sometimes check, but synthesizes if it has an explicit return type or if it is nondependent and its first branch synthesizes. *)
      | Match : {
          tm : 'a synth located;
          (* Implicit means no "return" statement was given, so Narya has to guess what to do.  Explicit means a "return" statement was given with a motive.  "Nondep" means a placeholder return statement like "_ ↦ _" was given, indicating that a non-dependent matching is intended (to silence hints about fallback from the implicit case). *)
          sort : [ `Implicit | `Explicit of 'a check located | `Nondep of int located ];
          branches : (Constr.t, 'a branch) Abwd.t;
          refutables : 'a refutables option;
          (* If this is the "master" controlling match in a family of matches generated by a multiple/deep match, record all the toggles for all the ⤇ matches to check that they actually contain something higher-dimensional *)
          highers : bool ref located list;
        }
          -> 'a synth
      | Fail : Reporter.Code.t -> 'a synth
      (* Pass the synthesized type of an argument as an implicit first argument of a function. *)
      | ImplicitSApp : 'a synth located * Asai.Range.t option * 'a synth located -> 'a synth
      (* Try several terms, testing for each whether the synthesized type of the specified term has certain constructors or fields. *)
      | SFirst :
          ([ `Data of Constr.t list | `Codata of string list | `Any ] * 'a synth * bool) list
          * 'a synth option
          -> 'a synth
      (* Chain of equational reasoning *)
      | Calc : 'a synth located * ('a check located * 'a check located option) list -> 'a synth

    (* Checkable raw terms *)
    and _ check =
      | Synth : 'a synth -> 'a check
      (* An abstraction knows whether it is a cube abstraction (⤇) or a normal one (↦).  In the former case it stores an optional dimension, so that multiple variables in the same abstraction (x y ⤇) can be enforced to be the same dimension, and the location of the previous variable that set the dimension. *)
      | Lam : {
          name : I.name located;
          cube : [ `Cube of (D.wrapped * Asai.Range.t option) option ref | `Normal ] located;
          implicit : [ `Explicit | `Implicit ];
          dom : 'a check located option;
          body : 'a I.suc check located;
        }
          -> 'a check
      (* A "Struct" is our current name for both tuples and comatches, which share a lot of their implementation even though they are conceptually and syntactically distinct.  Those with eta=`Eta are tuples, those with eta=`Noeta are comatches.  We index them by an option so as to include any unlabeled fields, with their relative order to the labeled ones.  The field hasn't been interned to an intrinsic dimension yet (that depends on what it checks against), so it's just a string name, plus a list of strings to indicate a pbij for higher fields.  We also store whether they were defined with a ↦ or a ⤇. *)
      | Struct :
          ('s, 'et) eta
          * ((string * string list) option, [ `Normal | `Cube ] located * 'a check located) Abwd.t
          -> 'a check
      | Constr : Constr.t located * 'a check located list -> 'a check
      | Numeral : Q.t -> 'a check
      (* "[]", which could be either an empty pattern-matching lambda or an empty comatch *)
      | Empty_co_match : 'a check
      | Data : (Constr.t, 'a dataconstr located) Abwd.t -> 'a check
      (* A codatatype binds one more "self" variable in the types of each of its fields.  For a higher-dimensional codatatype (like a codata version of Gel), this becomes a cube of variables.  The field also knows its dimension already. *)
      | Codata : (Field.wrapped, 'a codatafield) Abwd.t -> 'a check
      (* A record type binds its "self" variable namelessly, exposing it to the user by additional variables that are bound locally to its fields.  This can't be "cubeified" as easily, so we have the user specify a list of ordinary variables to be its boundary.  Thus, in practice below 'c must be a number of faces associated to a dimension, but the parser doesn't know the dimension, so it can't ensure that.  The unnamed internal variable is included as the last one. *)
      | Record : ('a, 'c, 'ac) Namevec.t located * ('ac, 'd, 'acd) tel * opacity -> 'a check
      (* There's also a notation for record types that uses self variables like codata. *)
      | SelfRecord : (Field.wrapped, 'a codatafield) Abwd.t -> 'a check
      (* Empty match against the first one of the arguments belonging to an empty type. *)
      | Refute : 'a synth located list * [ `Explicit | `Implicit ] -> 'a check
      (* A hole must store the entire "state" from when it was entered, so that the user can later go back and fill it with a term that would have been valid in its original position.  This includes the variables in lexical scope, which are available only during parsing, so we store them here at that point.  During typechecking, when the actual metavariable is created, we save the lexical scope along with its other context and type data.  A hole also stores its source location so that proofgeneral can create an overlay at that place, and the notation tightnesses of the hole location. *)
      | Hole : {
          scope : 'a I.scope;
          loc : Asai.Range.t;
          li : No.interval;
          ri : No.interval;
          num : int ref;
        }
          -> 'a check
      (* Force a leaf of the case tree *)
      | Realize : 'a check -> 'a check
      (* Pass the type being checked against as the implicit first argument of a function. *)
      | ImplicitApp : 'a synth located * (Asai.Range.t option * 'a check located) list -> 'a check
      (* Embed an arbitrary object *)
      | Embed : 'a I.embed -> 'a check
      (* Try several terms, testing for each whether the goal type has certain constructors or fields. *)
      | First :
          ([ `Data of Constr.t list | `Codata of string list | `Any ] * 'a check * bool) list
          -> 'a check
      (* Check a term, but then verify its correctness with an external oracle. *)
      | Oracle : 'a check located -> 'a check
      (* Lift a term to a longer context *)
      | Weaken : 'a check * ('a I.suc, 'b) Eq.t -> 'b check

    (* The location of the namevec is that of the whole pattern.  The location of the cube flag is that of the mapsto. *)
    and _ branch =
      | Branch :
          ('a, 'b, 'ab) Namevec.t located
          (* The ref argument to `Cube records whether any of the matches in this ⤇ group are *actually* higher-dimensional, so we can raise an error if they're not. *)
          * [ `Normal of Asai.Range.t option | `Cube of bool ref located list ]
          * 'ab check located
          -> 'a branch

    (* *)
    and _ dataconstr = Dataconstr : ('a, 'b, 'ab) tel * 'ab check located option -> 'a dataconstr

    (* A field of a codatatype has a self variable and a type.  At the raw level we don't need any more information about higher fields. *)
    and _ codatafield = Codatafield : I.name * 'a I.suc check located -> 'a codatafield

    (* A raw match stores the information about the pattern variables available from previous matches that could be used to refute missing cases.  But it can't store them as raw terms, since they have to be in the correct context extended by the new pattern variables generated in any such case.  So it stores them as a callback that puts them in any such extended context. *)
    and 'a refutables = { refutables : 'b 'ab. ('a, 'b, 'ab) bplus -> 'ab synth located list }

    (* An ('a, 'b, 'ab) tel is a raw telescope of length 'b in context 'a, with 'ab = 'a+'b the extended context. *)
    and (_, _, _) tel =
      | Emp : ('a, Fwn.zero, 'a) tel
      | Ext : I.name * 'a check located * ('a I.suc, 'b, 'ab) tel -> ('a, 'b Fwn.suc, 'ab) tel

    (* The length of a telescope is a forwards nat. *)
    let rec fwn_of_tel : type a b c. (a, b, c) tel -> b Fwn.t = function
      | Emp -> Zero
      | Ext (_, _, tel) -> Suc (fwn_of_tel tel)
  end

module Indexed = Make (DeBruijnIndices)

(* We supply a generic name-resolution module that turns explicit names into De Bruijn indices, threading through a scope of bound variables.  In fact, it is more straightforward to implement a general translation operation that turns raw terms for one implementation of Indices into those for another.  For this we need an additional parameter module.  *)

module type Resolver = sig
  module I1 : Indices
  module I2 : Indices

  module T1 : module type of struct
    include Make (I1)
  end

  module T2 : module type of struct
    include Make (I2)
  end

  type ('a1, 'a2) scope

  (* What we need is basically the ability to look up names and indices to translate them.  Typically this will be a vector of explicit names used to translate in one direction or the other between names and nat-indices.  *)
  val reindex : ('a1, 'a2) scope -> 'a1 I1.index -> ('a2 I2.index, Reporter.Code.t) Result.t
  val rename : ('a1, 'a2) scope -> I1.name -> I2.name

  (* We also need to be able to translate the 'scopes' that appear in Holes. *)
  val rescope : ('a1, 'a2) scope -> 'a1 I1.scope -> 'a2 I2.scope

  (* This is how we extend a scope when passing under a binder. *)
  val snoc : ('a1, 'a2) scope -> I1.name -> ('a1 I1.suc, 'a2 I2.suc) scope

  (* Remove the last element of a scope *)
  type (_, _) pop = Pop : ('a1, 'a2) scope * ('a2 I2.suc, 'a2s) Eq.t -> ('a1, 'a2s) pop

  val pop : ('a1 I1.suc, 'a2) scope -> ('a1, 'a2) pop

  (* This is for annotations and saving all the seen scopes. *)
  val visit : ('a1, 'a2) scope -> 'a2 T2.check located -> unit

  (* Deal with embedded objects, possibly recursively *)
  val embed : ('a1, 'a2) scope -> 'a1 I1.embed -> ('a1 T1.check, 'a2 T2.check) Either.t
end

(* Resolution is basically a straightforward structural induction that walks the terms, extending the scope as it goes. *)
module Resolve (R : Resolver) = struct
  (* We can't make things more concise with aliases like
       module I1 = R.I1
     because module aliases are not preserved by functors: F(I1) will not be equal to F(R.I1). *)

  let rec append : type a1 a2 b ab1 ab2.
      (a1, a2) R.scope ->
      (a1, b, ab1) R.T1.Namevec.t ->
      (a2, b, ab2) R.T2.bplus ->
      (ab1, ab2) R.scope =
   fun ctx xs ab2 ->
    match xs with
    | [] ->
        let Eq = R.T2.bplus_zero ab2 in
        ctx
    | x :: xs ->
        let ab2 = R.T2.bplus_suc ab2 in
        append (R.snoc ctx x) xs ab2

  let rec renames : type a1 a2 b ab1 ab2.
      (a1, a2) R.scope ->
      (a1, b, ab1) R.T1.Namevec.t ->
      (a2, b, ab2) R.T2.bplus ->
      (a2, b, ab2) R.T2.Namevec.t =
   fun ctx xs ab ->
    match xs with
    | [] ->
        let Eq = R.T2.bplus_zero ab in
        []
    | x :: xs ->
        let ab = R.T2.bplus_suc ab in
        R.rename ctx x :: renames (R.snoc ctx x) xs ab

  module DomTraverse =
    IcubeTraverse2 (R.I1) (R.I2) (R.T1.DomFam) (R.T2.DomFam)
      (struct
        type ('a1, 'a2) t = ('a1, 'a2) R.scope
      end)

  let rec synth : type a1 a2. (a1, a2) R.scope -> a1 R.T1.synth located -> a2 R.T2.synth located =
   fun ctx tm ->
    let newtm : a2 R.T2.synth =
      match tm.value with
      | Var (name, fa) -> (
          (* Here's the important resolution bit: we "look up" names in the scope (although at this point that is just an abstract operation supplied by the caller), and insert an error in case of failure.  Note that we store the error in the term rather than raising it immediately; a caller who wants to raise it immediately can do that in the function 'scope_error' instead of returning it. *)
          match R.reindex ctx name with
          | Ok ix -> Var (ix, fa)
          | Error e -> Fail e)
      | Const c -> Const c
      | Field (tm, fld) -> Field (synth ctx tm, fld)
      | Pi (x, dom, cod) -> Pi (R.rename ctx x, check ctx dom, check (R.snoc ctx x) cod)
      | HigherPi (x, dom, cod) -> HigherPi (R.rename ctx x, synth ctx dom, synth (R.snoc ctx x) cod)
      | InstHigherPi (n, doms, cod) ->
          let (Gfolded (doms, ctx)) =
            DomTraverse.fold_map_left
              {
                foldmap =
                  (fun _ ctx (DomFam (x, dom)) ->
                    (DomFam (R.rename ctx x, check ctx dom), R.snoc ctx x));
              }
              ctx doms in
          InstHigherPi (n, doms, check ctx cod)
      | App (fn, arg, impl) ->
          let arg =
            match arg.value with
            | Some x ->
                let arg = check ctx (locate_opt arg.loc x) in
                locate_opt arg.loc (Some arg.value)
            | None -> locate_opt arg.loc None in
          App (check ctx fn, arg, impl)
      | Asc (tm, ty) -> Asc (check ctx tm, check ctx ty)
      | AscLam (x, dom, body) ->
          AscLam (locate_map (R.rename ctx) x, check ctx dom, synth (R.snoc ctx x.value) body)
      | UU -> UU
      | Let (x, tm, body) -> Let (R.rename ctx x, synth ctx tm, (check (R.snoc ctx x)) body)
      | Letrec (tys, tms, body) ->
          let (Bplus ab) = R.T2.bplus (Vec.length tms) in
          let tys2, ctx2 = tel ctx tys ab in
          let tms2 = Vec.map (check ctx2) tms in
          Letrec (tys2, tms2, check ctx2 body)
      | Act (s, fa, tm) -> Act (s, fa, Option.map (check ctx) tm)
      | Match { tm; sort; branches; refutables = r; highers } ->
          let tm = synth ctx tm in
          let sort =
            match sort with
            | `Explicit ty -> `Explicit (check ctx ty)
            | `Nondep i -> `Nondep i
            | `Implicit -> `Implicit in
          let branches = Abwd.map (branch ctx) branches in
          let refutables = Option.map (refutables ctx) r in
          Match { tm; sort; branches; refutables; highers }
      | Fail e -> Fail e
      | ImplicitSApp (fn, apploc, arg) -> ImplicitSApp (synth ctx fn, apploc, synth ctx arg)
      | SFirst (tms, arg) ->
          SFirst
            ( List.map (fun (t, x, b) -> (t, (synth ctx (locate_opt tm.loc x)).value, b)) tms,
              Option.map (fun arg -> (synth ctx (locate_opt tm.loc arg)).value) arg )
      | Calc (first, rest) ->
          Calc
            ( synth ctx first,
              List.map (fun (y, xeqy) -> (check ctx y, Option.map (check ctx) xeqy)) rest ) in
    R.visit ctx (locate_opt tm.loc (R.T2.Synth newtm));
    locate_opt tm.loc newtm

  and check : type a1 a2. (a1, a2) R.scope -> a1 R.T1.check located -> a2 R.T2.check located =
   fun ctx tm ->
    let newtm : a2 R.T2.check =
      match tm.value with
      | Synth x -> Synth (synth ctx (locate_opt tm.loc x)).value
      | Lam { name; cube; implicit; dom; body } ->
          Lam
            {
              name = locate_map (R.rename ctx) name;
              cube;
              implicit;
              dom = Option.map (check ctx) dom;
              body = check (R.snoc ctx name.value) body;
            }
      | Struct (eta, fields) ->
          Struct (eta, Abwd.map (fun (cube, tm) -> (cube, check ctx tm)) fields)
      | Constr (c, args) -> Constr (c, List.map (check ctx) args)
      | Numeral x -> Numeral x
      | Empty_co_match -> Empty_co_match
      | Data constrs -> Data (Abwd.map (locate_map (dataconstr ctx)) constrs)
      | Codata fields ->
          Codata
            (Abwd.map
               (fun (R.T1.Codatafield (x, fld)) ->
                 R.T2.Codatafield (R.rename ctx x, check (R.snoc ctx x) fld))
               fields)
      | SelfRecord fields ->
          SelfRecord
            (Abwd.map
               (fun (R.T1.Codatafield (x, fld)) ->
                 R.T2.Codatafield (R.rename ctx x, check (R.snoc ctx x) fld))
               fields)
      | Record (xs, fields, opaq) ->
          let (Bplus ac2) = R.T2.bplus (R.T1.Namevec.length xs.value) in
          let xs2 = renames ctx xs.value ac2 in
          let ctx2 = append ctx xs.value ac2 in
          let (Bplus ad) = R.T2.bplus (R.T1.fwn_of_tel fields) in
          let fields2, _ = tel ctx2 fields ad in
          Record (locate_opt xs.loc xs2, fields2, opaq)
      | Refute (args, sort) -> Refute (List.map (synth ctx) args, sort)
      | Hole { scope; loc; li; ri; num } -> Hole { scope = R.rescope ctx scope; loc; li; ri; num }
      | Realize x -> Realize (check ctx (locate_opt tm.loc x)).value
      | ImplicitApp (fn, args) ->
          ImplicitApp (synth ctx fn, List.map (fun (l, x) -> (l, check ctx x)) args)
      | Embed e -> (
          match R.embed ctx e with
          | Left x -> (check ctx (locate_opt tm.loc x)).value
          | Right x -> x)
      | First tms ->
          First (List.map (fun (t, x, b) -> (t, (check ctx (locate_opt tm.loc x)).value, b)) tms)
      | Oracle tm -> Oracle (check ctx tm)
      | Weaken (x, Eq) ->
          let (Pop (ctx, Eq)) = R.pop ctx in
          Weaken ((check ctx (locate_opt tm.loc x)).value, Eq) in
    let newtm = locate_opt tm.loc newtm in
    R.visit ctx newtm;
    newtm

  and branch : type a1 a2. (a1, a2) R.scope -> a1 R.T1.branch -> a2 R.T2.branch =
   fun ctx (Branch (xs, cube, body)) ->
    let (Bplus ab) = R.T2.bplus (R.T1.Namevec.length xs.value) in
    let xs2 = renames ctx xs.value ab in
    let ctx2 = append ctx xs.value ab in
    Branch (locate_opt xs.loc xs2, cube, check ctx2 body)

  and dataconstr : type a1 a2. (a1, a2) R.scope -> a1 R.T1.dataconstr -> a2 R.T2.dataconstr =
   fun ctx (Dataconstr (args, body)) ->
    let (Bplus ab) = R.T2.bplus (R.T1.fwn_of_tel args) in
    let args2, ctx2 = tel ctx args ab in
    Dataconstr (args2, Option.map (check ctx2) body)

  and refutables : type a1 a2. (a1, a2) R.scope -> a1 R.T1.refutables -> a2 R.T2.refutables =
   fun ctx { refutables } ->
    let refutables : type b ab2. (a2, b, ab2) R.T2.bplus -> ab2 R.T2.synth located list =
     fun ab2 ->
      let (Bplus ab1) = R.T1.bplus (R.T2.bplus_right ab2) in
      let ctx2 = append ctx (R.T1.Namevec.none ab1) ab2 in
      List.map (synth ctx2) (refutables ab1) in
    { refutables }

  and tel : type b a1 ab1 a2 ab2.
      (a1, a2) R.scope ->
      (a1, b, ab1) R.T1.tel ->
      (a2, b, ab2) R.T2.bplus ->
      (a2, b, ab2) R.T2.tel * (ab1, ab2) R.scope =
   fun ctx tele ab ->
    match tele with
    | Emp ->
        let Eq = R.T2.bplus_zero ab in
        (Emp, ctx)
    | Ext (x, ty, rest) ->
        let ctx2 = R.snoc ctx x in
        let ab = R.T2.bplus_suc ab in
        let rest3, ctx3 = tel ctx2 rest ab in
        (Ext (R.rename ctx x, check ctx ty, rest3), ctx3)
end

(* Since the De Bruijn index version is the standard one, we include that here. *)
include Indexed

(* Some utility functions specialized to the Indexed case. *)

let rec namevec_of_vec : type a b ab.
    (a, b, ab) Fwn.bplus -> (string option, b) Vec.t -> (a, b, ab) Namevec.t =
 fun ab xs ->
  match (ab, xs) with
  | Zero, [] -> []
  | Suc ab, x :: xs -> x :: namevec_of_vec ab xs

(* We end with some useful lemmas. *)

let rec dataconstr_of_pi : type a. a check located -> a dataconstr =
 fun ty ->
  match ty.value with
  | Synth (Pi (x, dom, cod)) ->
      let (Dataconstr (tel, out)) = dataconstr_of_pi cod in
      Dataconstr (Ext (x, dom, tel), out)
  | _ -> Dataconstr (Emp, Some ty)

(* Produces only explicit lambdas. *)
let rec lams : type a b ab.
    (a, b, ab) Indexed.bplus ->
    (string option located, b) Vec.t ->
    ab check located ->
    Asai.Range.t option ->
    a check located =
 fun ab xs tm loc ->
  match (ab, xs) with
  | Zero, [] -> tm
  | Suc ab, name :: xs ->
      {
        value =
          Lam
            {
              name;
              cube = locate_opt None `Normal;
              implicit = `Explicit;
              dom = None;
              body = lams ab xs tm loc;
            };
        loc;
      }

let rec bplus_of_tel : type a b c. (a, b, c) tel -> (a, b, c) Fwn.bplus = function
  | Emp -> Zero
  | Ext (_, _, tel) -> Suc (bplus_of_tel tel)
