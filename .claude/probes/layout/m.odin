package layout
S  :: struct { a: int, b: int }
RU :: struct #raw_union { a: int, b: [2]int }
PK :: struct #packed { a: u8, b: u32 }
#assert(size_of(S)  == 16)
#assert(size_of(RU) == 16)
#assert(size_of(PK) == 5)
#assert(offset_of(S, b) == 8)
main :: proc() {}
