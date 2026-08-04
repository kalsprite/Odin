package complit_bad
S :: struct { a: int, b: string }
main :: proc() {
	s := S{1, 2}
	t := S{a = 1, c = 2}
	u := S{1, "x", 3}
	v := [2]int{1,2,3}
	_ = s; _ = t; _ = u; _ = v
}
