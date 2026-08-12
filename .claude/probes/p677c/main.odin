package main
B :: bit_field u32 {
	a: u8 | 3,
	b: u8 | 5,
}
main :: proc() { b: B; _ = b }
