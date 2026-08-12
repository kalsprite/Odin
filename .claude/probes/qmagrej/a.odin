package qmagrej
// REJECT half. The first two are UPSTREAM #642: jmag/kmag can never succeed on an untyped
// CONSTANT quaternion, because C++ clobbers the type to untyped complex before testing it.
A :: jmag(3j)
B :: kmag(3k)
C :: jmag(3)

main :: proc() {
	c: complex128
	i: int
	x := jmag(c)
	y := jmag(i)
	_, _ = x, y
}
