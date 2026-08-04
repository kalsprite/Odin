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
PORT="${1:-}"
ROOT="${2:-/tmp/claude-1000/-home-kalsprite-dev-odin/5ae0f352-0d85-4f59-825d-514e4ce56a75/scratchpad}"
[ -z "$PORT" ] || [ ! -x "$PORT" ] && { echo "usage: corpus_vet.sh <VET_PORT_BIN> [PROBE_ROOT]" >&2; exit 2; }
cd /home/kalsprite/dev/odin || exit 2

CORPUS_VET=(shadowparam shadowvar vetctl vetmap)

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
[ $differ -eq 0 ] && [ $missing -eq 0 ]
