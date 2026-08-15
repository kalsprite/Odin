#!/usr/bin/env bash
# crosstarget.sh <PORT_BIN> [PROBE_ROOT] -- oracle-vs-port comparison for probes that need a NON-HOST
# target, and optionally a specific -microarch.
#
# STATUS: VERIFIED 2026-08-09. Clean run 6/6 MATCH rc=0. POSITIVE CONTROL FIRES: pinning
# `arch := Target_Arch_Kind.Amd64` in microarch_default_features (reproducing the #612 defect) turns 4 of
# the 6 probes DIFFER and the gate exits rc=1; reverting returns it to 6/6 rc=0.
#
# WHICH PROBES ARE SENSITIVE TO WHAT -- stated because "the control fired" is not the same as "every
# member is load-bearing". Under that arch-pinning control, mp611 and mp611d still MATCHED: with the arch
# pinned to Amd64 the enabled set still lacks `atomics`, so the gate fires identically and those two
# probes cannot see the fault. They pin the DEFAULT-microarch direction instead. The four that moved
# (mp611d_be, mp611e, mp611f, mp612) are the ones that depend on reading the right arch's feature table.
# A future control that targets a different fault will move a different subset; do not read this split as
# a ranking.
#
# WHY THIS EXISTS. corpus.sh is HOST-TARGET ONLY. Every probe in it runs with no -target and no
# -microarch, so the #611 work -- the wasm atomics gate, the ^u32/u32 operand types, and five bespoke
# operand messages -- could not join it. Those were verified BY HAND and then nothing re-ran them. The
# same hole existed on the parity side until #572 added -target: support, and until then every
# target-dependent rule was measured at exactly one point.
#
# THE TWO TRAPS THIS SCRIPT IS SHAPED AROUND, both paid for in this session:
#
#   1. `odin check` DOES NOT ACCEPT -microarch:. It prints "Unknown flag for 'odin check'" and exits
#      WITHOUT CHECKING ANYTHING. A grep for 'Error' over that output finds nothing and reads as CLEAN.
#      That produced two confidently-wrong claims before it was caught. The oracle side here therefore
#      uses `odin build -build-mode:obj`, which does accept the flag. The script also FAILS LOUDLY if
#      the oracle output contains "Unknown flag", instead of scoring it as a match.
#
#   2. BUILD-VS-CHECK ASYMMETRY. `odin build` runs checks that `odin check` does not -- notably
#      require_results ("...requires that its results must be handled"). The port side is a CHECK-mode
#      harness, so such a line appears on the oracle side only and is a HARNESS artefact, not a defect.
#      Rather than filter it silently, probes are expected to be written so it cannot fire (assigning or
#      returning the result is enough). Any probe that needs filtering must say so in its manifest note.
#
# MANIFEST, NOT A GLOB. corpus.sh's header explains why at length: a glob is a guess, and on 2026-08-03
# it swept in eleven directories that were never probes and reported them as differences. Membership
# here is explicit, one line per probe, and every exclusion is NAMED WITH ITS REASON and PRINTED --
# an excluded probe is UNMEASURED, not clean.

set -o pipefail
# #898: the checker library no longer walks up from CWD to find `base/runtime` -- the root
# must be given to it. The harness conforms to the library, not the other way round, so the
# repo root is exported here (self-locating, and respects an ODIN_ROOT already in the env).
export ODIN_ROOT="${ODIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

PORT="$1"
ROOT="${2:-/home/kalsprite/dev/odin/.claude/probes}"
ODIN="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/odin"

if [ -z "$PORT" ]; then echo "usage: crosstarget.sh <PORT_BIN> [PROBE_ROOT]" >&2; exit 2; fi
if [ ! -x "$PORT" ]; then echo "crosstarget.sh: port binary '$PORT' is not executable" >&2; exit 2; fi
if [ ! -x "$ODIN" ]; then echo "crosstarget.sh: oracle '$ODIN' is not executable" >&2; exit 2; fi

