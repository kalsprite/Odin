package emptycl
// #634. The zero value of an EMPTY compound literal of a constant type. C++
// (check_expr.cpp:11613-11634) walks an ordered chain of FLAG tests; the port hand-listed kinds
// and omitted string16/cstring16, which carry BasicFlag_String in BOTH tables. Phrased as
// CONSTANT assertions so the stored VALUE decides the outcome -- a wrong value is otherwise
// silent, which is why no gate saw this.
//
// NO QUATERNION COMPARISON HERE, DELIBERATELY. `#assert(quaternion128{} == 0)` ABORTS the
// reference compiler (GB_PANIC exact_value.cpp:1092, 5/5) -- compare_exact_values has no
// ExactValue_Quaternion arm. That is upstream #635; a probe that crashes the oracle is
// UNMEASURABLE, not a finding, so it is kept out of the corpus and repro'd in $S/qcrash.

// Boolean arm
B    :: bool{};          #assert(B == false)
B32  :: b32{};           #assert(B32 == false)
// Integer arm (endian variants carry the same flag)
I    :: int{};           #assert(I == 0)
U8   :: u8{};            #assert(U8 == 0)
I64B :: i64be{};         #assert(I64B == 0)
// Float arm
F32  :: f32{};           #assert(F32 == 0)
F16L :: f16le{};         #assert(F16L == 0)
// Complex arm (complex HAS a comparison arm in both; quaternion does not -- see above)
C64  :: complex64{};     #assert(C64 == 0)
// Rune: carries BasicFlag_Integer too, so C++'s Integer arm claims it first -- same value
R    :: rune{};          #assert(R == 0)
// String arm. The last two are THE DISCRIMINATORS: pre-fix they kept the compound marker and
// both assertions failed. The first two passed even pre-fix and are the CONTROLS -- they are
// what proves the probe exercises the arm rather than merely rejecting more.
S    :: string{};        #assert(S == "")
CS   :: cstring{};       #assert(CS == "")
S16  :: string16{};      #assert(S16 == "")
CS16 :: cstring16{};     #assert(CS16 == "")

main :: proc() {}
