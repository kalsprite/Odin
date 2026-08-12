package probe_size_ctl
S  :: struct { a: int, b: int }
RU :: struct #raw_union { a: int, b: [2]int }
PK :: struct #packed { a: u8, b: u32 }
#assert(size_of(S)  == 99)
#assert(size_of(RU) == 99)
#assert(size_of(PK) == 5)
#assert(offset_of(S, b) == 8)
main :: proc() {}
