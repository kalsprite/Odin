package m
f :: proc(x: int) -> int { y := 0; switch x { case 1: y = 1; case: y = 2; case: y = 3; y = 4 }; return y }
main :: proc() {}
