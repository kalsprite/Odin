package bitfield_bad
B :: bit_field u8 {
	a: int | 3,
	b: int | 9,
}
C :: bit_field string { a: int | 1 }
main :: proc() { _ = B{}; _ = C{} }
