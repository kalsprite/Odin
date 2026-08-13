package s16len
// #7268's FIRST half: a string16 constant held UTF-8 bytes, so compile-time len
// disagreed with runtime len. "hello" + e-acute is 6 UTF-8 bytes, 5 UTF-16 units.
S: string16 : "héllo"
#assert(len(S) == 5)   // UTF-16 code units -- what #7268 makes true
main :: proc() {}
