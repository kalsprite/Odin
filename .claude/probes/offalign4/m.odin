package m
I :: struct #max_field_align(1) { x: u32, y: u32 }
S :: struct { a: u8, b: I }
#assert(offset_of(I, y) == 4)
#assert(offset_of(S, b) == 1)
main :: proc() {}
