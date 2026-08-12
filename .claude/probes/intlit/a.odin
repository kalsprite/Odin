package intlit
// #225: the exponent branch of big_int_from_string. Upstream replaced two GB_ASSERTs with
// early `success = false` returns, so each of these is now a diagnosable literal rather than
// a compiler abort. One line per rejected form; the accepted forms are in b.odin.
A :: 0b1e5
B :: 0b1E5
C :: 0b1e
D :: 0o1e0
E :: 0z1e1
F :: 0d1e-5
G :: 0d1e
H :: 0d1e+5
I :: 1e
J :: 1e309
K :: 0b19
