# `quote_to_ascii(String16)` indexes a 16-entry table with a 12-bit value

**Component:** `src/string.cpp`
**Severity:** out-of-bounds read of a global array (read-only, adjacent rodata)
**Status:** confirmed by inspection 2026-08-04. **Reachability from Odin source not demonstrated** — see below.

## Location

`src/string.cpp:963-964`, in the `String16` overload of `quote_to_ascii` (begins at `:935`).

## What is wrong

```cpp
gb_global char const lower_hex[] = "0123456789abcdef";   // :849, 16 entries
```

```cpp
gb_internal String quote_to_ascii(gbAllocator a, String16 str, u8 quote='"') {
	u16 *s = cast(u16 *)str.text;                        // <-- u16
	...
		if (width == 1 && r == GB_RUNE_INVALID) {
			array_add(&buf, cast(u8)'\\');
			array_add(&buf, cast(u8)'x');
			array_add(&buf, cast(u8)lower_hex[s[0]>>4]);  // :963
			array_add(&buf, cast(u8)lower_hex[s[0]&0xf]);
			continue;
		}
```

`s[0]` is a `u16`, so `s[0] >> 4` ranges over **0..4095**. `lower_hex` has 16 elements. Any
`s[0] >= 0x100` reaching this branch reads past the end of the table, by up to 4080 bytes.

`s[0] & 0xf` on the next line is fine.

## It is a copy of the `u8` overload

The `String` overload at `:865-866` is character-for-character the same expression:

```cpp
	u8 *s = str.text;                                    // <-- u8
	...
			array_add(&buf, cast(u8)lower_hex[s[0]>>4]);
			array_add(&buf, cast(u8)lower_hex[s[0]&0xf]);
```

There it is correct: `s[0]` is a `u8`, so `s[0] >> 4` is at most 15. The expression was carried
over to the 16-bit version without widening the shift, which is exactly the kind of thing that
survives review because the two lines look identical.

Note also that the same function gets it *right* further down, at `:1002-1008`, where the `\u`
path masks each nibble explicitly:

```cpp
	for (isize i = 12; i >= 0; i -= 4) {
		array_add(&buf, cast(u8)lower_hex[(r>>i)&0xf]);   // masked
	}
```

## Which inputs reach the branch

The guard is `width == 1 && r == GB_RUNE_INVALID`. Tracing the loop, two shapes qualify:

1. **`s[0] == 0xFFFD`** (U+FFFD itself). The first branch `r < _surr1 || _surr3 <= r` leaves `r`
   unchanged, and `GB_RUNE_INVALID` *is* `0xFFFD`, so the guard passes with `width == 1`.
   `0xFFFD >> 4 == 0xFFF == 4095`.
2. **An unpaired high surrogate at the end of the string** (`0xD800..0xDBFF` with `n == 1`), which
   sets `r = GB_RUNE_INVALID` while leaving `width == 1`. `0xD800 >> 4 == 3456`.

A high surrogate followed by an invalid low one also reaches it — `decode_surrogate_pair` returns
`GB_RUNE_INVALID` and `width` is only advanced to 2 on success.

## What I could NOT establish

I did not find an Odin source input that drives a `String16` value through this function. The
call site is `src/exact_value.cpp:1116` (`exact_value_to_string` on `v.value_string16`), but the
diagnostics I tried — duplicate `case` on a `string16` switch, bad assignment, bad declaration —
all render the constant through `expr_to_string`, i.e. the source text, and never reach the
quoting path:

```
switch x { case "\ud800": case "\ud800": }   ->  Error: Duplicate case '"\ud800"'   (source text)
```

So this is filed as a defect in the function rather than as a user-visible symptom. It is worth
fixing regardless — the index is unambiguously out of range for two identified input values, and
whoever wires a `string16` constant into a diagnostic later will hit it — but a maintainer should
know that the reachability half is unproven rather than assume a repro exists.

## Suggested fix

```diff
-			array_add(&buf, cast(u8)lower_hex[s[0]>>4]);
-			array_add(&buf, cast(u8)lower_hex[s[0]&0xf]);
+			array_add(&buf, cast(u8)lower_hex[(s[0]>>4)&0xf]);
+			array_add(&buf, cast(u8)lower_hex[s[0]&0xf]);
```

That matches the masking the same function already uses on its `\u` path. Emitting `\x` with two
nibbles for a value that can exceed 0xFF is arguably wrong on its own terms, so the better fix may
be to route these through the `\u` escape instead — but the mask is the minimal correction.
