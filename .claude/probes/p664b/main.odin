package p664b

@(entry_point_only)
target :: proc() {}

caller :: proc() {
	target()
}

main :: proc() {
	caller()
}
