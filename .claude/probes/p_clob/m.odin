package p_clob
vdot :: proc(a, b: $T/[$N]$E) -> E {
	r: E
	for i in 0..<N { r += a[i]*b[i] }
	return r
}
main :: proc() {
	x: [3]f32
	y: [4]f32
	z: [3]f64
	_ = vdot(x, x)
	_ = vdot(y, y)
	_ = vdot(z, z)
}
