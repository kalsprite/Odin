package quat
// ACCEPT half. The constant folds are #643 (Jon's report); the width derivations are the
// over-rejection the hardcoded quaternion128 caused.
Q :: quaternion(w=1.5, x=2.5, y=3.5, z=4.5)
#assert(real(Q) == 1.5)
#assert(imag(Q) == 2.5)
#assert(jmag(Q) == 3.5)
#assert(kmag(Q) == 4.5)
I :: quaternion(w=1, x=0, y=7, z=0)   // integer literals: the untyped-float promotion
#assert(real(I) == 1)
#assert(jmag(I) == 7)

main :: proc() {
	a16: f16 = 1
	a32: f32 = 1
	a64: f64 = 1
	q16: quaternion64  = quaternion(w=a16, x=a16, y=a16, z=a16)
	q32: quaternion128 = quaternion(w=a32, x=a32, y=a32, z=a32)
	q64: quaternion256 = quaternion(w=a64, x=a64, y=a64, z=a64)

	// THE MIXED SHAPE: one TYPED component with untyped integer literals. This is the ordinary
	// form in real code -- it appears four times in this checker's own exact_value.odin -- and it
	// is what C++'s "first typed value dictates the type for all untyped values" step
	// (check_builtin.cpp:3684-3696) exists for. Omitting that step was a regression the root suite
	// caught and these probes did not, because every earlier probe used either all-constant or
	// all-same-typed arguments.
	m1 := quaternion(w=a64, x=0, y=0, z=0)
	m2 := quaternion(w=a32, x=0, y=0, z=0)
	m3 := quaternion(w=0, x=0, y=0, z=a64)   // typed component LAST
	m4 := quaternion(w=a64, x=a64, y=0, z=0) // two typed, two untyped
	_, _, _ = q16, q32, q64
	_, _, _, _ = m1, m2, m3, m4
}
