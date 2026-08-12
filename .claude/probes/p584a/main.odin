package p584a
main :: proc() {
	// (a) non-constant index into a constant  -> C++ 12014 "index < 0" arm
	S :: "hello"
	i := 1
	_ = S[i]
	// (d) failed check_index_value, then a use that would cascade
	a: [4]int
	b: string = a[10]
	_ = b
}
