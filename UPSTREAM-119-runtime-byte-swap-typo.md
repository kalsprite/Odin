# `intrinicss.byte_swap` typo in base/runtime

**Component:** `base/runtime` (Odin source, not the compiler)
**Severity:** latent build break — dead on little-endian targets
**Status:** still present; re-verified 2026-08-04 by inspection against current master

## Location

`base/runtime/random_generator_chacha8_ref.odin:26`

> **Note on an earlier revision of this file.** It originally cited
> `random_generator_chacha8_simd128.odin:72`. That instance has since been corrected upstream —
> the simd128 file now reads `intrinsics.byte_swap` on every line. The identical typo survives in
> `random_generator_chacha8_ref.odin`, so the defect is still live; only its address changed.

## What is wrong

```odin
s9  := intrinsics.byte_swap(k[5])
s10 := intrinsics.byte_swap(k[6])
s11 := intrinicss.byte_swap(k[7])   // <-- "intrinicss"
```

Line 26 spells the package `intrinicss` instead of `intrinsics`. The seven lines above it are
correct, which is what makes it look like a transcription slip rather than an alias.

## Why it has not been caught

It sits in the `else` arm of `when ODIN_ENDIAN == .Little`, so on every target CI builds the
block is discarded before name resolution and no diagnostic is produced. It becomes a hard
"Undeclared name" the first time `base:runtime` is compiled for a big-endian target.

## Fix

```diff
-		s11 := intrinicss.byte_swap(k[7])
+		s11 := intrinsics.byte_swap(k[7])
```

## How this was found

Cross-checking a self-hosted Odin checker against the reference compiler. The port resolves
package-qualified names on a different schedule and surfaced the name where the reference had
not yet reached it.
