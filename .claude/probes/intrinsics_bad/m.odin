package intrinsics_bad
import "base:intrinsics"
main :: proc() {
	a := intrinsics.type_is_integer(int)
	b := intrinsics.type_is_integer(1)
	c := intrinsics.nonexistent_thing(int)
	_ = a; _ = b; _ = c
}
