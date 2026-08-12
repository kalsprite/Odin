package a
import "base:intrinsics"
main :: proc() { x := intrinsics.type_is_superset_of(1, int); _ = x }
