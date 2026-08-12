# `real` / `imag` / `jmag` / `kmag` absorb the enclosing conversion's type

**Component:** `src/check_builtin.cpp` (`BuiltinProc_real` / `_imag` / `_jmag` / `_kmag`)
**Severity:** the checker records a wrong type for the accessor expression. Visible in the
compiler's own diagnostics as a self-contradictory message; visible to any consumer of the checked
AST as a float typed as an integer.
**Compiler:** `dev-2026-08:958fe3b51`
**Status:** reproduced 5/5 on 2026-08-09 with the stock `./odin`. Every line quoted was re-read in
`src/` at filing time.
**Issue number:** do NOT file as new — **already open upstream as
[odin-lang/Odin#5964](https://github.com/odin-lang/Odin/issues/5964)**. A PR should say
`Fixes #5964`.
**Internal duplicate:** `~/dev/COMPILER_ISSUES/UPSTREAM-UNFILED-real-imag-typed-by-conversion-context.md`
is the same defect, scoped to `real`/`imag` only. This doc supersedes it; fold in its
`int(imag(x))` → `4611686018427387904` bit-pattern table and drop the other file.

## Upstream status — DUPLICATE of #5964 (checked 2026-08-10)

[#5964](https://github.com/odin-lang/Odin/issues/5964) — "Real and Imag builtin functions cause
parsing errors", filed 2025-11-26 by `149-code` against `dev-2025-11:e5153a937`, is this bug
reported from the outside:

```odin
x: complex128 = 10
fmt.println(i8(real(x) / 3.2))
// Error: '3.2' truncated to 'i8', got 3.200000
```

Same mechanism as the `int(imag(C))` case above — `real(x)` is recorded with the conversion's
destination type, so the division is checked in `i8`. Their control (routing `real` through a
`proc(complex128) -> f64`) isolates the builtin the same way the explicit `f64` insertion does
here. The issue is mistitled as a parsing problem and has no diagnosis, no comments, and no
label; a title search will not surface it.

Nothing upstream covers `jmag` / `kmag` (the local `UPSTREAM-642` doc is internal numbering, not an
Odin issue number), so name both in the PR, and confirm the bug still reproduces on
`dev-2026-08:958fe3b51` — #5964 was last measured nine months earlier.

---

## Reproduction — the compiler contradicts itself

```odin
package a
C :: complex128(0+2.5i)
X :: int(imag(C))
main :: proc() {}
```

`odin check . -no-entry-point`:

```
Error: Cannot cast 'imag(C)' as 'int' from 'int'
```

`imag(C)` is an `f64`. The compiler reports that it is casting **from `int`** — and then that this
`int`-to-`int` cast is impossible. Inserting an explicit `f64` restores the correct message, which is
the control:

```odin
X :: int(f64(imag(C)))
```
```
Error: Cannot cast 'f64(imag(C))' as 'int' from 'f64'
```

`real` behaves identically (`Cannot cast 'real(C)' as 'int' from 'int'`).

## What is wrong

Two lines compose. A type conversion passes its **destination** as the type hint:

```cpp
// check_expr.cpp:8709
			check_expr_with_type_hint(c, operand, arg, t);
```

and the accessor arms end by **accepting** that hint as their own result type:

```cpp
// check_builtin.cpp:3827-3829   (real / imag; :3883-3885 is the jmag / kmag copy)
		if (type_hint != nullptr && check_is_castable_to(c, operand, type_hint)) {
			operand->type = type_hint;
		}
```

So `imag(C)` — whose type is fully determined by its argument, `f64` for a `complex128` — is
overwritten with `int` before the cast is checked, which is why the cast then reports `int` as its
source type.

## Why this looks like accidental spread rather than intent

That tail appears on exactly four builtins, and only these four:

| line | builtin | is the hint load-bearing? |
|---|---|---|
| 3564 | `complex` | **yes** — `complex(1, 2)` needs the hint to pick complex32/64/128 |
| 3763 | `quaternion` | **yes** — same, for the quaternion widths |
| 3827 | `real` / `imag` | no — the type follows from the argument |
| 3883 | `jmag` / `kmag` | no — same |

For the two constructors the hint resolves a genuine ambiguity. For the two accessor pairs there is
nothing to resolve, so the assignment can only replace an already-correct type with a different one.

The four sites are adjacent in one file, and copy-paste between these specific arms is already
demonstrable: the `jmag`/`kmag` arm carries a clobber (`x->type = t_untyped_complex`) that its own
gate then rejects, plus a `case Basic_UntypedQuaternion:` arm that the clobber makes unreachable —
filed separately as UPSTREAM-642. The same copying plausibly carried this tail from the constructors,
where it is needed, into the accessors, where it is not.

`abs`, `min` and `max` have no such tail, and `int(abs(y))` reports its source type correctly — which
is what isolates this to these arms rather than to builtin calls in general.

## Suggested fix

Drop the `type_hint` tail from the `real`/`imag` and `jmag`/`kmag` arms, keeping it on `complex` and
`quaternion` where it resolves a real ambiguity. The diagnostic above then names `f64`, and a consumer
reading the checked AST sees the accessor's actual type.

---

## Port status

The Odin self-hosted checker (`core/odin/checker`) reproduces this **exactly** — byte-identical
message, `Cannot cast 'imag(C)' as 'int' from 'int'` — because both lines were ported faithfully. No
port change has been made: the reference is the contract, and the port should follow whatever lands
upstream.

It matters more for the port than for the reference, though, and that is how it was found. The
reference's backend emits conversions from its own internal representation and never consults the
recorded type, so `odin build` produces correct code. A consumer of the port's checked AST that
decides "is this a float-to-int conversion?" from the recorded type sees int-to-int, emits no
conversion, and passes the f64's bit pattern through: `int(imag(x))` yielded
`4611686018427387904` (= `transmute(u64)f64(2.0)`) instead of `2`. Found while implementing complex
numbers in a backend (rexcode/mir).
