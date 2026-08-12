package main
B :: bit_field u32 {
	a: u16le | 5,
	b: u16be | 5,
}
main :: proc() { b: B; _ = b }