# --- Manifest: "<dir>|<flags>|<what this probe pins>" ----------------------------------------------
MANIFEST=(
  "mp611|-target:js_wasm32|#611 wasm atomics gate FIRES on the default microarch (generic has no atomics)."
  "mp611d|-target:js_wasm32|#611 same, result assigned so require_results cannot confound the comparison."
  "mp611d_be|-target:js_wasm32 -microarch:bleeding-edge|#611 the gate PASSES when atomics is present -- the direction a default-microarch-only probe cannot reach."
  "mp611e|-target:js_wasm32 -microarch:bleeding-edge|#611 bespoke operand message: ^u32 for the memory pointer."
  "mp611f|-target:js_wasm32 -microarch:bleeding-edge|#611 the other four bespoke messages, one bad operand per call (C++ returns after the first failure)."
  "mp612|-target:js_wasm32|#612 has_target_feature: bulk-memory true and sse2 false on wasm32 generic. Pins the per-arch table walk."
  # #823. These are here rather than in corpus.sh because corpus members run plain `odin build`
  # with NO -bedrock, so build_context.no_rtti is false and check_rtti_type_disallowed cannot
  # fire. That is precisely why the defect survived 326 corpus probes and two 323-package parity
  # sweeps. `-bedrock` ALONE is enough: it is a COMPOSITE that sets no_rtti on both sides
  # (C++ main.cpp:1669-1673; the port models it in triage_st). Passing -no-rtti as well would be
  # worse than redundant -- the port harness turns an unknown -flag into a PHANTOM PACKAGE.
  "rtti_decl|-bedrock|#823 the rtti expression-path call: a declaration reaching the check_expr_base tail. Oracle 2 errors, port 1 before the fix."
  "rtti_expr|-bedrock|#823 the same tail via a pure EXPRESSION (an any-returning call, discarded) -- neither a declaration nor a type usage, so only the tail can report it."

  # LEDGER #832. objc_super is DARWIN-ONLY, so nothing in the 327-member corpus or either
  # 323-package parity sweep can reach it -- this row is the FIRST gate over that surface.
  # It exercises three fixes at once: #831's invalid sentinel (the cascading objc_send message
  # reads "of type invalid type" only if the failed builtin repaired the operand), and #832's
  # single collapsed guard plus its corrected predicate. On the pre-fix binary the second
  # diagnostic reads "type has no @(objc_superclass=...) attribute defined" instead of C++'s
  # "expected a pointer to an Objective-C object, but got 'd' of type ^Derived", so this row
  # can fail.
  "p829objc|-target:darwin_amd64|#832 objc_super's guard, message and invalid-sentinel repair -- the only darwin-reachable surface any gate covers."
)

# --- Exclusions: NAMED, with reasons, and PRINTED ---------------------------------------------------
EXCLUSIONS=(
  'mp611b|Produces no diagnostic on either side, so it discriminates nothing. Kept on disk only as the record of a probe that looked meaningful and was not.'
  'mp611c|Superseded by mp611e/mp611f, which fire the messages deliberately rather than incidentally.'
)

norm() { sed -e "s|$ROOT/||g" -e 's/[[:space:]]*$//' | grep -vE '^[[:space:]]*$'; }

pass=0; fail=0; unmeasured=0
echo "=== crosstarget: ${#MANIFEST[@]} probes, oracle=$ODIN port=$PORT ==="
for row in "${MANIFEST[@]}"; do
  dir="${row%%|*}"; rest="${row#*|}"; flags="${rest%%|*}"; note="${rest#*|}"
  if [ ! -d "$ROOT/$dir" ]; then
    printf '  %-12s UNMEASURED  probe directory missing\n' "$dir"; unmeasured=$((unmeasured+1)); continue
  fi

  o_raw="$($ODIN build "$ROOT/$dir" -build-mode:obj -no-entry-point -out:"$ROOT/.ct_$dir.o" $flags 2>&1)"
  # TRAP 1 GUARD: a rejected flag must never be scored as a clean run.
  if printf '%s' "$o_raw" | grep -q 'Unknown flag'; then
    printf '  %-12s UNMEASURED  ORACLE REJECTED A FLAG (%s) -- not a match, the oracle never ran\n' "$dir" "$flags"
    unmeasured=$((unmeasured+1)); continue
  fi
  o="$(printf '%s' "$o_raw" | grep -E '(Error|Warning):' | norm)"
  p="$($PORT "$ROOT/$dir" $flags 2>&1 | grep -E '(Error|Warning):' | norm)"

  if [ "$o" = "$p" ]; then
    printf '  %-12s MATCH       %s\n' "$dir" "$flags"; pass=$((pass+1))
  else
    printf '  %-12s DIFFER      %s\n' "$dir" "$flags"
    printf '      note: %s\n' "$note"
    diff <(printf '%s\n' "$o") <(printf '%s\n' "$p") | sed 's/^/        /'
    fail=$((fail+1))
  fi
  rm -f "$ROOT/.ct_$dir.o"
done

if [ ${#EXCLUSIONS[@]} -gt 0 ]; then
  echo "--- excluded (UNMEASURED, not clean) ---"
  for e in "${EXCLUSIONS[@]}"; do printf '  %-12s %s\n' "${e%%|*}" "${e#*|}"; done
fi

echo "CROSSTARGET-DONE members=${#MANIFEST[@]} match=$pass differ=$fail unmeasured=$unmeasured excluded=${#EXCLUSIONS[@]}"
[ "$fail" -eq 0 ] && [ "$unmeasured" -eq 0 ]
