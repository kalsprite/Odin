#!/usr/bin/env bash
# newdiag.sh [BASE_COMMIT] -- diagnostics ADDED to the C++ semantic analyser since a baseline,
# cross-checked against the port. This is the instrument for LEDGER #7.
#
# WHY IT EXISTS. The parity sweeps compare the port against the CURRENT C++ compiler, so a feature
# added since the port's snapshot is only caught if core/ happens to exercise it. Measured on
# 2026-08-03: of 225 packages, only 15 emit any diagnostic in plain mode (63 lines) and 100 in vet
# mode (164 lines). core is valid code, so it cannot test the rejection surface. Every
# under-rejection closed in #305/#306 was invisible to both sweeps.
#
# EMPIRICAL FALSE-POSITIVE RATE (measured 2026-08-03, 11 of the 30 probed):
#   REAL      4  -- n7_fixcap over-rejection (#309, fixed), n7_sizeof missing entirely,
#                   n7_dashdash and n7_bitset both stale text (port rejects, wrong wording)
#   FALSE     5  -- n7_sumsn, n7_inline, and the whole #c_vararg cluster: present and
#                   byte-identical, flagged only because the port words the surrounding
#                   diagnostics differently or the literal lives in core/odin/ast, which this
#                   script does not grep
#   BAD PROBE 2  -- my own, not the instrument's: #c_vararg is a field prefix written BEFORE the
#                   name (`#c_vararg args: ..any`), and labels are not expressions
# So roughly half the "absent" verdicts survive probing. USE THIS TO NARROW THE SEARCH, never as
# a defect count -- every entry needs a probe before it is believed.
#
# THE QUERY. Take the set of diagnostic string literals in the semantic-analysis translation units
# at BASE, take the same set at HEAD, and subtract. What remains is what C++ learned to say since
# BASE. For each, ask whether the port says it too. A message C++ has and the port does not is a
# candidate gap -- NOT proof of one: the port legitimately words some things differently, and a
# few C++ messages are unreachable. Treat the output as a WORKLIST to probe, never as a defect
# count.
#
# Deliberately NOT included: llvm_backend*, linker, CLI, and build_settings. The port does
# semantic analysis only, so a diagnostic from those files is out of scope by construction.

set -o pipefail
BASE="${1:-$(git rev-list -1 --before=2026-01-01 HEAD)}"
FILES="src/check_expr.cpp src/check_type.cpp src/check_stmt.cpp src/check_decl.cpp
       src/checker.cpp src/parser.cpp src/types.cpp src/check_builtin.cpp src/entity.cpp"

# A diagnostic literal: the first string argument of an error-emitting call. Long enough to be a
# real sentence (>= 18 chars) so that format fragments and identifiers do not flood the set.
# COMMENTED-OUT CALLS ARE DROPPED (LEDGER #333). The extractor used to take the literal from any
# matching line, including ones the reference has commented out, e.g.
#
#     src/parser.cpp:5182   // syntax_error(import_name, "Cannot cyclicly import packages");
#
# That message CANNOT be emitted by C++, so reporting it as "absent from the port" is true and
# useless -- the port is correct not to have it. It cost a probe to find that out. The `//` filter
# below is deliberately crude: it drops a line whose first non-blank characters are `//`, which
# catches the whole-line-commented case that actually occurs here. It does NOT understand /* */
# blocks or a call commented mid-line, so this narrows the false positives rather than eliminating
# them -- the header's "every entry needs a probe before it is believed" still stands.
extract() { # $1 = git revision
  for f in $FILES; do
    git show "$1:$f" 2>/dev/null \
      | grep -vE '^[[:space:]]*//' \
      | grep -oE '(syntax_error|syntax_warning|error|warning|error_line)\s*\([^;]*"[^"]{18,}"' \
      | grep -oE '"[^"]{18,}"'
  done | sed 's/^"//; s/"$//' | sort -u
}

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
extract "$BASE" > "$TMP/base.txt"
extract HEAD     > "$TMP/head.txt"
comm -13 "$TMP/base.txt" "$TMP/head.txt" > "$TMP/added.txt"

printf "baseline   %s  %s\n" "${BASE:0:9}" "$(git log -1 --format='%ad' --date=short "$BASE")"
printf "messages   base=%s head=%s added=%s\n" \
  "$(wc -l < "$TMP/base.txt")" "$(wc -l < "$TMP/head.txt")" "$(wc -l < "$TMP/added.txt")"
echo

# A message counts as PRESENT in the port if its distinctive prefix appears anywhere in the
# checker or parser sources. Prefix rather than whole string because both sides interpolate.
present=0; absent=0
: > "$TMP/missing.txt"
while IFS= read -r msg; do
  [ -z "$msg" ] && continue
  # Match on the LONGEST run of the message that contains no format specifier. Cutting at the
  # first '%' instead was wrong: every message beginning "'%.*s' ..." collapsed to a fragment that
  # still contained "%.*s", which the port never writes literally, so all of them were reported
  # ABSENT. simd.sums_of_n's "requires a power of two 'n' parameter >= 2" was flagged that way and
  # is in fact present and byte-identical. Verified 2026-08-03.
  probe=$(printf '%s' "$msg" \
    | sed -E 's/%[-#0-9.*]*(ll|l|t|z|h)?[a-zA-Z]/\n/g; s/\\[nt]/\n/g' \
    | tr '\n' '\0' | tr -d '\r' | xargs -0 -n1 printf '%s\n' 2>/dev/null \
    | awk '{ if (length($0) > length(best)) best=$0 } END { print best }' \
    | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
  [ ${#probe} -lt 12 ] && continue   # too generic to decide either way; skip rather than guess
  if grep -rqsF -- "$probe" core/odin/checker core/odin/parser; then
    present=$((present+1))
  else
    absent=$((absent+1)); printf '%s\n' "$msg" >> "$TMP/missing.txt"
  fi
done < "$TMP/added.txt"

echo "--- ADDED SINCE BASE AND ABSENT FROM THE PORT (worklist, not a defect count) ---"
cat "$TMP/missing.txt"
echo
echo "NEWDIAG-DONE added=$(wc -l < "$TMP/added.txt") present_in_port=$present absent_from_port=$absent"
