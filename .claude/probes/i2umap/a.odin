package i2umap
import "base:intrinsics"

// ACCEPT half. Every line is a control except the rune one.
A :: intrinsics.type_integer_to_unsigned(i32)
B :: intrinsics.type_integer_to_signed(u32)
C :: intrinsics.type_integer_to_unsigned(int)
D :: intrinsics.type_integer_to_signed(uint)
E :: intrinsics.type_integer_to_unsigned(i32le)
F :: intrinsics.type_integer_to_signed(u64be)
G :: intrinsics.type_integer_to_unsigned(i128)
// The upstream quirk: rune passes the signed-integer gate and its enum successor is f16.
H :: intrinsics.type_integer_to_unsigned(rune)

#assert(A == u32)
#assert(B == i32)
#assert(C == uint)
#assert(D == int)
#assert(E == u32le)
#assert(F == i64be)
#assert(G == u128)
#assert(H == f16)

main :: proc() {}
