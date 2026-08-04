package deref_bad
main :: proc() {
	x := 1
	y := x^
	p := &x
	z := p.field
	_ = y; _ = z
}
