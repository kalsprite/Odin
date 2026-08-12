package intlit
// The accepted contrast set: these must produce NO diagnostic.
//   0x1e5   -- `e` is a hex digit, not an exponent marker
//   0d1e5   -- explicit decimal prefix with a well-formed exponent
//   1e5ff   -- a malformed exponent TAIL is still accepted; big_int_exp_u64 clobbers
//              the failure flag, and #225's fix works by returning early, which this
//              path never does
L :: 0x1e5
M :: 0d1e5
N :: 0d_1e5
O :: 1e5ff
P :: 0d1e5ff
Q :: 1e308
R :: 1e+5
S :: 0h1234
main :: proc() {}
