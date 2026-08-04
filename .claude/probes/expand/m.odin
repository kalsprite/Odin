package expand
V :: struct { x, y, z: f32 }
takes3 :: proc(a, b, c: f32) {}
takes8 :: proc(a, b, c, d, e, f, g, h: int) {}
main :: proc() {
	v := V{1, 2, 3}
	takes3(**v)
	arr := [8]int{1,2,3,4,5,6,7,8}
	takes8(**arr)
	one := [1]int{5}
	single: int = **one
	_ = single
}
