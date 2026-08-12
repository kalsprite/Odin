package m
v1 :: proc(x: int)            -> int { return 1 }
v2 :: proc(x: int, ys: ..int) -> f32 { return 2 }
v :: proc{v1, v2}
main :: proc() {
	r := v(1)
	bad: bool = r
	_ = bad
}
