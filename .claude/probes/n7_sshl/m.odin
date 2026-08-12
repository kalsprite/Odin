package main
main :: proc() {
	v: #simd[4]i32
	s: i32 = 2
	w := v << s
	_ = w
}
