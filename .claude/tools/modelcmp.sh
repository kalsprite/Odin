#!/bin/bash
# modelcmp.sh -- compare the port's TYPE MODEL against the oracle's, not just its diagnostics.
#
# WHY THIS EXISTS. parity.sh proves the two checkers agree about WHAT IS WRONG with a program.
# It does not prove they build the same TYPES. A checker can diagnose identically and still hand a
# backend a different type graph -- different sizes, alignments, field offsets. Nothing in the gate
# set measured that; doccmp.sh is the nearest thing and only covers doc-visible state. #112
# (offset_of had only the aligned arm), #113 (type_align_of ignored every struct alignment
# directive) and #110 (dynamic arrays/maps had hardcoded wrong sizes) were all defects of exactly
# this class, and all were found by accident rather than by a gate.
#
# METHOD. A checker never runs code, so layout values are not directly printable. But a type error
# PRINTS THE TYPE, so `p: [size_of(T)]u8` assigned to an int yields
#     Cannot assign value 'p' of type '[40]u8' to 'int'
# and the array length IS the value. Works for size_of / align_of / offset_of alike.
#
# TWO INSTRUMENT DEFECTS ALREADY FOUND AND FIXED HERE, both of which reported a FALSE CLEAN:
#   1. the diagnostic names the ARRAY (p_N_...), not the int (f_N_...). Anchoring the sed on f_
#      left every line unsubstituted, so "Cannot" became the join key for all of them and the run
#      reported 1296 mismatches (36x36 cartesian product).
#   2. BOTH compilers cap at 36 reported errors by default. A single file with 62 probes therefore
#      measured only the first 36 and silently called the rest clean. Hence CHUNKING below: each
#      chunk stays well under the cap. The oracle accepts -max-error-count but the port has no such
#      flag, so raising it would compare unequal configurations -- chunking keeps both at default.
# Coverage is now reported explicitly (probes vs values) and a shortfall is an ABORT, not a pass.
#
# USAGE: modelcmp.sh <PORT_BIN>
set -u
# #906: the checker library no longer walks up from CWD to find `base/runtime` (#898 removed it,
# because a LIBRARY's answer must not depend on the caller's working directory). Tools that only
# `cd` into the repo were relying on that walk-up BY ACCIDENT and now report "Undeclared name:
# append" -- runtime never loaded. The harness conforms to the library: export the root.
export ODIN_ROOT="${ODIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

cd /home/kalsprite/dev/odin

