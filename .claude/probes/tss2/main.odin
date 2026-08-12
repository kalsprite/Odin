package a
import "base:intrinsics"
main :: proc() { x := intrinsics.type_is_superset_of(int, 1); _ = x }
