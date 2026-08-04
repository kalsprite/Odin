package const_ovf
main :: proc() {
	a: u8 = 256
	b: i8 = -129
	c: u32 = -1
	d :: 1 / 0
	_ = a; _ = b; _ = c; _ = d
}
