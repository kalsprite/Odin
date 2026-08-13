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
n_match=0; n_diff=0; n_empty=0; n_expected=0; n_failed=0; n_died=0; n_nostate=0; n_total=0
for p in "$@"; do
  n_total=$((n_total+1))
  # #760: this was `basename "$p"`, which is AMBIGUOUS at corpus scale and silently so. The
  # 323-package list contains TWELVE packages whose basename is `tools`
  # (core/crypto/_edwards25519/tools, core/unicode/tools, ten under core/rexcode/isa/*/tools) --
  # so twelve rows printed the identical label `tools`, ten of them DOC-EMPTY and two STATE-MATCH,
  # and NOTHING in the output said which was which. A report you cannot act on is not a report:
  # the whole point of a per-package row is to name the package that failed. Full path now.
  name="$p"

  timeout "$TO" ./odin doc "$p" > "$TMP/doc.raw" 2>&1; drc=$?
  timeout "$TO" "$DOC_BIN" "$p" > "$TMP/port.raw" 2>&1; prc=$?

  # rc on BOTH sides before any diff -- a crash prints nothing and looks like agreement (#285).
  if died "$drc"; then
    printf "%-46s DOC-DIED   %s\n" "$name" "$(why $drc)"; n_died=$((n_died+1)); rc_all=1; continue
  fi
  # #760: `odin doc`'s ORDINARY exit status was never examined -- only signals/timeouts were. So a
  # package where the REFERENCE ITSELF FAILED fell through to the nd==0 branch and printed
  # DOC-EMPTY, which reads as a property of the package ("nothing to document") when it is really a
  # property of the run ("the oracle could not check this"). Measured on the 323-package list: of
  # 22 DOC-EMPTY rows, SEVEN were rc=0 with genuinely nothing exported and FIFTEEN were rc!=0 --
  # core/sys/darwin (3 errors, platform-gated names undeclared on this target), core/sys/freebsd
  # (31), the ten core/rexcode/isa/*/tools (each a directory of standalone `package main` generators,
  # so `Redeclaration of 'main'`), core/path, core/odin/format, core/odin/printer. Same family as
  # #275 and #759: a comparison whose reference side failed is NOT a measurement, and must not be
  # reported in the same breath as one that succeeded and found nothing.
  if [ "$drc" -ne 0 ]; then
    nerr=$(grep -c ' Error: ' "$TMP/doc.raw")
    printf "%-46s DOC-FAILED rc=%s errors=%s (oracle could not document this -- NOT a measurement)\n" \
           "$name" "$drc" "$nerr"; n_failed=$((n_failed+1)); rc_all=1; continue
  fi
  if died "$prc"; then
    printf "%-46s PORT-DIED  %s\n" "$name" "$(why $prc)"; n_died=$((n_died+1)); rc_all=1; continue
  fi
  if grep -q '^### \(LOAD-FAILED\|NO-ROOT-SCOPE\|ABS-FAILED\)' "$TMP/port.raw"; then
    printf "%-46s PORT-NO-STATE\n" "$name"; n_nostate=$((n_nostate+1)); rc_all=1; continue
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
      printf "%-46s DOC-EMPTY-EXPECTED  (oracle emits no doc for base/runtime; port=%s entities)\n" "$name" "$np"; n_expected=$((n_expected+1))
    else
      printf "%-46s DOC-EMPTY  (nothing to compare -- NOT a pass)\n" "$name"; n_empty=$((n_empty+1)); rc_all=1
    fi
    continue
  fi

  if [ "$nm" -eq 0 ]; then
    printf "%-46s STATE-MATCH  doc=%-5s port=%-5s port-only=%s\n" "$name" "$nd" "$np" "$extra"; n_match=$((n_match+1))
  else
    printf "%-46s STATE-DIFFER doc=%-5s port=%-5s MISSING=%s\n" "$name" "$nd" "$np" "$nm"; n_diff=$((n_diff+1))
    head -8 "$TMP/missing" | sed 's/^/                                 missing: /'
    rc_all=1
  fi
done

# #227: a SUMMARY line, because this tool had none. Every per-package row on a clean run is
# STATE-MATCH, and batch_gates filters rows it does not recognise -- so inside the batch a fully
# green doccmp stage printed NOTHING AT ALL, which is indistinguishable from "the stage never ran"
# (#26: an absent result is never a pass; #10: never conclude clean from an empty grep). The
# counts also make the partition add up in one glance, so a shortfall is visible rather than
# inferred from a missing row.
printf "DOCCMP-DONE packages=%s match=%s differ=%s empty=%s empty_expected=%s doc_failed=%s died=%s no_state=%s\n" \
       "$n_total" "$n_match" "$n_diff" "$n_empty" "$n_expected" "$n_failed" "$n_died" "$n_nostate"
if [ "$n_match" -eq 0 ] && [ "$n_expected" -eq 0 ]; then
  echo "DOCCMP-ABORTED 0 of $n_total packages were compared -- the counts above are NOT a measurement" >&2
  exit 2
fi
exit $rc_all
