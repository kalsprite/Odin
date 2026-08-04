package rawunion_bad
R :: struct #raw_union { a: int, b: f32 }
main :: proc() {
	r: R
	r.a = 1
	_ = r.c
	s: struct #raw_union #packed { x: int }
	_ = s
}
