package soa_bad
S :: struct { a: int, b: f32 }
main :: proc() {
	x: #soa[]S
	y: #soa[]int
	z := x.nope
	_ = y; _ = z
}
