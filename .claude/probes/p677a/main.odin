package main
B :: bit_field u32 {
	a: u8     | 3,
	a: string | 4,
}
main :: proc() { b: B; _ = b }
