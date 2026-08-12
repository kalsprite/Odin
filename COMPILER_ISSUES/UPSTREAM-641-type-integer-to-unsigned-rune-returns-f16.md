# `intrinsics.type_integer_to_unsigned(rune)` returns `f16`

**Component:** `src/check_builtin.cpp` (`BuiltinProc_type_integer_to_unsigned`)
**Severity:** silently wrong **type** — no diagnostic, the intrinsic simply answers a floating-point
type where an integer type was asked for
**Compiler:** `dev-2026-08:958fe3b51`
**Status:** reproduced 5/5 on 2026-08-09 using the stock `./odin` (not an instrumented build), and
re-verified 5/5 from the exact input below immediately before filing. There is a clean control: every
other signed integer kind maps correctly. Every line quoted below was re-read in `src/` at filing time
and still says what is quoted.

---

## Reproduction

```odin
package a
import "base:intrinsics"

U :: intrinsics.type_integer_to_unsigned(rune)

#assert(U == f16)          // passes
#assert(size_of(U) == 2)   // passes

main :: proc() {}
```

`odin check . -no-entry-point` exits 0 with both assertions satisfied: the intrinsic answered `f16`.

### It is reachable from ordinary generic code

The direct call above is contrived; this shape is not. A generic constrained to integers, instantiated
with `rune`, silently gets a float — and the constraint does not catch it, because `rune` genuinely
satisfies `type_is_integer`:

```odin
package a
import "base:intrinsics"

widen :: proc($T: typeid) where intrinsics.type_is_integer(T) {
	U :: intrinsics.type_integer_to_unsigned(T)
	#assert(size_of(U) == 2)   // passes for T = rune: U is f16
}

main :: proc() { widen(rune) }
```

`odin check . -no-entry-point` exits 0, 5/5. A caller writing `widen(rune)` has no signal that the
intrinsic left the integer domain.

**Control** — the neighbouring kinds all behave, so this is specific to `rune` rather than a general
breakage:

```odin
#assert(intrinsics.type_integer_to_unsigned(i32)  == u32)
#assert(intrinsics.type_integer_to_unsigned(i128) == u128)
#assert(intrinsics.type_integer_to_unsigned(int)  == uint)
#assert(intrinsics.type_integer_to_unsigned(i32le) == u32le)
```

---

## What is wrong

Three facts compose. Each is independently reasonable; together they produce the wrong answer.

**1. The mapping is unguarded enum adjacency.** After its gates, the intrinsic simply steps one place
forward in the `Basic_` enum:

```cpp
// check_builtin.cpp:6946
			Type *u_type = &basic_types[bt->Basic.kind + 1];

			operand->type = u_type;
```

That is correct precisely because `Basic_Kind` pairs every signed kind immediately before its unsigned
partner — `i8,u8`, `i16,u16`, … `i128,u128`, `int,uint`, and likewise for every endian variant
(`types.cpp`, the `Basic_` enum). The step encodes that invariant without asserting it.

**2. `rune` is flagged as an integer and is not flagged unsigned:**

```cpp
// types.cpp:506
	{Type_Basic, {Basic_rune,              BasicFlag_Integer | BasicFlag_Rune,         4, STR_LIT("rune")}},
```

so it passes the gate that is supposed to admit only signed integers:

```cpp
// check_builtin.cpp:6930-6937
			if (bt->kind != Type_Basic ||
				(bt->Basic.flags & BasicFlag_Unsigned) != 0 ||
				(bt->Basic.flags & BasicFlag_Integer) == 0) {
				gbString t = type_to_string(operand->type);
				error(operand->expr, "Expected a signed integer type for '%.*s', got %s", LIT(builtin_name), t);
				gb_string_free(t);
				return false;
			}
```

**3. `rune` is the one integer-flagged kind whose successor is not an unsigned partner.** It sits at
the end of the signed/unsigned run, immediately before the float block:

```
	Basic_i128,
	Basic_u128,

	Basic_rune,

	Basic_f16,
	Basic_f32,
	Basic_f64,
```

So `basic_types[Basic_rune + 1]` is `Basic_f16`, and that is what the intrinsic returns.

`rune` appears to be the only kind that reaches this, which is why the control above is clean.

## The signed direction does not have this hole, and shows the intended remedy

`BuiltinProc_type_integer_to_signed` steps *backwards*, and it has exactly one kind whose predecessor
is not its signed partner — `uintptr`, preceded by `uint`. That case is rejected by name rather than
being allowed to produce a wrong answer:

```cpp
// check_builtin.cpp:6983-6988
			if (bt->Basic.kind == Basic_uintptr) {
				gbString t = type_to_string(operand->type);
				error(operand->expr, "Type %s does not have a signed integer mapping for '%.*s'", t, LIT(builtin_name));
				gb_string_free(t);
				return false;
			}
```

The unsigned direction needs the mirror of that guard for `rune`: either reject it the same way, or
exclude `BasicFlag_Rune` from the signed-integer gate at :6930 so it fails with the existing
"Expected a signed integer type" message.

---

## Port status

The Odin self-hosted checker (`core/odin/checker`) **reproduces this deliberately.**

Its two arms were, until now, hand-written `Basic_Kind` mapping tables rather than a port of the
adjacency step. Those tables happened to return `rune` unchanged — so the port was *accidentally*
diverging from the reference here, by a mechanism that was also wrong in four other ways (it returned
already-correct-signedness inputs unchanged where the reference errors, returned every endian variant
unchanged, mapped `uintptr` to `int` where the reference rejects it, and had none of the reference's
polymorphic/untyped gates). Replacing them with the reference's adjacency step fixed all of that and
reproduced this quirk for free.

That is the intended outcome: the port matches the reference, and a `rune` special case on the port
side would be inventing a semantics the reference does not have. If a guard lands upstream, the port
follows it.
