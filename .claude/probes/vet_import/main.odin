package vetctl

import "core:strings"

Point :: struct {
	x: int,
	y: int,
}

f :: proc() {
	unused_local := 42
	p: Point
	_ = p
}

// Entry point so the oracle does not report "Undefined entry point procedure".
// Appended at the END so the diagnostic line numbers above stay stable.
main :: proc() {}
