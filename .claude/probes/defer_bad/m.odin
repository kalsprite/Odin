package defer_bad
main :: proc() {
	defer return
	for i in 0..<3 {
		defer break
	}
}
