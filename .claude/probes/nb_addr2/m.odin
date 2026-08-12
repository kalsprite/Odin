package main
main :: proc() {
	a := &b
	b := &a
	_ = a
	_ = b
}
