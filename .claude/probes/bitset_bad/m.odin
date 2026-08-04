package bitset_bad
E :: enum { A, B }
S :: bit_set[E]
main :: proc() {
	s: S = {.A, .C}
	t: bit_set[int] = {}
	u: S = 3
	_ = s; _ = t; _ = u
}
