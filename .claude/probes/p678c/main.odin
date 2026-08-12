package main
B :: bit_field u32le {
	a: bool | 1,
	b: u8   | 3,
}
main :: proc() { b: B; _ = b }
