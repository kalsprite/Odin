# A non-decimal integer literal with an `e` aborts the compiler (two assertions in `big_int_from_string`)

**Component:** `src/big_int.cpp`, `src/tokenizer.cpp`
**Severity:** **crash** — assertion failure, SIGILL, core dumped, no diagnostic
**Status:** reproduced 2026-08-04, deterministic, 6 distinct inputs

## Reproduction

Any of these as a whole file is enough:

```odin
package lit
X :: 0b1e5
```

```
$ odin check . -no-entry-point
src/big_int.cpp(252): Assertion Failure: `base == 10`
This is a compiler error. Please report this.
Illegal instruction (core dumped)      # rc 132
```

### Inputs and which assertion they hit

| literal | result |
|---|---|
| `0b1e5` | `big_int.cpp(252)` — `base == 10` |
| `0b1E5` | `big_int.cpp(252)` — `base == 10` |
| `0b1e`  | `big_int.cpp(252)` — `base == 10` |
| `0o1e0` | `big_int.cpp(252)` — `base == 10` |
| `0z1e1` | `big_int.cpp(252)` — `base == 10` |
| `0d1e-5` | `big_int.cpp(253)` — `text[i] != '-'` |

Accepted without complaint (for contrast): `0d1e5`, `0d1e+5`, `0d1e`, `0x1e5`, `0d_1e5`.
`0x1e5` is correct — `e` is a hex digit. `0d…` is the explicitly-decimal prefix, so an exponent
there is at least arguable; the `-` case is not, since `0d1e+5` and `0d1e5` both work.

A genuinely invalid digit is handled properly and is the useful contrast: `0b19` produces an
ordinary error and exits 1. Only the `e`/`E` path aborts.

## Mechanism

Three steps, each individually defensible:

**1. The tokenizer deliberately over-consumes.** Every prefixed base calls `scan_mantissa` with
`force_base = false` (`src/tokenizer.cpp:471` and the `o`/`d`/`z`/`x` cases beside it):

```cpp
gb_internal gb_inline void scan_mantissa(Tokenizer *t, i32 base, bool force_base) {
	if (!force_base) {
		base = 16; // always check for any possible letter
	}
	while (digit_value(t->curr_rune) < base || t->curr_rune == '_') {
		advance_to_next_rune(t);
	}
}
```

So for `0b1e5` the requested base is 2 but the scan runs at base 16, and `e` (value 14) and `5`
are both pulled into the token. The token text becomes the whole of `0b1e5`.

**2. Nothing rejects the bad digits.** The only validation after each prefixed scan is an
emptiness test, `if (t->curr - prev <= 2)`. Digits that are invalid *for the declared base* are
never checked here — that is left to the consumer.

**3. The consumer assumes base 10 once it sees `e`.** `src/big_int.cpp:238-253`:

```cpp
if (v >= base) {
    // NOTE(Jeroen): Can still be a valid integer if the next character is an `e` or `E`.
    if (r != 'e' && r != 'E') {
        *success = false;
    }
    break;                       // <-- leaves the loop WITHOUT failing, for e/E
}
...
if (i < len && (text[i] == 'e' || text[i] == 'E')) {
    i += 1;
    GB_ASSERT(base == 10);       // 252
    GB_ASSERT(text[i] != '-');   // 253
```

The `v >= base` guard exempts `e`/`E` from the failure path so that decimal exponents survive,
but that exemption is not conditioned on the base actually being 10. Control then reaches an
assertion that says it must be.

The second assertion is the same shape: `0d1e-5` passes `base == 10` and dies on the `-`, even
though `0d1e+5` is accepted.

## Suggested direction

The exemption and the assertion need to agree. Something like:

```diff
 		if (v >= base) {
 			// NOTE(Jeroen): Can still be a valid integer if the next character is an `e` or `E`.
-			if (r != 'e' && r != 'E') {
+			if (base != 10 || (r != 'e' && r != 'E')) {
 				*success = false;
 			}
 			break;
 		}
```

and the `-` case wants `*success = false` rather than `GB_ASSERT`, since a negative exponent on
an integer literal is user input, not an internal invariant. Either way an assertion is the wrong
instrument here: every one of these six inputs is something a user can type, so each deserves a
diagnostic.

## How this was found

Differential testing of a self-hosted Odin checker against the reference compiler. The port
rejects all six with diagnostics; the reference aborts, which is how the asymmetry surfaced.
