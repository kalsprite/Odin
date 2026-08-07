# big_int.cpp: every negative integer constant is printed with its digits scrambled

**File:** `src/big_int.cpp:635` `big_int_to_string`, the final reversal loop
**Severity:** wrong user-facing output. Diagnostics report a different number than the one in the
source. No miscompilation — the VALUE is correct, only its rendering is wrong.

## The self-evident symptom

```odin
package rch
a: [4]int
v := a[-14]
```

```
Error: Index '-14' cannot be a negative value, got -41
```

One sentence prints the same number twice, two different ways. `'-14'` is the source expression
text; `got -41` is the value rendered through `big_int_to_string`.

## The code

`big_int_to_string` emits digits least-significant-first, then reverses them in place:

```cpp
isize first_word_idx = buf.count;   // 0 normally; 1 if a '-' was already pushed

if (v.sign) {
    array_add(&buf, '-');
    mp_abs(&v, &v);
}
isize first_word_idx = buf.count;   // (assignment shown above occurs after this push)
... digits appended least-significant-first ...

for (isize i = first_word_idx; i < buf.count/2; i++) {
    isize j = buf.count + first_word_idx - i - 1;
    char tmp = buf[i];
    buf[i] = buf[j];
    buf[j] = tmp;
}
```

The index `j` is computed correctly for the sub-range `[first_word_idx, buf.count)`, but the loop
BOUND is `buf.count/2`, which is the midpoint of the WHOLE buffer, not of that sub-range. When a
`'-'` has been pushed, `first_word_idx == 1` and the loop stops one swap early — or never runs.

Positive values are unaffected (`first_word_idx == 0`, so `buf.count/2` is the correct midpoint),
which is why this has stayed invisible.

## Worked example

`-14` → buffer after digit emission is `['-', '4', '1']`, `count == 3`, `first_word_idx == 1`.

* correct bound: `1 + (3-1)/2 = 2` → one swap of indices 1 and 2 → `-14`
* actual bound: `3/2 = 1` → loop body never executes → **`-41`**

`-1021` → `['-','1','2','0','1']`, count 5. Correct bound `1 + 2 = 3` (two swaps); actual bound
`5/2 = 2` (one swap), and the one swap it does perform is a no-op here, so the result is `-1201`.

## Reproduced values

Simulating the loop exactly reproduces the compiler's output in every case observed:

| value | printed |
|---|---|
| -14 | -41 |
| -37 | -73 |
| -12 | -21 |
| -10 | -01 |
| -1021 | -1201 |
| -2147483648 | -2147843648 |
| -292277022399 | -292270722399 |
| -2013265920 | -2013625920 |
| -2 | -2 (single digit, nothing to reverse) |
| any positive | correct |

## Suggested fix

Bound the loop by the midpoint of the digit sub-range rather than of the whole buffer:

```cpp
isize digit_count = buf.count - first_word_idx;
for (isize i = first_word_idx; i < first_word_idx + digit_count/2; i++) {
```

Verified against 16 cases (negative, positive, zero, single-digit, multi-limb): correct in all.

## Blast radius

`big_int_to_string` is reached from `write_exact_value_to_string`'s `ExactValue_Integer` arm
(`src/exact_value.cpp:1129`), so any diagnostic or documentation output that prints a negative
integer constant is affected. The array-index message above is one demonstrated path; the value
column of any tooling that renders constants is another.

## Provenance

Found while building a full-state model comparison between the C++ checker and the self-hosted
checker in `core/odin/checker`. The port renders these values correctly, so they appeared as ~5000
"value divergences" across a 323-package corpus. Every one of them was this bug. The two
implementations agree on the VALUES — confirmed independently: both accept
`#assert(linux.MAP_HUGE_16GB == transmute(Map_Flags)((u32(32) << 26) | (u32(2) << 26)))`, i.e. both
hold `0x88000000`, while only the C++ side misprints it.
