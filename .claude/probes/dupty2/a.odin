package a
// #298's shape: duplicate TYPE cases in a typeid switch. This exercises the y.mode == .Type branch
// and add_type_switch_case -- the path #652 must NOT have disturbed.
f :: proc(tid: typeid) -> int {
	switch tid {
	case int: return 1
	case int: return 2
	}
	return 0
}
// And a polymorphic type as a case, which C++ rejects with "Invalid type for case clause".
P :: struct($T: typeid) { x: T }
g :: proc(tid: typeid) -> int {
	switch tid {
	case P: return 1
	}
	return 0
}
main :: proc() {}
