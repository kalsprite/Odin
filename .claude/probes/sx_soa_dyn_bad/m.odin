package m
S :: struct { a: int }
main :: proc() {
	x: #soa[dynamic]S
	_ = x.nope
}
