package main
main :: proc() {
	a := [3]int{1, 2, 3}
	#unroll for x in a {
		_ = x
	}
}
