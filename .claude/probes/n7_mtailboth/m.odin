package main
main :: proc() {
	f := #force_inline #force_no_inline proc() {}
	_ = f
}
