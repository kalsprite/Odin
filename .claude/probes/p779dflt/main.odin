package p779

U :: union {
	int,
	f32,
}

S :: struct {
	b: int,
}

main :: proc() {
	u: U = 1
	a: S

	// Non-identifier LHS (a selector) AND two default clauses. C++ runs the case-clause loop
	// FIRST -- emitting "Multiple default clauses" -- and only then rejects the LHS, so both
	// diagnostics appear. An early return before the loop would emit only the identifier error.
	switch a.b in u {
	case int:
	case:
	case:
	}
	_ = a
}
