package layout_bad
S  :: struct { a: int, b: int }
RU :: struct #raw_union { a: int, b: [2]int }
#assert(size_of(S)  == 99)
#assert(size_of(RU) == 99)
main :: proc() {}
