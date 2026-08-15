package rtti_expr

// #823, the EXPRESSION arm specifically: the value of `g()` is an `any`-typed expression that
// is not a declaration and not a type usage, so ONLY the check_expr_base tail can report it.
// rtti_decl reaches the same tail via a declaration; this one isolates the expression path.
// Pre-fix the port emitted 1 (the "Use of a type" line from check_type) and missed the second.
g :: proc() -> any { return nil }
main :: proc() { g() }
