# check_expr.cpp: constant transmute wraps one value too many, producing out-of-range constants

**File:** `src/check_expr.cpp:4086` `check_transmute`, the unsigned-to-signed wrap
**Severity:** wrong constant value. `transmute(i32)u32(0x7FFFFFFF)` yields `-2147483649`, which is not
representable in `i32` at all. Off by one — exactly one input value is affected per width.

## The code

When a constant transmute crosses a signedness boundary, the stored `ExactValue` (a signed big
integer) has to be re-expressed, because the bit pattern is preserved but the *number* is not:

```cpp
BigInt smax = {};
big_int_from_u64(&smax, 0);
big_int_not(&smax, &smax, cast(i32)(srcz*8 - 1), false);   // smax = 2^(bits-1) - 1

BigInt umax = {};
big_int_from_u64(&umax, 1);
BigInt sz_in_bits = big_int_make_i64(srcz*8);
big_int_shl_eq(&umax, &sz_in_bits);                        // umax = 2^bits

if (is_type_unsigned(src_t) && !is_type_unsigned(dst_t)) {
    if (big_int_cmp(&v, &smax) >= 0) {                     // <-- should be > , not >=
        big_int_sub_eq(&v, &umax);
    }
}
```

`smax` is `2^(bits-1) - 1`, the **largest value that still fits** in the signed destination. A value
should be wrapped only when it *exceeds* that — i.e. when it is `>= 2^(bits-1)`. Testing `>= smax`
wraps `smax` itself.

For 32 bits: `0x7FFFFFFF` (2147483647) is a perfectly good `i32`, but it compares `>= smax` and gets
`2^32` subtracted, giving `2147483647 - 4294967296 = -2147483649` — below `i32`'s minimum.

The opposite direction (`signed -> unsigned`, guarded by `big_int_is_neg`) is correct.

## Reproduction

```odin
package p
E  :: enum u32 { A = 0, Z = 31 }
BS :: bit_set[E; i32]

B_7FFFFFFE :: transmute(BS)u32(0x7FFFFFFE)
B_7FFFFFFF :: transmute(BS)u32(0x7FFFFFFF)
B_80000000 :: transmute(BS)u32(0x80000000)
I_7FFFFFFF :: transmute(i32)u32(0x7FFFFFFF)
```

Observed constant values:

| expression | value stored | correct |
|---|---|---|
| `transmute(BS)u32(0x7FFFFFFE)` | 2147483646 | 2147483646 ✓ |
| `transmute(BS)u32(0x7FFFFFFF)` | **-2147483649** | 2147483647 |
| `transmute(BS)u32(0x80000000)` | -2147483648 | -2147483648 ✓ |
| `transmute(i32)u32(0x7FFFFFFF)` | **-2147483649** | 2147483647 |
| `transmute(u32)i32(-1)` | 4294967295 | 4294967295 ✓ |

Only the single value `2^(bits-1) - 1` is wrong; its neighbours on both sides are correct, which is
the signature of the `>=`/`>` off-by-one. The same applies at every width (`u8`->`i8` at `0x7F`,
`u64`->`i64` at `0x7FFFFFFFFFFFFFFF`).

Note that the value printed for these constants is *also* subject to the digit-reversal bug in
`big_int_to_string` (filed separately); the values above were read from an instrumented dump with
that reversal fixed, so they are the true stored values, not rendering artefacts.

## Suggested fix

```cpp
if (big_int_cmp(&v, &smax) > 0) {
    big_int_sub_eq(&v, &umax);
}
```

## Provenance

Found while porting `check_transmute` to the self-hosted checker in `core/odin/checker`, building a
full-state model comparison between the two implementations. The port reproduces the `>=` behaviour
deliberately, for bit-exact parity with the reference; this write-up records why that code looks
wrong on purpose.
