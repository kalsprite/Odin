#!/bin/bash
# dumpdet.sh -- determinism screen for the MODEL DUMP, with an ASLR control.
#
# WHY THIS EXISTS. flake.sh screens DIAGNOSTICS for run-to-run variation. It cannot see the
# semantic model, so an entity-ORDER defect is invisible to it -- which is exactly how #335 stayed
# open. -dump-model (#343) exposes the model; this script turns it into a repeatable metric.
#
# WHAT IT MEASURES. N runs, counting DISTINCT md5s of each dump view:
#   insertion view -- order-sensitive. This is the #335 metric.
#   sorted view    -- order-INdependent. If this varies, the SET changed, which is #344, a
#                     different and worse defect. Reported separately so the two never get
#                     confused again (they were, until LEDGER #427 split them).
#
# THE ASLR CONTROL IS THE POINT. Odin's map iteration order is address-derived even for string
# keys (measured, LEDGER #437), so an address-ordered iteration shows up as variance with ASLR ON
# and vanishes under `setarch -R`. This script runs BOTH arms:
#   ASLR OFF distinct == 1  -> the harness can see stability at all. A POSITIVE CONTROL; if this
#                              is not 1, something else is nondeterministic and the ASLR-ON number
#                              means nothing.
#   ASLR ON  distinct == 1  -> no address-ordered iteration remains on this target. The goal.
#
# N MATTERS. LEDGER #439 compared 4-distinct-of-5 against 5-distinct-of-5 and briefly read it as
# an improvement. It is not -- at n=5 one repeat is ordinary chance. Default is 12.
#
# USAGE: dumpdet.sh <BIN> [TARGET] [N]
set -u
cd /home/kalsprite/dev/odin

BIN="${1:-}"; TARGET="${2:-core/odin/parser}"; N="${3:-12}"; MODE="${4:-seq}"

# MODE (LEDGER #461, for task #344):
#   seq       (default) -- the #335 shape. Runs -no-threads and contrasts ASLR on/off. Answers
#                          "is there address-seeded nondeterminism in the ORDER?"
#   threaded             -- the #344 shape. Runs WITH the thread pool and reports both views.
#                          Answers "does worker scheduling change the model?"
#
# The two modes need DIFFERENT controls, and using seq's control for threaded would be wrong:
# under threading, ASLR-off is NOT expected to be stable (scheduling varies regardless), so an
# unstable ASLR-off arm would prove nothing. Threaded mode's control is instead a -no-threads PAIR
# that must be identical -- that proves the harness and the target are otherwise deterministic, so
# any variance in the threaded arm is attributable to the pool.
case "$MODE" in seq|threaded) ;; *)
  echo "DUMPDET-ABORTED reason=bad-mode '$MODE' (expected seq|threaded)" >&2; exit 2 ;;
esac
[ -x "$BIN" ] || { echo "DUMPDET-ABORTED reason=bin-missing: '$BIN'" >&2; exit 2; }
[ -d "$TARGET" ] || { echo "DUMPDET-ABORTED reason=target-missing: '$TARGET'" >&2; exit 2; }
command -v setarch >/dev/null || { echo "DUMPDET-ABORTED reason=no-setarch" >&2; exit 2; }

# LEDGER #435. The checker checks ITS OWN SOURCE, so if the target is inside core/odin/checker any
# edit to the checker changes the measurement INPUT, not just the instrument. Cross-run comparisons
# then silently compare different programs. Refuse rather than produce a number that looks fine.
case "$TARGET" in
  core/odin/checker*|./core/odin/checker*)
    echo "DUMPDET-ABORTED reason=self-target '$TARGET'" >&2
    echo "         The checker's own source is the thing you are editing; measuring it means the" >&2
    echo "         INPUT moves with the fix. Pick a target outside core/odin/checker." >&2
    exit 2 ;;
