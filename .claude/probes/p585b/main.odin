package p585b
Color :: enum{R, G, B, A}
E :: [Color]int{.R = 1, .G = 2}
X :: E[.A]
main :: proc() { _ = X }
