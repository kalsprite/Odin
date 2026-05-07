package complex_union_repro

// Minimal reproduction: complex() builtin panics when return type is union
// Run: odin build complex_union_repro.odin -file
// Expected: src/types.cpp(1863): Panic: Invalid complex type

Value :: union {
	bool,
	f64,
	complex128,
}

// This panics during code generation
make_complex :: proc(r, i: f64) -> Value {
	return complex(r, i)
}

// Workaround: explicit type
make_complex_fixed :: proc(r, i: f64) -> Value {
	c: complex128 = complex(r, i)
	return c
}

main :: proc() {
	v := make_complex(1.0, 2.0)
	_ = v
}
