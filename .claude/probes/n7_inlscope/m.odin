package main
main :: proc() {
	a := #force_inline #load("missing_one.bin")
	b := #load("missing_two.bin")
	_ = a; _ = b
}
