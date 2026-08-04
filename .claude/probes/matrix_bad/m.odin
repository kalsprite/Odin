package matrix_bad
main :: proc() {
	m: matrix[2,3]f32
	n: matrix[3,2]f32
	a := m * m
	b: matrix[2,2]string
	c := m + n
	_ = a; _ = b; _ = c
}
