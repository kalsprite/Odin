package ternary_bad
main :: proc() {
	a := true ? 1 : "x"
	b := 1 ? 1 : 2
	c := true if 1 else 2
	_ = a; _ = b; _ = c
}
