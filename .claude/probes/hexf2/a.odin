package a
// 0h3fb999999999999a is 0.1 as an f64 bit pattern -- NON-integral, so int() must reject it and
// the diagnostic has to PRINT the value the checker actually decoded.
P :: 0h3fb999999999999a
X :: int(P)
// Independent value check: if the decode is right these hold; if the value is nil/0 they fail.
#assert(0h3C00 == 1.0)
#assert(0h3f800000 == 1.0)
#assert(P > 0.09 && P < 0.11)
main :: proc() {}
