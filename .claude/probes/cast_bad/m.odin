package cast_bad
main :: proc() {
	s := "x"
	a := cast(int)s
	b := transmute(f64)1
	c := s.(int)
	_ = a; _ = b; _ = c
}
