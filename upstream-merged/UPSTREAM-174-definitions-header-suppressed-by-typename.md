# "With the following definitions:" is suppressed whenever a type name is printed first

**Component:** `src/check_expr.cpp`
**Severity:** diagnostic block printed without the header that announces it
**Status:** confirmed by inspection 2026-08-04. **Reachability from Odin source not demonstrated** — see below.

## Location

`src/check_expr.cpp:7119-7148`, in `evaluate_where_clauses` (begins `:7098`), on the
`'where' clause evaluated to false` path.

## What is wrong

Two entity kinds can contribute lines to the definitions block, and they share one counter:

```cpp
isize print_count = 0;
for (auto const &entry : scope->elements) {
	Entity *e = entry.value;
	switch (e->kind) {
	case Entity_TypeName: {
		// if (print_count == 0) error_line("\n\tWith the following definitions:\n");   // :7125

		gbString str = type_to_string(e->type);
		error_line("\t\t%.*s :: %s;\n", LIT(e->token.string), str);
		gb_string_free(str);
		print_count += 1;                                                              // still counts
		break;
	}
	case Entity_Constant: {
		if (print_count == 0) error_line("\n\tWith the following definitions:\n");      // :7134
		...
		print_count += 1;
		break;
	}
	}
}
```

In the `Entity_TypeName` arm the header line is **commented out**, but `print_count += 1` remains.
So a type name emits its definition line, bumps the counter, and the `Entity_Constant` arm's
`print_count == 0` guard is then false forever. The header is never printed.

Three outcomes, decided by which kind is encountered first:

| scope contents | result |
|---|---|
| constants only | header printed, then the definitions — correct |
| type names only | definitions printed, **no header** |
| a type name before any constant | definitions printed, **no header** |
| a constant before any type name | header printed — correct |

The block is emitted either way; what goes missing is the line that says what it is. The reader
gets bare `Name :: Type;` lines hanging under the error with nothing introducing them.

## Note on the framing

This is the reverse of how it is easy to describe. The header does not destroy the block — the
block survives intact, and the *header* is what gets lost. The commented-out line at `:7125` is the
whole defect; uncommenting it (or hoisting the header above the loop) restores the announcement.

## Ordering makes it unpredictable

`scope->elements` is iterated in hash order, so for a scope containing both kinds, whether the
header appears depends on the hash layout rather than anything in the source. Related work on this
same block found its contents to be hash-order dependent for exactly this reason, so a user can see
the header on one build and not another for equivalent code.

## What I could NOT establish

I did not find an Odin input that reaches the block at all. Four shapes were tried — a failing
`where` on a polymorphic procedure with `$N: int`, the same with `$T: typeid, $N: int`, and both
equivalents on a polymorphic `struct` — and all four produce the `'where' clause evaluated to
false` error with no definitions block following:

```odin
Foo :: struct($T: typeid, $N: int) where N > 10 { x: T }
X :: Foo(int, 5)
```
```
Error: 'where' clause evaluated to false:
	N > 10
	Foo :: struct($T: typeid, $N: int) where N > 10 { x: T }
	                                       ^~~~~^
```

So either `scope` is null on these paths or the scope holds no `Entity_TypeName`/`Entity_Constant`
entries at that point. A maintainer who knows which scope is intended here will reach it faster
than I could from outside.

## Suggested fix

```diff
 	case Entity_TypeName: {
-		// if (print_count == 0) error_line("\n\tWith the following definitions:\n");
+		if (print_count == 0) error_line("\n\tWith the following definitions:\n");
```

Hoisting the header out of the switch entirely — printed once before the loop if the scope has any
printable entity — would remove the coupling between the two arms and the shared counter, which is
what made this possible.
