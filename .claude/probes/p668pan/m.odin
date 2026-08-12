package m
f :: proc() { x := #panic; _ = x }
main :: proc() { f() }
