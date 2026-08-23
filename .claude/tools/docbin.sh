#!/usr/bin/env bash
# docbin.sh <DOCBIN_BIN> <PACKAGE>... -- gate the port's BINARY .odin-doc WRITER against
# `odin doc <pkg> -doc-format`.
#
# #906: the checker library no longer walks up from CWD to find `base/runtime`, so a harness must
# export the root rather than rely on the caller's working directory.
export ODIN_ROOT="${ODIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
#
# WHY THIS EXISTS. docs_writer.odin is 1776 lines and had NO gate that could see the reference
# side. doccmp.sh compares ENTITY PRESENCE in the package scope and never touches the writer;
# docflag.sh gates flag bits and is explicitly port-side-only; dump_doc drives the writer but
# prints not one Doc_Type; doctext.sh (tick 227) gates the TEXT printer, a different code path
# entirely. Six defects sat behind that blind spot simultaneously -- a stale entity snapshot in
# doc_update_entities, field_group_index never written, init_string built by a helper that could
# not reach expr_to_string_shorthand, a missing Fixed_Capacity_Dynamic_Array type kind, an
# INVENTED where_clauses write on the Proc arm, and comment-group text assembled without C++'s
# early bail or blank-line rules. `odin doc <pkg> -doc-format` emits precisely the artifact
# odin_doc_write emits, so the reference side costs nothing but was never asked for.
#
# WHY IT DIFFS A DECODED DUMP RATHER THAN THE BYTES. The format is index-based: Doc_Type_Index
# and Doc_Entity_Index are positions in an array built in visit order, and Doc_Array{offset,length}
# points into pooled blobs. One extra type written early shifts every subsequent index, so a byte
# diff -- or an index-keyed diff -- reports the entire file as different and explains nothing.
# `triage_docbin dump` therefore renders entities keyed by name@file:line:col and types
# STRUCTURALLY, then sorts and counts them (`typeset 3x Slice(u8)`). Index shifts become invisible
# and real content differences become one line each.
#
# ONE NORMALISATION, AND IT IS NAMED RATHER THAN HIDDEN. Both compilers append a body marker to
# every procedure literal, ` /* 33!7776 */` -- that is FILE_ID!OFFSET of the proc literal, NOT
# line!offset as this comment said until tick 248. MEASURED: in $S/phase2/witdoc_ctxfile247 the
# marker reads `34!204`; the procedure is on LINE 7 and byte 204 is exactly the offset of its
# `proc` keyword. Both halves were checked, because the offset alone would not have distinguished
# the two readings.
#
# UPDATED AT t1292. This comment used to end "The port does not emit the marker ... It is stripped
# from the ORACLE side only ... If d_proclit_str is ever fixed, this becomes a no-op, not a lie."
# THE PORT NOW EMITS THE MARKER (#1270), and the one-sided strip did not become a no-op -- it
# became a lie, reporting DIFF on 12 of 12 packages, every diff consisting solely of the marker
# the filter had removed from one side. **A ONE-SIDED FILTER IS A CLAIM ABOUT THE OTHER SIDE, AND
# THAT CLAIM EXPIRES.**
#
# What is normalised now is the FILE_ID half only, on BOTH sides. The reasoning, and the
# measurement behind it, are at the sed itself.

