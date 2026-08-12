package i2ureject
import "base:intrinsics"

// REJECT half: the four gates the port had none of.
P :: intrinsics.type_integer_to_signed(uintptr)   // uintptr has no signed mapping
Q :: intrinsics.type_integer_to_unsigned(u32)     // already unsigned
R :: intrinsics.type_integer_to_signed(i32)       // already signed
T :: intrinsics.type_integer_to_unsigned(f32)     // not an integer
U :: intrinsics.type_integer_to_unsigned(bool)    // not an integer
V :: intrinsics.type_integer_to_unsigned(3)       // not a type

main :: proc() {}
