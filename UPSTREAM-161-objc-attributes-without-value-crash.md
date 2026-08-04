# Three `objc_*` attributes crash the compiler when written without a value

**Component:** `src/checker.cpp`
**Severity:** **crash** — assertion failure or segfault, core dumped, no diagnostic
**Status:** reproduced 2026-08-04, deterministic

## Reproduction

Each of these is a complete file. Replace `ATTR` with one of the three names below.

```odin
package objsweep
import "base:intrinsics"
_ :: intrinsics

@(ATTR)
Foo :: struct {}
```

| attribute | result |
|---|---|
| `objc_superclass` | `src/checker.cpp(52): Assertion Failure: `expr != nullptr`` — SIGILL (132), core dumped |
| `objc_ivar`       | `src/checker.cpp(52): Assertion Failure: `expr != nullptr`` — SIGILL (132), core dumped |
| `objc_context_provider` | **SIGSEGV (139)**, core dumped, no message at all |

## Every other objc attribute handles this correctly

Same file shape, no value, exhaustively over the attribute names in `src/*.cpp`:

```
objc_class             Error: Expected a non-empty string value for 'objc_class'
objc_implement         Error: @(objc_implement) may only be applied when ...
objc_instancetype      Error: Unknown attribute element name 'objc_instancetype'
objc_name              Error: Expected a string value for 'objc_name'
objc_type              Error: Expected a type for 'objc_type'
objc_selector          Error: Expected a string value for 'objc_selector'
objc_is_class_method   Error: Expected a boolean value for 'objc_is_class_method'
```

So the correct behaviour is well established in the same function — these three are the outliers.

## Cause

When an attribute is written bare, `value` is `nullptr`. The three crashing branches use it
without checking.

`src/checker.cpp:4484` and `:4493` pass it straight to `check_type`:

```cpp
} else if (name == "objc_superclass") {
    Type *objc_superclass = check_type(c, value);          // value == nullptr
    if (objc_superclass != nullptr) {
        ac->objc_superclass = objc_superclass;
    } else {
        error(value, "'%.*s' expected a named type", LIT(name));
    }
```

which reaches `check_rtti_type_disallowed(Ast *expr, ...)` at `src/checker.cpp:51-53`:

```cpp
gb_internal bool check_rtti_type_disallowed(Ast *expr, Type *type, char const *format) {
    GB_ASSERT(expr != nullptr);
    return check_rtti_type_disallowed(ast_token(expr), type, format);
}
```

Note the `else` branch already intends to produce a diagnostic — but it calls `error(value, ...)`
with the same null `value`, so even had the assertion not fired first, the error path would
dereference it too.

`src/checker.cpp:4503` does the equivalent with `check_expr`:

```cpp
} else if (name == "objc_context_provider") {
    Operand o = {};
    check_expr(c, &o, value);                              // value == nullptr
    Entity *e = entity_of_node(o.expr);
```

That one segfaults rather than asserting.

## Contrast with the guarded form

`objc_name`, immediately alongside, is the model:

```cpp
} else if (name == "objc_name") {
    ExactValue ev = check_decl_attribute_value(c, value);
    if (ev.kind == ExactValue_String) {
        ...
    } else {
        error(elem, "Expected a string value for '%.*s'", LIT(name));
    }
```

`check_decl_attribute_value` (`src/checker.cpp:3636`) handles the null case, and the diagnostic
anchors on `elem` — the attribute element — rather than on the absent `value`.

## Suggested fix

Guard the three branches the way their siblings are guarded, and anchor the diagnostics on `elem`:

```diff
 	} else if (name == "objc_superclass") {
+		if (value == nullptr) {
+			error(elem, "Expected a named type for '%.*s'", LIT(name));
+			return true;
+		}
 		Type *objc_superclass = check_type(c, value);
 		if (objc_superclass != nullptr) {
 			ac->objc_superclass = objc_superclass;
 		} else {
-			error(value, "'%.*s' expected a named type", LIT(name));
+			error(elem, "'%.*s' expected a named type", LIT(name));
 		}
```

and likewise for `objc_ivar` and `objc_context_provider`.

## Related

`@(objc_context_provider=provider)` **with** a value also crashes when the provider procedure takes
no parameters — a separate defect at a separate site, written up in
`UPSTREAM-285-objc-context-provider-segfault.md`.

## How this was found

Differential testing of a self-hosted Odin checker against the reference compiler, then an
exhaustive sweep: every `objc_*` name in `src/*.cpp`, each written without a value. Sweeping the
whole attribute set rather than sampling is what showed that exactly three of twelve are affected
and that the other nine already model the fix.
