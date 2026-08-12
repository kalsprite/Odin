package sel288b
T :: struct { field: int }
noargs :: proc() {}
main :: proc() {
	t: T
	t->noargs()         // C++ check_expr.cpp:11789 -- zero-parameter callee
	_ = t
}
