package main
main :: proc() {
	loop: for i in 0..<3 {
		x := loop
		_ = x
		_ = i
	}
}