esac

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# arm <label> <runner...>  -- prints "<label> insertion=<d>/<N> sorted=<d>/<N>"
arm() {
  local label="$1"; shift
  local i
  : > "$TMP/ins.$label"; : > "$TMP/srt.$label"
  for ((i=0; i<N; i++)); do
    local f="$TMP/d.$label.$i"
    "$@" "$BIN" "$TARGET" $THREADFLAG "-dump-model:$f" >/dev/null 2>&1
    # VACUITY GUARD (#405). A missing dump md5s to a constant, so absent runs would read as
    # perfectly stable -- the exact false-green this whole family keeps producing.
    if [ ! -s "$f" ]; then
      echo "DUMPDET-ABORTED reason=no-dump arm=$label run=$i -- NOT a clean result." >&2
      : > "$TMP/FAIL"; echo "0 0"; return 2
    fi
    # SECOND VACUITY GUARD (LEDGER #462). The check above only proves the FILE exists. A dump with
    # ZERO ENTITIES is a well-formed file whose md5 is constant, so it reports as perfectly stable
    # -- measured on base/intrinsics, which has no entities at all and scored 1/8. That is the same
    # false-green shape as #405, one level in: absence of content is indistinguishable from stable
    # content whenever the metric counts DIFFERENCES.
    local ne
    ne=$(grep -c '^ins' "$f")
    if [ "$ne" -eq 0 ]; then
      echo "DUMPDET-ABORTED reason=zero-entities arm=$label run=$i target='$TARGET'" >&2
      echo "         The dump is well-formed but EMPTY, so any stability result is vacuous." >&2
      : > "$TMP/FAIL"; echo "0 0"; return 2
    fi
    sed -n '/^## insertion-order/,/^## sorted/p' "$f" | md5sum | cut -c1-12 >> "$TMP/ins.$label"
    sed -n '/^## sorted/,/^## end/p'            "$f" | md5sum | cut -c1-12 >> "$TMP/srt.$label"
  done
  local di ds
  di=$(sort -u "$TMP/ins.$label" | wc -l)
  ds=$(sort -u "$TMP/srt.$label" | wc -l)
  echo "$di $ds"
}

if [ "$MODE" = threaded ]; then
  # CONTROL FIRST, and it must pass before the measurement means anything: two -no-threads runs
  # must be byte-identical. If they are not, the target is nondeterministic for some reason OTHER
  # than the pool and nothing in the threaded arm can be attributed to scheduling.
  THREADFLAG="-no-threads" N_SAVE=$N N=2
  read -r CTL_INS CTL_SRT <<<"$(arm ctl)"
  [ -e "$TMP/FAIL" ] && exit 2
  N=$N_SAVE
  THREADFLAG=""
  read -r THR_INS THR_SRT <<<"$(arm thr)"
  [ -e "$TMP/FAIL" ] && exit 2
  # LEDGER #470. The sorted view over ALL entities has a CEILING it can never pass on any target
  # containing polymorphic code, and the ceiling is not a port defect. Polymorphic instantiations
  # are created through a find-or-create whose two cache scans both release their shared lock
  # before the create+append (check_poly_proc.odin, and C++ check_expr.cpp:483-638 line for line),
  # so two workers can both miss and both create. Measured on core/strings: sequential is a
  # constant 47 instantiations and byte-stable; threaded ranges 47..54 -- 47 is the MINIMUM, i.e.
  # threading only ever ADDS duplicates. The port reproduces upstream's race faithfully, so
  # "sorted=1/N over everything" is not an achievable target and reporting it as a failure would
  # train the reader to ignore this gate.
  #
  # So report BOTH: the raw sorted view, and the sorted view with instantiations excluded. The
  # latter is the metric that can legitimately reach 1/N, and it is the one rc keys off.
  instfree() {
    local label="$1" i
    for ((i=0; i<N; i++)); do
      sed -n '/^## sorted/,/^## end/p' "$TMP/d.$label.$i" \
        | grep '^entity' | grep -v '<instantiation>' | md5sum | cut -c1-12
    done | sort -u | wc -l
  }
  THR_SRT_NI=$(instfree thr)
  INSTS=$(for f in "$TMP"/d.thr.*; do
            sed -n '/^## sorted/,/^## end/p' "$f" | grep -c '<instantiation>'
          done | sort -n | uniq | tr '\n' ' ')
  ENTS=$(grep -m1 '^## insertion-order' "$TMP/d.thr.0" | grep -o '[0-9]*')
  CNTS=$(for f in "$TMP"/d.thr.*; do grep -m1 '^## insertion-order' "$f" | grep -o '[0-9]*'; done \
         | sort -n | uniq | tr '\n' ' ')
  echo "target=$TARGET runs=$N mode=threaded entities(run0)=$ENTS"
  echo "  CONTROL -no-threads x2   insertion=$CTL_INS/2  sorted=$CTL_SRT/2"
  echo "  THREADED                 insertion=$THR_INS/$N  sorted=$THR_SRT/$N"
  echo "  entity counts seen: $CNTS"
  echo "  SORTED excl. instantiations   $THR_SRT_NI/$N     (instantiation counts seen: $INSTS)"
  rc=0
  if [ "$CTL_INS" -ne 1 ] || [ "$CTL_SRT" -ne 1 ]; then
    echo "  CONTROL FAILED: the target is not deterministic even single-threaded, so the threaded" >&2
    echo "                  numbers cannot be attributed to the pool. Fix that first." >&2
    rc=2
  else
    if [ "$THR_SRT_NI" -ne 1 ]; then
      echo "  SET VARIES under threading, EXCLUDING instantiations -- a real defect (#344 family)."
      rc=1
    elif [ "$THR_SRT" -ne 1 ]; then
      echo "  set varies ONLY in polymorphic instantiations -- upstream's own find-or-create race,"
      echo "  reproduced faithfully (#470). Not a port defect; not counted as a failure."
    fi
    # INSERTION ORDER IS NOT SOMETHING THIS GATE CAN FAIL ON, because both implementations append
    # to info.entities from several collection workers at once (port check_collect.odin:459, C++
    # checker.cpp:5801), so the order follows the scheduler upstream exactly as it does here.
    # Failing on it would leave the gate permanently red for a reason the port cannot fix.
    #
    # DO NOT READ "expected" AS "harmless" (LEDGER #474 corrects #470 on exactly this). That order
    # DECIDES WHICH ENTITY RESOLVES A CROSS-PACKAGE DECLARATION FIRST, in the single-threaded Phase
    # 4 that walks info.entities -- and therefore which package an entity ends up attributed to
    # (#469). It is load-bearing, it is just not something a determinism gate on THIS side can act
    # on. The SET (excluding instantiations) is what rc keys off.
    [ "$THR_INS" -ne 1 ] && echo "  order varies under threading (insertion view) -- expected: append order follows the scheduler."
    [ "$rc" -eq 0 ] && echo "  DUMPDET-CLEAN: deterministic under threading."
  fi
  echo "DUMPDET-DONE rc=$rc"
  exit $rc
