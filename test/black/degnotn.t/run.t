  $ narya degnotn.ny
  refl a
    : Id A a a
  
  Id A a0 a1
    : Type
  
  ap f
    : {𝑥₀ : A} {𝑥₁ : A} (𝑥₂ : Id A 𝑥₀ 𝑥₁) →⁽ᵉ⁾ Id C (f 𝑥₀) (f 𝑥₁)
  
  Id B
    : {𝑥₀ : A} {𝑥₁ : A} (𝑥₂ : Id A 𝑥₀ 𝑥₁) →⁽ᵉ⁾ Type⁽ᵉ⁾ (B 𝑥₀) (B 𝑥₁)
  
  Unit⁽ᵉ⁾ u0 u1
    : Type
  
