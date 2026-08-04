package typeintrin
import "base:intrinsics"
main :: proc() {
	a := intrinsics.type_is_integer(1)
	b := intrinsics.type_has_nil(2)
	c: intrinsics.type_base_type(3)
	d: intrinsics.type_core_type(4)
	e: intrinsics.type_elem_type(5)
	f := intrinsics.type_is_integer(int, int)
	g := intrinsics.type_is_integer()
	_ = a; _ = b; _ = c; _ = d; _ = e; _ = f; _ = g
}
