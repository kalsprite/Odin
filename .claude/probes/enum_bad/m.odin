package enum_bad
E :: enum { A, B, C }
main :: proc() {
	e: E = .D
	x: int = E.A
	f: f32 = .A
	_ = e; _ = x; _ = f
}
