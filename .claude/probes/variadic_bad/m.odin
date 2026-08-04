package variadic_bad
f :: proc(xs: ..int) {}
g :: proc(a: int, xs: ..string) {}
main :: proc() {
	f(1, 2, "x")
	g("a", "b")
	xs := []int{1,2}
	f(..xs)
	f(..1)
}
