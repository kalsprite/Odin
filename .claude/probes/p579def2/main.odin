package m
h1 :: proc(x: int)         -> int { return 1 }
h2 :: proc(x: int, y := 0) -> f32 { return 2 }
h :: proc{h1, h2}
main :: proc() {
	r := h(1)
	bad: bool = r
	_ = bad
}
