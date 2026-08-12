package quatrej
// REJECT half: the three diagnostics the port had none of.
main :: proc() {
	a: f32 = 1
	b: f64 = 1
	e: f32le = 1
	i: int = 1
	q1 := quaternion(w=a, x=b, y=a, z=a)   // mismatched component types
	q2 := quaternion(w=i, x=i, y=i, z=i)   // not floating point
	q3 := quaternion(w=e, x=e, y=e, z=e)   // endian-specific
	_, _, _ = q1, q2, q3
}
