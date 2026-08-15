package p828poly

foo :: proc($T: typeid, x: T, y: f64) -> T {
	#assert(size_of(T) == 999)
	return x
}

main :: proc() {
	_ = foo(i64, 3, 1.0)
}
