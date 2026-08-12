package m
f :: proc() { x := #defined(); _ = x }
main :: proc() { f() }
