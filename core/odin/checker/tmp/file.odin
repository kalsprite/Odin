package repro

Value :: union {
	bool,
	f64,
	complex128,
}

make_complex :: proc(r, i: f64) -> Value {
	return complex(r, i)  // PANIC
}

main :: proc() {
	_ = make_complex(1.0, 2.0)
}