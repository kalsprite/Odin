package distinct_bad
My :: distinct int
main :: proc() {
	m: My = 1
	i: int = m
	m2: My = i
	_ = i; _ = m2
}
