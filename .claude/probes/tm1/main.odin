package a
import "base:intrinsics"
main :: proc() { T :: intrinsics.type_merge(1, int); _ = T{} }
