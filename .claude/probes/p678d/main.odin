package main
B :: bit_field u32le {
	a: u16be | 5,
	b: u16be | 99,
}
main :: proc() { b: B; _ = b }
