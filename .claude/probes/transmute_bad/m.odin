package transmute_bad
main :: proc() {
	a: u32 = 1
	b := transmute(u64)a
	c := transmute(f32)a
	d := transmute(int)"x"
	_ = b; _ = c; _ = d
}
