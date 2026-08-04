package orreturn_bad
E :: enum { None, Bad }
f :: proc() -> (int, E) { return 1, .None }
g :: proc() -> int {
	a := f() or_return
	return a
}
main :: proc() { _ = g() }
