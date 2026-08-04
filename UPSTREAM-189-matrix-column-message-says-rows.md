# Matrix column-count error reports "rows"

**Component:** `src/check_type.cpp`
**Severity:** cosmetic (misleading diagnostic)
**Status:** verified 2026-08-04 by inspection

## Location

`src/check_type.cpp:3124`

## What is wrong

```cpp
if (column.expr == nullptr) {
    error(node, "Invalid matrix column count, got nothing");
} else {
    gbString s = expr_to_string(column.expr);
    error(column.expr, "Invalid matrix column count, expected %d+ rows, got %s", MATRIX_ELEMENT_COUNT_MIN, s);
    gb_string_free(s);
}
```

The branch is the **column** count check — it says so in its own first clause — but the
expectation clause reads `expected %d+ rows`. A user given `Invalid matrix column count,
expected 1+ rows` is told to fix the wrong dimension.

Nearly certainly a copy-paste from the row-count branch above it.

## Suggested fix

```diff
-		error(column.expr, "Invalid matrix column count, expected %d+ rows, got %s", MATRIX_ELEMENT_COUNT_MIN, s);
+		error(column.expr, "Invalid matrix column count, expected %d+ columns, got %s", MATRIX_ELEMENT_COUNT_MIN, s);
```
