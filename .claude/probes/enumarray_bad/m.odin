package enumarray_bad
E :: enum { A, B }
main :: proc() {
	a: [E]int
	a[.C] = 1
	b: [E]int = {.A = 1}
	c: [int]int
	_ = a; _ = b; _ = c
}
