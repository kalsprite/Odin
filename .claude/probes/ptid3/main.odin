package ptid3
// $T is bound as a CONSTANT typeid at instantiation, so `int == T` reaches
// C++ check_comparison's fold branch (check_expr.cpp:3210-3218).
f :: proc($T: typeid) {
	#assert(int == T)
}
g :: proc($T: typeid) {
	#assert(int != T)
}
main :: proc() {
	f(int)
	g(f32)
}
