package complexq_bad
main :: proc() {
	c: complex64 = 1
	q: quaternion128 = 2
	x := real(c)
	y := imag(q)
	z := real(1)
	w := conj("x")
	_ = x; _ = y; _ = z; _ = w
}
