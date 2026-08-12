package p664a

@(entry_point_only)
target :: proc(x: int) {}

caller :: proc() {
	target("wrong")
}

main :: proc() {
	caller()
}
