#!/usr/bin/env bash
# doctext.sh <DOCTEXT_BIN> <PACKAGE>... -- gate the port's RENDERED DOC TEXT against `odin doc`.
#
# #906: the checker library no longer walks up from CWD to find `base/runtime`, so a harness must
# export the root rather than rely on the caller's working directory.
export ODIN_ROOT="${ODIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
#
# WHY THIS EXISTS. The plain-text doc printer -- `generate_documentation` / `print_doc_package`,
# which is what a bare `odin doc` runs -- had no gate of any kind. doccmp.sh compares ENTITY
# PRESENCE in the package scope; docflag.sh gates the BINARY writer's flag bits and is explicitly
# port-side only; dump_doc drives the binary writer and never reaches the text path. Four defects
# sat in docs.odin simultaneously behind that blind spot, all four flag-conditional:
#   * `-in-source-order` had no comparator (docs.cpp has TWO; the port had one) and no per-file
#     grouping, so the flag was accepted and silently ignored.
#   * `-short` did not select expr_to_string_shorthand (the port made it a defaulted PARAMETER
#     that no call site ever passed) so shorthand rendering was unreachable.
#   * `-short` did not suppress doc comments, for the same reason.
#   * Cmd_Doc_Flag_Bit was missing In_Source_Order entirely, which shifted All_Packages and
#     Doc_Format down one bit each relative to C++'s numbering.
# An UNFLAGGED instrument could not have caught any of them. So this sweeps the FLAG COMBINATIONS,
# not just the default rendering -- that is the whole point.
#
# ONE NORMALISATION, AND IT IS NAMED RATHER THAN HIDDEN. The oracle appends a body marker to every
# procedure literal -- ` /* 33!77 */`, line!offset of the body -- which the port does not emit.
# That is the STANDING, SEPARATELY-TRACKED d_proclit_str divergence (wit_b3rest/d_proclit_str), not
# a doc defect, and leaving it in would make every package fail this gate for an unrelated reason.
# It is stripped from the ORACLE side only, by a pattern that cannot match anything else. If
# d_proclit_str is ever fixed, this stripping becomes a no-op rather than a lie.
#
# KNOWN-DIVERGENT COMBINATIONS are listed in KNOWN_DIFF below, each with its reason. A combination
# that diverges and is NOT listed fails the gate. A listed combination that matched EVERYWHERE in
# the run is reported as STALE-KNOWN and also fails, because a stale exemption reads as coverage it
# no longer has.

