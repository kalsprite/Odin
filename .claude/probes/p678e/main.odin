package main
B :: bit_field u32le {
	a: u16le | 5,
	b: u16le | 5,
}
main :: proc() { b: B; _ = b }
