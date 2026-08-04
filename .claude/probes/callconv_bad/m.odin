package callconv_bad
f :: proc "nonesuch" () {}
g :: proc "c" (x: int) -> int { return x }
main :: proc() { f(); _ = g(1) }
