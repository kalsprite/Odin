package alignattr_bad
A :: struct #align(3) { x: int }
B :: struct #align(0) { x: int }
C :: struct #packed #align(8) { x: int }
main :: proc() { _ = A{}; _ = B{}; _ = C{} }
