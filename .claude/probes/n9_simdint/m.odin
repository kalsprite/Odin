package main
import "core:simd"
main :: proc() {
	v: #simd[4]i32
	r := simd.reduce_any(v)
	_ = r
}
