package p781

U :: union {
	int,
	f32,
	bool,
}

main :: proc() {
	u: U = 1
	p := &u

	// Pointer subject. C++ (check_stmt.cpp:1586-1591) sets case_type = type_deref(x.type)
	// for every clause that is not exactly one type, so `v` is U -- not ^U -- in the
	// multi-type clause and in the default clause.
	switch v in p {
	case int:
		x: int = v // exactly one type: both bind `v` as int
		_ = x
	case f32, bool:
		y: U = v // multi-type clause: C++ binds `v` as U
		_ = y
	case:
		z: U = v // default clause: C++ binds `v` as U
		_ = z
	}
}
