package m
f :: proc() { x := #location; _ = x }
main :: proc() { f() }
