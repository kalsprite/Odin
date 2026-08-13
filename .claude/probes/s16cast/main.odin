package m752c
// "héllo": 6 UTF-8 bytes, 5 UTF-16 code units.
V: string : "héllo"
W :: string16(V)
#assert(len(W) == 5)   // must be UTF-16 UNITS after the cast re-expresses the value
main :: proc() { _ = W }
