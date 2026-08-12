package main
x := 3
B :: bit_field u32 {
	a: u8 | x,
	a: u8 | 3,
}
main :: proc() { b: B; _ = b }
