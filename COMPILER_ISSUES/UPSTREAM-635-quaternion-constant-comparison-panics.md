# Comparing two constant quaternions panics the compiler

**Component:** `src/exact_value.cpp` (`compare_exact_values`)
**Severity:** **crash** — `GB_PANIC` fires, compiler aborts with "This is a compiler error"
**Compiler:** `dev-2026-08:958fe3b51`
**Status:** reproduced 5/5 on 2026-08-09 for each of the three shapes below, using the stock
`./odin` (not an instrumented build), and re-verified 5/5 from these exact inputs immediately
before filing. There is a clean control: the same comparison on `complex64` exits 0, 5/5. Every
line quoted below was re-read in `src/` at filing time and still says what is quoted.

`compare_exact_values` handles eleven `ExactValueKind`s and has no arm for
`ExactValue_Quaternion`, so any compile-time comparison of quaternion constants falls past the
switch into the trailing `GB_PANIC`.

---

## Reproduction

Three shapes, all `odin check . -no-entry-point`, all rc=132 (SIGILL, core dumped):

```odin
package a
Q :: quaternion128(0)
#assert(Q == 0)
main :: proc() {}
```

```
src/exact_value.cpp(1092): Panic: Invalid comparison: 6
This is a compiler error. Please report this.
```

```odin
package b
Q :: quaternion256(1)
R :: quaternion256(1)
#assert(Q != R)          // `!=` between two quaternions, no untyped operand involved
main :: proc() {}
```

```odin
package c
Q :: quaternion64(0)
when Q == 0 { X :: 1 }   // not #assert-specific: any constant-folded comparison
main :: proc() {}
```

All three produce the identical panic. It is not specific to `#assert`, to `==`, to a particular
quaternion width, or to one operand being untyped.

**Control** — the same shape on the neighbouring type exits 0, 5/5:

```odin
package ctl
C :: complex64(0)
#assert(C == 0)
main :: proc() {}
```

---

## What is wrong

`compare_exact_values` switches on `x.kind` and has arms for `ExactValue_Invalid`, `_Bool`,
`_Integer`, `_Float`, `_Complex`, `_String`, `_String16`, `_Pointer`, `_Typeid`, `_Procedure`
and `_Compound` — eleven of the twelve kinds. `ExactValue_Quaternion` (= 6) has none, and the
function ends with an unconditional panic:

```cpp
// exact_value.cpp:972-975
gb_internal bool compare_exact_values(TokenKind op, ExactValue x, ExactValue y) {
	match_exact_values(&x, &y);

	switch (x.kind) {
	...
// exact_value.cpp:1092  (reached by falling off the end of the switch)
	GB_PANIC("Invalid comparison: %d", x.kind);
```

`_Complex` immediately above it is fully handled, which is what makes the omission look
accidental rather than intended:

```cpp
// exact_value.cpp:1017-1027
	case ExactValue_Complex: {
		f64 a = x.value_complex->real;
		f64 b = x.value_complex->imag;
		f64 c = y.value_complex->real;
		f64 d = y.value_complex->imag;
		switch (op) {
		case Token_CmpEq: return cmp_f64(a, c) == 0 && cmp_f64(b, d) == 0;
		case Token_NotEq: return cmp_f64(a, c) != 0 || cmp_f64(b, d) != 0;
		}
		break;
	}
```

The strongest evidence that this is an oversight is the first line of the function.
`match_exact_values` **deliberately promotes into** `ExactValue_Quaternion` — from Integer, from
Float and from Complex:

```cpp
// exact_value.cpp:755-756   (Float, when the other side is a quaternion)
		case ExactValue_Quaternion:
			*x = exact_value_to_quaternion(*x);
// exact_value.cpp:765-766   (Complex, likewise)
		case ExactValue_Quaternion:
			*x = exact_value_to_quaternion(*x);
```

So the promotion step manufactures quaternion operands and hands them straight to a switch that
cannot accept them. This is also why shape `a` panics: `0` is an untyped integer, promoted to
quaternion by `match_exact_values`, and both operands then reach the switch as kind 6.

The fix is a `case ExactValue_Quaternion:` arm modelled on the `_Complex` one — comparing the
four components for `Token_CmpEq` / `Token_NotEq` and falling through to `break` for the
ordering operators, exactly as complex does (quaternions are unordered, so `<`, `<=`, `>`, `>=`
should keep producing the existing "not a constant boolean"-style outcome rather than a value).

---

## Port status

The Odin self-hosted checker (`core/odin/checker`) does **not** abort on any of these inputs, but
it is not correct either, and the reason is worth stating precisely: it is faithful to this code.

`compare_exact_values` in `core/odin/checker/exact_value.odin` has arms for the same eleven
kinds and no quaternion arm, so it degrades to `false` where C++ panics. The port's `false` is
therefore the *same* missing arm expressed as a non-crashing fallback: `#assert(Q == 0)` reports
a failed compile-time assertion instead of aborting. That answer is still wrong — a zero
quaternion does equal zero — but there is no reference behaviour to match here other than the
abort, so the port is deliberately left alone rather than given invented semantics. It will
follow whatever arm upstream adds.
