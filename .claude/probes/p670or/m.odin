package m
f :: proc() { x := #load("nope.txt") or_else g(); _ = x }
g :: proc() -> []byte { return nil }
main :: proc() { f() }
