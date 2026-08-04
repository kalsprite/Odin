package assert_bad
main :: proc() {
	#assert(1 == 2)
	#assert("x")
	x := 1
	#assert(x == 1)
}
