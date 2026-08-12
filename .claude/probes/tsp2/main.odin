package a
import "base:intrinsics"
main :: proc() { x := intrinsics.type_is_specialization_of(1, int); _ = x }
