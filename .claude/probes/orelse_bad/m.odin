package orelse_bad
f :: proc() -> (int, bool) { return 1, true }
main :: proc() {
	a := f() or_else 2
	b := f() or_else "x"
	c := 1 or_else 2
	_ = a; _ = b; _ = c
}
