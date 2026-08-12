package main
main :: proc() {
	a := #force_inline len("abc")
	b := #force_no_inline len("abc")
	_ = a; _ = b
}
