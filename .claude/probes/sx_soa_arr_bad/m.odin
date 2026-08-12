package m
S :: struct { a: int }
main :: proc() {
	x: #soa[4]S
	_ = x.nope
}
