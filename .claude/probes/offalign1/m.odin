package m
S :: struct #min_field_align(8) { a: u8, b: u8 }
X :: offset_of(S, b)
#assert(X == 8)
#assert(size_of(S) == 16)
main :: proc() {}
