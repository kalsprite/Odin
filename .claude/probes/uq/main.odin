package uq

// Does a j/k-suffixed literal actually produce an UNTYPED QUATERNION operand,
// and what happens converting it toward a non-quaternion numeric target?
a: quaternion128 = 1 + 2i + 3j + 4k   // control: quaternion target, must work in both
b: complex128    = 3j                  // untyped quaternion -> COMPLEX target
c: f64           = 3j                  // untyped quaternion -> FLOAT target
d: int           = 3j                  // untyped quaternion -> INTEGER target

main :: proc() {}