fi

THREADFLAG="-no-threads"
read -r ON_INS  ON_SRT  <<<"$(arm on)"
[ -e "$TMP/FAIL" ] && exit 2
read -r OFF_INS OFF_SRT <<<"$(arm off setarch -R)"
[ -e "$TMP/FAIL" ] && exit 2

# GRADED METRIC. Distinct-md5 is effectively BINARY: one surviving address-ordered iteration keeps
# it pegged at N/N no matter how many others were fixed. That makes it blind to partial progress,
# which matters because this is plausibly a MULTI-FACTOR defect -- several independent raw map
# iterations each contributing. LEDGER #439 mis-read a null from this metric as evidence against a
# change; it was only evidence the metric could not resolve it.
#
# So also count HOW MANY ENTITIES MOVE: take each run's insertion-view entity sequence, and count
# positions that are not identical across all runs. Fixing one of several contributing sites should
# lower this even while distinct-md5 stays N/N.
movers() {
  local label="$1" i
  for ((i=0; i<N; i++)); do
    sed -n '/^## insertion-order/,/^## sorted/p' "$TMP/d.$label.$i" \
      | grep '^ins' | awk -F'\t' '{print $3"/"$4}' > "$TMP/seq.$label.$i"
  done
  # paste the N sequences side by side; a row where any column differs is a moved position
  paste "$TMP"/seq."$label".* | awk '{
    for (i=2; i<=NF; i++) if ($i != $1) { moved++; break }
  } END { print moved+0 }'
}
ON_MOVERS=$(movers on)
OFF_MOVERS=$(movers off)

ENTS=$(grep -m1 '^## insertion-order' "$TMP/d.on.0" | grep -o '[0-9]*')
echo "target=$TARGET runs=$N entities=$ENTS"
echo "  ASLR OFF (control)  insertion=$OFF_INS/$N  sorted=$OFF_SRT/$N  moved_positions=$OFF_MOVERS"
echo "  ASLR ON             insertion=$ON_INS/$N  sorted=$ON_SRT/$N  moved_positions=$ON_MOVERS"
echo "  (moved_positions is the GRADED metric -- compare it across candidate fixes; distinct-md5"
echo "   stays pegged at $N/$N while ANY address-ordered iteration survives.)"

rc=0
if [ "$OFF_INS" -ne 1 ] || [ "$OFF_SRT" -ne 1 ]; then
  echo "  CONTROL FAILED: not stable even with ASLR off. Something OTHER than address order varies;" >&2
  echo "                  the ASLR-ON numbers below cannot be attributed and must not be quoted." >&2
  rc=2
fi
[ "$ON_SRT" -ne 1 ] && { echo "  SET VARIES (sorted view) -- that is #344 territory, not #335."; rc=1; }
[ "$ON_INS" -ne 1 ] && { echo "  ORDER VARIES (insertion view) -- an address-ordered iteration remains (#335)."; rc=1; }
[ "$rc" -eq 0 ] && echo "  DUMPDET-CLEAN: deterministic under ASLR."
echo "DUMPDET-DONE rc=$rc"
exit $rc
