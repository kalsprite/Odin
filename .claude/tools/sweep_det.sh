#!/bin/bash
# sweep_det.sh <BIN> <OUT>   -- stdout AND stderr into OUT (order matters).
#
# Per-package timeout: the port has a known intermittent deadlock (#25/#41/#141) that can hang
# a single package indefinitely. It strikes even with NO competing load, so running the sweep
# alone reduces but does not eliminate it. Without a timeout one hang stalls the entire sweep
# and the run has to be discarded. A hung package is recorded as ### TIMEOUT and the sweep
# continues; the partitioned diff treats TIMEOUT like CRASH (unstable, excluded).
BIN="$1"; OUT="$2"; S="$(dirname "$0")"
: > "$OUT"
while read -r p; do
  [ -d "$p" ] || continue
  if timeout 120 "$BIN" "$p" >> "$OUT" 2>&1; then :; else
    rc=$?
    if [ $rc -eq 124 ]; then echo "### TIMEOUT $p" >> "$OUT"; else echo "### CRASH $p" >> "$OUT"; fi
  fi
done < "$S/pkglist.txt"
echo "SWEEP-DONE" >> "$OUT"
