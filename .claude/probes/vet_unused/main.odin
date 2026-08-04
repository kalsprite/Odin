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

// Entry point so the oracle does not report "Undefined entry point procedure".
// Appended at the END so the diagnostic line numbers above stay stable.
main :: proc() {}
