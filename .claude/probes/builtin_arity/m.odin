package builtin_arity
main :: proc() {
	a := make([]int)
	b := len()
	c := len(1, 2)
	d: [dynamic]int
	append(&d)
	e := cap("x")
	_ = a; _ = b; _ = c; _ = e
}
