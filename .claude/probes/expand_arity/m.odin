package expand_arity
V :: struct { x, y, z: f32 }
takes3 :: proc(a, b, c: f32) {}
main :: proc() {
	v := V{1, 2, 3}
	arr := [8]int{1,2,3,4,5,6,7,8}
	takes3(**arr)
	takes3(**v, 1)
	_ = v
}
