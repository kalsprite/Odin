# `%a` in a cast suggestion is an unimplemented stub, so the following `%s` prints the wrong argument

**Component:** `src/check_expr.cpp`, `src/gb/gb.h`
**Severity:** wrong output in a user-facing diagnostic
**Status:** verified 2026-08-04 by inspection

## Location

Call site: `src/check_expr.cpp:2734`
Formatter: `src/gb/gb.h:6157`

## What is wrong

The suggestion is formatted with `%a`:

```cpp
gbString a = expr_to_string(o->expr);
gbString b = type_to_string(type);
...
error_line("\tSuggestion: %a may be directly casted to %s\n", a, b);
```

`a` and `b` are both `gbString` (i.e. `char *`). `%a` is the C hex-float specifier, so this was
already suspect — but gb's formatter does not implement it at all:

```cpp
case 'a':
case 'A':
    // TODO(bill):
    break;
```

The case breaks **without calling `va_arg`**. Because it consumes no argument, every subsequent
conversion in the format string is shifted by one. The `%s` that should print `b` (the target
type) instead prints `a` (the expression).

## Observed vs expected

```
actual     Suggestion:  may be directly casted to <expression>
expected   Suggestion: <expression> may be directly casted to <type>
```

The `%a` renders as nothing, and the type name never appears — `b` is formatted nowhere and is
freed unused.

## Suggested fix

The call site wants a plain string:

```diff
-			error_line("\tSuggestion: %a may be directly casted to %s\n", a, b);
+			error_line("\tSuggestion: %s may be directly casted to %s\n", a, b);
```

Separately, a formatter case that silently consumes no vararg will misalign *any* format string
that reaches it. If `%a`/`%A` are not going to be implemented, it would be safer for the default
path to consume an argument, or for the stub to be removed so an unknown specifier is handled by
whatever the fallback is, rather than silently desynchronising the vararg walk.

## How this was found

Auditing the reference compiler's diagnostic sites while porting them to a self-hosted checker.
The port emitted the type name where the reference emitted the expression, which pointed at the
format string rather than at the logic.
