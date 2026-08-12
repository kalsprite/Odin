package mxidx

M :: matrix[2, 2]f32
C :: M{1, 2, 3, 4}

get :: proc() -> M { return C }

main :: proc() {
	m: M
	s: string
	i := 1

	_ = m["a", "b"]   // both indices non-integer: C++ checks BOTH
	_ = m[5, 7]       // both out of bounds: C++ reports BOTH
	_ = s[1, 1]       // matrix indexing on a non-matrix
	_ = C[i, i]       // constant matrix, non-constant indices
	get()[0, 0] = 1   // non-addressable matrix element: assignable?
}
