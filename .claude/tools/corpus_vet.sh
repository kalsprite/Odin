#!/usr/bin/env bash
# corpus_vet.sh <VET_PORT_BIN> [PROBE_ROOT] -- the VET-mode probe corpus.
#
# WHY THIS EXISTS. corpus.sh drives the PLAIN harness, so the four vet-mode probes could never be
# members of it -- running them there compares a vet probe against a non-vet oracle. They were
# therefore parked in corpus.sh's EXCLUDED list with the note "vet-mode probe -- must be run with
# triage_vet, not this harness", which was true and also meant NOTHING RAN THEM. An exclusion that
# names the right tool but leaves no tool that does it is a coverage hole wearing a reason.
# LEDGER #384.
#
# The oracle invocation mirrors parity_vet.sh exactly: `odin check <p> -vet -no-entry-point`.
# Compares TEXTS, not counts (#363: agreeing counts hid four swapped messages in fb2).
set -u
# #898: the checker library no longer walks up from CWD to find `base/runtime` -- the root
# must be given to it. The harness conforms to the library, not the other way round, so the
# repo root is exported here (self-locating, and respects an ODIN_ROOT already in the env).
export ODIN_ROOT="${ODIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

PORT="${1:-}"
ROOT="${2:-/home/kalsprite/dev/odin/.claude/probes}"
[ -z "$PORT" ] || [ ! -x "$PORT" ] && { echo "usage: corpus_vet.sh <VET_PORT_BIN> [PROBE_ROOT]" >&2; exit 2; }
cd /home/kalsprite/dev/odin || exit 2

CORPUS_VET=(shadowparam shadowvar vetctl vetmap)

# HARNESS SELF-CHECK. This gate requires the VET harness (.claude/tools/triage_vet). Handing it the
# PLAIN harness (triage_st) makes every vet probe come back EMPTY on the port side, which the loop below
# scores as "differ" -- i.e. it reports a REGRESSION when the only fault is the caller's argument.
# That has now happened TWICE: #511 (against parity_vet.sh, retracted) and again here, where it read as
# corpus_vet 4/4 -> 2/2. Both times the number looked like a defect and was not.
# The check: vetctl is known to yield vet diagnostics under -vet on the ORACLE. If the oracle produces
# lines for it and the port produces NONE, the port cannot be a vet harness. Refuse, loudly, rather than
# report differ -- an unmeasured run must never be scoreable (#483).
if [ -d "$ROOT/vetctl" ]; then
  _o=$(timeout 120 ./odin check "$ROOT/vetctl" -vet -no-entry-point 2>&1 | grep -cE "Error:|Warning:")
  _v=$(timeout 120 "$PORT" "$ROOT/vetctl"                           2>&1 | grep -cE "Error:|Warning:")
  if [ "$_o" -gt 0 ] && [ "$_v" -eq 0 ]; then
    echo "corpus_vet.sh: '$PORT' produced NO diagnostics on vetctl while the oracle produced $_o." >&2
    echo "  This is the PLAIN harness, not the VET harness. Build and pass triage_vet:" >&2
    echo "     ./odin build .claude/tools/triage_vet -out:<path> -o:minimal" >&2
    echo "  REFUSING to score -- see #511. Not a regression; a wrong argument." >&2
    exit 2
  fi
fi

match=0; differ=0; missing=0
for p in "${CORPUS_VET[@]}"; do
  if [ ! -d "$ROOT/$p" ]; then printf "MISSING-PROBE %s\n" "$p"; missing=$((missing+1)); continue; fi
  o=$(timeout 120 ./odin check "$ROOT/$p" -vet -no-entry-point 2>&1 | grep -E "Error:|Warning:" | sed 's|.*/||')
  v=$(timeout 120 "$PORT" "$ROOT/$p"                            2>&1 | grep -E "Error:|Warning:" | sed 's|.*/||')
  if [ "$o" = "$v" ]; then
    printf "%-14s TEXT-MATCH  (%s lines)\n" "$p" "$(printf '%s' "$o" | grep -c . )"
    match=$((match+1))
  else
    printf "%-14s TEXT-DIFFER\n" "$p"
    diff <(printf '%s\n' "$o") <(printf '%s\n' "$v") | sed 's/^/    /'
    differ=$((differ+1))
  fi
done
echo "CORPUS-VET-DONE members=${#CORPUS_VET[@]} match=$match differ=$differ missing=$missing"

# LEDGER #745 (Jon: "if its got an error in the checker port it needs announced from tool").
# A probe that is not on disk is NOT a pass. Until now `missing` was counted, printed inside the
# summary above, and then ignored -- so a run that located 4 of 302 members printed `members=302`
# and exited 0. That is the #380 failure one level up: the guard was added for the COMPARATOR
# dying, and left open for the INPUTS going missing. #155/#26: a green from an instrument that had
# nothing to measure is not evidence.
if [ "$missing" -gt 0 ]; then
  echo "CORPUS-VET-ABORTED $missing of ${#CORPUS_VET[@]} probe directories are MISSING from $ROOT -- the numbers above are NOT a measurement" >&2
  exit 1
fi

[ $differ -eq 0 ] && [ $missing -eq 0 ]
