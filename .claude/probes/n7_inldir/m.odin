package main
main :: proc() {
	a := #force_inline #config(SOMEFLAG, 1)
	_ = a
}
