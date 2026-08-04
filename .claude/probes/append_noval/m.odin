package append_noval
main :: proc() {
	d: [dynamic]int
	append(&d)
	append()
	append(&d, "x")
	_ = d
}
