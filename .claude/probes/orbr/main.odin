package orbr

f :: proc() {}

// Same helper, the other sibling: check_or_branch_expr, C++ check_expr.cpp:10268.
main :: proc() {
	for i := 0; i < 1; i += 1 {
		f() or_break
	}
	for i := 0; i < 1; i += 1 {
		int or_continue
	}
}
