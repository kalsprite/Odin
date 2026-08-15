#!/usr/bin/env bash

# #906: the checker library no longer walks up from CWD to find `base/runtime` (#898 removed it,
# because a LIBRARY's answer must not depend on the caller's working directory). Tools that only
# `cd` into the repo were relying on that walk-up BY ACCIDENT and now report "Undeclared name:
# append" -- runtime never loaded. The harness conforms to the library: export the root.
export ODIN_ROOT="${ODIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
# probe.sh <PORT_BIN> <PROBE_DIR> [PROBE_DIR...] -- compare one probe against the oracle, SAFELY.
#
# WHY THIS EXISTS. Ad-hoc probe comparisons are written as
#     diff <(./odin check $P ... | grep ...) <($PORT $P | grep ...)
# and that construction CANNOT distinguish "both agreed on no diagnostics" from "one of them
# died before printing anything". On 2026-08-03 this misled me twice in one session:
#   #283  the port SIGILL'd at teardown; the diff showed the port emitting nothing and I read
#         it as a missing diagnostic, then spent a tick hunting the wrong function.
#   #285  the ORACLE segfaulted 6/6 on a zero-parameter @(objc_context_provider); I checked the
#         port's rc but not the oracle's and filed "oracle: 0 diagnostics" as the premise.
# Both were the #275 laundering failure -- a crash produces no output, which looks exactly like
# agreement. parity.sh learned this lesson at corpus scale; single probes never did.
#
# So: capture rc on BOTH sides FIRST, classify, and only diff when both actually completed.
#
# Classification follows parity.sh: rc 124 is `timeout`, rc >= 128 is a fatal signal, anything
# else (INCLUDING 1) is a completed run -- `odin check` exits 1 whenever it reports diagnostics,
# so treating non-zero as failure would discard every probe worth comparing.
#
# Exit status: 0 if every probe is MATCH, 1 otherwise. Verdicts are never silently downgraded.

cd /home/kalsprite/dev/odin || exit 2
PORT="$1"; shift
[ -z "$PORT" ] || [ $# -eq 0 ] && { echo "usage: probe.sh <PORT_BIN> <PROBE_DIR>..." >&2; exit 2; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
VET="${PROBE_VET:-}"        # PROBE_VET=1 adds -vet to the oracle; pass a vet-mode port binary
TO="${PROBE_TIMEOUT:-90}"

died() { [ "$1" -eq 124 ] || [ "$1" -ge 128 ]; }
why()  { [ "$1" -eq 124 ] && echo "TIMEOUT" || echo "SIG$(($1-128))"; }

rc_all=0
for p in "$@"; do
  name=$(basename "$p")

  if [ -n "$VET" ]; then
    timeout "$TO" ./odin check "$p" -vet -no-entry-point > "$TMP/o.raw" 2>&1; orc=$?
  else
    timeout "$TO" ./odin check "$p" -no-entry-point > "$TMP/o.raw" 2>&1; orc=$?
  fi
  timeout "$TO" "$PORT" "$p" > "$TMP/p.raw" 2>&1; prc=$?

  # --- the check that ad-hoc diffs omit ---
  if died "$orc" && died "$prc"; then
    printf "%-16s BOTH-DIED    oracle=%s port=%s\n" "$name" "$(why $orc)" "$(why $prc)"; rc_all=1; continue
  fi
  if died "$orc"; then
    printf "%-16s ORACLE-DIED  %s (rc=%s) -- port completed rc=%s. Reproducing an upstream crash is NOT parity; see #285.\n" \
           "$name" "$(why $orc)" "$orc" "$prc"; rc_all=1; continue
  fi
  if died "$prc"; then
    printf "%-16s PORT-DIED    %s (rc=%s) -- oracle completed rc=%s. A crash is worse than a wrong diagnostic; see #283.\n" \
           "$name" "$(why $prc)" "$prc" "$orc"; rc_all=1; continue
  fi

  # The label is NOT always bare "Error:" -- the parser emits "Syntax Error:". Requiring
  # "Error:" immediately after the position silently dropped every syntax diagnostic, so two
  # files whose syntax errors differed ENTIRELY reported "MATCH (0 diagnostics)". Found while
  # probing #288 with a malformed probe: oracle gave 2 syntax errors, port 1, different text,
  # and probe.sh called it a match. parity.sh was never affected -- its pattern is ".*?Error: ".
  # Some diagnostics carry NO label at all. `error_no_newline` (check_stmt.cpp:1363/1635) emits
  # e.g. "main.odin(9:2) Unhandled switch case: string" -- no "Error:", no "Warning:". Requiring
  # a label dropped that entire class, so a DIVERGENCE in it would read as agreement.
  # Matching any positioned line with non-empty text covers labelled and unlabelled alike, and
  # naturally excludes the "first at <pos>" continuation lines, whose text after the position is
  # empty. parity.sh / parity_vet.sh / cmpfull.py still require a label -- see #290.
  DIAG='[^/]+\.odin\(\d+:\d+\) \S.*'
  grep -oP "$DIAG" < "$TMP/o.raw" | sort > "$TMP/o"
  grep -oP "$DIAG" < "$TMP/p.raw" | sort > "$TMP/p"
  n=$(wc -l < "$TMP/o")

  if diff -q "$TMP/o" "$TMP/p" >/dev/null; then
    printf "%-16s MATCH        (%s diagnostics, oracle rc=%s port rc=%s)\n" "$name" "$n" "$orc" "$prc"
  else
    printf "%-16s DIFFER       (oracle %s / port %s diagnostics)\n" "$name" "$n" "$(wc -l < "$TMP/p")"
    diff "$TMP/o" "$TMP/p" | sed 's/^/                 /'
    rc_all=1
  fi
done
exit $rc_all
