package autocast_bad
main :: proc() {
	x: int = 1
	y: f32 = auto_cast x
	s: string = auto_cast x
	z := auto_cast x
	_ = y; _ = s; _ = z
}