PORT="${1:-}"
[ -x "$PORT" ] || { echo "MODEL-ABORTED reason=port-missing: '$PORT'" >&2; exit 2; }
# Same guard as parity.sh (#392): a missing oracle manufactures a clean sweep.
[ -x ./odin ]  || { echo "MODEL-ABORTED reason=oracle-missing: ./odin" >&2; exit 2; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# Locally-declared types carrying the LAYOUT DIRECTIVES. These are the highest-value probes in
# the file: #112 (offset_of had only the aligned arm, so raw unions laid out sequentially and
# #packed was ignored) and #113 (type_align_of ignored every struct alignment directive) were both
# defects here, and a probe set built only from core types would not have caught either.
# Emitted into EVERY chunk, since each chunk is its own package.
DECLS='M_plain  :: struct { a: u8, b: u32, c: u8 }
M_packed :: struct #packed { a: u8, b: u32, c: u8 }
M_align16 :: struct #align(16) { a: u8 }
M_align32 :: struct #align(32) { a: u8, b: u64 }
M_raw    :: struct #raw_union { a: u8, b: u64, c: [3]u16 }
M_nested :: struct { h: u8, inner: M_packed, t: u8 }
M_nestraw :: struct { h: u8, inner: M_raw, t: u8 }
M_bf     :: bit_field u32 { a: u8 | 3, b: u8 | 5, c: u16 | 9 }
M_bf64   :: bit_field u64 { a: u16 | 12, b: u32 | 20, c: u8 | 7 }
M_enum   :: enum u16 { A, B, C }
M_bset   :: bit_set[M_enum; u16]
M_soa    :: #soa[]M_plain
M_soa_f  :: #soa[4]M_plain
M_soa_dy :: #soa[dynamic]M_plain
M_arr    :: [7]M_packed
// Polymorphic instantiation (#125 instantiation does not clone its AST, #126 operands cached as
// record instantiations were both this class). Instantiating the SAME generic at several
// arguments also exercises the instantiation cache, which is where #126 lived.
M_poly   :: struct($T: typeid, $N: int) { head: u8, data: [N]T, tail: u8 }
M_p_i32_4 :: M_poly(i32, 4)
M_p_u8_3  :: M_poly(u8,  3)
M_p_i64_2 :: M_poly(i64, 2)
M_p_pk_2  :: M_poly(M_packed, 2)
M_p_again :: M_poly(i32, 4)  // same args as M_p_i32_4 -- must hit the cache and agree'

IMPORTS='import "core:strings"
import "core:mem"
import "core:bytes"
import "core:time"
import "core:math/big"
import "core:container/queue"
import "core:sync"
import "core:thread"
import "core:slice"
import "core:odin/ast"
import "core:odin/tokenizer"

// Probe-local helper: an element aligned more strictly than a word, needed by the FCDA probes
// below (#515). A word-aligned element cannot distinguish "computed correctly" from "no arm at
// all", which is why the gap survived.
Aligned16 :: struct #align(16) { a: [4]f32 }
Soa_Elem  :: struct { a: int, b: f32 }'

# base:intrinsics is imported separately because it is the ONLY way to reach several
# type_offset_of arms (#518). offset_of reaches the Struct arm and nothing else; the
# Fixed_Capacity_Dynamic_Array arm is user-visible only through this intrinsic.
IMPORTS="$IMPORTS
import \"base:intrinsics\""

# MATRIX probes (#514). This harness had 37 align_of probes and NOT ONE matrix, so it reported
# "114 probes, 0 mismatches" while type_align_of's Matrix arm was `return type_align_of(mat.elem)`
# -- the element's alignment, wrong for every matrix whose total size exceeds its element size.
# modeldiff found it on core/math/linalg's identity constants; this harness could not have.
#
# C++'s rule (matrix_align_of, src/types.cpp) derives alignment from the TOTAL size -- the largest
# power of two dividing it -- floored at the element alignment and capped at max_simd_align, which
# is 32 here. So these probe THREE distinct regimes deliberately, and a naive elem-align
# implementation gets all of them wrong:
#   [2,2]f32 -> 16   total 16, under the cap
#   [4,4]f32 -> 32   total 64, AT the cap
#   [2,2]f16 ->  8   total 8, where the element (2) and the answer (8) differ most
# Non-square and f64 forms are included because row/column asymmetry and a 128-byte total are
# exactly where an off-by-one in the halving loop would show.
MATRIX_EXPRS=(
  'size_of(matrix[2,2]f32)'   'align_of(matrix[2,2]f32)'
  'size_of(matrix[4,4]f32)'   'align_of(matrix[4,4]f32)'
  'size_of(matrix[2,2]f16)'   'align_of(matrix[2,2]f16)'
  'size_of(matrix[4,4]f16)'   'align_of(matrix[4,4]f16)'
  'size_of(matrix[2,2]f64)'   'align_of(matrix[2,2]f64)'
  'size_of(matrix[4,4]f64)'   'align_of(matrix[4,4]f64)'
  'size_of(matrix[3,3]f32)'   'align_of(matrix[3,3]f32)'
  'size_of(matrix[2,4]f32)'   'align_of(matrix[2,4]f32)'
  'size_of(matrix[4,2]f32)'   'align_of(matrix[4,2]f32)'
  'size_of(matrix[1,4]f32)'   'align_of(matrix[1,4]f32)'
)

# FIXED-CAPACITY DYNAMIC ARRAY probes (#515). Found the same way as the matrix gap and in the same
# audit: `[dynamic; N]T` had NO arm in type_align_of at all (fell through to the default 8) and NO
# arm in type_size_of. C++ lays it out as `capacity` elements, padded up to int_size, then a len
# word, then rounded to max(int_size, elem_align).
#
# The `Aligned16` cases are the load-bearing ones: with a word-aligned element the missing arms
# happen to give the right answer, so a probe using only `int` would pass against a checker that
# has no arm whatsoever. That is precisely how this stayed invisible.
FCDA_EXPRS=(
  'size_of([dynamic; 4]int)'         'align_of([dynamic; 4]int)'
  'size_of([dynamic; 4]Aligned16)'   'align_of([dynamic; 4]Aligned16)'
  'size_of([dynamic; 1]Aligned16)'   'align_of([dynamic; 1]Aligned16)'
  'size_of([dynamic; 3]u8)'          'align_of([dynamic; 3]u8)'
  'size_of([dynamic; 2]matrix[4,4]f32)' 'align_of([dynamic; 2]matrix[4,4]f32)'
)

# #soa POINTER probes (#516/#517). A #soa pointer is {data, index} -- TWO words, because the fields
# it refers to live in separate per-field arrays, so the index must travel with the address. Two
# separate defects had to be fixed before these could pass:
#   #516  type_size_of grouped Soa_Pointer with ordinary pointers and returned ONE word.
#   #517  the TYPE SYNTAX `#soa ^T` never produced a Soa_Pointer at all -- the checker ignored the
#         pointer's tag and built a plain `^T`, so the size arm was unreachable from this spelling.
# The align probe is deliberately included even though it was never wrong: it pins the asymmetry
# (C++ returns int_size for the ALIGNMENT, same as a pointer, and int_size*2 only for the size),
# which is exactly what made grouping the two kinds look correct.
SOA_PTR_EXPRS=(
  'size_of(#soa ^#soa[]Soa_Elem)'   'align_of(#soa ^#soa[]Soa_Elem)'
  'size_of(#soa ^#soa[4]Soa_Elem)'  'align_of(#soa ^#soa[4]Soa_Elem)'
)

# type_offset_of NON-STRUCT arm probes (#518). All 22 pre-existing offset_of probes target STRUCTS,
# so the other seven arms of type_offset_of were unprobed. This is the only one reachable from user
# code -- the rest (Slice, Dynamic_Array, Union, Tuple, Basic) are used internally when the compiler
# lowers field access, not by any expression a probe can write.
#
# The Aligned16 case is the load-bearing one again: it is where #515's `padding_needed` write is
# observable, since the element block (64) needs no padding to reach a word boundary but the type's
# alignment (16) still governs where the len field lands. u8 covers the opposite end -- 3 bytes of
# elements padded up to 8.
OFFSET_EXPRS=(
  'intrinsics.type_fixed_capacity_dynamic_array_len_offset([dynamic; 4]int)'
  'intrinsics.type_fixed_capacity_dynamic_array_len_offset([dynamic; 3]u8)'
  'intrinsics.type_fixed_capacity_dynamic_array_len_offset([dynamic; 4]Aligned16)'
)

# Each entry becomes one probe. Kept as expressions so size_of/align_of/offset_of mix freely.
EXPRS=(
  "${MATRIX_EXPRS[@]}"
  "${FCDA_EXPRS[@]}"
  "${SOA_PTR_EXPRS[@]}"
  "${OFFSET_EXPRS[@]}"
  'size_of(strings.Builder)'      'align_of(strings.Builder)'
  'size_of(mem.Arena)'            'align_of(mem.Arena)'
  'size_of(bytes.Buffer)'         'align_of(bytes.Buffer)'
  'size_of(time.Time)'            'align_of(time.Time)'
  'size_of(big.Int)'              'align_of(big.Int)'
  'size_of(sync.Mutex)'           'align_of(sync.Mutex)'
  'size_of(sync.RW_Mutex)'        'align_of(sync.RW_Mutex)'
  'size_of(sync.Wait_Group)'      'align_of(sync.Wait_Group)'
  'size_of(thread.Thread)'        'align_of(thread.Thread)'
  'size_of(ast.Node)'             'align_of(ast.Node)'
  'size_of(ast.Expr)'             'size_of(ast.Ident)'
  'size_of(ast.Binary_Expr)'      'align_of(ast.Binary_Expr)'
  'size_of(ast.Proc_Lit)'         'size_of(ast.Struct_Type)'
  'size_of(tokenizer.Token)'      'align_of(tokenizer.Token)'
  'size_of(tokenizer.Pos)'        'align_of(tokenizer.Pos)'
  'size_of(ast.File)'             'size_of(ast.Field)'
  'size_of(ast.Call_Expr)'        'size_of(ast.Type_Assertion)'
  'size_of(queue.Queue(int))'     'align_of(queue.Queue(int))'
  'size_of(slice.Ordering)'       'size_of(mem.Allocator)'
  'offset_of(ast.Node, pos)'      'offset_of(ast.Node, end)'
  'offset_of(tokenizer.Token, kind)' 'offset_of(tokenizer.Token, text)'
  'offset_of(tokenizer.Token, pos)'  'offset_of(ast.Ident, name)'
  'offset_of(ast.Binary_Expr, op)'   'offset_of(ast.Binary_Expr, left)'
  'offset_of(ast.Binary_Expr, right)' 'offset_of(strings.Builder, buf)'
  'size_of([dynamic]int)'         'size_of(map[int]int)'
  'size_of([]int)'                'size_of(string)'
  'size_of(any)'                  'size_of(complex64)'
  'size_of(quaternion256)'        'align_of(quaternion256)'
  # --- LAYOUT DIRECTIVES (#112/#113 territory) ---
  'size_of(M_plain)'              'align_of(M_plain)'
  'offset_of(M_plain, b)'         'offset_of(M_plain, c)'
  'size_of(M_packed)'             'align_of(M_packed)'
  'offset_of(M_packed, b)'        'offset_of(M_packed, c)'
  'size_of(M_align16)'            'align_of(M_align16)'
  'size_of(M_align32)'            'align_of(M_align32)'
  'offset_of(M_align32, b)'
  'size_of(M_raw)'                'align_of(M_raw)'
  'offset_of(M_raw, a)'           'offset_of(M_raw, b)'
  'offset_of(M_raw, c)'
  'size_of(M_nested)'             'align_of(M_nested)'
  'offset_of(M_nested, inner)'    'offset_of(M_nested, t)'
  'size_of(M_nestraw)'            'offset_of(M_nestraw, inner)'
  'offset_of(M_nestraw, t)'
  'size_of(M_bf)'                 'align_of(M_bf)'
  'size_of(M_bf64)'               'align_of(M_bf64)'
  'size_of(M_enum)'               'align_of(M_enum)'
  'size_of(M_bset)'               'align_of(M_bset)'
  'size_of(M_arr)'                'align_of(M_arr)'
  # --- SOA (#61/#256 territory) ---
  'size_of(M_soa)'                'align_of(M_soa)'
  'size_of(M_soa_f)'              'align_of(M_soa_f)'
  'size_of(M_soa_dy)'             'align_of(M_soa_dy)'
  # --- POLYMORPHIC INSTANTIATION (#125/#126 territory) ---
  'size_of(M_p_i32_4)'            'align_of(M_p_i32_4)'
  'offset_of(M_p_i32_4, data)'    'offset_of(M_p_i32_4, tail)'
  'size_of(M_p_u8_3)'             'align_of(M_p_u8_3)'
  'offset_of(M_p_u8_3, data)'     'offset_of(M_p_u8_3, tail)'
  'size_of(M_p_i64_2)'            'align_of(M_p_i64_2)'
  'offset_of(M_p_i64_2, data)'    'offset_of(M_p_i64_2, tail)'
  'size_of(M_p_pk_2)'             'align_of(M_p_pk_2)'
  'offset_of(M_p_pk_2, data)'
  'size_of(M_p_again)'            'offset_of(M_p_again, tail)'
)

CHUNK=14   # well under the 36-error cap, leaving headroom for any incidental diagnostic
extract() {
  grep -oP "Cannot assign value 'p_\d+' of type '\[\d+\]u8'" \
    | sed -E "s/Cannot assign value 'p_([0-9]+)' of type '\[([0-9]+)\]u8'/\1 \2/"
}

: > "$TMP/o.txt"; : > "$TMP/p.txt"
n=${#EXPRS[@]}; probes=0
for ((base=0; base<n; base+=CHUNK)); do
  D="$TMP/c$base"; mkdir -p "$D"
  { echo 'package p'; echo "$IMPORTS"; echo "$DECLS"
    for ((i=base; i<base+CHUNK && i<n; i++)); do
      echo "p_$i: [${EXPRS[$i]}]u8"; echo "f_$i: int = p_$i"; probes=$((probes+1))
    done
  } > "$D/a.odin"
  timeout 300 ./odin check "$D" -no-entry-point 2>&1 | extract >> "$TMP/o.txt"
  timeout 300 "$PORT" "$D"                      2>&1 | extract >> "$TMP/p.txt"
done
sort -n -o "$TMP/o.txt" "$TMP/o.txt"; sort -n -o "$TMP/p.txt" "$TMP/p.txt"
o=$(wc -l < "$TMP/o.txt"); p=$(wc -l < "$TMP/p.txt")

# VACUITY / COVERAGE GUARD (#405/#408). Zero values, or fewer values than probes, is what a run
# that partly never happened looks like -- and with a mismatch metric that reads as agreement.
if [ "$o" -eq 0 ] || [ "$p" -eq 0 ]; then
  echo "MODEL-ABORTED reason=no-values oracle=$o port=$p -- nothing measured, NOT a clean result." >&2
  exit 2
fi
if [ "$o" -ne "$probes" ] || [ "$p" -ne "$probes" ]; then
  echo "MODEL-ABORTED reason=coverage-shortfall probes=$probes oracle=$o port=$p" >&2
  echo "         Some probe produced no value (bad expression, or the 36-error cap was hit)." >&2
  echo "         Lower CHUNK or fix the expression. A shortfall must never read as agreement." >&2
  exit 2
fi

mism=$(join -j1 "$TMP/o.txt" "$TMP/p.txt" | awk '$2 != $3' | wc -l)
if [ "$mism" -ne 0 ]; then
  echo "=== MODEL MISMATCHES ==="
  join -j1 "$TMP/o.txt" "$TMP/p.txt" | awk -v e="${EXPRS[*]}" '$2 != $3 {
    split(e, a, " "); printf "  probe[%s] oracle=%s port=%s\n", $1, $2, $3 }'
fi
echo "MODEL-DONE probes=$probes oracle_values=$o port_values=$p mismatches=$mism"

# ------------------------------------------------------------------------------------------------
# EXIT GATE (#749). This script already ABORTED correctly on a missing binary (:32/:34) and on a
# coverage shortfall (:261) -- but the actual COMPARISON, the thing it exists to do, ended on the
# bare `echo` above and returned 0 no matter how many probes disagreed. That is #747's split with
# only half of it built: the "inputs are broken" path was gated, the "port and oracle DISAGREE"
# path was not. Baseline measured at #749: probes=151 oracle_values=151 port_values=151
# mismatches=0 -- a clean zero, so unlike parity.sh this one gates on the real column directly.
#   exit 0 = all probes agree | exit 1 = MODEL-FAILED, values diverge (a valid measurement that
#   failed) | exit 2 = MODEL-ABORTED, inputs or coverage broken (numbers are NOT a measurement)
if [ "$mism" -ne 0 ]; then
  echo "MODEL-FAILED $mism of $probes probes have DIFFERENT MODEL VALUES -- see the MODEL MISMATCHES block above" >&2
  exit 1
fi
exit 0
