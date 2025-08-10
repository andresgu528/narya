open Bwd
open Dim
open Util
open List_extra
open Core
open Origin
open Readback
open Notation
open Postprocess
open Unparse
open Print
open Reporter
open User
open Modifier
open Printable
module Trie = Yuujinchou.Trie
module TermParse = Parse

module StringsMap = Map.Make (struct
  type t = string list

  let compare = compare
end)

type 'a attribute = {
  wshash : Whitespace.t list;
  wslparen : Whitespace.t list;
  loc : Asai.Range.t option;
  attr : 'a;
  wsattr : Whitespace.t list list;
  wsrparen : Whitespace.t list;
}

type def = {
  wsdef : Whitespace.t list;
  name : Trie.path;
  loc : Asai.Range.t option;
  wsname : Whitespace.t list;
  parameters : Parameter.t list;
  ty : (Whitespace.t list * wrapped_parse) option;
  wscoloneq : Whitespace.t list;
  tm : wrapped_parse;
}

type solve_data = {
  wssolve : Whitespace.t list;
  number : int;
  wsnumber : Whitespace.t list;
  column : int;
  wscolumn : Whitespace.t list;
  wscoloneq : Whitespace.t list;
  tm : wrapped_parse ref;
}

module Command = struct
  type t =
    | Axiom of {
        wsaxiom : Whitespace.t list;
        nonparam : unit attribute option;
        name : Trie.path;
        loc : Asai.Range.t option;
        wsname : Whitespace.t list;
        parameters : Parameter.t list;
        wscolon : Whitespace.t list;
        ty : wrapped_parse;
      }
    | Def of def list
    (* "synth" is almost just like "echo", so we implement them as one command distinguished by an "eval" flag. *)
    | Echo of {
        wsecho : Whitespace.t list;
        number : int option;
        wsin : Whitespace.t list;
        wsnumber : Whitespace.t list;
        tm : wrapped_parse;
        eval : bool;
      }
    | Notation : {
        fixity : ('left, 'tight, 'right) fixity;
        wsnotation : Whitespace.t list;
        wslparen : Whitespace.t list;
        wstight : Whitespace.t list; (* Empty for outfix *)
        wsellipsis : Whitespace.t list; (* Empty for non-associative *)
        loc : Asai.Range.t option;
        wsrparen : Whitespace.t list;
        pattern : ('left, 'right) User.Pattern.t;
        wscoloneq : Whitespace.t list;
        head : [ `Constr of string | `Constant of Trie.path ];
        wshead : Whitespace.t list;
        args : (string * Whitespace.t list) list;
      }
        -> t
    | Import of {
        wsimport : Whitespace.t list;
        export : bool;
        origin : [ `File of string | `Path of Trie.path ];
        wsorigin : Whitespace.t list;
        op : (Whitespace.t list * modifier) option;
      }
    | Solve of solve_data
    | Split of solve_data
    (* Show and Undo don't get reformatted (see pp_command, below), so there's no need to store whitespace in them, but we do it anyway for completeness. *)
    | Show of {
        wsshow : Whitespace.t list;
        what : [ `Hole of Whitespace.t list * int | `Holes ];
        wswhat : Whitespace.t list;
      }
    | Display of {
        wsdisplay : Whitespace.t list;
        wscoloneq : Whitespace.t list;
        what :
          [ `Chars of Whitespace.t list * Display.chars Display.toggle * Whitespace.t list
          | `Function_boundaries of
            Whitespace.t list * Whitespace.t list * Display.show Display.toggle * Whitespace.t list
          | `Type_boundaries of
            Whitespace.t list * Whitespace.t list * Display.show Display.toggle * Whitespace.t list
          ];
      }
    | Option of { wsoption : Whitespace.t list; wscoloneq : Whitespace.t list; what : Empty.t }
    | Undo of { wsundo : Whitespace.t list; count : int; wscount : Whitespace.t list }
    | Section of {
        wssection : Whitespace.t list;
        prefix : string list;
        wsprefix : Whitespace.t list;
        wscoloneq : Whitespace.t list;
      }
    | End of { wsend : Whitespace.t list }
    | Quit of Whitespace.t list
    | Bof of Whitespace.t list
    | Eof
end

include Command

module Parse = struct
  open Parse
  module C = Combinators (Command)
  open C.Basic

  let token x = step "" (fun state _ (tok, w) -> if tok = x then Some (w, state) else None)

  let ident =
    step "" (fun state _ (tok, w) ->
        match tok with
        | Ident name -> Some ((name, w), state)
        | _ -> None)

  let variable =
    let* loc, (xs, w) =
      located
        (step "" (fun state _ (tok, w) ->
             match tok with
             | Ident xs -> Some ((Some xs, w), state)
             | Underscore -> Some ((None, w), state)
             | _ -> None)) in
    match xs with
    | Some [ x ] when Lexer.valid_var x -> return (Some x, w)
    | None -> return (None, w)
    | Some xs -> fatal ~loc:(Range.convert loc) (Invalid_variable xs)

  let parameter =
    let* wslparen = token LParen in
    let* name, names = one_or_more variable in
    let names = name :: names in
    let* wscolon = token Colon in
    let* ty = C.term [ RParen ] in
    let* wsrparen = token RParen in
    return ({ wslparen; names; wscolon; ty; wsrparen } : Parameter.t)

  let attribute : type a. a StringsMap.t -> a attribute option t =
   fun values ->
    let* hash = optional (token (Op "#")) in
    match hash with
    | None -> return None
    | Some wshash -> (
        let* wslparen = token LParen in
        let* (Wrap tm) = C.term [] in
        let* wsrparen = token RParen in
        let strs, wsattr = strings_of_term tm.value in
        match StringsMap.find_opt strs values with
        | None -> fatal ?loc:tm.loc Unrecognized_attribute
        | Some attr -> return (Some { wshash; wslparen; loc = tm.loc; attr; wsattr; wsrparen }))

  let axiom =
    let* wsaxiom = token Axiom in
    let* nonparam = attribute (StringsMap.of_list [ ([ "nonparametric" ], ()) ]) in
    let* nameloc, (name, wsname) = located ident in
    let loc = Some (Range.convert nameloc) in
    let* parameters = zero_or_more parameter in
    let* wscolon = token Colon in
    let* ty = C.term [] in
    return (Command.Axiom { wsaxiom; nonparam; name; loc; wsname; parameters; wscolon; ty })

  let def tok =
    let* wsdef = token tok in
    let* nameloc, (name, wsname) = located ident in
    let loc = Some (Range.convert nameloc) in
    if not (Lexer.valid_ident name) then fatal ?loc (Invalid_constant_name (name, None));
    let* parameters = zero_or_more parameter in
    let* ty, wscoloneq, tm =
      (let* wscolon = token Colon in
       let* ty = C.term [ Coloneq ] in
       let* wscoloneq = token Coloneq in
       let* tm = C.term [] in
       return (Some (wscolon, ty), wscoloneq, tm))
      </>
      let* wscoloneq = token Coloneq in
      let* tm = C.term [] in
      return (None, wscoloneq, tm) in
    return ({ wsdef; name; loc; wsname; parameters; ty; wscoloneq; tm } : def)

  let def_and =
    let* first = def Def in
    let* rest = zero_or_more (def And) in
    return (Command.Def (first :: rest))

  let integer =
    step "" (fun state _ (tok, ws) ->
        match tok with
        | Ident [ num ] -> Some ((int_of_string num, ws), state)
        | _ -> None)

  let echo =
    let* wsecho, eval =
      (let* wsecho = token Echo in
       return (wsecho, true))
      </> let* wsecho = token Synth in
          return (wsecho, false) in
    let* number, wsin, wsnumber, tm =
      (let* wsin = token In in
       let* number, wsnumber = integer in
       let* tm = C.term [] in
       return (Some number, wsin, wsnumber, tm))
      </> let* tm = C.term [] in
          return (None, [], [], tm) in
    return (Command.Echo { wsecho; number; wsin; wsnumber; tm; eval })

  let tightness : (Whitespace.t list * No.wrapped option * Whitespace.t list * Whitespace.t list) t
      =
    (let* wslparen = token LParen in
     let* sign =
       (let* minusloc, wsminus = located (token (Op "-")) in
        if not (List.is_empty wsminus) then fatal ~loc:(Range.convert minusloc) Parse_error;
        return Q.neg)
       </> return (fun x -> x) in
     let* tloc, (tight, wstight) = located ident in
     let* wsrparen = token RParen in
     let tight = String.concat "." tight in
     match No.of_rat (sign (Q.of_string tight)) with
     | Some tight -> return (wslparen, Some tight, wstight, wsrparen)
     | None | (exception Invalid_argument _) ->
         fatal ~loc:(Range.convert tloc) (Invalid_tightness tight))
    </> return ([], None, [], [])

  let pattern_token =
    step "" (fun state _ (tok, ws) ->
        match tok with
        | String str -> (
            match Lexer.single str with
            (* Currently we hard code a `Nobreak space after each *symbol* in a notation.  Only certain kinds of token are allowed. *)
            | Some (Op _ as tok) | Some (Ident [ _ ] as tok) -> Some (`Op (tok, `Nobreak, ws), state)
            | Some tok
              when Array.mem tok
                     [|
                       LBracket;
                       RBracket;
                       LBrace;
                       RBrace;
                       Arrow;
                       Mapsto;
                       DblMapsto;
                       Colon;
                       Coloneq;
                       DblColoneq;
                       Pluseq;
                       Dot;
                       Ellipsis;
                     |] -> Some (`Op (tok, `Nobreak, ws), state)
            | _ -> fatal (Invalid_notation_symbol str))
        | _ -> None)

  let pattern_var =
    let* loc, (x, ws) = located ident in
    match x with
    (* Currently we hard code a `Break space after each *variable* in a notation. *)
    | [ x ] when Lexer.valid_var x -> return (`Var (x, `Break, ws))
    | _ -> fatal ~loc:(Range.convert loc) (Invalid_variable x)

  let pattern_ellipsis =
    let* ws = token Ellipsis in
    return (`Ellipsis ws)

  (* The function fixity_of_pattern "typechecks" a user notation pattern, verifying all the invariants and producing an element of User.Pattern.t in which those invariants are statically guaranteed.  It also interprets ellipses to produce a fixity: a starting ellipse before a variable means left-associative, an ending ellipse after a variable means right-associative, and any other use of ellipses is an error. *)

  type fixity_and_pattern =
    | Fix_pat :
        ('left, 'tight, 'right) fixity * ('left, 'right) User.Pattern.t
        -> fixity_and_pattern

  let fixity_of_pattern pat tight =
    let rec go : type left right.
        [ `Var of string * space * Whitespace.t list
        | `Op of Token.t * space * Whitespace.t list
        | `Ellipsis of Whitespace.t list ]
        Bwd.t ->
        (left, right) User.Pattern.t ->
        right User.Pattern.right_t =
     fun bwd_pat new_pat ->
      match bwd_pat with
      | Emp -> Right new_pat
      | Snoc (bwd_pat, `Var v) -> go bwd_pat (User.Pattern.var v new_pat)
      | Snoc (bwd_pat, `Op v) -> go bwd_pat (Op (v, new_pat))
      | Snoc (_, `Ellipsis _) -> fatal (Unimplemented "internal ellipses in notation") in
    let opnil (a, _, c) = User.Pattern.Op_nil (a, c) in
    let varnil v (a, _, c) = User.Pattern.Var_nil (v, (a, c)) in
    match pat with
    | [] -> fatal (Invalid_notation_pattern "empty")
    | [ `Ellipsis _ ] -> fatal (Invalid_notation_pattern "has no symbols")
    | `Ellipsis _ :: `Op _ :: _ ->
        fatal (Invalid_notation_pattern "prefix/outfix notation can't be left-associative")
    | `Ellipsis _ :: `Ellipsis _ :: _ -> fatal (Invalid_notation_pattern "too many ellipses")
    | `Op v :: pat -> (
        match Bwd.of_list pat with
        | Emp -> (Fix_pat (Outfix, opnil v), [])
        | Snoc (bwd_pat, `Op w) ->
            if Option.is_some tight then fatal Fixity_mismatch;
            let (Right new_pat) = go bwd_pat (opnil w) in
            (Fix_pat (Outfix, Op (v, new_pat)), [])
        | Snoc (Snoc (bwd_pat, `Op o), `Var w) ->
            let (No.Wrap tight) = tight <|> Fixity_mismatch in
            let (Right new_pat) = go bwd_pat (varnil o w) in
            (Fix_pat (Prefix tight, Op (v, new_pat)), [])
        | Snoc (Emp, `Var w) ->
            let (No.Wrap tight) = tight <|> Fixity_mismatch in
            (Fix_pat (Prefix tight, varnil v w), [])
        | Snoc (Snoc (_, `Var _), `Var _) ->
            fatal (Invalid_notation_pattern "missing symbol between variables")
        | Snoc (Snoc (_, `Ellipsis _), `Var _) ->
            fatal (Unimplemented "internal ellipses in notation")
        | Snoc (Snoc (Snoc (bwd_pat, `Op o), `Var w), `Ellipsis ws) ->
            let (No.Wrap tight) = tight <|> Fixity_mismatch in
            let (Right new_pat) = go bwd_pat (varnil o w) in
            (Fix_pat (Prefixr tight, Op (v, new_pat)), ws)
        | Snoc (Snoc (_, `Op _), `Ellipsis _) | Snoc (_, `Ellipsis _) ->
            fatal (Invalid_notation_pattern "postfix/outfix notation can't be right-associative"))
    | `Var v :: pat -> (
        match Bwd.of_list pat with
        | Emp | Snoc (Emp, `Ellipsis _) -> fatal (Invalid_notation_pattern "has no symbols")
        | Snoc (bwd_pat, `Op w) ->
            let (No.Wrap tight) = tight <|> Fixity_mismatch in
            let (Right new_pat) = go bwd_pat (opnil w) in
            (Fix_pat (Postfix tight, User.Pattern.var v new_pat), [])
        | Snoc (Snoc (bwd_pat, `Op o), `Var w) ->
            let (No.Wrap tight) = tight <|> Fixity_mismatch in
            let (Right new_pat) = go bwd_pat (varnil o w) in
            (Fix_pat (Infix tight, User.Pattern.var v new_pat), [])
        | Snoc (Snoc (Snoc (bwd_pat, `Op o), `Var w), `Ellipsis ws) ->
            let (No.Wrap tight) = tight <|> Fixity_mismatch in
            let (Right new_pat) = go bwd_pat (varnil o w) in
            (Fix_pat (Infixr tight, User.Pattern.var v new_pat), ws)
        | Snoc (Snoc (_, `Var _), `Var _)
        | Snoc (Emp, `Var _)
        | Snoc (Snoc (Snoc (_, `Var _), `Var _), `Ellipsis _)
        | Snoc (Snoc (Emp, `Var _), `Ellipsis _) ->
            fatal (Invalid_notation_pattern "missing symbol between variables")
        | Snoc (Snoc (_, `Ellipsis _), `Var _)
        | Snoc (Snoc (Snoc (_, `Ellipsis _), `Var _), `Ellipsis _) ->
            fatal (Unimplemented "internal ellipses in notation")
        | Snoc (Snoc (_, `Op _), `Ellipsis _) ->
            fatal (Invalid_notation_pattern "postfix/outfix notation can't be right-associative")
        | Snoc (Snoc (_, `Ellipsis _), `Ellipsis _) ->
            fatal (Invalid_notation_pattern "too many ellipses"))
    | `Ellipsis ws :: `Var v :: pat -> (
        match Bwd.of_list pat with
        | Emp -> fatal (Invalid_notation_pattern "has no symbols")
        | Snoc (bwd_pat, `Op w) ->
            let (No.Wrap tight) = tight <|> Fixity_mismatch in
            let (Right new_pat) = go bwd_pat (opnil w) in
            (Fix_pat (Postfixl tight, User.Pattern.var v new_pat), ws)
        | Snoc (Snoc (bwd_pat, `Op o), `Var w) ->
            let (No.Wrap tight) = tight <|> Fixity_mismatch in
            let (Right new_pat) = go bwd_pat (varnil o w) in
            (Fix_pat (Infixl tight, User.Pattern.var v new_pat), ws)
        | Snoc (Snoc (_, `Var _), `Var _) | Snoc (Emp, `Var _) ->
            fatal (Invalid_notation_pattern "missing symbol between variables")
        | Snoc (Snoc (_, `Ellipsis _), `Var _) ->
            fatal (Unimplemented "internal ellipses in notation")
        | Snoc (_, `Ellipsis _) ->
            fatal (Invalid_notation_pattern "can't be both right and left associative"))

  let notation_head =
    step "" (fun state _ (tok, ws) ->
        match tok with
        | Ident name -> Some ((`Constant name, ws), state)
        | Constr (c, []) -> Some ((`Constr c, ws), state)
        | _ -> None)

  let notation_var =
    let* loc, (x, ws) = located ident in
    match x with
    | [ x ] when Lexer.valid_var x -> return (x, ws)
    | _ -> fatal ~loc:(Range.convert loc) (Invalid_variable x)

  let notation =
    let* wsnotation = token Notation in
    let* wslparen, tight, wstight, wsrparen = tightness in
    let* loc, (pat, pattern) =
      located (one_or_more (pattern_token </> pattern_var </> pattern_ellipsis)) in
    let loc = Some (Range.convert loc) in
    let pattern = pat :: pattern in
    let Fix_pat (fixity, pattern), wsellipsis = fixity_of_pattern pattern tight in
    let* wscoloneq = token Coloneq in
    let* head, wshead = notation_head in
    let* args = zero_or_more notation_var in
    return
      (Command.Notation
         {
           fixity;
           wsnotation;
           wstight;
           wslparen;
           wsellipsis;
           loc;
           wsrparen;
           pattern;
           wscoloneq;
           head;
           wshead;
           args;
         })

  let path =
    ident
    </> let* wsdot = token Dot in
        return ([], wsdot)

  let rec modifier () =
    let* m =
      step "" (fun state _ (tok, ws) ->
          match tok with
          | Ident [ "all" ] -> Some (`All ws, state)
          | Ident [ "id" ] -> Some (`Id ws, state)
          | Ident [ "only" ] -> Some (`Only ws, state)
          | In -> Some (`In ws, state)
          | Ident [ "none" ] -> Some (`None ws, state)
          | Ident [ "except" ] -> Some (`Except ws, state)
          | Ident [ "renaming" ] -> Some (`Renaming ws, state)
          | Ident [ "seq" ] -> Some (`Seq ws, state)
          | Ident [ "union" ] -> Some (`Union ws, state)
          | _ -> None) in
    match m with
    | `All wsall -> return (All { wsall })
    | `Id wsid -> return (Id { wsid })
    | `Only wsonly ->
        let* path, wspath = path in
        return (Only { wsonly; path; wspath })
    | `In wsin ->
        let* path, wspath = path in
        let* op = modifier () in
        return (In { wsin; path; wspath; op })
    | `None wsnone -> return (MNone { wsnone })
    | `Except wsexcept ->
        let* path, wspath = path in
        return (Except { wsexcept; path; wspath })
    | `Renaming wsrenaming ->
        let* source, wssource = path in
        let* target, wstarget = path in
        return (Renaming { wsrenaming; source; wssource; target; wstarget })
    | `Seq wsseq ->
        let* wslparen = token LParen in
        let* ops =
          zero_or_more_fold_left Bwd.Emp
            (fun x y -> return (Snoc (x, y)))
            (backtrack
               (let* op = modifier () in
                let* wssemi = token (Op ",") in
                return (op, wssemi))
               "") in
        let* lastop = optional (modifier ()) in
        let ops =
          Bwd.fold_right
            (fun x y -> x :: y)
            ops
            (Option.fold ~none:[] ~some:(fun x -> [ (x, []) ]) lastop) in
        let* wsrparen = token RParen in
        return (Seq { wsseq; wslparen; ops; wsrparen })
    | `Union wsunion ->
        let* wslparen = token LParen in
        let* ops =
          zero_or_more_fold_left Bwd.Emp
            (fun x y -> return (Snoc (x, y)))
            (backtrack
               (let* op = modifier () in
                let* wssemi = token (Op ",") in
                return (op, wssemi))
               "") in
        let* lastop = optional (modifier ()) in
        let ops =
          Bwd.fold_right
            (fun x y -> x :: y)
            ops
            (Option.fold ~none:[] ~some:(fun x -> [ (x, []) ]) lastop) in
        let* wsrparen = token RParen in
        return (Union { wsunion; wslparen; ops; wsrparen })

  let import =
    let* wsimport, export =
      (let* wsimport = token Import in
       return (wsimport, false))
      </> let* wsimport = token Export in
          return (wsimport, true) in
    let* origin, wsorigin =
      step "" (fun state _ (tok, ws) ->
          match tok with
          | String file -> Some ((`File file, ws), state)
          | Ident x -> Some ((`Path x, ws), state)
          | Dot -> Some ((`Path [], ws), state)
          | _ -> None) in
    let* op =
      optional
        (backtrack
           (let* wsbar = token (Op "|") in
            let* m = modifier () in
            return (wsbar, m))
           "") in
    return (Import { wsimport; export; origin; wsorigin; op })

  let solve =
    let* wssolve = token Solve in
    let* number, wsnumber = integer in
    let* column, wscolumn = integer </> return (0, []) in
    let* wscoloneq = token Coloneq in
    let* tm = C.term [] in
    return (Solve { wssolve; number; wsnumber; column; wscolumn; wscoloneq; tm = ref tm })

  let split =
    let* wssolve = token Split in
    let* number, wsnumber = integer in
    let* column, wscolumn = integer </> return (0, []) in
    let* wscoloneq = token Coloneq in
    let* tm = C.term [] in
    return (Split { wssolve; number; wsnumber; column; wscolumn; wscoloneq; tm = ref tm })

  let show =
    let* wsshow = token Show in
    let* what =
      step "" (fun state _ (tok, ws) ->
          match tok with
          | Ident [ "hole" ] -> Some (`Hole ws, state)
          | Ident [ "holes" ] -> Some (`Holes ws, state)
          | _ -> None) in
    let* what, wswhat =
      match what with
      | `Hole ws ->
          let* number, wsnumber = integer in
          return (`Hole (ws, number), wsnumber)
      | `Holes ws -> return (`Holes, ws) in
    return (Show { wsshow; what; wswhat })

  let chars_of_token : Token.t -> Display.chars Display.toggle option = function
    | Ident [ "unicode" ] -> Some (`Set `Unicode)
    | Ident [ "ascii" ] -> Some (`Set `ASCII)
    | Ident [ "toggle" ] -> Some `Toggle
    | _ -> None

  let show_of_token : Token.t -> Display.show Display.toggle option = function
    | Ident [ "on" ] -> Some (`Set `Show)
    | Ident [ "off" ] -> Some (`Set `Hide)
    | Ident [ "toggle" ] -> Some `Toggle
    | _ -> None

  let display =
    let* wsdisplay = token Display in
    let* what, wswhat =
      step "" (fun state _ (tok, ws) ->
          match tok with
          | Ident [ "chars" ] -> Some ((`Chars, ws), state)
          | Ident [ "function" ] -> Some ((`Function, ws), state)
          | Ident [ "type" ] -> Some ((`Type, ws), state)
          | _ -> None) in
    match what with
    | `Chars ->
        let* wscoloneq = token Coloneq in
        step "" (fun state _ (tok, ws) ->
            let open Monad.Ops (Monad.Maybe) in
            let* chars = chars_of_token tok in
            return (Display { wsdisplay; wscoloneq; what = `Chars (wswhat, chars, ws) }, state))
    | `Function ->
        let* wsb = token (Ident [ "boundaries" ]) in
        let* wscoloneq = token Coloneq in
        step "" (fun state _ (tok, ws) ->
            let open Monad.Ops (Monad.Maybe) in
            let* show = show_of_token tok in
            return
              ( Display { wsdisplay; wscoloneq; what = `Function_boundaries (wswhat, wsb, show, ws) },
                state ))
    | `Type ->
        let* wsb = token (Ident [ "boundaries" ]) in
        let* wscoloneq = token Coloneq in
        step "" (fun state _ (tok, ws) ->
            let open Monad.Ops (Monad.Maybe) in
            let* show = show_of_token tok in
            return
              ( Display { wsdisplay; wscoloneq; what = `Type_boundaries (wswhat, wsb, show, ws) },
                state ))

  let implicit_of_token : Token.t -> [ `Implicit | `Explicit ] option = function
    | Ident [ "implicit" ] -> Some `Implicit
    | Ident [ "explicit" ] -> Some `Explicit
    | _ -> None

  let option =
    let* _ = token Option in
    fatal Parse_error

  let undo =
    let* wsundo = token Undo in
    let* count, wscount = integer in
    return (Command.Undo { wsundo; count; wscount })

  let section =
    let* wssection = token Section in
    let* prefix, wsprefix = ident in
    let* wscoloneq = token Coloneq in
    return (Command.Section { wssection; prefix; wsprefix; wscoloneq })

  let endcmd =
    let* wsend = token End in
    return (Command.End { wsend })

  let quit =
    let* wsquit = token Quit in
    return (Command.Quit wsquit)

  let bof =
    let* ws = C.bof in
    return (Command.Bof ws)

  let eof =
    let* () = expect_end () in
    return Command.Eof

  let command () =
    bof
    </> axiom
    </> def_and
    </> echo
    </> notation
    </> import
    </> solve
    </> split
    </> show
    </> display
    </> option
    </> undo
    </> section
    </> endcmd
    </> quit
    </> eof

  let command_or_echo () =
    command ()
    </> let* tm = C.term [] in
        return
          (Command.Echo { wsecho = []; number = None; wsin = []; wsnumber = []; tm; eval = true })

  type open_source = Range.Data.t * [ `String of int * string | `File of In_channel.t ]

  let start_parse ?(or_echo = false) source : C.Lex_and_parse.t * open_source =
    let (env : Range.Data.t), run =
      match source with
      | `String src ->
          ( { source = `String src; length = Int64.of_int (String.length src.content) },
            fun p ->
              let n, p = C.Lex_and_parse.run_on_string_at 0 src.content p in
              (`String (n, src.content), p) )
      | `File name -> (
          try
            let ic = In_channel.open_text name in
            ( { source = `File name; length = In_channel.length ic },
              fun p -> (`File ic, C.Lex_and_parse.run_on_channel ic p) )
          with Sys_error _ -> fatal (No_such_file name)) in
    Range.run ~env @@ fun () ->
    let p =
      C.Lex_and_parse.make Lexer.Parser.start
        (C.Basic.make_partial () (if or_echo then command_or_echo () else command ())) in
    let out, p = run p in
    (C.ensure_success p, (env, out))

  let restart_parse ?(or_echo = false) (p : C.Lex_and_parse.t) ((env, source) : open_source) :
      C.Lex_and_parse.t * open_source =
    let run =
      match source with
      | `String (n, content) ->
          fun p ->
            let n, p = C.Lex_and_parse.run_on_string_at n content p in
            (`String (n, content), p)
      | `File ic -> fun p -> (`File ic, C.Lex_and_parse.run_on_channel ic p) in
    Range.run ~env @@ fun () ->
    let p =
      C.Lex_and_parse.make_next p
        (C.Basic.make_partial () (if or_echo then command_or_echo () else command ())) in
    let out, p = run p in
    (C.ensure_success p, (env, out))

  let final p = C.Lex_and_parse.final p
  let has_consumed_end p = C.Lex_and_parse.has_consumed_end p
