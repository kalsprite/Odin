#!/usr/bin/env bash
# doccmp.sh <DOC_BIN> <PACKAGE>... -- compare CHECKER STATE against the oracle's `odin doc`.
#
# WHY. Every other instrument in .claude/tools is diagnostic-anchored: it compares emitted text.
# A whole class of divergence produces no diagnostic on either side and is therefore invisible to
# all of them -- #286 (info.init_procedures never populated, so the sort phase ran on empty arrays
# every run) sat undetected behind exactly that blind spot until the state dump existed.
#
# DOC_BIN is the triage_doc harness: it builds a Checker directly (Checker, Checker_Info and
# check_files are all public), runs it, and prints a sorted "ENTITY <Kind> <Name>" inventory of
# the ROOT package scope plus the INIT/FINI rosters.
#
# THE COMPARISON IS DELIBERATELY ONE-DIRECTIONAL: oracle-listed ⊆ port-known.
# `odin doc` reports only EXPORTED declarations. The port's package scope legitimately holds more
# -- imports, @(private) entities, and file-scope names doc omits. So an entity present in the
# port but absent from doc is EXPECTED and is counted, not failed. The failure signal is the other
# direction: something the oracle documents that the port's scope does not contain, which means
# the port failed to register a declaration the reference resolved.
#
# Verdicts: STATE-MATCH (nothing missing) / STATE-DIFFER (missing listed) / DOC-DIED / PORT-DIED.
# Exit 0 only if every package is STATE-MATCH.

cd /home/kalsprite/dev/odin || exit 2
DOC_BIN="$1"; shift
[ -z "$DOC_BIN" ] || [ $# -eq 0 ] && { echo "usage: doccmp.sh <DOC_BIN> <PACKAGE>..." >&2; exit 2; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
TO="${DOCCMP_TIMEOUT:-180}"

died() { [ "$1" -eq 124 ] || [ "$1" -ge 128 ]; }
why()  { [ "$1" -eq 124 ] && echo "TIMEOUT" || echo "SIG$(($1-128))"; }

rc_all=0
for p in "$@"; do
  name=$(basename "$p")

  timeout "$TO" ./odin doc "$p" > "$TMP/doc.raw" 2>&1; drc=$?
  timeout "$TO" "$DOC_BIN" "$p" > "$TMP/port.raw" 2>&1; prc=$?

  # rc on BOTH sides before any diff -- a crash prints nothing and looks like agreement (#285).
  if died "$drc"; then
    printf "%-30s DOC-DIED   %s\n" "$name" "$(why $drc)"; rc_all=1; continue
  fi
  if died "$prc"; then
    printf "%-30s PORT-DIED  %s\n" "$name" "$(why $prc)"; rc_all=1; continue
  fi
  if grep -q '^### \(LOAD-FAILED\|NO-ROOT-SCOPE\|ABS-FAILED\)' "$TMP/port.raw"; then
    printf "%-30s PORT-NO-STATE\n" "$name"; rc_all=1; continue
  fi

  # `odin doc`: one-tab section headings, two-tab entries as "NAME :: ..." or "NAME := ...".
  awk '
    /^\tconstants$/  { sec="Constant";   next }
    /^\tvariables$/  { sec="Variable";   next }
    /^\tprocedures$/ { sec="Procedure";  next }
    /^\ttypes$/      { sec="Type_Name";  next }
    /^\tproc_group/  { sec="Proc_Group"; next }
    /^\t[a-z_]+$/    { sec="";           next }
    # Take the identifier up to the FIRST colon. `odin doc` emits four declaration shapes:
    #   NAME :: value        constant
    #   NAME := value        variable with inferred type
    #   NAME: Type           variable with explicit type, no initialiser
    #   NAME: Type : value   constant with explicit type
    # Splitting on "::" or ":=" only handled the first two, so `stderr: ^FILE` (core/c/libc) and
    # `COMPACT_IMPLS: bool : #config(...)` (core/crypto) parsed as names WITH their type text
    # attached and were then reported MISSING -- three and one false positives respectively.
    # Splitting on the first colon handles all four.
    # Raw-string constants (NAME :: `...multi-line...`) spill their CONTENT into the listing at
    # the same two-tab indent as declarations. core/unicode/tools has a `GENERATED` constant whose
    # embedded W3C copyright text contains "http://www.w3.org/..." -- which parsed as a
    # declaration named `http` and was reported MISSING. Track backtick parity and skip content.
    { n = gsub(/`/, "`"); if (inraw) { if (n % 2 == 1) inraw = 0; next } else if (n % 2 == 1) { inraw = 1 } }
    sec != "" && /^\t\t[A-Za-z_][A-Za-z0-9_]*[ \t]*:/ {
      s=$0; sub(/^\t\t/,"",s); split(s, a, /[ \t]*:/); gsub(/[ \t]+$/,"",a[1]); if (a[1] != "") print a[1]
    }
  ' "$TMP/doc.raw" | sort -u > "$TMP/doc.names"

  grep -oP '(?<=^ENTITY )\S+ \S+$' "$TMP/port.raw" | awk '{print $2}' | sort -u > "$TMP/port.names"

  comm -23 "$TMP/doc.names" "$TMP/port.names" > "$TMP/missing"
  nd=$(wc -l < "$TMP/doc.names"); np=$(wc -l < "$TMP/port.names"); nm=$(wc -l < "$TMP/missing")
  extra=$(comm -13 "$TMP/doc.names" "$TMP/port.names" | wc -l)

  if [ "$nd" -eq 0 ]; then
    # `odin doc base/runtime` emits NOTHING (rc=0, zero bytes) -- the reference suppresses doc
    # output for that package entirely. That is an ORACLE property, not a port defect, so it is
    # named here rather than counted as a failure. Any OTHER empty listing is still a failure:
    # an empty comparison is a vacuous pass, which is what #1 was filed for.
    if [ "$p" = "base/runtime" ]; then
      printf "%-30s DOC-EMPTY-EXPECTED  (oracle emits no doc for base/runtime; port=%s entities)\n" "$name" "$np"
    else
      printf "%-30s DOC-EMPTY  (nothing to compare -- NOT a pass)\n" "$name"; rc_all=1
    fi
    continue
  fi

  if [ "$nm" -eq 0 ]; then
    printf "%-30s STATE-MATCH  doc=%-5s port=%-5s port-only=%s\n" "$name" "$nd" "$np" "$extra"
  else
    printf "%-30s STATE-DIFFER doc=%-5s port=%-5s MISSING=%s\n" "$name" "$nd" "$np" "$nm"
    head -8 "$TMP/missing" | sed 's/^/                                 missing: /'
    rc_all=1
  fi
done
exit $rc_all
