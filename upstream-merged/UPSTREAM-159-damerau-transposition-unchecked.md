# Damerau term in `levenstein_distance_case_insensitive` never checks for a transposition

**Component:** `src/common.cpp`
**Severity:** wrong "did you mean" suggestions; distances under-reported
**Status:** verified 2026-08-04 by inspection

## Location

`src/common.cpp:863-871`, inside `levenstein_distance_case_insensitive`
(function begins at `src/common.cpp:833`).

## What is wrong

```cpp
// Damerau-Levenshtein (transposition extension)
#if USE_DAMERAU_LEVENSHTEIN
if (i > 1 && j > 1) {
    isize transpose = matrix[(i-2)*w + j-2] + 1;
    if (transpose < minimum) {
        minimum = transpose;
    }
}
#endif
```

The transposition term is applied whenever `i > 1 && j > 1` — that is, at essentially every
interior cell. The actual Damerau-Levenshtein rule requires the two characters to be swapped:

```
a[i-1] == b[j-2]  &&  a[i-2] == b[j-1]
```

That condition is never tested, so the discount is handed out for arbitrary character pairs
that are not a transposition at all. The result is a distance that can be lower than the true
edit distance.

## Consequences

`USE_DAMERAU_LEVENSHTEIN` is `1` (`src/common.cpp:831`), so this is live, and it is not confined
to ranking. The same macro shifts the acceptance threshold:

```cpp
enum {MAX_SMALLEST_DID_YOU_MEAN_DISTANCE = 3-USE_DAMERAU_LEVENSHTEIN};   // src/common.cpp:892
```

So under-computed distances are compared against a threshold that was *tightened* on the
assumption the metric is a correct Damerau-Levenshtein. Unrelated identifiers can score within
range and be offered as suggestions.

## Suggested fix

```diff
 #if USE_DAMERAU_LEVENSHTEIN
-if (i > 1 && j > 1) {
+if (i > 1 && j > 1 &&
+    gb_char_to_lower(cast(char)a.text[i-1]) == gb_char_to_lower(cast(char)b.text[j-2]) &&
+    gb_char_to_lower(cast(char)a.text[i-2]) == gb_char_to_lower(cast(char)b.text[j-1])) {
     isize transpose = matrix[(i-2)*w + j-2] + 1;
```

Note this is the *optimal string alignment* variant, which is what the surrounding matrix
supports; full Damerau-Levenshtein needs an additional last-occurrence row.
