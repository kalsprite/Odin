package callarity
f :: proc(a: int, b: string) {}
g :: proc(a: int, b := 2) {}
main :: proc() {
	f(1)
	f(1, 2)
	f(1, "x", 3)
	g()
	g(1, 2, 3)
}
