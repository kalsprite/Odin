package union_bad
U :: union { int, f32 }
main :: proc() {
	u: U = 1
	s := u.(string)
	v := u.(int)
	w: U = "x"
	_ = s; _ = v; _ = w
}
