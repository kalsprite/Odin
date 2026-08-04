package whereclause
import "base:intrinsics"
f :: proc(x: $T) -> T where intrinsics.type_is_integer(T) { return x }
g :: proc(x: $T) -> T where 1 { return x }
main :: proc() {
	_ = f(1)
	_ = f("x")
	_ = g(1)
}
