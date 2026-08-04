package bitfield_dup
B :: bit_field u32 {
	a: int | 3,
	a: int | 4,
	b: int | "x",
}
main :: proc() { _ = B{} }
