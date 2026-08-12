package optok
f :: proc() -> (int, bool) #optional_ok { return 1, true }
main :: proc() {
	a := f()
	b, c := f()
	d, e, g := f()
	_ = a; _ = b; _ = c; _ = d; _ = e; _ = g
}
