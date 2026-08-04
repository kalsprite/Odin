package bitfield_over64
B :: bit_field u128 {
	a: u128 | 65,
	b: int  | 0,
	c: int  | -1,
}
main :: proc() { _ = B{} }
