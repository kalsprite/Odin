# Every named argument in "Given argument types" is labelled with the first argument's name

**Component:** `src/check_expr.cpp`
**Severity:** wrong information in a user-facing diagnostic
**Status:** reproduced 2026-08-04, deterministic

## Reproduction

```odin
package pa

foo :: proc(alpha: int,  beta: string) {}
bar :: proc(alpha: bool, beta: rune)   {}
g :: proc{foo, bar}

call :: proc() {
	g(alpha = 1.5, beta = 2.5)
}
```

```
$ odin check . -no-entry-point
main.odin(8:2) Error: No procedures or ambiguous call for procedure group 'g' that match with the given arguments
	g(alpha = 1.5, beta = 2.5)
	^
	Given argument types:
	 • alpha = untyped float
	 • alpha = untyped float          <-- should be `beta`
Did you mean one of the following overloads?
	pa.foo :: proc(alpha: int, beta: string) at main.odin(3:1)
	pa.bar :: proc(alpha: bool, beta: rune)  at main.odin(4:1)
```

The second bullet is the operand for `beta`, correctly typed, but labelled `alpha`. With N named
arguments, all N are labelled with the name of the first.

## Cause

`src/check_expr.cpp:7651-7675`:

```cpp
	auto print_argument_types = [&]() {
		error_line("\tGiven argument types:\n");
		isize i = 0;
		for (Operand const &o : positional_operands) {
			gbString type = type_to_string(o.type);
			defer (gb_string_free(type));
			error_line("\t • %s\n", type);
		}
		for (Operand const &o : named_operands) {
			gbString type = type_to_string(o.type);
			defer (gb_string_free(type));

			if (i < ce->split_args->named.count) {
				Ast *named_field = ce->split_args->named[i];
				ast_node(fv, FieldValue, named_field);

				gbString field = expr_to_string(fv->field);
				defer (gb_string_free(field));

				error_line("\t • %s = %s\n", field, type);
			} else {
				error_line("\t • %s\n", type);
			}
		}
	};
```

`i` is declared once, before the positional loop, and **never incremented anywhere**. So
`ce->split_args->named[i]` is always `named[0]`, and the `i < count` guard only ever fails when
there are no named arguments at all.

Both loops iterate by range-`for` over the operand arrays, so there is no other cursor that could
be advancing it.

## Suggested fix

```diff
 		for (Operand const &o : named_operands) {
 			gbString type = type_to_string(o.type);
 			defer (gb_string_free(type));
 
 			if (i < ce->split_args->named.count) {
 				Ast *named_field = ce->split_args->named[i];
 				ast_node(fv, FieldValue, named_field);
 
 				gbString field = expr_to_string(fv->field);
 				defer (gb_string_free(field));
 
 				error_line("\t • %s = %s\n", field, type);
 			} else {
 				error_line("\t • %s\n", type);
 			}
+			i += 1;
 		}
```

The declaration of `i` above the *positional* loop suggests it may once have been a shared cursor;
if `named_operands` and `split_args->named` are guaranteed parallel, an indexed loop over one of
them would make the invariant obvious and remove the guard entirely.

## Second call site

The same lambda is invoked from two places — `src/check_expr.cpp:7684` and `:7939` — so both the
"No procedures or ambiguous call" and the other diagnostic that prints this block are affected.

## How this was found

Differential testing of a self-hosted Odin checker against the reference compiler; the port labels
each named argument with its own name, and the diff pointed straight at the missing increment.
