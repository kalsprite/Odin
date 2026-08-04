# "cannot be use as an import name" — grammatical slip, and the message says the same thing twice

**Component:** `src/checker.cpp`
**Severity:** cosmetic (diagnostic text)
**Status:** verified 2026-08-04 by inspection

## Location

`src/checker.cpp:5650`

## What is wrong

```cpp
error(token, "Import name '%.*s' cannot be use as an import name as it is not a valid identifier", LIT(id->import_name.string));
```

Two problems in one string:

1. `cannot be use` should be `cannot be used`.
2. The sentence names the subject twice — "Import name 'x' cannot be use **as an import name**".

The sibling branch immediately below gets it right and is the model to follow:

```cpp
error(id->token, "Import name '%.*s' is not a valid identifier", LIT(invalid_name));
```

## Suggested fix

```diff
-		error(token, "Import name '%.*s' cannot be use as an import name as it is not a valid identifier", LIT(id->import_name.string));
+		error(token, "Import name '%.*s' cannot be used as an import name as it is not a valid identifier", LIT(id->import_name.string));
```

Or, to drop the repetition as well:

```cpp
error(token, "Import name '%.*s' is not a valid identifier", LIT(id->import_name.string));
```
