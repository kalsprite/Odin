package retmismatch
f :: proc() -> int { return "x" }
g :: proc() -> (int, string) { return 1 }
h :: proc() -> int { }
main :: proc() { _ = f(); _, _ = g(); _ = h() }
