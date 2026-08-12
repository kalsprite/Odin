package main

E :: enum { A, B }

f :: proc(a: $T, #any_int n: int) -> T {
	bad := nonexistent_name_in_body
	_ = bad
	return a
}

main :: proc() {
	f(1, E.A)
}
