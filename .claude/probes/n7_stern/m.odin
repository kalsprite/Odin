package main
main :: proc() {
	c: #simd[4]bool
	x := c ? 1 : 2
	_ = x
}
