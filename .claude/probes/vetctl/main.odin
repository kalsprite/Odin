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
