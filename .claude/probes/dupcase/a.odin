package a
// A typeid switch with a case expression that is NEITHER a type NOR a typeid.
// C++ (check_stmt.cpp:1303) branches only on `y.mode == Addressing_Type`; since 5 is a Constant,
// it takes the ELSE branch and runs convert_to_typed + check_comparison, which must reject
// comparing a typeid against an integer.
// The port gates that whole else-branch on `!is_typeid_switch` (check_stmt.odin:2210), so in a
// typeid switch it runs NEITHER -- predicting silence.
f :: proc(tid: typeid) -> int {
	switch tid {
	case 5: return 1
	}
	return 0
}
main :: proc() {}
