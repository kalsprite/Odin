package simdmsb

import "base:intrinsics"

main :: proc() {
	a: [4]f32
	// got-form site (check_builtin.cpp:1430)
	x := intrinsics.simd_extract_msbs(a)
	y := intrinsics.simd_extract_lsbs(a)
	// deliberately BARE neighbour (check_builtin.cpp:1382) -- must stay bare
	z := intrinsics.simd_reduce_or(a)
	_ = x; _ = y; _ = z
}
