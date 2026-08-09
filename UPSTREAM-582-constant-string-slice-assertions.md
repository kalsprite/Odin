# Two assertion failures when slicing a constant string

**Component:** `src/check_expr.cpp` (`check_slice_expr`)
**Severity:** **crash** — `GB_ASSERT` fires, compiler aborts with "This is a compiler error"
**Status:** both reproduced 5/5 on 2026-08-08

Two independent defects, both in `check_slice_expr`'s constant-string handling. They are
filed together because they sit in the same function and are found by the same probe family,
but they have different causes and different fixes.

---

## Bug A — inverted constant indices reach `substring()`, which asserts `lo <= hi`

### Reproduction

```odin
package a
main :: proc() {
	S :: "hello"
	x := S[3:1]
	_ = x
}
```

```
$ odin check . -no-entry-point
a/main.odin(4:12) Error: Invalid slice indices: [3 > 1]
	x := S[3:1]
	          ^
src/string.cpp(77): Assertion Failure: `lo <= hi && hi <= max` 3..1..5
This is a compiler error. Please report this.
```

### What is wrong

`check_slice_expr` detects `low > high` and reports it, but **does not return**:

```cpp
// check_expr.cpp:12203-12211
for (isize i = 0; i < gb_count_of(indices); i++) {
    i64 a = indices[i];
    for (isize j = i+1; j < gb_count_of(indices); j++) {
        i64 b = indices[j];
        if (a > b && b >= 0) {
            error(se->close, "Invalid slice indices: [%td > %td]", a, b);   // 12208 -- no return
        }
    }
}
```

Control then falls into the constant-folding tail, which calls `substring` with those same
indices unchanged:

```cpp
// check_expr.cpp:12270
o->value = exact_value_string(substring(s, cast(isize)indices[0], cast(isize)indices[1]));
```

and `substring` asserts:

```cpp
// string.cpp:75-79
gb_internal String substring(String const &s, isize lo, isize hi) {
	isize max = s.len;
	GB_ASSERT_MSG(lo <= hi && hi <= max, "%td..%td..%td", lo, hi, max);
	return make_string(s.text+lo, hi-lo);
}
```

Both folding branches are affected — the `String16` one at 12263 calls the `String16`
overload of `substring`, which has the same assertion.

The diagnostic is already correct and already emitted; only the fall-through is wrong. The
narrow fix is to make the `a > b && b >= 0` branch stop the constant fold, e.g. by setting a
flag the tail tests, or by taking the same shape as the non-constant-index branch at
12245-12256 (report, set `o->mode = Addressing_Value`, `o->expr = node`, `return kind`).

Note this is only reachable when the operand is a **constant** string: `max_count >= 0`
gates the folding tail, and for `Type_Basic` `max_count` is only set when
`o->mode == Addressing_Constant`. A non-constant string with the same indices reports the
error and exits cleanly.

---

## Bug B — every slice of a `string16` constant asserts, including valid ones

### Reproduction

```odin
package b
main :: proc() {
	S: string16 : "hello"
	x := S[0:2]        // a perfectly ordinary slice
	_ = x
}
```

```
$ odin check . -no-entry-point
src/check_expr.cpp(12081): Assertion Failure: `o->value.kind == ExactValue_String16`
This is a compiler error. Please report this.
```

Control: the same declaration **without** the slice checks cleanly, `rc=0`. So the
declaration itself is accepted; it is the slice that aborts.

### What is wrong

`check_slice_expr`'s `Type_Basic` arm assumes a constant of type `string16` carries an
`ExactValue_String16`:

```cpp
// check_expr.cpp:12078-12084
} else if (t->Basic.kind == Basic_string16) {
	valid = true;
	if (o->mode == Addressing_Constant) {
		GB_ASSERT(o->value.kind == ExactValue_String16);   // 12081 -- fires
		max_count = o->value.value_string16.len;
	}
	o->type = type_deref(o->type);
}
```

It does not. A `string16`-typed constant initialised from a string literal keeps the
literal's `ExactValue_String` — the constant is never re-expressed in UTF-16 when it is
converted to `string16`. The assertion is therefore not a defence against an impossible
state; it describes a state the checker never actually establishes, so **any** slice of a
`string16` constant aborts the compiler regardless of the indices.

Two possible fixes, depending on which invariant is intended:

1. Re-express the exact value as `ExactValue_String16` when a constant is converted to
   `string16`, which is what the assertion is asserting; or
2. Drop the assertion and handle `ExactValue_String` here (and at the folding site 12260),
   converting on demand.

(1) is the one that makes the rest of the tail — the `o->value.kind == ExactValue_String16`
test at 12260 that selects between the two folding branches — mean what it looks like it
means. Under the current representation that test is always false for `string16`, so
`string16` constants would silently fold through the `String` branch even if the assertion
were simply removed.

---

## Port status

The Odin self-hosted checker (`core/odin/checker`) does not reproduce either abort.

* **Bug A** — deliberate divergence, recorded at the site in `check_expr.odin`
  (`check_slice`): the constant fold is skipped when `indices[0] > indices[1]`. The
  diagnostic C++ emits before dying is still reported, so the observable output up to the
  point of the crash is identical.
* **Bug B** — the port's `string16` arm reads the value with a checked type assertion rather
  than an assert, so it degrades instead of aborting. It degrades *badly*, though: it leaves
  `max_count` at `-1`, and the operand then trips the "Cannot slice constant value '%s'"
  branch, which is a spurious error on a valid slice. That is tracked separately as a port
  defect; it cannot be oracle-verified until Bug B is fixed upstream, since the reference
  compiler has no observable behaviour on this input.
