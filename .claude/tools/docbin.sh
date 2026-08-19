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
# ONE NORMALISATION, AND IT IS NAMED RATHER THAN HIDDEN -- the same one doctext.sh makes. The
# oracle appends a body marker to every procedure literal, ` /* 33!7776 */` (line!offset of the
# body), which the port does not emit. That is the STANDING, SEPARATELY-TRACKED d_proclit_str
# divergence (wit_b3rest/d_proclit_str), not a doc-writer defect, and leaving it in would fail
# every package for an unrelated reason. It is stripped from the ORACLE side only, by a pattern
# that cannot match anything else. If d_proclit_str is ever fixed, this becomes a no-op, not a lie.

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

  timeout "$TO" "$BIN" write "$abs" "$cell/port.odin-doc" >"$cell/port.log" 2>&1; rc_port=$?

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
  timeout "$TO" "$BIN" dump "$cell/port.odin-doc" >"$cell/port.txt" 2>&1; rc_dp=$?
  if died "$rc_dr" || died "$rc_dp"; then
    echo "DUMP-DIED  $p ref_rc=$rc_dr port_rc=$rc_dp"
    n_died=$((n_died+1)); continue
  fi

  sed -E 's| /\* [0-9]+![0-9]+ \*/||g' "$cell/ref.raw" > "$cell/ref.txt"

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
  echo "DOCBIN-COVER $p entities=$ents library_names=$flib c_vararg_params=$cvar"

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
