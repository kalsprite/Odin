package qmag
// ACCEPT half. The two typed-constant folds are the LIVE OVER-REJECTION #642 closed;
// everything else is a control that already passed.
Q2 :: quaternion256(3)
Q1 :: quaternion128(3)
#assert(jmag(Q2) == 0)
#assert(kmag(Q1) == 0)
#assert(real(3i) == 0)
#assert(imag(3i) == 3)
#assert(real(3j) == 0)
#assert(imag(3j) == 0)
C :: complex64(3)
#assert(imag(C) == 0)

main :: proc() {
	q256: quaternion256
	q128: quaternion128
	q64:  quaternion64
	a: f64 = jmag(q256)
	b: f32 = jmag(q128)
	c: f16 = kmag(q64)
	_, _, _ = a, b, c
}
