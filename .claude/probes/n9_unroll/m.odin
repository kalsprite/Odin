package main
main :: proc() {
	s: []int
	#unroll for x in s {
		_ = x
	}
}
