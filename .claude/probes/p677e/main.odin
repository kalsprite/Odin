package main
B :: bit_field u32 {
	a: u8 | "x",
}
main :: proc() { b: B; _ = b }
