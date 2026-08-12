package vetmap

outer := 1

shadow_test :: proc() {
	outer := 2
	_ = outer
}

unused_test :: proc() {
	a := 1
}

unused_param_free :: proc() {
	b: int
}
