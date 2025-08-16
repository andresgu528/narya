open Bwd
open Util
open Tbwd
open Reporter
open Dim
open Dimbwd
open Term
open Value
open Act
open Printable
open View

(* Since some entries in an environment are lazy and some aren't, lookup_cube returns a cube whose entries belong to an existential type, along with a function to act on any element of that type and force it into a value.  It also returns an accumulated operator by which to act, first selecting an entry in the cube with a face and then acting on that value by a degeneracy. *)
type _ looked_up_cube =
  | Looked_up : {
      act : 'x 'y. 'a -> ('x, 'y) deg -> kinetic value;
      op : ('m, 'n) op;
      entry : ('n, 'a) CubeOf.t;
    }
      -> 'm looked_up_cube

(* Require that the supplied list contains exactly b (which is a Fwn) arguments, and add all of the cubes to the given environment. *)
let rec take_args : type m n mn a b ab.
    (m, a) env ->
    (m, n, mn) D.plus ->
    (mn, kinetic value) CubeOf.t list ->
    (a, b, n, ab) Tbwd.snocs ->
    (m, ab) env =
 fun env mn dargs plus ->
  match (dargs, plus) with
  | [], Zero -> env
  | arg :: args, Suc plus -> take_args (Ext (env, mn, Ok arg)) mn args plus
  | _ -> fatal (Anomaly "wrong number of arguments in argument list")

(* Eval-readback callback for tyof_higher_codatafield *)
type (_, _, _, _) shuffleable =
  | Trivial : (D.zero, 'i, 'i, 'c) shuffleable
  | Nontrivial : {
      dbwd : 'c Dbwd.t;
      shuffle : ('r, 'h, 'i) shuffle;
      deg_env :
        's 'sh 'r_sh.
        ('s, 'h, 'sh) D.plus ->
        ('r, 'sh, 'r_sh) D.plus ->
        ('sh, ('c, D.zero) snoc) env ->
        ('r_sh, ('c, D.zero) snoc) env;
      deg_nf : normal -> normal;
    }
      -> ('r, 'h, 'i, 'c) shuffleable

let rec view_term : type s. s value -> s value =
 fun tm ->
  if GluedEval.read () then
    match tm with
    | Neu { value; ty; _ } -> (
        (* For glued evaluation, when viewing a term, we force its value and proceed to view that value instead. *)
        match force_eval value with
        | Realize v -> view_term v
        | Val (Canonical { canonical = Data d; _ }) when Option.is_none !(d.tyfam) ->
            d.tyfam := Some (lazy { tm; ty = Lazy.force ty });
            tm
        | _ -> tm)
    | _ -> tm
  else tm

(* Viewing a type fails if the argument is not fully instantiated.  In most situations this would be a bug, but we allow the caller to specify it differently, since during typechecking it could be a user error. *)
and view_type ?(severity = Asai.Diagnostic.Bug) (ty : kinetic value) (err : string) : view_type =
  match ty with
  | Neu { head; args; value; ty = _ } -> (
      (* Glued evaluation: when viewing a type, we force its value and proceed to view that value instead. *)
      match force_eval value with
      | Val (Canonical { canonical = c; tyargs; ins; fields = _; inst_fields = _ }) -> (
          (match c with
          | Data d when Option.is_none !(d.tyfam) ->
              d.tyfam := Some (lazy { tm = ty; ty = inst (universe (TubeOf.inst tyargs)) tyargs })
          | _ -> ());
          match D.compare_zero (TubeOf.uninst tyargs) with
          | Zero ->
              let Eq = D.plus_uniq (TubeOf.plus tyargs) (D.zero_plus (TubeOf.inst tyargs)) in
              Canonical (head, c, ins, tyargs)
          | Pos k -> fatal ~severity (Type_not_fully_instantiated (err, k)))
      | Realize v -> view_type ~severity v err
      | _ -> (
          match inst_of_apps args with
          | apps, Some (Any_tube tyargs) -> (
              match D.compare_zero (TubeOf.uninst tyargs) with
              | Pos k -> fatal ~severity (Type_not_fully_instantiated (err, k))
              | Zero ->
                  let Eq = D.plus_uniq (TubeOf.plus tyargs) (D.zero_plus (TubeOf.inst tyargs)) in
                  Neutral (head, apps, tyargs))
          | apps, None -> Neutral (head, apps, TubeOf.empty D.zero)))
  | _ -> fatal ~severity (Type_expected (err, Dump.Val ty))

(* Evaluation of terms and evaluation of case trees are technically separate things.  In particular, evaluating a kinetic (standard) term always produces just a value, whereas evaluating a potential term (a function case tree) can either

   1. Produce a new partially-evaluated case tree that isn't fully applied yet.  This is actually represented by a value that's either a Lam or a Struct.
   2. Reach a leaf and produce a value.
   3. Conclude that the case tree is true neutral and will never reduce further.

   These possibilities are encoded in an "evaluation", defined in Syntax.Value.  The point is that, just as with the representation of terms, there is enough commonality between the two (application of lambdas and field projection from structs) that we don't want to duplicate the code, so we define the evaluation functions to return an "evaluation" result that is a GADT parametrized by the kind of energy of the term. *)

(* The master evaluation function. *)
and eval : type m b s. (m, b) env -> (b, s) term -> s evaluation =
 fun env tm ->
  match tm with
  | Var v -> Val (lookup env v)
  | Const name -> (
      let dim = dim_env env in
      let cty, defn = Global.find name in
      (* Its type must also be instantiated at the lower-dimensional versions of itself. *)
      let ty =
        lazy
          (inst (eval_term (Emp dim) cty)
             (TubeOf.build D.zero (D.zero_plus dim)
                {
                  build =
                    (fun fa ->
                      (* To compute those lower-dimensional versions, we recursively evaluate the same constant in lower-dimensional contexts. *)
                      let tm =
                        eval_term (act_env env (op_of_sface (sface_of_tface fa))) (Const name) in
                      (* We need to know the type of each lower-dimensional version in order to annotate it as a "normal" instantiation argument.  But we already computed that type while evaluating the term itself, since as a neutral term it had to be annotated with its type. *)
                      match tm with
                      | Neu { ty = (lazy ty); _ } -> { tm; ty }
                      | _ -> fatal (Anomaly "eval of lower-dim constant not neutral/canonical"));
                })) in
      let head = Const { name; ins = ins_zero dim } in
      match defn with
      | `Defined tree, _ -> (
          if GluedEval.read () then
            (* Glued evaluation: we evaluate the definition lazily and return a neutral with that lazy evaluation stored. *)
            Val (Neu { head; args = Emp; value = lazy_eval (Emp dim) tree; ty })
          else
            let value = eval (Emp dim) tree in
            let newtm = Neu { head; args = Emp; value = ready value; ty } in
            match value with
            | Realize x -> Val x
            | Val (Canonical { canonical = Data d; _ }) ->
                if Option.is_none !(d.tyfam) then
                  d.tyfam := Some (lazy { tm = newtm; ty = Lazy.force ty });
                Val newtm
            | _ -> Val newtm)
      | `Axiom, _ -> Val (Neu { head; args = Emp; value = ready Unrealized; ty }))
  | Meta (meta, ambient) -> (
      let dim = dim_env env in
      let head = Value.Meta { meta; env; ins = ins_zero dim } in
      (* As with constants, we need to instantiate the type at the same meta evaluated at lower dimensions. *)
      let make_ty meta ty =
        inst (eval_term env ty)
          (TubeOf.build D.zero (D.zero_plus dim)
             {
               build =
                 (fun fa ->
                   let tm =
                     eval_term
                       (act_env env (op_of_sface (sface_of_tface fa)))
                       (Meta (meta, Kinetic)) in
                   match tm with
                   | Neu { ty = (lazy ty); _ } -> { tm; ty }
                   | _ -> fatal (Anomaly "eval of lower-dim meta not neutral/canonical"));
             }) in
      match (Global.find_meta meta, ambient) with
      (* If a metavariable has a definition that fits with the current energy, we simply evaluate that definition. *)
      | { tm = `Defined tm; energy = Potential; _ }, Potential -> eval env tm
      | { tm = `Defined tm; energy = Kinetic; _ }, Kinetic -> eval env tm
      | { tm = `Defined tm; energy = Kinetic; _ }, Potential -> Realize (eval_term env tm)
      | { tm = `Defined tm; energy = Potential; ty; _ }, Kinetic -> (
          if GluedEval.read () then
            (* A defined potential metavariable in kinetic context evaluates to a glued neutral, with its evaluated definition stored lazily. *)
            Val (Neu { head; args = Emp; value = lazy_eval env tm; ty = lazy (make_ty meta ty) })
          else
            (* If a potential metavariable with a definition is used in a kinetic context, and doesn't evaluate yet to a kinetic result, we again have to build a neutral. *)
            match eval env tm with
            | Realize tm -> Val tm
            | value ->
                Val (Neu { head; args = Emp; value = ready value; ty = lazy (make_ty meta ty) }))
      (* If an undefined potential metavariable appears in a case tree, then that branch of the case tree is stuck.  We don't need to return the metavariable itself; it suffices to know that that branch of the case tree is stuck, as the constant whose definition it is should handle all identity/equality checks correctly. *)
      | _, Potential -> Unrealized
      (* To evaluate an undefined kinetic metavariable, we have to build a neutral. *)
      | { ty; _ }, Kinetic ->
          Val (Neu { head; args = Emp; value = ready Unrealized; ty = lazy (make_ty meta ty) }))
  | MetaEnv (meta, metaenv) ->
      let (Plus m_n) = D.plus (dim_term_env metaenv) in
      eval (eval_env env m_n metaenv) (Term.Meta (meta, Kinetic))
  | UU n ->
      let m = dim_env env in
      let (Plus mn) = D.plus n in
      Val (universe (D.plus_out m mn))
  | Inst (tm, args) -> (
      (* The arguments are an (n,k) tube, with k dimensions instantiated and n dimensions uninstantiated. *)
      let n = TubeOf.uninst args in
      let k = TubeOf.inst args in
      let n_k = TubeOf.plus args in
      (* Add the environment dimension to the uninstantiated dimensions *)
      let m = dim_env env in
      let (Plus m_n) = D.plus n in
      let mn = D.plus_out m m_n in
      (* Evaluate the inner term.  This gives an m+n+k dimensional object; it might have been instantiated from something higher-dimensional, but requires a full m+n+k tube to become fully instantiated.  We will instantiate k of those dimensions, leaving m+n. *)
      let newtm = eval_term env tm in
      let (Plus mn_k) = D.plus k in
      let mnk = D.plus_out mn mn_k in
      (* tys is a complete m+n+k tube, giving the types of all the arguments that newtm remains to be instantiated by. *)
      let (Full_tube tys) = inst_tys newtm in
      match D.compare (TubeOf.inst tys) mnk with
      | Neq -> fatal (Dimension_mismatch ("evaluation instantiation", TubeOf.inst tys, mnk))
      | Eq ->
          (* used_tys is an (m+n,k) tube, with m+n uninstantiated and k instantiated.  These are the types that we must instantiate to give the types of the added instantiation arguments. *)
          let used_tys = TubeOf.pboundary (D.zero_plus mn) mn_k tys in
          let newargstbl = Hashtbl.create 10 in
          let newargs =
            TubeOf.mmap
              {
                map =
                  (fun fa [ ty ] ->
                    (* fa : p+q => m+n+k, fa = fb+fc where fb : p => m and fcd : q => n+k. *)
                    let (TFace_of_plus (_, fb, fcd)) = tface_of_plus m_n fa in
                    let fa = sface_of_tface fa in
                    let Eq = D.plus_uniq (cod_plus_of_tface fcd) n_k in
                    (* Thus tm is p+q dimensional. *)
                    let tm = eval_term (act_env env (op_of_sface fb)) (TubeOf.find args fcd) in
                    (* So its type needs to be fully instantiated at that dimension. *)
                    let ty =
                      inst ty
                        (TubeOf.build D.zero
                           (D.zero_plus (dom_sface fa))
                           {
                             build =
                               (fun fij ->
                                 let faij = comp_sface fa (sface_of_tface fij) in
                                 Hashtbl.find newargstbl (SFace_of faij));
                           }) in
                    let v = { tm; ty } in
                    Hashtbl.add newargstbl (SFace_of fa) v;
                    v);
              }
              [ used_tys ] in
          (* The types not in used_tys form a complete m+n tube, which will be the remaining instantiation arguments of the type of the result.  We don't need to worry about that here, it's taken care of in "inst". *)
          Val (inst newtm newargs))
  | Lam (Variables (n, n_k, vars), body) ->
      let m = dim_env env in
      let (Plus m_nk) = D.plus (D.plus_out n n_k) in
      let (Plus m_n) = D.plus n in
      let mn_k = D.plus_assocl m_n n_k m_nk in
      Val (Lam (Variables (D.plus_out m m_n, mn_k, vars), eval_binder env m_nk body))
  | App (fn, args) ->
      (* First we evaluate the function. *)
      let efn = eval_term env fn in
      (* The environment is m-dimensional and the original application is n-dimensional, so the *substituted* application is m+n dimensional.  Thus must therefore match the dimension of the function being applied. *)
      let m = dim_env env in
      let n = CubeOf.dim args in
      let (Plus m_n) = D.plus n in
      let mn = D.plus_out m m_n in
      (* Then we evaluate all the arguments, not just in the given environment (of dimension m), but in that environment acted on by all the strict faces of m.  Since the given arguments are indexed by strict faces of n, the result is a collection of values indexed by strict faces of m+n.  *)
      let eargs = eval_args env m_n mn args in
      (* Having evaluated the function and its arguments, we now pass the job off to a helper function. *)
      apply efn eargs
  | Field (tm, fld, fldins) ->
      let m = dim_env env in
      let n, l = (dom_ins fldins, cod_left_ins fldins) in
      let Plus m_n, Plus m_l = (D.plus n, D.plus l) in
      field (eval_term env tm) fld (plus_ins m m_n m_l fldins)
  | Struct { eta; dim = n; fields; energy } ->
      let m = dim_env env in
      let (Plus m_n) = D.plus n in
      let mn = D.plus_out m m_n in
      let ins = ins_zero mn in
      let fields = eval_structfield_abwd env m m_n mn fields in
      Val (Struct { fields; ins; energy; eta })
  | Constr (constr, n, args) ->
      let m = dim_env env in
      let (Plus m_n) = D.plus n in
      let mn = D.plus_out m m_n in
      let eargs = List.map (eval_args env m_n mn) args in
      Val (Constr (constr, mn, eargs))
  | Pi (type n) ((x, doms, cods) : n variables * (n, (b, kinetic) term) CubeOf.t * (n, b) CodCube.t)
    ->
      (* We are starting with an n-dimensional pi-type and evaluating it in an m-dimensional environment, producing an (m+n)-dimensional result. *)
      let n = CubeOf.dim doms in
      let m = dim_env env in
      let (Plus (type mn) (m_n : (m, n, mn) D.plus)) = D.plus n in
      let mn = D.plus_out m m_n in
      (* The basic thing we do is evaluate the cubes of domains and codomains. *)
      let doms =
        CubeOf.build mn
          {
            build =
              (fun fab ->
                let (SFace_of_plus (_, fa, fb)) = sface_of_plus m_n fab in
                eval_term (act_env env (op_of_sface fa)) (CubeOf.find doms fb));
          } in
      let cods =
        BindCube.build mn
          {
            build =
              (fun fab ->
                let (SFace_of_plus (k_l, fa, fb)) = sface_of_plus m_n fab in
                eval_binder (act_env env (op_of_sface fa)) k_l (CodCube.find cods fb));
          } in
      (* However, because the result will be a Neu, we need to know its type as well.  The starting n-dimensional pi-type (which is itself uninstantiated) lies in a full instantiation of the n-dimensional universe at lower-dimensional pi-types formed from subcubes of its domains and codomains.  Accordingly, the resulting (m+n)-dimensional pi-type will like in a full instantiation of the (m+n)-dimensional universe at lower-dimensional pi-types obtained by evaluating these at appropriately split faces.  Since each of them *also* belongs to a universe instantiated similarly, and needs to know its type not just because it is an uninst but because it is a normal, we build the whole cube at once and then take its top. *)
      let pitbl = Hashtbl.create 10 in
      (* Since we only care about the hashtbl and the top, and we can get that from the hashtbl at the end anyway, we don't bother actually putting the normals into a meaningful cube. *)
      let build : type k. (k, mn) sface -> unit =
       fun fab ->
        let (SFace_of_plus (ab, fa, fb)) = sface_of_plus m_n fab in
        let kl = dom_sface fab in
        let ty =
          inst (universe kl)
            (TubeOf.build D.zero (D.zero_plus kl)
               {
                 build =
                   (fun fc -> Hashtbl.find pitbl (SFace_of (comp_sface fab (sface_of_tface fc))));
               }) in
        let subdoms, subcods = (CubeOf.subcube fab doms, BindCube.subcube fab cods) in
        let subx = plus_variables (dom_sface fa) ab (sub_variables fb x) in
        let head : head = Pi (subx, subdoms, subcods) in
        (* We don't need fibrancy fields for all the boundary types, since once something "is a type" we don't need it to be in Fib any more. *)
        let fields : (k * potential * no_eta) Value.StructfieldAbwd.t =
          match (is_id_sface fab, !Fibrancy.pi) with
          | None, _ | _, None -> Bwd.Emp
          | Some Eq, Some fields ->
              (* For the top face, we compute its fibrancy fields by evaluating the generic "fibrancy fields of a pi" at the evaluated domains and codomains.  *)
              let pi_env =
                Ext
                  ( Ext (Emp mn, D.plus_zero mn, Ok doms),
                    D.plus_zero mn,
                    Ok (lam_cube (plus_variables m m_n x) cods) ) in
              eval_structfield_abwd pi_env mn (D.plus_zero mn) mn fields in
        let value =
          ready
            (Val
               (Canonical
                  {
                    canonical = Pi (subx, subdoms, subcods);
                    tyargs = TubeOf.empty kl;
                    ins = ins_zero kl;
                    fields;
                    inst_fields = Some fields;
                  })) in
        let tm = Neu { head; args = Emp; value; ty = Lazy.from_val ty } in
        Hashtbl.add pitbl (SFace_of fab) { tm; ty } in
      let _ = CubeOf.build mn { build } in
      Val (Hashtbl.find pitbl (SFace_of (id_sface mn))).tm
  | Let (_, v, body) ->
      (* We evaluate let-bindings lazily, on the chance they aren't actually used. *)
      let m = dim_env env in
      let args = CubeOf.build m { build = (fun fa -> lazy_eval (act_env env (op_of_sface fa)) v) } in
      eval (LazyExt (env, D.plus_zero m, args)) body
  (* It's tempting to write just "act_value (eval env x) s" here, but that is WRONG!  Pushing a substitution through an operator action requires whiskering the operator by the dimension of the substitution. *)
  | Act (x, s, _) ->
      let k = dim_env env in
      let (Plus km) = D.plus (dom_deg s) in
      let (Plus kn) = D.plus (cod_deg s) in
      let ks = plus_deg k kn km s in
      (* We push as much of the resulting degeneracy into the environment as possible, in hopes that the remaining insertion outside will be trivial and act_value will be able to short-circuit.  (Ideally, the insertion would be carried through by eval for a single traversal in all cases.) *)
      let (Insfact (fa, ins)) = insfact ks kn in
      let (To p) = deg_of_ins ins in
      Val (act_value (eval_term (act_env env (op_of_deg fa)) x) p)
  | Match { tm; dim = match_dim; branches } -> (
      let env_dim = dim_env env in
      let (Plus plus_dim) = D.plus match_dim in
      let total_dim = D.plus_out env_dim plus_dim in
      (* Get the argument being inspected *)
      match view_term (eval_term env tm) with
      (* To reduce nontrivially, the discriminee must be an application of a constructor. *)
      | Constr (name, constr_dim, dargs) -> (
          match Constr.Map.find_opt name branches with
          (* Matches are constructed to contain all the constructors of the datatype being matched on, and this constructor belongs to that datatype, so it ought to be in the match. *)
          | None ->
              fatal
                (Anomaly
                   (Printf.sprintf "constructor %s missing from compiled match"
                      (Constr.to_string name)))
          | Some (Branch (plus, perm, body)) -> (
              match D.compare constr_dim total_dim with
              | Neq -> fatal (Dimension_mismatch ("evaluating match", constr_dim, total_dim))
              | Eq ->
                  (* If we have a branch with a matching constructor, then our constructor must be applied to exactly the right number of elements (in dargs).  In that case, we pick them out and add them to the environment. *)
                  let env = take_args env plus_dim dargs plus in
                  (* Then we proceed recursively with the body of that branch. *)
                  eval (Permute (perm, env)) body)
          (* If this constructor belongs to a refuted case, it must be that we are in an inconsistent context with some neutral belonging to an empty type.  In that case, the match must be stuck. *)
          | Some Refute -> Unrealized)
      (* Otherwise, the case tree doesn't reduce. *)
      | _ -> Unrealized)
  | Realize tm -> Realize (eval_term env tm)
  | Canonical c -> eval_canonical env c
  | Unshift (n, plusmap, tm) ->
      let (Cofactor mn) =
        cofactor (dim_env env) n
        <|> Anomaly "evaluating unshifted term in too low-dimensional environment" in
      eval (Shift (env, mn, plusmap)) tm
  | Unact (op, tm) -> (
      match cofactor (dim_env env) (cod_op op) with
      | None ->
          fatal
            (Anomaly
               (Printf.sprintf
                  "evaluating unacted term in too low-dimensional environment: %s doesn't cofactor through %s"
                  (string_of_dim (dim_env env))
                  (string_of_dim (cod_op op))))
      | Some (Cofactor kn) ->
          let (Plus km) = D.plus (dom_op op) in
          let k = D.minus (dim_env env) kn in
          let op = plus_op k kn km op in
          eval (Act (env, op)) tm)
  | Shift (n, plusmap, tm) ->
      let (Plus mn) = D.plus n in
      eval (Unshift (env, mn, plusmap)) tm
  | Weaken tm -> eval (remove_env env Now) tm

and eval_with_boundary : type m a. (m, a) env -> (a, kinetic) term -> (m, kinetic value) CubeOf.t =
 fun env tm ->
  CubeOf.build (dim_env env) { build = (fun fa -> eval_term (act_env env (op_of_sface fa)) tm) }

(* Evaluate a cube of arguments for an application. *)
and eval_args : type m n mn a.
    (m, a) env ->
    (m, n, mn) D.plus ->
    mn D.t ->
    (n, (a, kinetic) term) CubeOf.t ->
    (mn, kinetic value) CubeOf.t =
 fun env m_n mn tms ->
  CubeOf.build mn
    {
      build =
        (* Specifically, for each face of m+n... *)
        (fun fab ->
          (* ...we decompose it as a sum of a face "fa" of m and a face "fb" of n... *)
          let (SFace_of_plus (_, fa, fb)) = sface_of_plus m_n fab in
          (* ...and evaluate the supplied argument indexed by the face fb of n, in an environment acted on by the face fa of m. *)
          eval_term (act_env env (op_of_sface fa)) (CubeOf.find tms fb));
    }

(* Apply a function value to an argument (with its boundaries). *)
and apply : type n s. s value -> (n, kinetic value) CubeOf.t -> s evaluation =
 fun fn arg ->
  match view_term fn with
  (* If the function is a lambda-abstraction, we check that it has the correct dimension and then beta-reduce, adding the arguments to the environment. *)
  | Lam (_, body) -> (
      let m = CubeOf.dim arg in
      match D.compare (dim_binder body) m with
      | Neq -> fatal (Dimension_mismatch ("applying a lambda", dim_binder body, m))
      | Eq -> apply_binder body arg)
  (* If it is a uninstantiated neutral application... *)
  | Neu { head; args; value; ty = (lazy ty) } -> (
      (* ... we check that its type is fully instantiated... *)
      match view_type ty "apply" with
      | Canonical (_, Pi (_, doms, cods), ins, tyargs) -> (
          (* ... and that the pi-type and its instantiation have the correct dimension. *)
          let k = CubeOf.dim doms in
          let Eq = eq_of_ins_zero ins in
          match D.compare (CubeOf.dim arg) k with
          | Neq -> fatal (Dimension_mismatch ("applying a neutral function", CubeOf.dim arg, k))
          | Eq -> (
              (* We annotate the new argument by its type, extracted from the domain type of the function being applied. *)
              let newarg = norm_of_vals_cube arg doms in
              (* We compute the output type of the application. *)
              let newty = lazy (tyof_app cods tyargs arg) in
              (* We add the new argument to the existing application spine. *)
              let args = Arg (args, newarg, ins_zero k) in
              if GluedEval.read () then
                (* We add the argument to the lazy value and return a glued neutral. *)
                let value = apply_lazy value newarg in
                Val (Neu { head; args; value; ty = newty })
              else
                (* We evaluate further with a case tree. *)
                match force_eval value with
                | Unrealized -> Val (Neu { head; args; value = ready Unrealized; ty = newty })
                (* It could be an indexed datatype waiting to be applied to more indices. *)
                | Val
                    (Canonical
                       {
                         canonical =
                           Data { dim; tyfam; indices = Unfilled _ as indices; constrs; discrete };
                         tyargs = data_tyargs;
                         ins;
                         fields;
                         inst_fields = _;
                       }) -> (
                    let Eq = eq_of_ins_zero ins in
                    match (D.compare dim k, D.compare_zero (TubeOf.inst data_tyargs)) with
                    | Neq, _ -> fatal (Dimension_mismatch ("apply", dim, k))
                    | _, Pos _ ->
                        fatal
                          (Anomaly
                             "datatype was instantiated before being applied to all its indices")
                    | Eq, Zero ->
                        let indices = Fillvec.snoc indices newarg in
                        (* TODO: What happens to these?  What even are the fields of a not-fully-applied indexed datatype? *)
                        let fields =
                          match fields with
                          | Emp -> Bwd.Emp
                          | Snoc _ -> fatal (Unimplemented "fibrancy of indexed datatypes") in
                        let value =
                          Val
                            (Value.Canonical
                               {
                                 canonical = Data { dim; tyfam; indices; constrs; discrete };
                                 tyargs = TubeOf.empty dim;
                                 ins;
                                 fields;
                                 inst_fields = None;
                               }) in
                        Val (Neu { head; args; value = ready value; ty = newty }))
                | Val tm -> (
                    let value = apply tm arg in
                    let newtm = Neu { head; args; value = ready value; ty = newty } in
                    match value with
                    | Realize x -> Val x
                    | Val (Canonical { canonical = Data d; _ }) ->
                        if Option.is_none !(d.tyfam) then
                          d.tyfam := Some (lazy { tm = newtm; ty = Lazy.force newty });
                        Val newtm
                    | _ -> Val newtm)
                | _ -> fatal (Anomaly "invalid application of type")))
      | _ -> fatal (Anomaly "invalid application by non-function"))
  | _ -> fatal (Anomaly "invalid application of non-function")

(* Compute the output type of a function application, given the codomains and instantiation arguments of the pi-type (the latter being the functions acting on the boundary) and the arguments it is applied to. *)
and tyof_app : type k.
    (k, unit) BindCube.t ->
    (D.zero, k, k, normal) TubeOf.t ->
    (k, kinetic value) CubeOf.t ->
    kinetic value =
 fun cods fns args ->
  let out_arg_tbl = Hashtbl.create 10 in
  let out_args =
    TubeOf.mmap
      {
        map =
          (fun fa [ { tm = afn; ty = _ } ] ->
            let fa = sface_of_tface fa in
            let tmargs = CubeOf.subcube fa args in
            let tm = apply_term afn tmargs in
            let cod = apply_binder_term (BindCube.find cods fa) tmargs in
            let ty =
              inst cod
                (TubeOf.build D.zero
                   (D.zero_plus (dom_sface fa))
                   {
                     build =
                       (fun fc ->
                         Hashtbl.find out_arg_tbl (SFace_of (comp_sface fa (sface_of_tface fc))));
                   }) in
            let out_tm = { tm; ty } in
            Hashtbl.add out_arg_tbl (SFace_of fa) out_tm;
            out_tm);
      }
      [ fns ] in
  inst (apply_binder_term (BindCube.find_top cods) args) out_args

(* Compute a field of a structure (or a fibrant type). *)
and field : type n k nk s. s value -> k Field.t -> (nk, n, k) insertion -> s evaluation =
 fun tm fld fldins ->
  match view_term tm with
  | Struct { fields; ins = structins; energy; eta = _ } -> (
      match (is_id_ins structins, D.compare (cod_left_ins structins) (dom_ins fldins)) with
      | Some _, Eq -> struct_field "struct" energy fields fld fldins
      | Some _, Neq ->
          fatal (Dimension_mismatch ("field of struct", cod_left_ins structins, dom_ins fldins))
      | None, _ -> fatal (Anomaly "nonidentity insertion when computing field of struct"))
  (* A canonical type can have fibrancy fields. *)
  | Canonical c -> (
      (* TODO: Do something with c.ins, in the case of glue. *)
      let fields = get_fibrancy_fields c in
      match D.compare (TubeOf.uninst c.tyargs) (dom_ins fldins) with
      | Neq ->
          fatal (Dimension_mismatch ("field of canonical", TubeOf.uninst c.tyargs, dom_ins fldins))
      | Eq -> struct_field "canonical" Potential fields fld fldins)
  | viewed_tm -> (
      (* We push the permutation from the insertion inside. *)
      let n, k = (cod_left_ins fldins, cod_right_ins fldins) in
      let (Plus fldplus) = D.plus k in
      let p = deg_of_perm (perm_inv (perm_of_ins_plus fldins fldplus)) in
      match act_value viewed_tm p with
      (* It must be an uninstantiated neutral application (which could be either an element of a record/codata, or a fibrant type). *)
      | Neu { head; args; value; ty = (lazy ty) } -> (
          let newty = lazy (tyof_field (Ok tm) ty fld ~shuf:Trivial fldins) in
          let args = Field (args, fld, fldplus, ins_zero n) in
          if GluedEval.read () then
            let value = field_lazy value fld fldins in
            Val (Neu { head; args; value; ty = newty })
          else
            match force_eval value with
            | Unrealized -> Val (Neu { head; args; value = ready Unrealized; ty = newty })
            | Val tm -> (
                (* At this point we've already pushed the insertion inside in computing our neutral, so the remaining insertion on the field to compute of its value is "the identity" of appropriate dimensions *)
                let value = field tm fld (ins_of_plus n fldplus) in
                let newtm = Neu { head; args; value = ready value; ty = newty } in
                match value with
                | Realize x -> Val x
                | Val (Canonical { canonical = Data d; _ }) ->
                    if Option.is_none !(d.tyfam) then
                      d.tyfam := Some (lazy { tm = newtm; ty = Lazy.force newty });
                    Val newtm
                | _ -> Val newtm)
            | Realize _ -> fatal (Anomaly "realized neutral"))
      | _ ->
          fatal ~severity:Asai.Diagnostic.Bug
            (No_such_field (`Other (Dump.Val tm), `Ins (fld, fldins))))

and struct_field : type s et n k nk.
    ?unset_ok:bool ->
    string ->
    s energy ->
    (nk * s * et) StructfieldAbwd.t ->
    k Field.t ->
    (nk, n, k) insertion ->
    s evaluation =
 fun ?(unset_ok = false) err energy fields fld fldins ->
  match StructfieldAbwd.find_opt fields fld with
  | Found (Lower (v, _)) -> force_eval v
  | Found (Higher (lazy { vals; intrinsic; _ })) -> (
      match D.compare intrinsic (cod_right_ins fldins) with
      | Eq -> (
          match InsmapOf.find fldins vals with
          | Some v -> force_eval v
          | None -> if unset_ok then Unrealized else fatal (Anomaly (err ^ " field value unset")))
      | Neq ->
          fatal (Dimension_mismatch (err ^ " field intrinsic", intrinsic, cod_right_ins fldins)))
  | _ -> (
      match energy with
      | Potential -> Unrealized
      | Kinetic -> fatal (Anomaly ("missing field in eval struct: " ^ Field.to_string fld)))

and field_term : type n k nk. kinetic value -> k Field.t -> (nk, n, k) insertion -> kinetic value =
 fun x fld fldins ->
  let (Val v) = field x fld fldins in
  v

(* Given a term and its record type, compute the type of a field projection, and the substitution dimension it was evaluated at.  There are two versions of this function, one for when we already know the insertion associated to the field, and one for when we are synthesizing it from the user's integer sequence.  First we define the shared part of both, where we have already found the codatafield from the codata type.  We allow the term to be an error, in case typechecking failed earlier but we are continuing on; this can nevertheless succeed (or fail in more interesting ways) if the type doesn't actually depend on that value. *)

and tyof_codatafield : type m n mn a k r s i et.
    (kinetic value, Code.t) Result.t ->
    i Field.t ->
    (i, a * n * et) Codatafield.t ->
    (m, a) env ->
    (D.zero, mn, mn, normal) TubeOf.t ->
    m D.t ->
    (m, n, mn) D.plus ->
    (* We allow passing through a shuffle and eval-readback as well, in the case that this is a higher field being called recursively as part of the instantiation arguments. *)
    shuf:(r, k, i, a) shuffleable ->
    (m, s, k) insertion ->
    kinetic value =
 fun tm fldname fldty env tyargs m mn ~shuf fldins ->
  (* The type of the field projection comes from the type associated to that field name in general, evaluated at the stored environment extended by the term itself and its boundaries. *)
  match fldty with
  | Term.Codatafield.Lower fldty -> tyof_lower_codatafield tm fldname fldty env tyargs m mn
  | Term.Codatafield.Higher (ic0, fldty) ->
      let Eq = D.plus_uniq mn (D.plus_zero m) in
      tyof_higher_codatafield tm fldname env tyargs fldins ic0 fldty ~shuf

(* We dispatch to separate helper functions for lower fields and higher fields that assume all the dimensions are correct.  These helper functions can be called directly by a caller who knows that all the dimensions are correct, such as check_field where the field is obtained by iterating directly through the codatatype. *)
and tyof_lower_codatafield : type m n mn a.
    (kinetic value, Code.t) Result.t ->
    D.zero Field.t ->
    ((a, n) snoc, kinetic) term ->
    (m, a) env ->
    (D.zero, mn, mn, normal) TubeOf.t ->
    m D.t ->
    (m, n, mn) D.plus ->
    kinetic value =
 fun tm fldname fldty env tyargs m mn ->
  let tmcube =
    Result.map (fun tm -> TubeOf.plus_cube (val_of_norm_tube tyargs) (CubeOf.singleton tm)) tm in
  let env = Value.Ext (env, mn, tmcube) in
  (* This type is m-dimensional, hence must be instantiated at a full m-tube. *)
  let insttm = eval_term env fldty in
  let instargs =
    TubeOf.mmap
      {
        map =
          (fun fa [ arg ] ->
            let fains = ins_zero (dom_tface fa) in
            let tm = field_term arg.tm fldname fains in
            let ty = tyof_field (Ok arg.tm) arg.ty fldname ~shuf:Trivial fains in
            { tm; ty });
      }
      [ fst (TubeOf.split (D.zero_plus m) mn tyargs) ] in
  inst insttm instargs

(* This function is also called directly from check_higher_field.  In that case, the field is determined by a partial bijection that may *not* be just an insertion, and we have to frobnicate the environment in which we evaluate the type.  Some of that frobnication involves an eval-readback cycle, which requires a callback from here since readback isn't defined yet. *)
and tyof_higher_codatafield : type c n h s r i ic.
    (kinetic value, Code.t) Result.t ->
    i Field.t ->
    (* The codatatype is in context of length c.  It has been evaluated at dimension n, in an (n, c) env. *)
    (n, c) env ->
    (* And so it has a boundary n-tube. *)
    (D.zero, n, n, normal) TubeOf.t ->
    (* The field has intrinsic dimension i, determined by a pbij from n to i, with result s, remaining r, shared h.  We record the insertion and shuffle separately, with a shuffleable recording explicitly whether the shuffle is nontrivial and including a readback callback if so.  This is because we will have to readback a (s+h, [c;0]) env, in some context, and evaluate in an (r,a) env coming from degenerating that context, to get an (r+s+h, [c;0]) env, but readback depends on this file. *)
    (n, s, h) insertion ->
    (* It's very important that these callbacks be called on *all values* before they are used, including tm, env, and tyargs, since they start out in the non-degenerated context but everything has to actually happen in the degenerated one. *)
    shuf:(r, h, i, c) shuffleable ->
    (* We add i to all the dimensions in [c;0] to get i+[c;0]. *)
    (i, (c, D.zero) snoc, ic) Plusmap.t ->
    (* The unevaluated type of the field is a term in context of this length i+[c;0].  The extra 0 is for the 'self' variable, which is always 0-dimensional when *defining* the codatatype. *)
    (ic, kinetic) term ->
    (* In the nontrivial case, the return value is also in the degenerated context. *)
    kinetic value =
 fun tm fldname codataenv tyargs fldins ~shuf ic0 fldty ->
  let n = dom_ins fldins in
  let s = cod_left_ins fldins in
  let h =
    cod_right_ins fldins
    (* = right_shuffle fldshuf *) in
  let (Plus rh) = D.plus h in
  let (Plus rs) = D.plus s in
  let (Plus sh) = D.plus h in
  let (Plus r_sh) = D.plus (D.plus_out s sh) in
  let rs_h = D.plus_assocl rs sh r_sh in
  (* We extend the (n, c) env by a variable for the current term, getting an (n, [c;0]) env.  *)
  let tmcube =
    Result.map (fun tm -> TubeOf.plus_cube (val_of_norm_tube tyargs) (CubeOf.singleton tm)) tm in
  let env = Value.Ext (codataenv, D.plus_zero n, tmcube) in
  (* Now we act on this (n, [c;0]) env by the inverse of the insertion to get an (s+h, [c;0]) env. *)
  let env = Act (env, op_of_deg (deg_of_perm (perm_inv (perm_of_ins_plus fldins sh)))) in
  let env =
    match shuf with
    (* When r=0 and h=i, we can just shift this to get an (s, h+[c;0]) env, which is the same as (s, i+[c;0]), so it matches the context of fldty. *)
    | Trivial -> Shift (env, sh, ic0)
    (* In the general case... *)
    | Nontrivial { dbwd = _; shuffle; deg_env; deg_nf = _ } ->
        (* First we do some dimension arithemetic. *)
        let r = left_shuffle shuffle in
        let i = out_shuffle shuffle in
        let (Plus si) = D.plus i in
        let (Plus sr) = D.plus r in
        let (Plus sr_h) = D.plus h in
        let s_rh = D.plus_assocr sr rh sr_h in
        (* Then we eval-readback to get an (r+s+h, [c;0]) env. *)
        let env = deg_env sh r_sh env in
        (* Then we permute it to get an (s+r+h, [c;0]) env, and act by the shuffle to get (s+i, [c;0]) *)
        let swapdeg = deg_plus (swap_deg sr rs) rs_h sr_h in
        let shuffledeg = plus_deg s s_rh si (deg_of_shuffle shuffle rh) in
        let env = Value.Act (env, op_of_deg (comp_deg swapdeg shuffledeg)) in
        (* Finally, now we can shift this to get a (s, i+[c;0]) env. *)
        Shift (env, si, ic0) in
  (* Now this matches the context of fldty, so we can evaluate it. *)
  let insttm = eval_term env fldty in
  (* Since the result is s-dimensional, it has to be instantiated at a full s-tube. *)
  let instargs =
    TubeOf.build D.zero (D.zero_plus s)
      {
        build =
          (fun (type k) (fa : (k, s) pface) ->
            (* To get the instantiation arguments, we have to lift the faces along the field insertion to get the new insertion and the face to access.  *)
            let (Pface_lift_ins (type m) ((fains, faplus) : (m, k, h) insertion * (m, n) pface)) =
              pface_lift_ins fa fldins in
            let arg = TubeOf.find tyargs faplus in
            match shuf with
            | Trivial ->
                let tm = field_term arg.tm fldname fains in
                let ty = tyof_field (Ok arg.tm) arg.ty fldname ~shuf fains in
                { tm; ty }
            | Nontrivial { dbwd = _; shuffle; deg_env = _; deg_nf } ->
                (* In this case, we have to degenerate the arguments, since they depend on the context. *)
                let arg = deg_nf arg in
                (* We also use these extra dimensions to make the pbij into an insertion. *)
                let (Plus rm) = D.plus (dom_tface faplus) in
                let arg_ins = ins_plus_of_pbij fains shuffle rm in
                let tm = field_term arg.tm fldname arg_ins in
                let ty = tyof_field (Ok arg.tm) arg.ty fldname ~shuf:Trivial arg_ins in
                { tm; ty });
      } in
  inst insttm instargs

(* This version is when we already know the insertion.  In this case, it's a bug if the field name or dimension don't match. *)
and tyof_field : type m h s r i c.
    (kinetic value, Code.t) Result.t ->
    kinetic value ->
    i Field.t ->
    (* We allow passing through a shuffle and eval-readback as well, in the case that this is a higher field being called recursively as part of the instantiation arguments. *)
    shuf:(r, h, i, c) shuffleable ->
    (m, s, h) insertion ->
    kinetic value =
 fun tm ty fld ~shuf fldins ->
  let errtm =
    match tm with
    | Ok tm -> Dump.Val tm
    | Error _err -> PString "[ERROR]" in
  let errfld =
    match shuf with
    | Trivial -> `Ins (fld, fldins)
    | Nontrivial { shuffle; _ } -> `Pbij (fld, Pbij (fldins, shuffle)) in
  let severity = Asai.Diagnostic.Bug in
  match view_type ty "tyof_field" with
  | Canonical
      (type mn m n)
      (( head,
         Codata
           (type d a et)
           ({ env; fields; opacity = _; eta; termctx = _ } : (m, n, d, a, et) codata_args),
         codatains,
         tyargs ) :
        head * (m, n) canonical * (mn, m, n) insertion * (D.zero, mn, mn, normal) TubeOf.t) -> (
      (* The type cannot have a nonidentity degeneracy applied to it (though it can be at a higher dimension). *)
      match is_id_ins codatains with
      | None -> fatal ~severity (No_such_field (`Degenerated_record eta, errfld))
      | Some mn -> tyof_field_giventype tm head eta env mn fields tyargs fld ~shuf fldins)
  | Canonical (head, UU m, ins, tyargs) -> (
      let Eq = eq_of_ins_zero ins in
      let err = Code.No_such_field (`Type errtm, errfld) in
      match !Fibrancy.fields with
      | None -> fatal ~severity err
      | Some fields ->
          let tmcube =
            Result.map
              (fun tm -> TubeOf.plus_cube (val_of_norm_tube tyargs) (CubeOf.singleton tm))
              tm in
          let env = Value.Ext (Value.Emp m, D.plus_zero m, tmcube) in
          tyof_field_giventype tm head Noeta env (D.plus_zero m) fields tyargs fld ~shuf fldins)
  | _ ->
      let p =
        match tm with
        | Ok tm -> Dump.Val tm
        | Error _err -> PString "[ERROR]" in
      fatal ~severity (No_such_field (`Other p, errfld))

and tyof_field_giventype : type m n mn h s r i c et a k.
    (kinetic value, Code.t) Result.t ->
    head ->
    (potential, et) eta ->
    (m, a) env ->
    (m, n, mn) D.plus ->
    (a * n * et) Term.CodatafieldAbwd.t ->
    (D.zero, mn, mn, normal) TubeOf.t ->
    i Field.t ->
    shuf:(r, h, i, c) shuffleable ->
    (k, s, h) insertion ->
    kinetic value =
 fun tm head eta env mn fields tyargs fld ~shuf fldins ->
  let severity = Asai.Diagnostic.Bug in
  let errfld =
    match shuf with
    | Trivial -> `Ins (fld, fldins)
    | Nontrivial { shuffle; _ } -> `Pbij (fld, Pbij (fldins, shuffle)) in
  let m = dim_env env in
  (* Note that n is the Gel dimension while m is the evaluation dimension.  So we need an m+n tube of type arguments, but the insertion labeling the field being accessed has only m as its evaluation dimension. *)
  match D.compare m (dom_ins fldins) with
  | Neq ->
      fatal ~severity
        (Dimension_mismatch ("tyof_field evaluation " ^ Field.to_string fld, m, dom_ins fldins))
  | Eq -> (
      match Term.CodatafieldAbwd.find_opt fields fld with
      | Found fldty ->
          let shuf : (r, h, i, a) shuffleable =
            match shuf with
            | Trivial -> Trivial
            | Nontrivial { dbwd; _ } -> (
                match Dbwd.compare dbwd (length_env env) with
                | Eq -> shuf
                | Neq -> fatal (Anomaly "context length mismatch in tyof_field")) in
          tyof_codatafield tm fld fldty env tyargs m mn ~shuf fldins
      | Not_found -> fatal ~severity (No_such_field (`Record (eta, phead head), errfld))
      | Wrong_dimension (i, _) ->
          let errsuffix =
            match shuf with
            | Trivial -> `Ins fldins
            | Nontrivial { shuffle; _ } -> `Pbij (Pbij (fldins, shuffle)) in
          fatal ~severity (Wrong_dimension_of_field (eta, phead head, `Field fld, m, i, errsuffix)))

(* This version is for when we are synthesizing the insertion, so we return the resulting insertion along with the type.  The field might also be given positionally in this case, so we also return the field name when we find it.  In this case, mismatches in field names or dimensions are user errors. *)
and tyof_field_withname : type a b.
    (a, b) Ctx.t ->
    (kinetic value, Code.t) Result.t ->
    kinetic value ->
    [ `Name of string * int list | `Int of int ] ->
    Field.with_ins * kinetic value =
 fun ctx tm ty infld ->
  let errfld =
    match infld with
    | `Name (str, ints) -> `Strings (str, ints)
    | `Int n -> `Int n in
  let errtm =
    match tm with
    | Ok tm -> PVal (ctx, tm)
    | Error _err -> PString "[ERROR]" in
  match view_type ~severity:Asai.Diagnostic.Error ty "tyof_field" with
  | Canonical (head, Codata { env; fields; opacity = _; eta; termctx = _ }, codatains, tyargs) -> (
      (* The type cannot have a nonidentity degeneracy applied to it (though it can be at a higher dimension). *)
      match is_id_ins codatains with
      | None -> fatal (No_such_field (`Degenerated_record eta, errfld))
      | Some mn ->
          let err = Code.No_such_field (`Record (eta, phead head), errfld) in
          tyof_field_withname_giventype ctx tm ty eta env mn fields tyargs infld err)
  | Canonical (_head, UU m, ins, tyargs) -> (
      let Eq = eq_of_ins_zero ins in
      let err = Code.No_such_field (`Type errtm, errfld) in
      match !Fibrancy.fields with
      | None -> fatal err
      | Some fields ->
          let tmcube =
            Result.map
              (fun tm -> TubeOf.plus_cube (val_of_norm_tube tyargs) (CubeOf.singleton tm))
              tm in
          let env = Value.Ext (Value.Emp m, D.plus_zero m, tmcube) in
          tyof_field_withname_giventype ctx tm ty Noeta env (D.plus_zero m) fields tyargs infld err)
  | _ -> fatal (No_such_field (`Other errtm, errfld))

(* Subroutine of tyof_field_withname for after we've identified the type of the head as either a codatatype or a universe (for fibrancy fields). *)
and tyof_field_withname_giventype : type a b m n mn c et.
    (a, b) Ctx.t ->
    (kinetic value, Code.t) Result.t ->
    kinetic value ->
    (potential, et) eta ->
    (m, c) env ->
    (m, n, mn) D.plus ->
    (c * n * et) Term.CodatafieldAbwd.t ->
    (D.zero, mn, mn, normal) TubeOf.t ->
    [ `Name of string * int list | `Int of int ] ->
    Code.t ->
    Field.with_ins * kinetic value =
 fun ctx tm ty eta env mn fields tyargs infld err ->
  let m = dim_env env in
  match infld with
  | `Name (fldname, ints) -> (
      match ins_of_ints m ints with
      | None -> fatal (Invalid_field_suffix (PVal (ctx, ty), fldname, ints, m))
      | Some (Ins_of fldins) -> (
          let i = cod_right_ins fldins in
          let fld = Field.intern fldname i in
          match Term.CodatafieldAbwd.find_opt fields fld with
          | Found fldty ->
              let fldty = tyof_codatafield tm fld fldty env tyargs m mn ~shuf:Trivial fldins in
              (WithIns (fld, fldins), fldty)
          | Wrong_dimension (i, fldty) -> (
              (* If the user omitted the suffix completely, and the field and the term are both 1-dimensional, we fill in the unique suffix "1" for them. *)
              let err =
                Code.Wrong_dimension_of_field
                  (eta, PVal (ctx, ty), `String fldname, m, i, `Ints ints) in
              match (ints, D.compare m i, D.compare_zero m) with
              | [], Eq, Pos m' -> (
                  let (Is_suc (mpred, _, _)) = suc_pos m' in
                  match D.compare_zero mpred with
                  | Zero ->
                      let fld = Field.intern fldname i in
                      let fldins = zero_ins m in
                      let fldty =
                        tyof_codatafield tm fld fldty env tyargs m mn ~shuf:Trivial fldins in
                      (WithIns (fld, fldins), fldty)
                  | Pos _ -> fatal err)
              | _ -> fatal err)
          | Not_found -> fatal err))
  | `Int k -> (
      try
        let (Entry (fld, fldty)) = List.nth (Bwd.to_list fields) k in
        match D.compare_zero (Field.dim fld) with
        | Zero ->
            let fldins = ins_zero m in
            let fldty = tyof_codatafield tm fld fldty env tyargs m mn ~shuf:Trivial fldins in
            (WithIns (fld, fldins), fldty)
        | Pos _ -> fatal err
      with Failure _ -> fatal err)

and apply_binder : type n s. (n, s) Value.binder -> (n, kinetic value) CubeOf.t -> s evaluation =
 fun (Value.Bind { env; ins; body }) argstbl ->
  let m = dim_env env in
  let (Plus mn) = D.plus (cod_right_ins ins) in
  let perm = perm_of_ins_plus ins mn in
  (* The arguments have to be acted on by degeneracies to form the appropriate cube.  But not all the arguments may be actually used, so we do these actions lazily. *)
  act_evaluation
    (eval
       (LazyExt
          ( env,
            mn,
            CubeOf.build (D.plus_out m mn)
              {
                build =
                  (fun frfs ->
                    let (Face (fa, fb)) = perm_sface (perm_inv perm) frfs in
                    act_lazy_eval (defer (fun () -> Val (CubeOf.find argstbl fa))) (deg_of_perm fb));
              } ))
       body)
    (deg_of_perm perm)

and eval_canonical : type m a. (m, a) env -> a Term.canonical -> potential evaluation =
 fun env can ->
  match can with
  | Data { indices; constrs; discrete } ->
      let tyfam = ref None in
      let constrs =
        Abwd.map
          (fun (Term.Dataconstr { args; indices }) -> Value.Dataconstr { env; args; indices })
          constrs in
      let dim = dim_env env in
      let canonical = Data { dim; tyfam; indices = Fillvec.empty indices; constrs; discrete } in
      let tyargs = TubeOf.empty (dim_env env) in
      let fields =
        match Lazy.force Fibrancy.data with
        | None -> Bwd.Emp
        | Some () -> fatal (Unimplemented "fibrancy of datatypes") in
      Val (Canonical { canonical; tyargs; ins = ins_zero dim; fields; inst_fields = Some fields })
  | Codata c ->
      eval_codata env c.eta c.opacity c.dim (Lazy.from_val c.termctx) c.fields
        (Fibrancy.Codata.finished c)

(* We split out this subroutine so it can be called from Check.with_codata_so_far and a lazy termctx.  *)
and eval_codata : type m a c n et.
    (m, a) env ->
    (potential, et) eta ->
    opacity ->
    n D.t ->
    (c, (a, n) snoc) termctx option Lazy.t ->
    (a * n * et) CodatafieldAbwd.t ->
    (n * a * potential * no_eta) Term.StructfieldAbwd.t ->
    potential evaluation =
 fun env eta opacity n termctx fields fibrancy_fields ->
  let m = dim_env env in
  let (Plus (type mn) (m_n : (m, n, mn) D.plus)) = D.plus n in
  let mn = D.plus_out m m_n in
  let ins = id_ins m m_n in
  let canonical = Codata { eta; opacity; env; termctx; fields } in
  let tyargs = TubeOf.empty mn in
  let fields = eval_structfield_abwd env m m_n mn fibrancy_fields in
  Val (Canonical { canonical; tyargs; ins; fields; inst_fields = Some fields })

and eval_term : type m b. (m, b) env -> (b, kinetic) term -> kinetic value =
 fun env tm ->
  let (Val v) = eval env tm in
  v

and eval_env : type a m n mn b.
    (m, a) env -> (m, n, mn) D.plus -> (a, n, b) Term.env -> (mn, b) Value.env =
 fun env m_n tmenv ->
  let mn = D.plus_out (dim_env env) m_n in
  match tmenv with
  | Emp _ -> Emp mn
  | Ext (tmenv, n_k, xss) ->
      let (Plus mn_k) = D.plus (D.plus_right n_k) in
      let m_nk = D.plus_assocr m_n n_k mn_k in
      (* We make everything lazy, since we can, and not everything may end up being used. *)
      LazyExt
        ( eval_env env m_n tmenv,
          mn_k,
          CubeOf.build (D.plus_out mn mn_k)
            {
              build =
                (fun fab ->
                  let (SFace_of_plus (_, fa, fb)) = sface_of_plus m_nk fab in
                  lazy_eval (act_env env (op_of_sface fa)) (CubeOf.find xss fb));
            } )

and apply_term : type n. kinetic value -> (n, kinetic value) CubeOf.t -> kinetic value =
 fun fn arg ->
  let (Val v) = apply fn arg in
  v

and apply_binder_term : type n. (n, kinetic) binder -> (n, kinetic value) CubeOf.t -> kinetic value
    =
 fun b arg ->
  let (Val v) = apply_binder b arg in
  v

and force_eval : type s. s lazy_eval -> s evaluation =
 fun lev ->
  let undefer tm s apps =
    (* TODO: In an ideal world, there would be one function that would traverse the term once doing both "eval" and "act" by the insertion. *)
    let etm = act_evaluation tm s in
    let etm = app_eval_apps etm apps in
    lev := Ready etm;
    etm in
  match !lev with
  | Deferred_eval (env, tm, ins, apps) ->
      let (To p) = deg_of_ins ins in
      undefer (eval env tm) p apps
  | Deferred (tm, s, apps) -> undefer (tm ()) s apps
  | Ready etm -> etm

and force_eval_term : kinetic lazy_eval -> kinetic value =
 fun v ->
  let (Val v) = force_eval v in
  v

(* Apply an 'apps' to something, calling either 'apply' or 'field' or 'inst' for each stage as appropriate. *)
and app_eval_apps : type s any. s evaluation -> any apps -> s evaluation =
 fun ev x ->
  match x with
  | Emp -> ev
  | Arg (rest, xs, ins) -> (
      let (To p) = deg_of_ins ins in
      match app_eval_apps ev rest with
      | Val tm -> act_evaluation (apply tm (val_of_norm_cube xs)) p
      | Realize tm ->
          let (Val v) = act_evaluation (apply tm (val_of_norm_cube xs)) p in
          Realize v
      | Unrealized -> Unrealized)
  | Field (rest, fld, fldplus, ins) -> (
      let (To p) = deg_of_ins ins in
      match app_eval_apps ev rest with
      | Val tm -> act_evaluation (field tm fld (id_ins (cod_left_ins ins) fldplus)) p
      | Realize tm ->
          let (Val v) = act_evaluation (field tm fld (id_ins (cod_left_ins ins) fldplus)) p in
          Realize v
      | Unrealized -> Unrealized)
  | Inst (rest, _, args) -> (
      match app_eval_apps ev rest with
      | Val tm -> Val (inst tm args)
      | Realize tm -> Realize (inst tm args)
      | Unrealized -> Unrealized)

(* Look up a cube of values in an environment by variable index, accumulating operator actions and shifts as we go.  At the end, we usually use the operator to select a value from the cubes (with its face part) and act on it (with its degeneracy part). *)
and lookup_cube : type n a b k mk nk.
    (n, b) env -> (n, k, nk) D.plus -> (a, k, b) Tbwd.insert -> (mk, nk) op -> mk looked_up_cube =
 fun env nk v op ->
  match (env, v) with
  (* Since there's an index, the environment can't be empty. *)
  | Emp _, _ -> .
  (* If we encounter an operator action, we accumulate it. *)
  | Act (env, op'), _ ->
      let (Plus lk) = D.plus (D.plus_right nk) in
      let op'k = op_plus op' lk nk in
      lookup_cube env lk v (comp_op op'k op)
  (* If we encounter a shift or unshift, we just have to edit the insertion and go on. *)
  | Shift (env, n_x, xb), v ->
      (* In this branch, k is renamed to x+k. *)
      let n_xk = nk in
      let (Uncoinsert (x_k, v, _)) = Plusmap.uncoinsert v xb in
      let nx_k = D.plus_assocl n_x x_k n_xk in
      lookup_cube env nx_k v op
  | Unshift (env, n_x, xb), v ->
      (* In this branch, n is renamed to n+x. *)
      let nx_k = nk in
      let (Uninsert (x_k, v, _)) = Plusmap.uninsert v xb in
      let n_xk = D.plus_assocr n_x x_k nx_k in
      lookup_cube env n_xk v op
  (* If the environment is permuted, we apply the permutation to the index. *)
  | Permute (p, env), v ->
      let (Permute_insert (v, _)) = Tbwd.permute_insert v p in
      lookup_cube env nk v op
  (* If we encounter a variable that isn't ours, we skip it and proceed. *)
  | Ext (env, _, _), Later v -> lookup_cube env nk v op
  | LazyExt (env, _, _), Later v -> lookup_cube env nk v op
  (* Finally, when we find our variable, we decompose the accumulated operator into a strict face and degeneracy, use the face as an index lookup, and act by the degeneracy.  The forcing function is the identity if the entry is not lazy, and force_eval_term if it is lazy. *)
  | Ext (_, nk', Ok entry), Now ->
      let Eq = D.plus_uniq nk nk' in
      Looked_up { act = act_value; op; entry }
  (* Looking up a variable that's bound to an error immediately fails with that error.  (In particular, this sort of failure can't currently happen "deeper" inside a term.) *)
  | Ext (_, _, Error e), Now -> fatal e
  | LazyExt (_, nk', entry), Now ->
      let Eq = D.plus_uniq nk nk' in
      Looked_up { act = (fun x s -> force_eval_term (act_lazy_eval x s)); op; entry }

and lookup : type n b. (n, b) env -> b Term.index -> kinetic value =
 fun env (Index (v, fa)) ->
  let (Plus n_k) = D.plus (cod_sface fa) in
  let n = dim_env env in
  match lookup_cube env n_k v (id_op (D.plus_out n n_k)) with
  | Looked_up { act; op; entry } ->
      let (Plus x) = D.plus (dom_sface fa) in
      let (Op (f, s)) = comp_op op (plus_op n n_k x (op_of_sface fa)) in
      act (CubeOf.find entry f) s

(* Instantiate an arbitrary value, combining tubes. *)
and inst : type m n mn s. s value -> (m, n, mn, normal) TubeOf.t -> s value =
 fun tm args2 ->
  let n = TubeOf.inst args2 in
  match D.compare_zero n with
  | Zero -> tm
  | Pos dim2 -> (
      match view_term tm with
      | Neu { head; args = neu_args; value; ty = (lazy ty) } -> (
          (* We have to combine the new instantiation with any existing instantation at the end of the application spine. *)
          let base_args, args1 = inst_of_apps neu_args in
          let (Any_tube args1) =
            Option.value args1 ~default:(Any_tube (TubeOf.empty (TubeOf.out args2))) in
          match D.compare (TubeOf.out args2) (TubeOf.uninst args1) with
          | Neq ->
              fatal
                (Dimension_mismatch ("instantiating a type 1", TubeOf.out args2, TubeOf.uninst args1))
          | Eq -> (
              let (Plus nk) = D.plus (TubeOf.inst args1) in
              let newargs = TubeOf.plus_tube nk args1 args2 in
              let args = Inst (base_args, D.pos_plus dim2 nk, newargs) in
              let value = inst_lazy value args2 in
              (* Now we have to construct the type OF the new instantiation.  The old term must have belonged to some instantiation of the universe of the previously uninstantiated dimension. *)
              match view_type ty "inst" with
              | Canonical (_, UU m, ins, tys1) -> (
                  let Eq = eq_of_ins_zero ins in
                  match D.compare m (TubeOf.uninst args1) with
                  | Neq ->
                      fatal (Dimension_mismatch ("instantiating a type 2", m, TubeOf.uninst args1))
                  | Eq ->
                      let ty = lazy (tyof_inst tys1 args2) in
                      Neu { head; args; value; ty })
              | _ -> fatal (Anomaly "can't instantiate non-type")))
      | Canonical { canonical = c; tyargs = args1; ins; fields; inst_fields = _ } -> (
          match D.compare (TubeOf.out args2) (TubeOf.uninst args1) with
          | Neq ->
              fatal
                (Dimension_mismatch ("instantiating a type 3", TubeOf.out args2, TubeOf.uninst args1))
          | Eq ->
              let (Plus nk) = D.plus (TubeOf.inst args1) in
              let args = TubeOf.plus_tube nk args1 args2 in
              let inst_fields = inst_fibrancy_fields fields args in
              Canonical { canonical = c; tyargs = args; ins; fields; inst_fields })
      | Lam _ | Struct _ | Constr _ -> fatal (Anomaly "instantiating non-type"))

(* Instantiate a list of fibrancy fields by passing repeatedly to its internal corecursive 'id' field. *)
and inst_fibrancy_fields : type m n mn.
    (mn * potential * no_eta) Value.StructfieldAbwd.t ->
    (m, n, mn, normal) TubeOf.t ->
    (m * potential * no_eta) Value.StructfieldAbwd.t option =
 fun fields tyargs ->
  let open Monad.Ops (Monad.Maybe) in
  match Hott.faces () with
  | None -> None
  | Some (_, _, l) -> (
      match D.compare_zero (TubeOf.inst tyargs) with
      | Zero ->
          let Eq = D.plus_uniq (TubeOf.plus tyargs) (D.plus_zero (TubeOf.uninst tyargs)) in
          Some fields
      | Pos n -> (
          let m = TubeOf.uninst tyargs in
          let m_n1 = TubeOf.plus tyargs in
          let (Is_suc (n, n_1, one)) = suc_pos n in
          match D.compare (D.plus_right n_1) Hott.dim with
          | Neq -> fatal (Dimension_mismatch ("inst_fibrancy_fields", D.plus_right n_1, Hott.dim))
          | Eq -> (
              let (Plus m_n) = D.plus n in
              let middle, outer = TubeOf.split m_n n_1 tyargs in
              (* TODO: Is it always correct to use the identity fldins? *)
              let mn_1 = D.plus_assocl m_n n_1 m_n1 in
              let fldins = id_ins (D.plus_out m m_n) mn_1 in
              let idfld =
                struct_field ~unset_ok:true "fibrancy" Potential fields Fibrancy.fid fldins in
              let (Snoc (Snoc (Emp, xcube), ycube)) = TubeOf.to_cube_bwv one l outer in
              let v =
                match
                  app_eval_apps idfld
                    (Arg
                       ( Arg (Emp, xcube, ins_zero (CubeOf.dim xcube)),
                         ycube,
                         ins_zero (CubeOf.dim ycube) ))
                with
                | Val v -> Some v
                | Realize (Neu { value; _ }) -> (
                    match force_eval value with
                    | Val v -> Some v
                    | _ -> None)
                | _ -> None in
              match v with
              | Some (Struct { fields; ins; energy = Potential; eta = Noeta }) -> (
                  match (is_id_ins ins, D.compare (cod_left_ins ins) (TubeOf.out middle)) with
                  | Some _, Eq -> inst_fibrancy_fields fields middle
                  | Some _, Neq ->
                      fatal
                        (Dimension_mismatch ("inst_fibrancy", cod_left_ins ins, TubeOf.out middle))
                  | None, _ -> fatal (Anomaly "nonidentity insertion on evaluation of fibrancy id"))
              | Some _ -> fatal (Anomaly "fibrancy id didn't yield a struct")
              | None -> Some Emp)))

and get_fibrancy_fields : type m k mk e n.
    (m, k, mk, e, n) inst_canonical -> (m * potential * no_eta) Value.StructfieldAbwd.t =
 fun c ->
  match c.inst_fields with
  | Some f -> f
  | None -> (
      match inst_fibrancy_fields c.fields c.tyargs with
      | Some f ->
          c.inst_fields <- Some f;
          f
      | None -> Emp)

(* Given two families of values, the second intended to be the types of the other, annotate the former by instantiations of the latter to make them into normals.  Since we have to instantiate the types at the *normal* version of the terms, which is what we are computing, we also add the results to a hashtable as we create them so we can access them randomly later.  And since we have to do this sometimes with cubes and sometimes with tubes, we first define the content of the operation as a helper function. *)

and norm_of_val : type m n.
    (n sface_of, normal) Hashtbl.t -> (m, n) sface -> kinetic value -> kinetic value -> normal =
 fun new_tm_tbl fab tm ty ->
  let args =
    TubeOf.build D.zero
      (D.zero_plus (dom_sface fab))
      {
        build = (fun fc -> Hashtbl.find new_tm_tbl (SFace_of (comp_sface fab (sface_of_tface fc))));
      } in
  let ty = inst ty args in
  let newtm = { tm; ty } in
  Hashtbl.add new_tm_tbl (SFace_of fab) newtm;
  newtm

and norm_of_vals_cube : type k.
    (k, kinetic value) CubeOf.t -> (k, kinetic value) CubeOf.t -> (k, normal) CubeOf.t =
 fun tms tys ->
  let new_tm_tbl = Hashtbl.create 10 in
  CubeOf.mmap { map = (fun fab [ tm; ty ] -> norm_of_val new_tm_tbl fab tm ty) } [ tms; tys ]

and norm_of_vals_tube : type n k nk.
    (n, k, nk, kinetic value) TubeOf.t ->
    (n, k, nk, kinetic value) TubeOf.t ->
    (n, k, nk, normal) TubeOf.t =
 fun tms tys ->
  let new_tm_tbl = Hashtbl.create 10 in
  TubeOf.mmap
    { map = (fun fab [ tm; ty ] -> norm_of_val new_tm_tbl (sface_of_tface fab) tm ty) }
    [ tms; tys ]

(* Given a type belonging to the m+n dimensional universe instantiated at tyargs, compute the instantiation of the m-dimensional universe that its instantiation belongs to. *)
and tyof_inst : type m n mn.
    (D.zero, mn, mn, normal) TubeOf.t -> (m, n, mn, normal) TubeOf.t -> kinetic value =
 fun tyargs eargs ->
  let m = TubeOf.uninst eargs in
  let n = TubeOf.inst eargs in
  let mn = TubeOf.plus eargs in
  let margs =
    TubeOf.build D.zero (D.zero_plus m)
      {
        build =
          (fun fe ->
            let j = dom_tface fe in
            let (Plus jn) = D.plus (D.plus_right mn) in
            let jnargs =
              TubeOf.build j jn
                {
                  build =
                    (fun fa ->
                      let (PFace_of_plus (pq, fc, fd)) = pface_of_plus fa in
                      TubeOf.find eargs
                        (sface_plus_tface
                           (comp_sface (sface_of_tface fe) fc)
                           (D.plus_zero m) mn pq fd));
                } in
            (* We need to able to look things up in tyargs that are indexed by a composite of tfaces.  TODO: Actually define composites of tfaces, with each other and/or with sfaces on one side or the other, so that this works.  For the moment, we punt and use a hashtbl indexed by sfaces. *)
            let tyargtbl = Hashtbl.create 10 in
            TubeOf.miter
              { it = (fun fa [ ty ] -> Hashtbl.add tyargtbl (SFace_of (sface_of_tface fa)) ty) }
              [ tyargs ];
            let jntyargs =
              TubeOf.build D.zero
                (D.zero_plus (D.plus_out j jn))
                {
                  build =
                    (fun fa ->
                      let fb = sface_plus_sface (sface_of_tface fe) mn jn (id_sface n) in
                      Hashtbl.find tyargtbl (SFace_of (comp_sface fb (sface_of_tface fa))));
                } in
            let tm = inst (TubeOf.find tyargs (tface_plus fe mn mn jn)).tm jnargs in
            let ty = tyof_inst jntyargs jnargs in
            { tm; ty });
      } in
  inst (universe m) margs

(* Apply a function to all the values in a cube one by one as 0-dimensional applications, rather than as one n-dimensional application. *)
let apply_singletons : type n. kinetic value -> (n, kinetic value) CubeOf.t -> kinetic value =
 fun fn xs ->
  let module MC = CubeOf.Monadic (Monad.State (struct
    type t = kinetic value
  end)) in
  snd (MC.miterM { it = (fun _ [ x ] fn -> ((), apply_term fn (CubeOf.singleton x))) } [ xs ] fn)

(* Evaluate a term context to produce a value context. *)

let eval_bindings : type a b n.
    (a, b) Ctx.Ordered.t -> (n, (b, n) snoc binding) CubeOf.t -> (n, Ctx.Binding.t) CubeOf.t =
 fun ctx cbs ->
  let i = Ctx.Ordered.length ctx in
  let vbs = CubeOf.build (CubeOf.dim cbs) { build = (fun _ -> Ctx.Binding.unknown ()) } in
  let tempctx = Ctx.Ordered.Snoc (ctx, Invis vbs, Zero) in
  let argtbl = Hashtbl.create 10 in
  let j = ref 0 in
  let () =
    CubeOf.miter
      {
        it =
          (fun fa [ ({ ty = cty; tm = ctm } : (b, n) snoc binding); vb ] ->
            (* Unlike in dom_vars, we don't need to instantiate the types, since their instantiations should have been preserved by readback and will reappear correctly here. *)
            let ety = eval_term (Ctx.Ordered.env tempctx) cty in
            let level = (i, !j) in
            j := !j + 1;
            let lvl, v =
              match ctm with
              | None -> (Some level, ({ tm = var level ety; ty = ety } : normal))
              | Some ctm -> (None, { tm = eval_term (Ctx.Ordered.env tempctx) ctm; ty = ety }) in
            Hashtbl.add argtbl (SFace_of fa) v;
            Ctx.Binding.specify vb lvl v);
      }
      [ cbs; vbs ] in
  vbs

let eval_entry : type a b f n. (a, b) Ctx.Ordered.t -> (b, f, n) entry -> (f, n) Ctx.entry =
 fun ctx e ->
  match e with
  | Vis { dim; plusdim; vars; bindings; hasfields; fields; fplus } ->
      let bindings = eval_bindings ctx bindings in
      let fields = Bwv.map (fun (f, x, _) -> (f, x)) fields in
      Vis { dim; plusdim; vars; bindings; hasfields; fields; fplus }
  | Invis bindings -> Invis (eval_bindings ctx bindings)

let rec eval_ordered_ctx : type a b. (a, b) ordered_termctx -> (a, b) Ctx.Ordered.t = function
  | Emp -> Emp
  | Ext (ctx, e, af) ->
      let ectx = eval_ordered_ctx ctx in
      Snoc (ectx, eval_entry ectx e, af)
  | Lock ctx -> Lock (eval_ordered_ctx ctx)

let eval_ctx : type a b. (a, b) termctx -> (a, b) Ctx.t = function
  | Permute (perm, ctx) ->
      let ctx = eval_ordered_ctx ctx in
      Permute { perm; env = Ctx.Ordered.env ctx; level = Ctx.Ordered.length ctx; ctx }

(* Evaluate a telescope (forwards context of terms) and append the result to a context. *)
let rec eval_append : type a b c ac bc.
    (a, b) Ctx.t -> (a, c, ac) Fwn.bplus -> (b, c, bc) Telescope.t -> (ac, bc) Ctx.t =
 fun ctx ac tel ->
  match (ac, tel) with
  | Zero, Emp -> ctx
  | Suc ac, Ext (x, ty, tel) ->
      let ty = eval_term (Ctx.env ctx) ty in
      eval_append (Ctx.ext ctx x ty) ac tel

(* Get the instantiation arguments of a type, of any sort. *)
let get_tyargs ?(severity = Asai.Diagnostic.Bug) (ty : kinetic value) (err : string) :
    normal TubeOf.full =
  match view_type ~severity ty err with
  | Canonical (_, _, _, tyargs) -> Full_tube tyargs
  | Neutral (_, _, tyargs) -> Full_tube tyargs

(* Check whether a given type is discrete, or has one of the the supplied constant heads (since for testing whether a newly defined datatype can be discrete, it and members of its mutual families can appear in its own parameters and arguments). *)
let is_discrete : ?discrete:unit Constant.Map.t -> kinetic value -> bool =
 fun ?discrete ty ->
  match (view_type ty "is_discrete", discrete) with
  | Canonical (_, Data { discrete = `Yes; _ }, _, _), _ -> true
  (* The currently-being-defined types may not be known to be discrete yet, but we treat them as discrete if they are one of the given heads. *)
  | Canonical (Const { name; ins }, _, _, _), Some consts ->
      Option.is_some (is_id_ins ins) && Constant.Map.mem name consts
  | Neutral (Const { name; ins }, _, _), Some consts ->
      Option.is_some (is_id_ins ins) && Constant.Map.mem name consts
      (* In theory, pi-types with discrete codomain, and record types with discrete fields, could also be discrete.  But that would be trickier to check as it would require evaluating their codomain and fields under binders, and eta-conversion for those types should implement direct discreteness automatically.  So the only thing we're missing is that they can't appear as arguments to a constructor of some other discrete datatype. *)
  | _ -> false

let () =
  View.term_viewer := view_term;
  View.type_viewer := view_type;
  View.eval_forcer := { force = force_eval }
