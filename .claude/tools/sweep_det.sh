#!/bin/bash
# sweep_det.sh <BIN> <OUT>   -- stdout AND stderr into OUT (order matters).
#
# Per-package timeout: the port has a known intermittent deadlock (#25/#41/#141) that can hang
# a single package indefinitely. It strikes even with NO competing load, so running the sweep
# alone reduces but does not eliminate it. Without a timeout one hang stalls the entire sweep
# and the run has to be discarded. A hung package is recorded as ### TIMEOUT and the sweep
# continues; the partitioned diff treats TIMEOUT like CRASH (unstable, excluded).
BIN="$1"; OUT="$2"; S="$(dirname "$0")"

# #761: INPUT CONTRACT. This is a PRODUCER, not a comparator -- its verdict is the file it writes,
# and the judging is done downstream by swdiff.py / flakecmp.py. So it is NOT gated on divergence.
# But it had NO input validation at all, and its failure mode is actively misleading: a missing or
# non-executable BIN makes `timeout 120 "$BIN" "$p"` return 127 for EVERY package, so the output
# becomes 323 `### CRASH` lines. Downstream that reads as "the port crashes on everything" -- a
# catastrophic-looking port regression -- when the real cause is a mistyped path. swdiff's new
# SWDIFF-ABORTED (#761) would catch the consequence, but the tool that KNOWS the cause should say
# so itself (#745: the exit status IS the announcement; #759: assert the capability before
# measuring). Refusing here also costs 323 process spawns less than discovering it later.
[ -n "$BIN" ] && [ -x "$BIN" ] || {
  echo "SWEEP-ABORTED binary '${BIN:-<missing>}' is not executable -- NOTHING WAS SWEPT" >&2
  echo "usage: sweep_det.sh <BIN> <OUT>" >&2; exit 2; }
[ -n "$OUT" ] || { echo "SWEEP-ABORTED no output path given" >&2; exit 2; }
[ -s "$S/pkglist.txt" ] || {
  echo "SWEEP-ABORTED $S/pkglist.txt is missing or empty -- NOTHING WAS SWEPT" >&2; exit 2; }

: > "$OUT" || { echo "SWEEP-ABORTED cannot write '$OUT'" >&2; exit 2; }
n=0; nto=0; ncr=0
while read -r p; do
  [ -d "$p" ] || continue
  n=$((n+1))
  if timeout 120 "$BIN" "$p" >> "$OUT" 2>&1; then :; else
    rc=$?
    if [ $rc -eq 124 ]; then echo "### TIMEOUT $p" >> "$OUT"; nto=$((nto+1))
    else echo "### CRASH $p" >> "$OUT"; ncr=$((ncr+1)); fi
  fi
done < "$S/pkglist.txt"
# The counts go in the FILE, so the sweep is self-describing: a reader of an old sweep can see how
# much of it was usable without re-deriving it by grepping for the markers.
echo "SWEEP-DONE packages=$n timeouts=$nto crashes=$ncr" >> "$OUT"
