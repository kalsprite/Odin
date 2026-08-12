package m
S :: struct { a: int, b: f32 }
main :: proc() {
	x: #soa[]S
	z := x.nope
	_ = z
}
