package m
S :: struct #max_field_align(2) { a: u8, b: u64 }
X :: offset_of(S, b)
#assert(X == 2)
main :: proc() {}
