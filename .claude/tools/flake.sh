#!/bin/bash
# flake.sh <BIN> <RUNS> [OUTDIR]  -- determinism screen over the full package list.
#
# Runs sweep_det.sh RUNS times with the SAME binary and reports every package whose output
# is not byte-identical across all runs. Works for either harness: pass a plain triage
# binary or a vet one -- the only difference is which binary you hand it, which is what
# LEDGER #280 needs (the redeclaration-file flip was only ever seen in VET mode, and there
# was no vet-capable determinism screen).
#
# WHY THIS EXISTS SEPARATELY FROM parity.sh: parity compares PORT vs ORACLE and so cannot
# distinguish "the port disagrees with the reference" from "the port disagrees with itself".
# A flip that is nondeterministic shows up in parity as an intermittent mismatch and is easy
# to misread as a fixed divergence. This screen holds the reference constant by removing it.
#
# RUN IT ALONE. sweep_det.sh uses a 120s per-package timeout and parity.sh's header documents
# that concurrent sweeps push slow packages past their timeout; a TIMEOUT here would be
# reported as a difference and manufacture a false flake.
set -o pipefail
BIN="$1"; RUNS="${2:-3}"; OUT="${3:-/tmp/claude-1000/-home-kalsprite-dev-odin/5ae0f352-0d85-4f59-825d-514e4ce56a75/scratchpad}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -z "$BIN" ] || [ ! -x "$BIN" ]; then echo "usage: flake.sh <BIN> <RUNS> [OUTDIR]" >&2; exit 2; fi

FLAKE_LOCK=/tmp/.odin_flake_running
if [ -f "$FLAKE_LOCK" ] && kill -0 "$(cat "$FLAKE_LOCK" 2>/dev/null)" 2>/dev/null; then
  echo "WARNING: flake run PID $(cat "$FLAKE_LOCK") is still active; concurrent sweeps cause" >&2
  echo "         spurious TIMEOUTs that read as flakes. Prefer sequential runs." >&2
fi
echo $$ > "$FLAKE_LOCK"
trap 'rm -f "$FLAKE_LOCK"' EXIT

for i in $(seq 1 "$RUNS"); do
  echo "run $i/$RUNS ..." >&2
  bash "$HERE/sweep_det.sh" "$BIN" "$OUT/flake_run$i.txt"
done

python3 "$HERE/flakecmp.py" "$OUT" "$RUNS"
