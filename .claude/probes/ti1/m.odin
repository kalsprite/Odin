package ti1

import "base:intrinsics"

Foo :: struct { a: int }

main :: proc() {
	// pass a TYPE where a value expression is expected
	a := intrinsics.type_is_superset_of(Foo, int)
	b := len(Foo)
	_ = a; _ = b
}
