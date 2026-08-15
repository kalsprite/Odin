package m
S :: struct #min_field_align(2) #max_field_align(4) { a: u8, b: u64, c: u8, d: u16 }
#assert(offset_of(S, b) == 4)
#assert(offset_of(S, c) == 12)
#assert(offset_of(S, d) == 14)
main :: proc() {}