end

let parse_single (content : string) : Whitespace.t list * Command.t option =
  let src : Asai.Range.source = `String { content; title = None } in
  let p, src = Parse.start_parse ~or_echo:true src in
  match Parse.final p with
  | Bof ws ->
      let p, src = Parse.restart_parse ~or_echo:true p src in
      let cmd = Parse.final p in
      if cmd <> Eof then
        let p, _ = Parse.restart_parse ~or_echo:true p src in
        let eof = Parse.final p in
        if eof = Eof then (ws, Some cmd) else Core.Reporter.fatal Too_many_commands
      else (ws, None)
  | _ -> Core.Reporter.fatal (Anomaly "interactive parse doesn't start with Bof")

let show_hole = function
  | Global.Found_hole { instant; meta; termctx; ty; vars; _ } ->
      emit (Hole (Meta.name meta, PHole (Instant instant, vars, termctx, ty)))

let to_string : Command.t -> string = function
  | Axiom _ -> "axiom"
  | Def _ -> "def"
  | Echo { eval = true; _ } -> "echo"
  | Echo { eval = false; _ } -> "synth"
  | Notation _ -> "notation"
  | Import _ -> "import"
  | Solve _ -> "solve"
  | Split _ -> "split"
  | Show _ -> "show"
  | Display _ -> "display"
  | Option _ -> .
  | Quit _ -> "quit"
  | Undo _ -> "undo"
  | Section _ -> "section"
  | End _ -> "end"
  | Bof _ -> "bof"
  | Eof -> "eof"

(* Whether a command requires an interactive mode (i.e. not interactive mode and not ProofGeneral interaction). *)
let needs_interactive : Command.t -> bool = function
  | Solve _ | Split _ | Show _ | Undo _ -> true
  | _ -> false

let condense : Command.t -> [ `Import | `Option | `None | `Bof ] = function
  | Import _ -> `Import
  | Option _ -> .
  | _ -> `None

(* Most execution of commands we can do here, but there are a couple things where we need to call out to the executable: noting when an effectual action like 'echo' is taken (for recording warnings in compiled files), and loading another file.  So this function takes a couple of callbacks as arguments. *)
let rec execute ~(action_taken : unit -> unit) ~(get_file : string -> Scope.trie) (cmd : Command.t)
    : int option * (int * int * int) list =
  (match (Origin.current (), needs_interactive cmd) with
  | Top, true | File _, true -> fatal (Forbidden_interactive_command (to_string cmd))
  | _ -> ());
  match cmd with
  | Axiom { name; nonparam; loc; parameters; ty = Wrap ty; _ } ->
      Global.run_command ~holes_allowed:(Ok ()) @@ fun () ->
      (match name with
      | [ str ] ->
          if Option.is_some (deg_of_name str) then
            fatal (Invalid_constant_name (name, Some "that's a degeneracy name"))
      | _ -> ());
      Scope.check_name name loc;
      let const = Scope.define ?loc name in
      let (Processed_tel (params, ctx, _)) = process_tel Emp parameters in
      let parametric = Option.is_none nonparam in
      Core.Command.execute (Axiom { name = const; params; ty = process ctx ty; parametric })
  | Def defs ->
      Global.run_command ~holes_allowed:(Ok ()) @@ fun () ->
      let cdefs =
        List.map
          (fun { name; loc; parameters; ty; tm = Wrap tm; _ } ->
            (match name with
            | [ str ] ->
                if Option.is_some (deg_of_name str) then
                  fatal (Invalid_constant_name (name, Some "that's a degeneracy name"))
            | _ -> ());
            Scope.check_name name loc;
            ( lazy (Scope.define ?loc name),
              lazy
                (let (Processed_tel (params, ctx, _)) = process_tel Emp parameters in
                 match ty with
                 | Some (_, Wrap ty) ->
                     let ty = process ctx ty in
                     let tm = lazy (process ctx tm) in
                     Core.Command.Def_check { params; ty; tm }
                 | None -> (
                     match process ctx tm with
                     | { value = Synth tm; loc } -> Def_synth { params; tm = { value = tm; loc } }
                     | _ -> fatal (Nonsynthesizing "body of def without specified type"))) ))
          defs in
      Core.Command.execute (Def cdefs)
  | Echo { tm = Wrap tm; eval; number; _ } -> (
      let module Scope_and_ctx = struct
        type t = Scope_and_ctx : (string option, 'a) Bwv.t * ('a, 'b) Ctx.t -> t
      end in
      let open Scope_and_ctx in
      let Scope_and_ctx (vars, ctx), run =
        match number with
        | None ->
            (Scope_and_ctx (Bwv.Emp, Ctx.empty), Global.run_command_then_undo ~holes_allowed:(Ok ()))
        | Some number ->
            let num = Global.find_hole number in
            let (Found_hole { instant; termctx; vars; parametric; _ }) = num in
            show_hole num;
            ( Scope_and_ctx (vars, Norm.eval_ctx termctx),
              Global.rewind_command_then_undo ~parametric ~holes_allowed:(Ok ()) instant ) in
      run @@ fun () ->
      let rtm = process vars tm in
      action_taken ();
      match rtm.value with
      | Synth stm ->
          Readback.Displaying.run ~env:true @@ fun () ->
          let ctm, ety = Check.synth (Kinetic `Nolet) ctx { value = stm; loc = rtm.loc } in
          let btm =
            if eval then
              let etm = Norm.eval_term (Ctx.env ctx) ctm in
              readback_at ctx etm ety
            else ctm in
          let bty = readback_at ctx ety (Value.universe D.zero) in
          let utm = unparse (Names.of_ctx ctx) btm No.Interval.entire No.Interval.entire in
          let uty = unparse (Names.of_ctx ctx) bty No.Interval.entire No.Interval.entire in
          PPrint.(
            ToChannel.pretty 1.0 (Display.columns ()) stdout
              (hang 2
                 (pp_complete_term (Wrap utm) `None
                 ^^ hardline
                 ^^ Token.pp Colon
                 ^^ blank 1
                 ^^ pp_complete_term (Wrap uty) `None)));
          print_newline ();
          print_newline ();
          (None, fun _ -> None)
      | _ -> fatal (Nonsynthesizing ("argument of " ^ if eval then "echo" else "synth")))
  | Notation { fixity; loc; pattern; head; args; _ } ->
      Global.run_command ~holes_allowed:(Error (to_string cmd)) @@ fun () ->
      let name = "«" ^ User.Pattern.to_string pattern ^ "»" in
      let notation_name = [ "notations"; name ] in
      Scope.check_name notation_name loc;
      let key =
        match head with
        | `Constr c -> `Constr (Constr.intern c, List.length args)
        | `Constant c -> (
            match Scope.lookup c with
            | Some c -> `Constant c
            | None -> fatal (Invalid_notation_head (String.concat "." c))) in
      (* Find the "unbound" variables, if any, in the notation definition. *)
      let rec unbounds : type left right.
          (string * Whitespace.t list) list ->
          string list ->
          (left, right) User.Pattern.t ->
          (string * Whitespace.t list) list =
       fun args seen pat ->
        let check_var x =
          if List.mem x seen then fatal (Duplicate_notation_variable x);
          let found, rest = List.partition (fun (y, _) -> x = y) args in
          match found with
          | [ _ ] -> rest
          | [] -> fatal (Unused_notation_variable x)
          | _ -> fatal (Notation_variable_used_twice x) in
        match pat with
        | User.Pattern.Var ((x, _, _), pat) ->
            let rest = check_var x in
            unbounds rest (x :: seen) pat
        | Op (_, pat) -> unbounds args seen pat
        | Op_nil _ -> args
        | Var_nil (_, (x, _)) -> check_var x in
      (match unbounds args [] pattern with
      | [] -> ()
      | _ :: _ as unbound -> fatal (Unbound_variable_in_notation (List.map fst unbound)));
      let user = User { name; fixity; pattern; key; val_vars = List.map fst args } in
      let shadow = Scope.define_notation user ?loc notation_name in
      List.iter
        (fun key ->
          let keyname =
            match key with
            | `Constr (c, _) -> Constr.to_string c ^ "."
            | `Constant c -> String.concat "." (Scope.name_of c) in
          emit (Head_already_has_notation keyname))
        shadow;
      (None, fun _ -> Some (Notation_defined name))
  | Import { export; origin; op; _ } ->
      Global.run_command ~holes_allowed:(Error (to_string cmd)) @@ fun () ->
      let trie =
        match origin with
        | `File file ->
            if FilePath.check_extension file "ny" then emit (Library_has_extension file);
            let file = FilePath.add_extension file "ny" in
            get_file file
        | `Path path -> Trie.find_subtree path (Scope.get_visible ()) in
      let trie =
        match op with
        | Some (_, op) -> Scope.Mod.modify (process_modifier op) trie
        | None -> trie in
      if export then Scope.include_subtree ([], trie) else Scope.import_subtree ([], trie);
      (None, fun _ -> None)
  | Solve data ->
      let (Found_hole { instant; parametric; _ } as found) = Global.find_hole data.number in
      Global.rewind_command ~parametric ~holes_allowed:(Ok ()) instant @@ fun () ->
      execute_solve data found
  | Split data ->
      let (Found_hole { instant; termctx; ty; vars; parametric; _ } as found) =
        Global.find_hole data.number in
      Global.rewind_command ~parametric ~holes_allowed:(Ok ()) instant @@ fun () ->
      let (Wrap tm) = !(data.tm) in
      let content =
        let ctx = Norm.eval_ctx termctx in
        match tm.value with
        | Placeholder _ -> (
            let ety = Norm.eval_term (Ctx.env ctx) ty in
            match View.view_type ety "split" with
            | Canonical (_, Pi (_, doms, _), _, _) ->
                let cube, mapsto =
                  match D.compare_zero (CubeOf.dim doms) with
                  | Zero -> (`Normal, Token.Mapsto)
                  | Pos _ -> (`Cube, Token.DblMapsto) in
                let xs = Domvars.get_pi_vars ctx cube Emp ety in
                (* TODO: Should generate real variable names. *)
                String.concat " " (Bwd_extra.to_list_map (Option.value ~default:"_") xs)
                ^ Token.to_string mapsto
                ^ " ?"
            | Canonical (_, Codata { eta; fields; _ }, ins, _) -> (
                let m = cod_left_ins ins in
                let do_field : type a n et.
                    (a * n * et) Term.CodatafieldAbwd.entry -> string list -> string list =
                 fun (Term.CodatafieldAbwd.Entry (fld, cdf)) acc ->
                  match cdf with
                  | Lower _ -> Field.to_string fld :: acc
                  | Higher _ ->
                      let i = Field.dim fld in
                      let pbijs = List.of_seq (all_pbij_between m i) in
                      List.fold_right
                        (fun (Pbij_between pbij) acc ->
                          (Field.to_string fld ^ string_of_pbij pbij) :: acc)
                        pbijs acc in
                let fields = Bwd.fold_right do_field fields [] in
                match eta with
                | Eta ->
                    Token.to_string LParen
                    ^ String.concat ", "
                        (List.map
                           (fun fld ->
                             fld ^ " " ^ Token.to_string Coloneq ^ " " ^ Token.to_string (Hole None))
                           fields)
                    ^ Token.to_string RParen
                | Noeta ->
                    Token.to_string LBracket
                    ^ String.concat " | "
                        (List.map
                           (fun fld ->
                             "."
                             ^ fld
                             ^ " "
                             ^ Token.to_string Mapsto
                             ^ " "
                             ^ Token.to_string (Hole None))
                           fields)
                    ^ Token.to_string RBracket)
            | Canonical (_, UU _, _, _) -> fatal (Invalid_split (`Goal, "universe"))
            | Canonical (_, Data _, _, _) -> fatal (Invalid_split (`Goal, "datatype"))
            | Neutral _ -> fatal (Invalid_split (`Goal, "neutral")))
        | _ -> (
            match process vars tm with
            | { value = Synth rtm; loc } -> (
                let _, sty = Check.synth (Kinetic `Nolet) ctx (Asai.Range.locate_opt loc rtm) in
                match View.view_type sty "split" with
                | Canonical (_, Data { dim; constrs; _ }, _, _) ->
                    let mapsto =
                      match D.compare_zero dim with
                      | Zero -> Token.to_string Mapsto
                      | Pos _ -> Token.to_string DblMapsto in
                    let rec do_args : type a p ap. (a, p, ap) Term.Telescope.t -> string -> string =
                     fun args acc ->
                      match args with
                      | Emp -> acc
                      | Ext (x, _, args) ->
                          Option.value ~default:(Token.to_string Underscore) x
                          ^ " "
                          ^ do_args args acc in
                    let do_constrs : type m ij.
                        Constr.t * (m, ij) Value.dataconstr -> string list -> string list =
                     fun (c, Dataconstr { args; _ }) acc ->
                      (Constr.to_string c
                      ^ ". "
                      ^ do_args args " "
                      ^ mapsto
                      ^ " "
                      ^ Token.to_string (Hole None))
                      :: acc in
                    let constrs = Bwd.fold_right do_constrs constrs [] in
                    let buf = Buffer.create 10 in
                    PPrint.(
                      ToBuffer.pretty 1.0 (Display.columns ()) buf
                        (pp_complete_term (Wrap tm) `None));
                    Token.to_string Match
                    ^ " "
                    ^ Buffer.contents buf
                    ^ " "
                    ^ Token.to_string LBracket
                    ^ " "
                    ^ String.concat " | " constrs
                    ^ " "
                    ^ Token.to_string RBracket
                | _ -> fatal (Invalid_split (`Term, "non-datatype")))
            | _ -> fatal (Nonsynthesizing "splitting term")) in
      (data.tm := TermParse.Term.(final (parse (`String { title = None; content }))));
      execute_solve data found
  | Show { what; _ } ->
      action_taken ();
      (match what with
      | `Hole (_, number) -> show_hole (Global.find_hole number)
      | `Holes -> (
          match Global.all_holes () with
          | Emp -> emit No_open_holes
          | holes -> Mbwd.miter (fun [ h ] -> show_hole h) [ holes ]));
      (None, [])
  | Display { what; _ } ->
      (match what with
      | `Chars (_, chars, _) ->
          let chars = Display.modify_chars chars in
          emit (Display_set ("chars", Display.to_string (chars :> Display.values)))
      | `Function_boundaries (_, _, fb, _) ->
          let fb = Display.modify_function_boundaries fb in
          emit (Display_set ("function boundaries", Display.to_string (fb :> Display.values)))
      | `Type_boundaries (_, _, tb, _) ->
          let tb = Display.modify_type_boundaries tb in
          emit (Display_set ("type boundaries", Display.to_string (tb :> Display.values))));
      (None, [])
  | Option _ -> .
  | Undo { count; _ } ->
      for _ = 1 to count do
        match Origin.undo () with
        | `Ok -> ()
        | `No_past -> fatal Not_enough_to_undo
        | `Not_interactive -> fatal (Forbidden_interactive_command "undo")
      done;
      emit (Commands_undone count);
      (None, [])
  | Section { prefix; _ } ->
      Global.run_command ~holes_allowed:(Error (to_string cmd)) @@ fun () ->
      Scope.start_section prefix;
      (None, fun _ -> Some (Section_opened prefix))
  | End _ -> (
      Global.run_command ~holes_allowed:(Error (to_string cmd)) @@ fun () ->
      match Scope.end_section () with
      | Some prefix -> (None, fun _ -> Some (Section_closed prefix))
      | None -> fatal No_such_section)
  | Quit _ -> fatal (Quit None)
  | Bof _ -> (None, [])
  | Eof -> fatal (Anomaly "EOF cannot be executed")

and execute_solve data found =
  let (Global.Found_hole { meta; instant = _; termctx; ty; status; vars; li; ri; parametric = _ }) =
    found in
  let (Wrap tm) = !(data.tm) in
  let ptm = process vars tm in
  (* We set the hole location offset to the start of the *term*, so that ProofGeneral can create hole overlays in the right places when solving a hole and creating new holes. *)
  let tmloc = ptm.loc <|> Anomaly "missing location in solve" in
  let offset = (fst (Asai.Range.split tmloc)).offset in
  (* Now we typecheck the supplied term. *)
  let ctx = Norm.eval_ctx termctx in
  let ety = Norm.eval_term (Ctx.env ctx) ty in
  let ctm = Check.check status ctx ptm ety in
  Global.set_meta meta ~tm:ctm;
  let buf = Buffer.create 20 in
  PPrint.ToBuffer.compact buf (pp_complete_term !(data.tm) `None);
  ( Reporter.try_with ~fatal:(fun _ -> data.tm := Wrap (parenthesize tm)) @@ fun () ->
    let _ = TermParse.Term.parse ~li ~ri (`String { content = Buffer.contents buf; title = None }) in
    () );
  (Some offset, fun h -> Some (Code.Hole_solved h))

let tightness_of_fixity : type left tight right. (left, tight, right) fixity -> string option =
  function
  | Infix tight
  | Infixl tight
  | Infixr tight
  | Prefix tight
  | Prefixr tight
  | Postfix tight
  | Postfixl tight -> Some (No.to_string tight)
  | Outfix -> None

let rec pp_parameters : Whitespace.t list -> Parameter.t list -> PPrint.document * Whitespace.t list
    =
 fun prews params ->
  let open PPrint in
  match params with
  | [] -> (empty, prews)
  | { wslparen; names; wscolon; ty; wsrparen } :: params ->
      let pnames, wnames =
        List.fold_left
          (fun (accum, prews) (name, wsname) ->
            (accum ^^ group (optional (pp_ws `Break) prews ^^ pp_var name), Some wsname))
          (empty, None) names in
      let pparams, wparams = pp_parameters wsrparen params in
      ( group
          (pp_ws `Break prews
          ^^ group
               (Token.pp LParen
               ^^ pp_ws `None wslparen
               ^^ group pnames
               ^^ optional (pp_ws `Break) wnames)
          ^^ Token.pp Colon
          ^^ pp_ws `Nobreak wscolon
          ^^ pp_complete_term ty `None
          ^^ Token.pp RParen)
        ^^ pparams,
        wparams )

let rec pp_defs :
    Token.t ->
    Whitespace.t list option ->
    def list ->
    PPrint.document ->
    PPrint.document * Whitespace.t list =
 fun tok prews defs accum ->
  let open PPrint in
  match defs with
  | [] -> (accum, Option.fold ~some:(fun x -> x) ~none:[] prews)
  | { wsdef; name; loc = _; wsname; parameters; ty; wscoloneq; tm = Wrap tm } :: defs ->
      let prews =
        match tok with
        | And -> Option.fold ~some:(Whitespace.normalize 2) ~none:[ `Newlines 2 ] prews
        | _ -> Option.value ~default:[] prews in
      let accum_prews = accum ^^ pp_ws `None prews in
      let pparams, wparams = pp_parameters wsname parameters in
      (* The type is always displayed in term mode, with a wrapping break allowed before the colon. *)
      let gty, wty =
        match ty with
        | Some (wscolon, Wrap ty) ->
            let pty, wty = pp_term ty in
            (pp_ws `Break wparams ^^ Token.pp Colon ^^ pp_ws `Nobreak wscolon ^^ group pty, wty)
        | None -> (empty, wparams) in
      let params_and_ty =
        group
          (hang 2
             (Token.pp tok
             ^^ pp_ws `Nobreak wsdef
             ^^ utf8string (String.concat "." name)
             ^^ group pparams
             ^^ gty)) in
      let coloneq = Token.pp Coloneq ^^ pp_ws `Nobreak wscoloneq in
      if is_case tm then
        (* If the term is a case tree, we display it in case mode.  In this case, the principal breaking points are those in the term's case tree, and we group its "intro" with the def and type. *)
        let itm, ptm, wtm = pp_case `Nontrivial tm in
        pp_defs And (Some wtm) defs
          (accum_prews
          ^^ group
               (group
                  (params_and_ty
                  ^^ nest 2 (pp_ws `Break wty ^^ group (coloneq ^^ group (hang 2 itm))))
               ^^ ptm))
      else
        (* If the term is not a case tree, then we display it in term mode, and the principal breaking points are before the colon (if any), before the coloneq, and before the "in" (though that will be rare, since "in" is so short). *)
        let ptm, wtm = pp_term tm in
        pp_defs And (Some wtm) defs
          (accum_prews
          ^^ group (params_and_ty ^^ nest 2 (pp_ws `Break wty ^^ coloneq ^^ group (hang 2 ptm))))

let pp_attribute : type a.
    (a -> Whitespace.t list list -> PPrint.document) -> a attribute -> PPrint.document =
 fun pp { wshash; wslparen; loc = _; attr; wsattr; wsrparen } ->
  let open PPrint in
  Token.pp (Op "#")
  ^^ pp_ws `None wshash
  ^^ Token.pp LParen
  ^^ pp_ws `None wslparen
  ^^ pp attr wsattr
  ^^ Token.pp RParen
  ^^ pp_ws `Nobreak wsrparen

(* We only print commands that can appear in source files or for which ProofGeneral may need reformatting info (e.g. solve). *)
let pp_command : t -> PPrint.document * Whitespace.t list =
 fun cmd ->
  let open PPrint in
  (* Indent when inside of sections. *)
  let indent = Scope.count_sections () * 2 in
  let indent, doc, ws =
    match cmd with
    | Axiom { wsaxiom; nonparam; name; loc = _; wsname; parameters; wscolon; ty = Wrap ty } ->
        let pparams, wparams = pp_parameters wsname parameters in
        let ty, rest = split_ending_whitespace ty in
        ( indent,
          group
            (hang 2
               (Token.pp Axiom
               ^^ pp_ws `Nobreak wsaxiom
               ^^ PPrint.optional
                    (pp_attribute (fun () ws ->
                         string "nonparametric" ^^ concat_map (pp_ws `None) ws))
                    nonparam
               ^^ utf8string (String.concat "." name)
               ^^ pparams
               ^^ pp_ws `Break wparams
               ^^ Token.pp Colon
               ^^ pp_ws `Nobreak wscolon
               ^^ pp_complete_term (Wrap ty) `None)),
          rest )
    | Def defs ->
        let doc, ws = pp_defs Def None defs empty in
        (indent, doc, ws)
    | Echo { wsecho; number; wsin; wsnumber; tm = Wrap tm; eval } ->
        let tm, rest = split_ending_whitespace tm in
        ( indent,
          hang 2
            (Token.pp (if eval then Echo else Synth)
            ^^ pp_ws `Nobreak wsecho
            ^^ optional
                 (fun n ->
                   Token.pp In
                   ^^ pp_ws `Nobreak wsin
                   ^^ string (string_of_int n)
                   ^^ pp_ws `Nobreak wsnumber)
                 number
            ^^ pp_complete_term (Wrap tm) `None),
          rest )
    | Notation
        {
          fixity;
          wsnotation;
          wslparen;
          wstight;
          wsellipsis;
          loc = _;
          wsrparen;
          pattern;
          wscoloneq;
          head;
          wshead;
          args;
        } ->
        let pargs, rest =
          match split_last args with
          | None ->
              let wshead, rest = Whitespace.split wshead in
              (pp_ws `None wshead, rest)
          | Some (args, (last, wslast)) ->
              let wslast, rest = Whitespace.split wslast in
              (* We "flow" the arguments of the head. *)
              let pargs, wargs =
                List.fold_left
                  (fun (acc, prews) (arg, wsarg) ->
                    (acc ^^ group (pp_ws `Break prews ^^ utf8string arg), wsarg))
                  (empty, wshead) args in
              (pargs ^^ group (pp_ws `Break wargs ^^ utf8string last) ^^ pp_ws `None wslast, rest)
        in
        let ppat, wpat = User.pp_pattern pattern in
        let notn_tight, ws =
          match tightness_of_fixity fixity with
          | Some str ->
              ( pp_ws `None wsnotation
                ^^ Token.pp LParen
                ^^ pp_ws `None wslparen
                ^^ string str
                ^^ pp_ws `None wstight
                ^^ Token.pp RParen,
                wsrparen )
          | None -> (empty, wsnotation) in
        ( indent,
          hang 2
            (Token.pp Notation
            ^^ notn_tight
            ^^ group
                 (group
                    (pp_ws `Break ws
                    ^^ (match fixity with
                       | Infixl _ | Postfixl _ -> Token.pp Ellipsis ^^ pp_ws `Nobreak wsellipsis
                       | _ -> empty)
                    ^^ group (hang 2 ppat))
                 ^^ (match fixity with
                    | Infixr _ | Prefixr _ ->
                        pp_ws `Nobreak wpat ^^ Token.pp Ellipsis ^^ pp_ws `Break wsellipsis
                    | _ -> pp_ws `Break wpat)
                 ^^ Token.pp Coloneq
                 ^^ pp_ws `Nobreak wscoloneq
                 ^^ group
                      (hang 2
                         ((match head with
                          | `Constr c -> pp_constr c
                          | `Constant c -> utf8string (String.concat "." c))
                         ^^ pargs)))),
          rest )
    | Import { wsimport; export; origin; wsorigin; op } ->
        let op, rest =
          match op with
          | None ->
              let ws, rest = Whitespace.split wsorigin in
              (pp_ws `None ws, rest)
          | Some (wsbar, op) ->
              let pmod, wmod = pp_modifier op in
              let ws, rest = Whitespace.split wmod in
              ( pp_ws `Break wsorigin
                ^^ Token.pp (Op "|")
                ^^ pp_ws `Nobreak wsbar
                ^^ pmod
                ^^ pp_ws `None ws,
                rest ) in
        ( indent,
          group
            (nest 2
               (Token.pp (if export then Export else Import)
               ^^ pp_ws `Nobreak wsimport
               ^^ (match origin with
                  | `File file -> dquotes (utf8string file)
                  | `Path [] -> Token.pp Dot
                  | `Path path -> utf8string (String.concat "." path))
               ^^ op)),
          rest )
    | Solve { column; tm; _ } ->
        let (Wrap tm) = !tm in
        (* We (mis)use pretty-printing of a solve *command* to actually just reformat the solving *term*.  This is appropriate since "solve" should never appear in a source file, and when it's called from ProofGeneral, PG knows that the reformatted return is the new string to insert at the hole location. *)
        let tm, rest = split_ending_whitespace tm in
        (* When called from ProofGeneral, the 'column' is the column number of the hole, so the reformatted term should "start at that indentation".  The best way I've thought of so far to mimic that effect is to reduce the margin by that amount, and then add extra indentation to each new line on the ProofGeneral end.  Also, section indents should be ignored when printing solve terms. *)
        (0, nest column (pp_complete_term (Wrap tm) `None), rest)
    | Split { column; tm; _ } ->
        (* Same with split. *)
        let (Wrap tm) = !tm in
        let tm, rest = split_ending_whitespace tm in
        (0, nest column (pp_complete_term (Wrap tm) `None), rest)
    | Option _ -> .
    | Section { wssection; prefix; wsprefix; wscoloneq } ->
        let ws, rest = Whitespace.split wscoloneq in
        (* Since we pp a command *after* executing it, the indent is too large for the 'section' command. *)
        ( indent - 2,
          Token.pp Section
          ^^ pp_ws `Nobreak wssection
          ^^ utf8string (String.concat "." prefix)
          ^^ pp_ws `Nobreak wsprefix
          ^^ Token.pp Coloneq
          ^^ pp_ws `None ws,
          rest )
    | End { wsend } ->
        let ws, rest = Whitespace.split wsend in
        (indent, Token.pp End ^^ pp_ws `None ws, rest)
    | Quit ws -> (indent, empty, ws)
    | Bof ws -> (indent, empty, ws)
    | Eof -> (indent, empty, [])
    (* These commands can't appear in a source file, and ProofGeneral doesn't need any reformatting info from them, so we display nothing.  In fact, in the case of Undo, PG uses this emptiness to determine that it should not replace any command in the buffer. *)
    | Show _ | Display _ | Undo _ -> (indent, empty, []) in
  (* "nest" only has effect *after* linebreaks, so we have to separately indent the first line. *)
  (nest indent (blank indent ^^ doc), ws)
