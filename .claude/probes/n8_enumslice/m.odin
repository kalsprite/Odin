package main
E :: enum{A, B}
main :: proc() {
	arr: [E]int
	s := arr[:]
	_ = s
}
