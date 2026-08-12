# `jmag` and `kmag` reject every untyped constant quaternion

**Component:** `src/check_builtin.cpp` (`BuiltinProc_jmag` / `BuiltinProc_kmag`)
**Severity:** valid code rejected — `jmag(3j)` and `kmag(3k)` cannot be written at all
**Compiler:** `dev-2026-08:958fe3b51`
**Status:** reproduced 5/5 on 2026-08-09 using the stock `./odin` (not an instrumented build). The
boundary below was measured, not inferred: four neighbouring shapes all succeed, and only the
untyped-constant case fails. Every line quoted was re-read in `src/` at filing time.

The `j` and `k` literal suffixes are the *only* way to write an untyped quaternion constant, so this
makes the two accessors unusable on exactly the values the literals produce.

---

## Reproduction

```odin
package a
#assert(jmag(3j) == 3)
main :: proc() {}
```

```
a.odin(2:1) Error: 'jmag(3j) == 3' is not a constant boolean
a.odin(2:9) Error: Argument has type 'untyped complex', expected a quaternion type
```

`kmag(3k)` gives the identical pair. Note the reported type: the argument was written as a
quaternion literal and is reported as **untyped complex**.

## The boundary — only the untyped constant fails

| shape | result |
|---|---|
| `#assert(imag(3i) == 3)` — the complex analogue | **exits 0** |
| `Q :: quaternion256(3); #assert(jmag(Q) == 0)` — *typed* constant | **exits 0** |
| `q: quaternion256; z := jmag(q)` — *non-constant* | **exits 0** |
| `#assert(jmag(3j) == 3)` — *untyped constant* | **fails** |

---

## What is wrong

The arm rewrites the operand's type before testing it, and the rewrite is to *complex*:

```cpp
// check_builtin.cpp:3844-3856
		if (is_type_untyped(x->type)) {
			if (x->mode == Addressing_Constant) {
				if (is_type_numeric(x->type)) {
					x->type = t_untyped_complex;
				}
			} else{
				convert_to_typed(c, x, t_quaternion256);
				if (x->mode == Addressing_Invalid) {
					return false;
				}
			}
		}

// check_builtin.cpp:3858-3862  — immediately after
		if (!is_type_quaternion(x->type)) {
			gbString s = type_to_string(x->type);
			error(call, "Argument has type '%s', expected a quaternion type", s);
			gb_string_free(s);
			return false;
		}
```

For an untyped **constant** the first block sets `t_untyped_complex`, and the second block then asks
for a quaternion — a condition the first block has just made impossible to satisfy. The
`else` branch is fine: a non-constant untyped operand is converted to `t_quaternion256`, which is why
the variable case in the table above works.

## Two independent signs that this is a copy-paste, not a decision

**1. The `real`/`imag` arm directly above is identical, and there the clobber is harmless.** Its gate
accepts complex, so rewriting to `t_untyped_complex` costs nothing:

```cpp
// check_builtin.cpp:3798  (real/imag)
		if (!is_type_complex(x->type) && !is_type_quaternion(x->type)) {
```

The `jmag`/`kmag` arm keeps the same rewrite but narrows the gate to quaternions only, which is
exactly where the two stop being interchangeable.

**2. The `jmag`/`kmag` result switch has an arm that cannot be reached.** After the gate, the arm
maps the operand kind to a float width, and it includes:

```cpp
// check_builtin.cpp:3879
		case Basic_UntypedQuaternion: x->type = t_untyped_float; break;
```

`Basic_UntypedQuaternion` can never arrive there: any untyped constant has already been rewritten to
`Basic_UntypedComplex`, and any untyped non-constant has been converted to `Basic_quaternion256`. The
author wrote a handler for a state the earlier line makes unreachable — which is what one would
expect if that earlier line were meant to say `t_untyped_quaternion`.

The fix is the one-word change the second sign points at: in the `jmag`/`kmag` arm, rewrite an
untyped numeric constant to `t_untyped_quaternion` rather than `t_untyped_complex`. That satisfies the
gate, and the already-present `Basic_UntypedQuaternion` switch arm then does the right thing.

---

## Port status

The Odin self-hosted checker (`core/odin/checker`) **reproduces this deliberately**, and did not
before.

Its `check_builtin_jmag_kmag` was a reimplementation rather than a port — among other divergences it
had no untyped handling at all, so it never performed the clobber and instead failed later with a
different message. Rewriting it as a faithful port of `check_builtin.cpp:3834-3888` (mirroring the
`real`/`imag` arm, which the port already had correct) fixed several genuine port defects — including
a missing constant fold that made `jmag` on a *typed* constant quaternion non-constant, rejecting code
the reference accepts — and reproduced this behaviour as a side effect.

That is the intended outcome: the reference is the contract, and a special case on the port side would
be inventing semantics the reference does not have. If a fix lands upstream, the port follows it.
