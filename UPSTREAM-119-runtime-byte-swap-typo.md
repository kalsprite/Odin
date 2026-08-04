# `intrinicss.byte_swap` typo in base/runtime

**Component:** `base/runtime` (Odin source, not the compiler)
**Severity:** latent build break — dead on current targets
**Status:** verified 2026-08-04 by inspection

## Location

`base/runtime/random_generator_chacha8_simd128.odin:72`

## What is wrong

```odin
s9_  := intrinsics.byte_swap(k[5])
s10_ := intrinsics.byte_swap(k[6])
s11_ := intrinicss.byte_swap(k[7])   // <-- "intrinicss"
```

Line 72 spells the package `intrinicss` instead of `intrinsics`. The two lines either side of
it are correct, which is what makes it look like a transcription slip rather than an alias.

## Why it has not been caught

The enclosing block is not reachable on the targets CI builds, so the identifier is never
resolved and no diagnostic is produced. It will become a hard "Undeclared name" the first time
this path is compiled for a target that selects it.

## Fix

```diff
-		s11_ := intrinicss.byte_swap(k[7])
+		s11_ := intrinsics.byte_swap(k[7])
```

## How this was found

Cross-checking a self-hosted Odin checker against the reference compiler. The port resolves
package-qualified names on a different schedule and surfaced the name where the reference had
not yet reached it.
