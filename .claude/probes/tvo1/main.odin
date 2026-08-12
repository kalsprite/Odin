package a
import "base:intrinsics"
main :: proc() { x := intrinsics.type_is_variant_of(1, int); _ = x }
