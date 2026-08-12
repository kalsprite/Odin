package pandep
import "./dep"
main :: proc() {
	x: int = "not an int"
	y: string = 42
	_ = x; _ = y; _ = dep.VALUE
}