cd /home/kalsprite/dev/odin || exit 2
BIN="$1"; shift
[ -x "$BIN" ] || { echo "usage: docbin.sh <DOCBIN_BIN> <PACKAGE>..." >&2; exit 2; }
[ $# -gt 0 ]  || { echo "usage: docbin.sh <DOCBIN_BIN> <PACKAGE>..." >&2; exit 2; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
TO="${DOCBIN_TIMEOUT:-180}"

died() { [ "$1" -eq 124 ] || [ "$1" -ge 128 ]; }

n_total=0; n_match=0; n_diff=0; n_died=0
for p in "$@"; do
  n_total=$((n_total+1))
  # #760: a bare basename is ambiguous at corpus scale (twelve packages in pkglist are named
  # `tools`). The full path is the identity, and it is also what `write` matches pkg.fullpath on.
  abs=$(cd "$p" 2>/dev/null && pwd) || { echo "DOCBIN-DIED $p no-such-dir"; n_died=$((n_died+1)); continue; }

  # The oracle writes <pkgname>.odin-doc into the CWD and gives no way to name the output, so
  # each cell gets a fresh directory -- never reuse one, or a stale artifact from the previous
  # package grades as this package's reference.
  cell="$TMP/cell$n_total"; mkdir -p "$cell"
  ( cd "$cell" && timeout "$TO" /home/kalsprite/dev/odin/odin doc "$abs" -doc-format ) >"$cell/ref.log" 2>&1
  rc_ref=$?
  refdoc=$(ls "$cell"/*.odin-doc 2>/dev/null | head -1)

  # LEDGER #1293. RETRY A `#panic` PACKAGE WITH `-internal-ignore-panic` INSTEAD OF SKIPPING IT.
  # Three packages in the 224-package list are deliberate panic stubs -- core/path (which panics to
  # tell you to use slashpath or filepath), core/odin/format and core/odin/printer (both
  # deprecated) -- and the ORACLE cannot document them either, so they landed as REF-NODOC and
  # graded NOTHING. That is a limit of THIS SCRIPT, not of the reference: measured at t1293,
  # `odin doc <pkg> -doc-format -internal-ignore-panic` documents all three.
  #
  # RETRY, not always-on. Passing the flag to all 224 packages would change what is under test
  # everywhere in order to buy three cells, and would mask a divergence whose symptom is a panic
  # firing on one side only -- exactly the shape this gate should report.
  #
  # The flag is then passed to BOTH sides. A one-sided flag is the #1292 mistake in a new costume.
  ipflag=""
  if [ -z "$refdoc" ] && grep -q 'Compile time panic' "$cell/ref.log"; then
    rm -f "$cell"/*.odin-doc
    ( cd "$cell" && timeout "$TO" /home/kalsprite/dev/odin/odin doc "$abs" -doc-format -internal-ignore-panic ) >"$cell/ref.log" 2>&1
    rc_ref=$?
    refdoc=$(ls "$cell"/*.odin-doc 2>/dev/null | head -1)
    [ -n "$refdoc" ] && ipflag="-internal-ignore-panic"
  fi

  timeout "$TO" "$BIN" write "$abs" "$cell/port.odin-doc" $ipflag >"$cell/port.log" 2>&1; rc_port=$?

  if died "$rc_ref" || died "$rc_port"; then
    echo "DOCBIN-DIED $p ref_rc=$rc_ref port_rc=$rc_port"
    n_died=$((n_died+1)); continue
  fi
  if [ -z "$refdoc" ]; then
    echo "REF-NODOC  $p $(tail -1 "$cell/ref.log")"
    n_died=$((n_died+1)); continue
  fi
  # `### ` is triage_docbin's own loud-failure prefix -- e.g. NO-TARGET-PKG, when the package it
  # was asked to document never appeared in info.packages. That is a harness failure, not a match.
  if grep -q '^### ' "$cell/port.log"; then
    echo "PORT-FAIL  $p $(grep -m1 '^### ' "$cell/port.log")"
    n_died=$((n_died+1)); continue
  fi

  timeout "$TO" "$BIN" dump "$refdoc"            >"$cell/ref.raw"  2>&1; rc_dr=$?
  timeout "$TO" "$BIN" dump "$cell/port.odin-doc" >"$cell/port.txt.raw" 2>&1; rc_dp=$?
  if died "$rc_dr" || died "$rc_dp"; then
    echo "DUMP-DIED  $p ref_rc=$rc_dr port_rc=$rc_dp"
    n_died=$((n_died+1)); continue
  fi

  # LEDGER #1292. THIS LINE USED TO STRIP THE PROC-LITERAL BODY MARKER FROM THE ORACLE ONLY, and
  # by tick t1292 that had turned the whole gate into a false-positive machine: 12 of 12 packages
  # reported DIFF, every diff consisting of nothing but ` /* 33!1497 */` present on the port side
  # and absent on the reference side.
  #
  # The header comment above predicted the wrong failure: it said "If d_proclit_str is ever fixed,
  # this becomes a no-op, not a lie." It became a LIE, not a no-op. A ONE-SIDED normalisation is
  # only harmless while the side it strips is the only side that has the thing; the moment the
  # port grew the marker, stripping the oracle's copy manufactured a difference on every single
  # procedure in every package. **A ONE-SIDED FILTER IS A CLAIM ABOUT THE OTHER SIDE, AND THAT
  # CLAIM EXPIRES.**
  #
  # MEASURED before changing anything, on core/math/bits: both sides emit 77 markers; the sorted
  # multisets of marker texts are IDENTICAL (`diff` empty, same file_id 33 and same offsets); and
  # with the marker left in place on both sides the full decoded dumps differ by ZERO lines.
  #
  # So the marker is now a MATCHING field, and the right treatment is to strip it from NEITHER
  # side. Normalising it away would hide a future regression in exactly the value the
  # `-in-source-order` upstream filing says is fragile -- file_id is handed out by enqueue order
  # and the port derives it differently, so if the two ever disagree this gate should say so
  # rather than smooth it over.
  # ...and then, having established that, ONE normalisation remains, applied SYMMETRICALLY to
  # both sides and named rather than hidden: the marker's FILE_ID half is blanked, its OFFSET half
  # is kept.
  #
  # MEASURED with $S/fidmap.sh, which recovers the file -> marker-file_id map from each side's own
  # dump. core/strings:
  #     ascii_set  ref=33 port=33      builder  ref=35 port=34
  #     reader     ref=34 port=37      conversion ref=36 port=35
  #     intern     ref=37 port=36      strings  ref=38 port=38
  # The port's ids run in ALPHABETICAL order; the reference's run in RAW `readdir` order. That is
  # not an off-by-one and not a port defect -- it is the already-filed
  # UPSTREAM-UNFILED-in-source-order-doc-output-follows-raw-directory-order-... issue:
  # `read_directory` sorts on no platform (src/path.cpp:407), so reference file ids are a property
  # of how the directory came to be populated, while the port's loader enumerates with a sorted
  # glob. The filing already decided the port keeps its sorted order.
  #
  # WHAT THE FILING DID NOT ANTICIPATE, and this gate is how it surfaced: the file id is not
  # confined to `-in-source-order`. It is half of the proc-literal discriminator
  # `/* file_id!offset */` (check_expr.cpp:13161, inside write_expr_to_string's ProcLit arm), which
  # is emitted on EVERY doc build -- so on ANY multi-file package whose directory order is not
  # alphabetical, EVERY procedure differs. That is a property of the reference's unspecified
  # enumeration order, not of the port, and it would swamp every real finding in this gate.
  #
  # SCOPED AT t1294, after checking rather than repeating: this comment used to say the marker
  # "feeds type_canonical_name" full stop. The call that puts it there
  # (name_canonicalization.cpp:481) is guarded by `is_in_doc_writer()` at line 472, so it reaches
  # canonical strings ONLY while the doc writer runs -- it is NOT part of the identity an ordinary
  # build's `intrinsics.type_canonical_name` computes. The upstream filing was corrected the same
  # way. A CITATION IS NOT A VERIFICATION; READ THE GUARD ABOVE THE CALL.
  #
  # The OFFSET half is deliberately NOT normalised: it is the part that actually discriminates two
  # proc literals, it is a property of the source text alone, and it matched everywhere measured.
  # If the ids are ever made deterministic upstream, delete this and the gate gets strictly
  # stronger.
  sed -E 's| /\* [0-9]+!([0-9]+) \*/| /* !\1 */|g' "$cell/ref.raw"        > "$cell/ref.txt"
  sed -E 's| /\* [0-9]+!([0-9]+) \*/| /* !\1 */|g' "$cell/port.txt.raw"   > "$cell/port.txt"

  # COVERAGE COUNTS, printed on EVERY cell including matching ones (#3-of-4, tick 238b). Three of
  # four foreign-import packages once "matched" this gate because the construct under test was
  # never reached on this platform -- a green that measures nothing, indistinguishable in the log
  # from a green that measures everything. A row that cannot say what it exercised is silent, not
  # passing. These counts come from the ORACLE dump, so they describe the input, not the port.
  # Count a construct the ORACLE actually emits. Counting `Param_C_Vararg` here was wrong and the
  # positive control caught it: that flag is the port-only defect, so the oracle dump ALWAYS has
  # zero of it and the counter read 0 on core/c/libc, a package full of #c_vararg. A coverage
  # counter must count the INPUT construct, never the symptom under test -- or it reports "not
  # exercised" precisely when the bug is present. `Proc(flags=C_Vararg` is emitted by both sides.
  # (No `|| echo 0`: grep -c already prints 0, and exits 1 while doing it, so the fallback
  # appended a SECOND 0 and corrupted the field.)
  cvar=$(grep -c 'Proc(flags=C_Vararg' "$cell/ref.txt" 2>/dev/null); cvar=${cvar:-0}
  flib=$(grep -c 'kind=Library_Name' "$cell/ref.txt" 2>/dev/null); flib=${flib:-0}
  ents=$(grep -c '^entity' "$cell/ref.txt" 2>/dev/null); ents=${ents:-0}
  # `ignore_panic=` is printed on every row, 0 or 1, so a retried cell is never silently
  # indistinguishable from an ordinary one (#1293).
  echo "DOCBIN-COVER $p entities=$ents library_names=$flib c_vararg_params=$cvar ignore_panic=$([ -n "$ipflag" ] && echo 1 || echo 0)"

  if diff -q "$cell/ref.txt" "$cell/port.txt" >/dev/null; then
    n_match=$((n_match+1))
  else
    echo "DOCBIN-DIFF $p"
    diff "$cell/ref.txt" "$cell/port.txt" | head -30
    n_diff=$((n_diff+1))
  fi
done

echo "DOCBIN-DONE cells=$n_total match=$n_match diffs=$n_diff died=$n_died"
[ "$n_diff" -eq 0 ] && [ "$n_died" -eq 0 ]
