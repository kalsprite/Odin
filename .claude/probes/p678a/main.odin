package main
B :: bit_field u32le {
	a: u16be | 5,
}
main :: proc() { b: B; _ = b }
