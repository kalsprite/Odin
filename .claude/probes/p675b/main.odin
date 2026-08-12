package main

f :: proc(a: $T, n: int) -> T {
	bad := nonexistent_name_in_body
	_ = bad
	return a
}

main :: proc() {
	f(1, "hi")
}
