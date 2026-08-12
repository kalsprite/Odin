package m
f :: proc() -> int { return 1 }
X :: #config(FOO, (f()))
main :: proc() { _ = X }
