package main
main :: proc() {
	f := #must_tail proc() {}
	_ = f
}
