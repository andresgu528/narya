  $ narya degconstr.ny
  left. (refl a)
    : Sum⁽ᵉ⁾ (Id A) (Id B) (left. a) (left. a)
  
  left. (refl a)
    : Sum⁽ᵉ⁾ (Id A) (Id B) (left. a) (left. a)
  
  nil.
    : List⁽ᵉ⁾ (Id A) nil. nil.
  
  cons. (refl a) (cons. (refl a) nil.)
    : List⁽ᵉ⁾ (Id A) (cons. a (cons. a nil.)) (cons. a (cons. a nil.))
  
  cons. a⁽ᵉᵉ⁾ (cons. a⁽ᵉᵉ⁾ nil.)
    : List⁽ᵉᵉ⁾ A⁽ᵉᵉ⁾ {cons. a (cons. a nil.)} {cons. a (cons. a nil.)}
        (cons. (refl a) (cons. (refl a) nil.)) {cons. a (cons. a nil.)}
        {cons. a (cons. a nil.)} (cons. (refl a) (cons. (refl a) nil.))
        (cons. (refl a) (cons. (refl a) nil.))
        (cons. (refl a) (cons. (refl a) nil.))
  

  $ narya -e 'import "degconstr" echo refl nil. : List A'
   ￫ warning[W2400]
   ￮ not re-executing echo/synth/show commands when loading compiled file $TESTCASE_ROOT/degconstr.nyo
  
   ￫ error[E0602]
   ￭ command-line exec string
   1 | import "degconstr" echo refl nil. : List A
     ^ insufficient dimension for expected type of degeneracy 'refl':
        0 does not factor through e
  
  [1]


  $ narya -e 'import "degconstr" axiom a1 : A echo refl (cons. a nil.) : Id (List A) (cons. a nil.) (cons. a1 nil.)'
   ￫ warning[W2400]
   ￮ not re-executing echo/synth/show commands when loading compiled file $TESTCASE_ROOT/degconstr.nyo
  
   ￫ error[E0401]
   ￭ command-line exec string
   1 | import "degconstr" axiom a1 : A echo refl (cons. a nil.) : Id (List A) (cons. a nil.) (cons. a1 nil.)
     ^ term synthesized type
         List⁽ᵉ⁾ (Id A) (cons. a nil.) (cons. a nil.)
       but is being checked against type
         List⁽ᵉ⁾ (Id A) (cons. a nil.) (cons. a1 nil.)
       unequal head constants:
         a
       does not equal
         a1
  
  [1]

  $ narya degnumeral.ny
  refl 3
    : ℕ⁽ᵉ⁾ 3 3
  
  3⁽ᵉᵉ⁾
    : ℕ⁽ᵉᵉ⁾ {3} {3} (refl 3) {3} {3} (refl 3) (refl 3) (refl 3)
  
  3⁽ᵉᵉ⁾
    : ℕ⁽ᵉᵉ⁾ {3} {3} (refl 3) {3} {3} (refl 3) (refl 3) (refl 3)
  

  $ narya -e 'def ℕ : Type ≔ data [ zero. | suc. (_ : ℕ) ] echo refl 3 : ℕ'
   ￫ error[E0602]
   ￭ command-line exec string
   1 | def ℕ : Type ≔ data [ zero. | suc. (_ : ℕ) ] echo refl 3 : ℕ
     ^ insufficient dimension for expected type of degeneracy 'refl':
        0 does not factor through e
  
  [1]

  $ narya degtuple.ny
  (refl a, refl b)
    : Prod⁽ᵉ⁾ (Id A) (Id B) (a, b) (a, b)
  
  (fst ≔ refl a, snd ≔ refl b)
    : Prod⁽ᵉ⁾ (Id A) (Id B) (a, b) (a, b)
  
  (snd ≔ refl b, fst ≔ refl a)
    : Prod⁽ᵉ⁾ (Id A) (Id B) (a, b) (a, b)
  

  $ narya -v symabs.ny
   ￫ info[I0001]
   ￮ axiom A assumed
  
   ￫ info[I0001]
   ￮ axiom a00 assumed
  
   ￫ info[I0001]
   ￮ axiom a01 assumed
  
   ￫ info[I0001]
   ￮ axiom a02 assumed
  
   ￫ info[I0001]
   ￮ axiom a10 assumed
  
   ￫ info[I0001]
   ￮ axiom a11 assumed
  
   ￫ info[I0001]
   ￮ axiom a12 assumed
  
   ￫ info[I0001]
   ￮ axiom a20 assumed
  
   ￫ info[I0001]
   ￮ axiom a21 assumed
  
   ￫ info[I0001]
   ￮ axiom a22 assumed
  
   ￫ info[I0001]
   ￮ axiom B assumed
  
   ￫ info[I0001]
   ￮ axiom b00 assumed
  
   ￫ info[I0001]
   ￮ axiom b01 assumed
  
   ￫ info[I0001]
   ￮ axiom b02 assumed
  
   ￫ info[I0001]
   ￮ axiom b10 assumed
  
   ￫ info[I0001]
   ￮ axiom b11 assumed
  
   ￫ info[I0001]
   ￮ axiom b12 assumed
  
   ￫ info[I0001]
   ￮ axiom b20 assumed
  
   ￫ info[I0001]
   ￮ axiom b21 assumed
  
   ￫ info[I0001]
   ￮ axiom b22 assumed
  
   ￫ info[I0000]
   ￮ constant prod defined
  
   ￫ info[I0000]
   ￮ constant ab22 defined
  
   ￫ info[I0000]
   ￮ constant sym_ab22 defined
  
   ￫ info[I0000]
   ￮ constant sym_ab22' defined
  
   ￫ info[I0001]
   ￮ axiom f00 assumed
  
   ￫ info[I0001]
   ￮ axiom f01 assumed
  
   ￫ info[I0001]
   ￮ axiom f02 assumed
  
   ￫ info[I0001]
   ￮ axiom f10 assumed
  
   ￫ info[I0001]
   ￮ axiom f11 assumed
  
   ￫ info[I0001]
   ￮ axiom f12 assumed
  
   ￫ info[I0001]
   ￮ axiom f20 assumed
  
   ￫ info[I0001]
   ￮ axiom f21 assumed
  
   ￫ info[I0001]
   ￮ axiom f22 assumed
  
   ￫ info[I0000]
   ￮ constant etaf22 defined
  
   ￫ info[I0000]
   ￮ constant eta_symf22 defined
  
   ￫ info[I0000]
   ￮ constant eta_symf22' defined
  

  $ narya deglam.ny
  ap (x ↦ f x)
    : {x₀ : A} {x₁ : A} (x₂ : Id A x₀ x₁) →⁽ᵉ⁾ Id B x₂ (f x₀) (f x₁)
  
  x ⤇ refl f x.2
    : {x₀ : A} {x₁ : A} (x₂ : Id A x₀ x₁) →⁽ᵉ⁾ Id B x₂ (f x₀) (f x₁)
  

  $ narya deglamtuple.ny
  ap (x ↦ (f x, g x))
    : {x₀ : A} {x₁ : A} (x₂ : Id A x₀ x₁)
      →⁽ᵉ⁾ Prod⁽ᵉ⁾ (Id B x₂) (Id C x₂) (f x₀, g x₀) (f x₁, g x₁)
  
  x ⤇ (refl f x.2, refl g x.2)
    : {x₀ : A} {x₁ : A} (x₂ : Id A x₀ x₁)
      →⁽ᵉ⁾ Prod⁽ᵉ⁾ (Id B x₂) (Id C x₂) (f x₀, g x₀) (f x₁, g x₁)
  
  refl (x ↦ f x, x ↦ g x)
    : Prod⁽ᵉ⁾ ((x : Id A) ⇒ Id B x.2) ((x : Id A) ⇒ Id C x.2) (f, g) (f, g)
  
  (x ⤇ refl f x.2, x ⤇ refl g x.2)
    : Prod⁽ᵉ⁾ ((x : Id A) ⇒ Id B x.2) ((x : Id A) ⇒ Id C x.2) (f, g) (f, g)
  

  $ narya -e 'import "deglamtuple" synth refl (x ↦ (f x, g x)) : (x : A) → Prod (B x) (C x)'
   ￫ warning[W2400]
   ￮ not re-executing echo/synth/show commands when loading compiled file $TESTCASE_ROOT/deglamtuple.nyo
  
   ￫ error[E0602]
   ￭ command-line exec string
   1 | import "deglamtuple" synth refl (x ↦ (f x, g x)) : (x : A) → Prod (B x) (C x)
     ^ insufficient dimension for expected type of degeneracy 'refl':
        0 does not factor through e
  
  [1]

  $ narya degblank.ny
  refl a
    : Id A a a
  
  refl a
    : Id A a a
  
  (refl a)⁽¹ᵉ⁾
    : A⁽ᵉᵉ⁾ (refl a) (refl a) (refl a) (refl a)
  
  a⁽ᵉᵉ⁾
    : A⁽ᵉᵉ⁾ (refl a) (refl a) (refl a) (refl a)
  
  a⁽ᵉᵉ⁾
    : A⁽ᵉᵉ⁾ (refl a) (refl a) (refl a) (refl a)
  
  refl a2
    : A⁽ᵉᵉ⁾ (refl a0) (refl a1) a2 a2
  


  $ narya -e 'import "degblank" echo refl _ : Id A a0 a1'
   ￫ warning[W2400]
   ￮ not re-executing echo/synth/show commands when loading compiled file $TESTCASE_ROOT/degblank.nyo
  
   ￫ error[E0401]
   ￭ command-line exec string
   1 | import "degblank" echo refl _ : Id A a0 a1
     ^ term synthesized type
         Id A a1 a1
       but is being checked against type
         Id A a0 a1
       unequal head constants:
         a1
       does not equal
         a0
  
  [1]


  $ narya -e 'import "degblank" echo sym _ : Id (Id A) a2 a2 (refl a0) (refl a1)'
   ￫ warning[W2400]
   ￮ not re-executing echo/synth/show commands when loading compiled file $TESTCASE_ROOT/degblank.nyo
  
   ￫ error[E0400]
   ￭ command-line exec string
   1 | import "degblank" echo sym _ : Id (Id A) a2 a2 (refl a0) (refl a1)
     ^ non-synthesizing term in synthesizing position (pure symmetry of placeholder)
  
  [1]
