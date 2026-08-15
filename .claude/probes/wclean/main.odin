package a
f :: proc(x: $S) -> int where size_of(S) == 999 { return 1 }
main :: proc() { _ = f(1) }