cd /home/kalsprite/dev/odin || exit 2
BIN="$1"; shift
[ -x "$BIN" ] || { echo "usage: doctext.sh <DOCTEXT_BIN> <PACKAGE>..." >&2; exit 2; }
[ $# -gt 0 ]  || { echo "usage: doctext.sh <DOCTEXT_BIN> <PACKAGE>..." >&2; exit 2; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
TO="${DOCTEXT_TIMEOUT:-180}"

# FLAG COMBINATIONS under test. `-all-packages` is deliberately absent: it makes the oracle
# document the entire transitive dependency set, which is thousands of lines dominated by
# base:runtime and turns a targeted gate into a whole-tree diff.
COMBOS=("" "-short" "-in-source-order" "-short -in-source-order")

# KNOWN_DIFF entries are "<combo>" strings. Each needs a reason on the line above it.
#
# -in-source-order sorts by Entity.order_in_src, whose HIGH 32 BITS are the file identity. C++ uses
# token.pos.file_id (parser.cpp:6982, `file->id = imported_file.index+1` -- import/parse order); the
# port has no file_id at all (core:odin/parser assigns neither ast.File.id nor ast.Node.file_id;
# file_helpers.odin records this and routes get_file_from_node around it) and substitutes a hash of
# the file PATH. So entities order correctly WITHIN a file and the file blocks come out in hash
# order instead of parse order. The grouping, the headers and the intra-file ordering all match --
# only the order of the `file:` blocks differs.
# THE RESIDUE IS ONLY OBSERVABLE IN A MULTI-FILE PACKAGE -- a single-file package has one `file:`
# block, so there is no block order to get wrong, and core/unicode/utf8 duly MATCHES. So a stale
# exemption cannot be inferred from one package matching: it is stale only when the combination
# matched on EVERY package in the run. That is what seen_match/seen_diff below tally, and it is why
# the STALE-KNOWN verdict is deferred to the end instead of printed inline.
KNOWN_DIFF=("-in-source-order" "-short -in-source-order")

is_known() { local c="$1" k; for k in "${KNOWN_DIFF[@]}"; do [ "$c" = "$k" ] && return 0; done; return 1; }
died() { [ "$1" -eq 124 ] || [ "$1" -ge 128 ]; }

declare -A seen_match seen_diff
n_total=0; n_match=0; n_diff=0; n_known=0; n_stale=0; n_died=0
for p in "$@"; do
  # #760: a bare basename is ambiguous at corpus scale (twelve packages in pkglist are named
  # `tools`). The full path is the identity.
  for combo in "${COMBOS[@]}"; do
    n_total=$((n_total+1))
    label="${combo:-<none>}"

    # shellcheck disable=SC2086 -- $combo is an intentional word-split flag list.
    timeout "$TO" ./odin doc "$p" $combo > "$TMP/ref.raw" 2>&1; rc_ref=$?
    # shellcheck disable=SC2086
    timeout "$TO" "$BIN" $combo "$p" > "$TMP/port.txt" 2>&1; rc_port=$?

    if died "$rc_ref" || died "$rc_port"; then
      echo "DOC-DIED   $p [$label] ref_rc=$rc_ref port_rc=$rc_port"
      n_died=$((n_died+1)); continue
    fi
    if grep -q '^### ' "$TMP/port.txt"; then
      echo "PORT-FAIL  $p [$label] $(grep -m1 '^### ' "$TMP/port.txt")"
      n_died=$((n_died+1)); continue
    fi

    sed -E 's| /\* [0-9]+![0-9]+ \*/||g' "$TMP/ref.raw" > "$TMP/ref.txt"

    if diff -q "$TMP/ref.txt" "$TMP/port.txt" >/dev/null; then
      seen_match["$label"]=$(( ${seen_match["$label"]:-0} + 1 ))
      if is_known "$combo"; then
        n_known=$((n_known+1))
      else
        n_match=$((n_match+1))
      fi
    elif is_known "$combo"; then
      seen_diff["$label"]=$(( ${seen_diff["$label"]:-0} + 1 ))
      n_known=$((n_known+1))
    else
      echo "TEXT-DIFF  $p [$label]"
      diff "$TMP/ref.txt" "$TMP/port.txt" | head -40
      n_diff=$((n_diff+1))
    fi
  done
done

# A KNOWN_DIFF combination that never diverged anywhere in this run is an exemption the gate is
# still paying for and no longer needs. Report it: a stale exemption reads as coverage.
for combo in "${KNOWN_DIFF[@]}"; do
  # Tallies are keyed on the LABEL, not the raw combo: bash rejects an empty array subscript and
  # the unflagged run's combo IS the empty string.
  klabel="${combo:-<none>}"
  if [ "${seen_diff["$klabel"]:-0}" -eq 0 ] && [ "${seen_match["$klabel"]:-0}" -gt 0 ]; then
    echo "STALE-KNOWN [$klabel] -- exempted but matched on all ${seen_match["$klabel"]} packages; remove the exemption"
    n_stale=$((n_stale+1))
  fi
done

echo "DOCTEXT-DONE cells=$n_total match=$n_match text_diffs=$n_diff known_diffs=$n_known stale_known=$n_stale died=$n_died"
[ "$n_diff" -eq 0 ] && [ "$n_died" -eq 0 ] && [ "$n_stale" -eq 0 ]
