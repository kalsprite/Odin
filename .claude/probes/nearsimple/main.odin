package nearsimple

import "base:intrinsics"

BF :: bit_field u32 { a: u8 | 3, b: u8 | 5 }

// gap (a): every one of these carries SimpleCompare|Numeric in C++
#assert(intrinsics.type_is_nearly_simple_compare(rune))
#assert(intrinsics.type_is_nearly_simple_compare(quaternion64))
#assert(intrinsics.type_is_nearly_simple_compare(u32le))
#assert(intrinsics.type_is_nearly_simple_compare(i64be))
#assert(intrinsics.type_is_nearly_simple_compare(b8))
#assert(intrinsics.type_is_nearly_simple_compare(b32))
// gap (b): C++'s true-set includes Type_BitField
#assert(intrinsics.type_is_nearly_simple_compare(BF))
// control: plainly true in both, before and after
#assert(intrinsics.type_is_nearly_simple_compare(u32))

// the other consumer: `struct #simple` requires every field nearly-simple
S1 :: struct #simple { r: rune, q: quaternion64, e: u32le, f: BF }

main :: proc() {}
