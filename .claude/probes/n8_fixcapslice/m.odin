package main
main :: proc() {
	f :: proc() -> [dynamic; 4]int { return {} }
	s := f()[:]
	_ = s
}
