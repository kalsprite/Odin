# "in not allowed within this field list" — "in" for "is"

**Component:** `src/parser.cpp`
**Severity:** cosmetic (diagnostic text)
**Status:** verified 2026-08-04 by inspection

## Location

`src/parser.cpp:4320`

## What is wrong

```cpp
syntax_error(f->curr_token, "'%s%.*s' in not allowed within this field list", prefix, LIT(m.name));
```

`in` should be `is`. The rendered message reads e.g.

```
'#no_alias' in not allowed within this field list
```

The slip is easy to miss in review precisely because `in` is a keyword in this language and
reads as plausible until you parse the sentence.

## Suggested fix

```diff
-				syntax_error(f->curr_token, "'%s%.*s' in not allowed within this field list", prefix, LIT(m.name));
+				syntax_error(f->curr_token, "'%s%.*s' is not allowed within this field list", prefix, LIT(m.name));
```
