open Util

(* Since dimensions are epimorphisms, given n and nk there is at most one k such that (n,k,nk) D.plus.  This function finds it if it exists. *)

type (_, _) factor = Factor : ('n, 'k, 'nk) D.plus -> ('nk, 'n) factor

let rec factor : type nk n. nk D.t -> n D.t -> (nk, n) factor option =
 fun nk n ->
  let open Monad.Ops (Monad.Maybe) in
  match N.compare nk n with
  | Eq -> Some (Factor Zero)
  | Neq -> (
      match nk with
      | Nat Zero -> None
      | Nat (Suc nk) ->
          let* (Factor n_k) = factor (Nat nk) n in
          return (Factor (Suc n_k)))

type (_, _) cofactor = Cofactor : ('n, 'k, 'nk) D.plus -> ('nk, 'k) cofactor

let rec cofactor : type nk k. nk D.t -> k D.t -> (nk, k) cofactor option =
 fun nk k ->
  let open Monad.Ops (Monad.Maybe) in
  match (nk, k) with
  | Nat Zero, Nat Zero -> Some (Cofactor Zero)
  | Nat (Suc nk), Nat (Suc k) ->
      let* (Cofactor n) = cofactor (Nat nk) (Nat k) in
      return (Cofactor (Suc n))
  | Nat (Suc _), Nat Zero -> return (Cofactor (D.plus_zero nk))
  | _ -> None

(* Compute the pushout of a span of dimensions, if it exists.  In practice we only need pushouts of spans that can be completed to some commutative square (equivalently, pushouts in slice categories), but in our primary examples all pushouts exist, so we don't bother putting an option on it yet. *)

type (_, _) pushout = Pushout : ('a, 'c, 'p) D.plus * ('b, 'd, 'p) D.plus -> ('a, 'b) pushout

let pushout : type a b. a D.t -> b D.t -> (a, b) pushout =
 fun a b ->
  match D.trichotomy a b with
  | Eq -> Pushout (Zero, Zero)
  | Lt ab -> Pushout (ab, Zero)
  | Gt ba -> Pushout (Zero, ba)

(* A dimension is totally nullary if all its directions have arity zero.  Currently there is only one direction, so it suffices to test whether the overall arity is zero.  *)

let totally_nullary : type a. a D.t -> bool =
 fun _ ->
  let (Wrap l) = Endpoints.wrapped () in
  match Endpoints.len l with
  | Nat Zero -> true
  | Nat (Suc _) -> false
