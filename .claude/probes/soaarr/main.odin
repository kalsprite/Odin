package n754
main :: proc() {
	soa: #soa[4][3]f32
	x := soa[0][1]
	p := &soa[0][1]
	_, _ = x, p
}
