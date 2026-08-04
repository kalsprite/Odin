package namedret_bad
f :: proc() -> (a: int, b: string) {
	a = 1
	return
}
g :: proc() -> (a: int) { return 1, 2 }
h :: proc() -> (a: int, a: int) { return }
main :: proc() { _, _ = f(); _ = g(); _, _ = h() }
