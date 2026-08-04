# The 64-bit signed constant range check is a tautology, so out-of-range constants are accepted

**Component:** `src/check_expr.cpp`
**Severity:** silently accepts constants that cannot be represented in their declared type
**Status:** reproduced 2026-08-04, deterministic

## Reproduction

```odin
package rng
X : i64 : 18446744073709551615      // u64 max, declared as i64
```

```
$ odin check . -no-entry-point
$ echo $?
0
```

Accepted. And the constant keeps its true value — it is not wrapped or truncated:

```odin
X : i64 : 18446744073709551615
#assert(X == 18446744073709551615)  // holds
#assert(X > 0)                      // holds
```

So `X` is an `i64` whose value is greater than `max(i64)`.

### Range of the defect

| declaration | reference |
|---|---|
| `X : i64 : 9223372036854775807` (i64 max) | accepted — correct |
| `X : i64 : 9223372036854775808` | **accepted** — should be rejected |
| `X : i64 : 18446744073709551615` (u64 max) | **accepted** — should be rejected |
| `X : i64 : 18446744073709551616` (2⁶⁴) | rejected — "Cannot convert numeric value" |
| `X : i64 : -9223372036854775809` (i64 min − 1) | **accepted**, and `#assert(X < min(i64))` holds |
| `X : int : 18446744073709551615` | **accepted** |
| `X : i64le : 18446744073709551615` | **accepted** |

The enforced bound is 2⁶⁴, not `i64`'s range.

**Only the 64-bit signed types are affected.** `i32` and `u64` are correct:

```
X : i32 : 2147483648            rejected
X : i32 : 4294967295            rejected
X : i32 : -2147483649           rejected
X : u64 : -1                    rejected
```

## Cause

`src/check_expr.cpp:2388-2396`, in `check_representable_as_constant`:

```cpp
case Basic_i64:
case Basic_int:
...
	if (c->bit_field_bit_size == 0) {
		// return imin <= i && i <= imax;
		if (!big_int_can_be_represented_in_64_bits(&i)) {
			return false;
		}

		i64 val64 = big_int_to_i64(&i);

		return imin_64 <= val64 && val64 <= imax_64;
	}
```

For `i64`/`int`/`i64le`/`i64be`, `imin_64` and `imax_64` *are* `INT64_MIN` and `INT64_MAX`. So

```cpp
return imin_64 <= val64 && val64 <= imax_64;
```

is true for **every** possible `i64`, for the same reason `x >= INT64_MIN` is always true. The
comparison cannot fail, and the only surviving gate is
`big_int_can_be_represented_in_64_bits` — a *width* test that admits the whole unsigned 64-bit
range. `big_int_to_i64` then wraps u64 max to `-1`, which duly passes the tautological bounds
check, and the original unwrapped value is what gets stored.

The narrower types escape this because their `imin_64`/`imax_64` are genuinely narrower than
`i64`, so the same comparison is a real test.

The commented-out line directly above is the correct implementation:

```cpp
// return imin <= i && i <= imax;
```

`imin`/`imax` are the `BigInt` bounds computed earlier in the same function (`src/check_expr.cpp`
around 2351-2357). Comparing in big-int space has no width to overflow and needs no narrowing.

## Consequence

A constant that is out of range for its declared type flows onward with its true value. Downstream
arithmetic does catch some of it — `Y :: X + 1` where `X` is u64 max declared `i64` is rejected —
but the declaration itself is not, so the invalid constant is available to anything that does not
happen to trip a later check. I have not traced what code generation emits for such a constant;
that is worth checking, since the checker and the backend would be working from a value the type
cannot hold.

## Suggested fix

Restore the big-int comparison for the 64-bit signed cases, i.e. use the commented-out line rather
than narrowing to `i64` first.

## How this was found

Differential testing of a self-hosted Odin checker against the reference. The port rejects all of
the rows marked **accepted** above. Sweeping the boundary values rather than testing one of them is
what showed the enforced bound is 2⁶⁴ and that the defect stops at 64-bit signed types.
