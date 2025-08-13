(* This module should not be imported, but used qualified (including its constructor names for printable). *)

open Bwd
open Dim
open Util
open Tbwd
open Reporter
open Format
open Value
open Term
open Raw

(* Functions to dump a partial direct representation of various kinds of syntax, avoiding the machinery of readback, unparsing, etc. that's needed for ordinary pretty-printing.  Intended only for debugging. *)

type printable +=
  | Val : 's value -> printable
  | DeepVal : 's value * int -> printable
  | Head : head -> printable
  | Binder : ('b, 's) binder -> printable
  | Term : ('b, 's) term -> printable
  | Tel : ('a, 'b, 'ab) Telescope.t -> printable
  | Env : ('n, 'b) Value.env -> printable
  | DeepEnv : ('n, 'b) Value.env * int -> printable
  | Check : 'a check -> printable
  | Apps : 'any apps -> printable
  | Entry : ('x, 'n) Ctx.entry -> printable
  | OrderedCtx : ('a, 'b) Ctx.Ordered.t -> printable
  | Ctx : ('a, 'b) Ctx.t -> printable

(* The dump functions were written using Format, but printable has now been changed to use PPrint instead.  To put off updating the dump functions to PPrint, we wrap the old versions in a module, and then at the end wrap them in functions that convert them to strings and make those into PPrint.documents. *)

module F = struct
  let dim : formatter -> 'a D.t -> unit = fun ppf d -> fprintf ppf "%s" (string_of_dim d)

  let tubeof : type k n nk a.
      (formatter -> a -> unit) -> formatter -> (k, n, nk, a) TubeOf.t -> unit =
   fun pp ppf args ->
    fprintf ppf "(";
    let started = ref false in
    TubeOf.miter
      {
        it =
          (fun s [ x ] ->
            if !started then fprintf ppf ", ";
            started := true;
            fprintf ppf "%s ≔ %a" (string_of_sface (sface_of_tface s)) pp x);
      }
      [ args ];
    fprintf ppf ")"

  let cubeof : type n a. (formatter -> a -> unit) -> formatter -> (n, a) CubeOf.t -> unit =
   fun pp ppf args ->
    fprintf ppf "(";
    let started = ref false in
    CubeOf.miter
      {
        it =
          (fun _ [ x ] ->
            if !started then fprintf ppf ", ";
            started := true;
            pp ppf x);
      }
      [ args ];
    fprintf ppf ")"

  let rec dvalue : type s. int -> formatter -> s value -> unit =
   fun depth ppf v ->
    match v with
    | Neu { head = h; args = a; value = _; ty } ->
        if depth > 0 then
          fprintf ppf "Neu (%a, %a, %a)" head h apps a (dvalue (depth - 1)) (Lazy.force ty)
        else fprintf ppf "Neu (%a, %a, ?)" head h apps a
    | Lam (x, body) -> fprintf ppf "Lam (?^%s, %a)" (string_of_dim (dim_variables x)) binder body
    | Struct { fields = f; ins; _ } ->
        let n = cod_left_ins ins in
        fprintf ppf "Struct %s (%a)" (string_of_dim n) (fields depth n) f
    | Constr (c, d, args) ->
        fprintf ppf "Constr (%s, %a, (%a))" (Constr.to_string c) dim d
          (pp_print_list ~pp_sep:(fun ppf () -> pp_print_string ppf ", ") value)
          (List.map CubeOf.find_top args)
    | Canonical ic -> fprintf ppf "Canonical %a" inst_canonical ic

  and value : type s. formatter -> s value -> unit = fun ppf v -> dvalue 0 ppf v
  and normal : formatter -> normal -> unit = fun ppf x -> value ppf x.tm

  and fields : type s n et.
      int -> n D.t -> formatter -> (n * s * et) Value.StructfieldAbwd.t -> unit =
   fun depth n ppf -> function
    | Emp -> fprintf ppf "Emp"
    | Snoc (flds, Entry (f, Lower (v, l))) ->
        fprintf ppf "%a <: " (fields depth n) flds;
        lazy_field depth ppf f "" v l
    | Snoc (flds, Entry (f, Higher (lazy { vals; _ }))) ->
        fprintf ppf "%a <: " (fields depth n) flds;
        InsmapOf.miter n
          {
            it =
              (fun p [ x ] ->
                match x with
                | None -> fprintf ppf "None"
                | Some v -> lazy_field depth ppf f (string_of_ins p) v `Labeled);
          }
          [ vals ]

  and lazy_field : type s i.
      int -> formatter -> i Field.t -> string -> s lazy_eval -> [ `Labeled | `Unlabeled ] -> unit =
   fun depth ppf f p v l ->
    let l =
      match l with
      | `Unlabeled -> "`Unlabeled"
      | `Labeled -> "`Labeled" in
    if depth > 0 then
      fprintf ppf "(%s%s, %a, %s)" (Field.to_string f) p
        (evaluation (depth - 1))
        (View.force_eval v) l
    else
      match !v with
      | Ready v -> fprintf ppf "(%s%s, %a, %s)" (Field.to_string f) p (evaluation 0) v l
      | Deferred _ -> fprintf ppf "(%s%s, (Deferred), %s)" (Field.to_string f) p l
      | Deferred_eval (e, tm, ins, args) ->
          fprintf ppf "(%s%s, Deferred_eval (?(%s), %a, %s(%s), %a), %s)"
            (string_of_dim (dim_env e))
            (Field.to_string f) p term tm (string_of_ins ins)
            (string_of_dim (dom_ins ins))
            apps args l

  and lazy_eval : type s. int -> formatter -> s lazy_eval -> unit =
   fun depth ppf v ->
    if depth > 0 then (evaluation (depth - 1)) ppf (View.force_eval v)
    else
      match !v with
      | Ready v -> (evaluation (depth - 1)) ppf v
      | _ -> fprintf ppf "(Deferred)"

  and evaluation : type s. int -> formatter -> s evaluation -> unit =
   fun depth ppf v ->
    match v with
    | Unrealized -> fprintf ppf "Unrealized"
    | Realize v -> fprintf ppf "Realize (%a)" (dvalue depth) v
    | Val v -> fprintf ppf "Val (%a)" (dvalue depth) v

  (* TODO: display the outer insertion *)
  and apps : type any. formatter -> any apps -> unit =
   fun ppf args ->
    match args with
    | Emp -> fprintf ppf "Emp"
    | Arg (rest, xs, _) -> fprintf ppf "%a <: %a" apps rest (cubeof normal) xs
    | Field (rest, fld, plus, ins) -> (
        (* 'ins' is an *outer* insertion, not the field insertion.  The field insertion has been pushed inside and become the 'plus'. *)
        apps ppf rest;
        fprintf ppf " <: ";
        (* Intrinsic dimension *)
        let i = D.plus_right plus in
        (* result dimension *)
        let t = cod_left_ins ins in
        (* Total use dimension *)
        let n = D.plus_out t plus in
        match D.compare_zero i with
        | Zero -> fprintf ppf ".%s(%s)" (Field.to_string fld) (string_of_dim n)
        | Pos _ ->
            fprintf ppf ".%s%s(%s)" (Field.to_string fld)
              (string_of_ins (ins_of_plus t plus))
              (string_of_dim n))
    | Inst (rest, d, args) ->
        apps ppf rest;
        fprintf ppf " <: ";
        fprintf ppf "Inst (%a, %a)" dim (D.pos d) (tubeof normal) args

  and level : formatter -> level -> unit = fun ppf l -> fprintf ppf "LVar (%d,%d)" (fst l) (snd l)

  and head : formatter -> head -> unit =
   fun ppf h ->
    match h with
    | Var { level = l; _ } -> level ppf l
    | Const { name; ins } ->
        let (To p) = deg_of_ins ins in
        fprintf ppf "Const (%s, %s)" (print_to_string (PConstant name)) (string_of_deg p)
    | Meta { meta; env = e; ins } ->
        let (To p) = deg_of_ins ins in
        fprintf ppf "Meta (%s, %a, %s)" (Meta.name meta) env e (string_of_deg p)
    | UU n -> fprintf ppf "UU %a" dim n
    | Pi (x, doms, cods) ->
        fprintf ppf "Pi^%s (%s, %a, (... %a))"
          (string_of_dim (CubeOf.dim doms))
          (Option.value ~default:"_" (top_variable x))
          (cubeof value) doms binder (BindCube.find_top cods)

  and binder : type b s. formatter -> (b, s) binder -> unit =
   fun ppf (Bind { env = e; ins = i; body }) ->
    fprintf ppf "Bind (%a, %s, %a)" env e (string_of_ins i) term body

  and inst_canonical : type m k mk e n. formatter -> (m, k, mk, e, n) inst_canonical -> unit =
   fun ppf { canonical; tyargs; ins; fields = _; inst_fields = _ } ->
    fprintf ppf "(%s, %a, (evdim=%s)%s, ?)"
      (match canonical with
      | UU _ -> "UU ?"
      | Pi (_, _, _) -> "Pi ?"
      | Data _ -> "Data ?"
      | Codata _ -> "Codata ?")
      (tubeof normal) tyargs
      (string_of_dim (cod_left_ins ins))
      (string_of_ins ins)

  and denv : type b n. int -> formatter -> (n, b) Value.env -> unit =
   fun depth ppf e ->
    match e with
    | Emp d -> fprintf ppf "Emp %a" dim d
    | Ext (e, _, Ok v) -> fprintf ppf "%a <: %a" env e (cubeof (dvalue depth)) v
    | Ext (e, _, Error _) -> fprintf ppf "%a <: Err" env e
    | LazyExt (e, _, v) -> fprintf ppf "%a <; %a" env e (cubeof (lazy_eval depth)) v
    | Act (e, Op (f, d)) -> fprintf ppf "%a <* (%s,%s)" env e (string_of_sface f) (string_of_deg d)
    | Permute (_, e) -> fprintf ppf "(%a) permuted(?)" env e
    | Shift (e, mn, _) -> fprintf ppf "%a << %a" env e dim (D.plus_right mn)
    | Unshift (e, mn, _) -> fprintf ppf "%a >> %a" env e dim (D.plus_right mn)

  and env : type b n. formatter -> (n, b) Value.env -> unit = fun ppf e -> denv 0 ppf e

  and term : type b s. formatter -> (b, s) term -> unit =
   fun ppf tm ->
    match tm with
    | Var (Index (x, fa)) -> fprintf ppf "IVar %d.%s" (Tbwd.int_of_insert x) (string_of_sface fa)
    | Const c -> fprintf ppf "Const %s" (print_to_string (PConstant c))
    | Meta (v, _) -> fprintf ppf "Meta %s" (print_to_string (PMeta v))
    | MetaEnv (v, _) -> fprintf ppf "MetaEnv (%s,?)" (print_to_string (PMeta v))
    | Field (tm, fld, ins) ->
        fprintf ppf "Field (%a, %s%s(%s))" term tm (Field.to_string fld) (string_of_ins ins)
          (string_of_dim (dom_ins ins))
    | UU n -> fprintf ppf "UU %a" dim n
    | Inst (tm, args) -> fprintf ppf "Inst (%a, %a)" term tm (tubeof term) args
    | Pi (x, doms, cods) ->
        fprintf ppf "Pi^(%a) (%s, %a, (... %a))" dim (CubeOf.dim doms)
          (Option.value (top_variable x) ~default:"_")
          (cubeof term) doms term (CodCube.find_top cods)
    | App (fn, arg) -> fprintf ppf "App (%a, %a)" term fn (cubeof term) arg
    | Lam (x, body) -> fprintf ppf "Lam^(%s) (?, %a)" (string_of_dim (dim_variables x)) term body
    | Constr (c, _, _) -> fprintf ppf "Constr (%s, ?, ?)" (Constr.to_string c)
    | Act (tm, s, _) -> fprintf ppf "Act (%a, %s)" term tm (string_of_deg s)
    | Let (_, _, _) -> fprintf ppf "Let ?"
    | Struct _ -> fprintf ppf "Struct ?"
    | Match _ -> fprintf ppf "Match ?"
    | Realize tm -> fprintf ppf "Realize (%a)" term tm
    | Canonical c -> fprintf ppf "Canonical (%a)" canonical c
    | Unshift (n, _, tm) -> fprintf ppf "Unshift (%s, %a)" (string_of_dim n) term tm
    | Unact (_, tm) -> fprintf ppf "Unact (?, %a)" term tm
    | Shift (n, _, tm) -> fprintf ppf "Shift (%s, %a)" (string_of_dim n) term tm
    | Weaken tm -> fprintf ppf "Weaken (%a)" term tm

  and canonical : type b. formatter -> b canonical -> unit =
   fun ppf c ->
    match c with
    | Data { indices; constrs; discrete = _ } ->
        fprintf ppf "Data (%d, (%a))" (Fwn.to_int indices)
          (pp_print_list
             ~pp_sep:(fun ppf () -> pp_print_string ppf " | ")
             (fun ppf (c, d) -> fprintf ppf "%s %a" (Constr.to_string c) dataconstr d))
          (Bwd.to_list constrs)
    | Codata { eta; fields; _ } ->
        fprintf ppf "Codata (%s, (%s))"
          (match eta with
          | Eta -> "Eta"
          | Noeta -> "Noeta")
          (String.concat ","
             (Bwd_extra.to_list_map
                (fun (CodatafieldAbwd.Entry (f, _)) -> Field.to_string f)
                fields))

  and dataconstr : type p i. formatter -> (p, i) Term.dataconstr -> unit =
   fun ppf (Dataconstr { args; indices = _ }) -> fprintf ppf "%a : ?" tel args

  and tel : type a b ab. formatter -> (a, b, ab) Term.tel -> unit =
   fun ppf -> function
    | Emp -> ()
    | Ext (x, ty, rest) ->
        fprintf ppf "(%a : %a)"
          (pp_print_option ~none:(fun ppf () -> pp_print_string ppf "_") pp_print_string)
          x term ty;
        tel ppf rest

  let rec check : type a. formatter -> a check -> unit =
   fun ppf c ->
    match c with
    | Synth s -> synth ppf s
    | Lam { name; cube = _; implicit; dom; body } ->
        fprintf ppf "Lam(%s%s%a%s, %a)"
          (if implicit = `Implicit then "{" else "")
          (Option.value ~default:"_" name.value)
          (fun ppf ->
            Option.fold ~none:() ~some:(fun (x : a check located) ->
                fprintf ppf " : %a" check x.value))
          dom
          (if implicit = `Implicit then "}" else "")
          check body.value
    | Struct (_, flds) ->
        fprintf ppf "Struct(";
        Mbwd.miter
          (fun [ (f, (_, (x : a check Asai.Range.located))) ] ->
            let f = Option.fold ~some:(fun (f, ps) -> String.concat "." (f :: ps)) ~none:"_" f in
            fprintf ppf "%s ≔ %a, " f check x.value)
          [ flds ];
        fprintf ppf ")"
    | Constr (c, args) ->
        fprintf ppf "Constr(%s,(%a))" (Constr.to_string c.value)
          (fun ppf ->
            List.iter (fun (x : a check Asai.Range.located) -> fprintf ppf "%a, " check x.value))
          args
    | Numeral x -> fprintf ppf "Numeral(%s)" (Q.to_string x)
    | Empty_co_match -> fprintf ppf "Emptycomatch(?)"
    | Data _ -> fprintf ppf "Data(?)"
    | Codata _ -> fprintf ppf "Codata(?)"
    | Record (_, _, _) -> fprintf ppf "Record(?)"
    | Refute (_, _) -> fprintf ppf "Refute(?)"
    | Hole _ -> fprintf ppf "Hole"
    | Realize x -> fprintf ppf "Realize %a" check x
    | ImplicitApp (fn, args) ->
        fprintf ppf "ImplicitApp (%a," synth fn.value;
        List.iter
          (fun (_, (x : a check Asai.Range.located)) -> fprintf ppf "%a, " check x.value)
          args;
        fprintf ppf ")"
    | Embed _ -> .
    | First tms ->
        fprintf ppf "First(%a)"
          (pp_print_list ~pp_sep:(fun ppf () -> pp_print_string ppf ", ") check)
          (List.map (fun (_, x, _) -> x) tms)
    | Oracle tm -> fprintf ppf "Oracle(%a)" check tm.value
    | Weaken (tm, Eq) -> check ppf tm

  and synth : type a. formatter -> a synth -> unit =
   fun ppf s ->
    match s with
    | Var (x, _) -> fprintf ppf "Var(%d)" (N.int_of_index x)
    | Const c -> fprintf ppf "Const(%a)" pp_printed (print (PConstant c))
    | Field (tm, fld) ->
        fprintf ppf "Field(%a, %s)" synth tm.value
          (match fld with
          | `Name (f, p) ->
              if List.exists (fun i -> i > 9) p then
                "." ^ f ^ ".." ^ String.concat "." (List.map string_of_int p)
              else "." ^ f ^ "." ^ String.concat "" (List.map string_of_int p)
          | `Int i -> "." ^ string_of_int i)
    | Pi (_, _, _) -> fprintf ppf "Pi(?)"
    | HigherPi (_, _, _) -> fprintf ppf "HigherPi(?)"
    | InstHigherPi (_, _, _) -> fprintf ppf "InstHigherPi(?)"
    | App (fn, { value = Some arg; _ }, _) -> fprintf ppf "App(%a, %a)" check fn.value check arg
    | App (fn, { value = None; _ }, _) -> fprintf ppf "App(%a, .)" check fn.value
    | Asc (tm, ty) -> fprintf ppf "Asc(%a, %a)" check tm.value check ty.value
    | AscLam (x, dom, body) ->
        fprintf ppf "AscLam(%s, %a, %a)"
          (Option.value ~default:"_" x.value)
          check dom.value synth body.value
    | Let (_, _, _) -> fprintf ppf "Let(?)"
    | Letrec (_, _, _) -> fprintf ppf "LetRec(?)"
    | Act (_, _, _) -> fprintf ppf "Act(?)"
    | Match { tm; sort = _; branches = br; refutables = _ } ->
        fprintf ppf "Match (%a, (%a))" synth tm.value branches br
    | UU -> fprintf ppf "Type"
    | Fail _ -> fprintf ppf "Error"
    | ImplicitSApp (fn, _, arg) -> fprintf ppf "ImplicitSApp(%a, %a)" synth fn.value synth arg.value
    | SFirst (tms, arg) ->
        fprintf ppf "SFirst(%a, %a)"
          (pp_print_list ~pp_sep:(fun ppf () -> pp_print_string ppf ", ") synth)
          (List.map (fun (_, x, _) -> x) tms)
          (pp_print_option synth) arg
    | Calc _ -> fprintf ppf "Calc(?)"

  and branches : type a. formatter -> (Constr.t, a branch) Abwd.t -> unit =
   fun ppf brs ->
    match brs with
    | Emp -> ()
    | Snoc (Emp, br) -> branch ppf br
    | Snoc (brs, br) ->
        branches ppf brs;
        if not (Bwd.is_empty brs) then fprintf ppf ", ";
        branch ppf br

  and branch : type a. formatter -> Constr.t * a branch -> unit =
   fun ppf (c, Branch (vars, cube, body)) ->
    let rec strvars : type a b ab. (a, b, ab) Namevec.t -> string = function
      | [] -> ""
      | [ Some x ] -> x
      | [ None ] -> "_"
      | Some x :: xs -> x ^ " " ^ strvars xs
      | None :: xs -> "_ " ^ strvars xs in
    let mapsto =
      match cube.value with
      | `Normal -> "↦"
      | `Cube | `Any -> "⤇" in
    fprintf ppf "%s %s %s %a" (Constr.to_string c) (strvars vars.value) mapsto check body.value

  let entry : type x n. formatter -> (x, n) Ctx.entry -> unit =
   fun ppf -> function
    | Vis { dim; plusdim; hasfields = No_fields; vars; bindings; _ } -> (
        match (D.compare_zero dim, D.compare_zero (D.plus_right plusdim)) with
        | Zero, Zero ->
            let x = NICubeOf.find_top vars in
            let b = CubeOf.find_top bindings in
            fprintf ppf "(%a%a : %a)"
              (pp_print_option ~none:(fun ppf () -> pp_print_string ppf "_") pp_print_string)
              x
              (pp_print_option (fun ppf l -> fprintf ppf "(%a)" level l))
              (Ctx.Binding.level b) value (Ctx.Binding.value b).ty
        | _ -> fprintf ppf "(?)")
    | _ -> fprintf ppf "(?)"

  let rec ordered_ctx : type a b. formatter -> (a, b) Ctx.Ordered.t -> unit =
   fun ppf -> function
    | Emp -> ()
    | Snoc (c, e, _) -> fprintf ppf "%a %a" ordered_ctx c entry e
    | Lock c -> fprintf ppf "%a Lock" ordered_ctx c

  let ctx : type a b. formatter -> (a, b) Ctx.t -> unit =
   fun ppf (Permute { ctx; _ }) -> fprintf ppf "Ctx (?, ?, %a)" ordered_ctx ctx
end

let dim d = PPrint.utf8string (Format.asprintf "%a" F.dim d)
let dvalue depth v = PPrint.utf8string (Format.asprintf "%a" (F.dvalue depth) v)
let value v = PPrint.utf8string (Format.asprintf "%a" F.value v)
let evaluation depth v = PPrint.utf8string (Format.asprintf "%a" (F.evaluation depth) v)
let head v = PPrint.utf8string (Format.asprintf "%a" F.head v)
let binder v = PPrint.utf8string (Format.asprintf "%a" F.binder v)
let env v = PPrint.utf8string (Format.asprintf "%a" F.env v)
let denv depth v = PPrint.utf8string (Format.asprintf "%a" (F.denv depth) v)
let term v = PPrint.utf8string (Format.asprintf "%a" F.term v)
let tel v = PPrint.utf8string (Format.asprintf "%a" F.tel v)
let check v = PPrint.utf8string (Format.asprintf "%a" F.check v)
let synth v = PPrint.utf8string (Format.asprintf "%a" F.synth v)
let apps v = PPrint.utf8string (Format.asprintf "%a" F.apps v)
let entry v = PPrint.utf8string (Format.asprintf "%a" F.entry v)
let ordered_ctx v = PPrint.utf8string (Format.asprintf "%a" F.ordered_ctx v)
let ctx v = PPrint.utf8string (Format.asprintf "%a" F.ctx v)
