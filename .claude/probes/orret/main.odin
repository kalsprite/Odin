package orret

f :: proc() {}

// No_Value operand: `f()` produces nothing. C++ enters check_or_return_expr through
// check_multi_expr_with_type_hint (check_expr.cpp:10185), whose switch emits
// error_operand_no_value and sets Addressing_Invalid, arming the bail on the next line.
g :: proc() -> bool {
	f() or_return
	return true
}

// Type operand: `int` is a type, not an expression -> error_operand_not_expression.
h :: proc() -> bool {
	int or_return
	return true
}

main :: proc() {
	_ = g
	_ = h
}
