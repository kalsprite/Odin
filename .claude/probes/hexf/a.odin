package a
// f64 bit pattern for +Inf, exactly the form core/c/libc/math.odin uses.
INF  :: 0h7ff00000_00000000
// f16 (4 digits) and f32 (8 digits) forms.
H16  :: 0h3C00
H32  :: 0h3f800000
// A truncating use forces the checker to PRINT the value/type it believes in
// (the technique that made #646 conclusive).
X :: int(H32)
main :: proc() {}
