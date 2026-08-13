#!/usr/bin/env bash
# Full oracle-vs-port PARITY at package granularity: error counts AND sorted diagnostic TEXT.
#
# This is the only instrument anchored to the REFERENCE rather than to the port's own history.
# swdiff.py compares port-run-N to port-run-N+1 and therefore cannot see a divergence that has
# always been present (see LEDGER #269). Run BOTH after every change.
#
# Text is compared as a SORTED MULTISET, so a pure ordering difference between the two compilers
# does not register; ordering is swdiff/flake.sh's job, not this one.
#
# CRASH/TIMEOUT PARTITION (LEDGER #275). Until 2026-08-03 this script piped each compiler straight
# into grep and compared line counts, never looking at exit status. A port run killed by the known
# intermittent #141 crash produces no diagnostics, so it was reported as a legitimate
# "oracle=N port=0" count mismatch. Three of the first vet-run's seven count mismatches were exactly
# that -- they matched the oracle perfectly when re-run individually. swdiff.py has always had this
# partition; this script was built without one (#269) and reported "clean" partly on luck.
#
# The classification rule is SIGNAL-BASED, not `rc != 0`. `odin check` exits 1 whenever it reports
# diagnostics at all (verified: a package with one type error gives rc=1), so treating any non-zero
# status as a crash would exclude every package that has errors -- i.e. exactly the ones worth
# comparing. Only two things mean "this run produced no trustworthy output":
#   rc == 124  -> `timeout` killed it
#   rc >= 128  -> killed by a signal (139 SIGSEGV, 134 SIGABRT, ...)
# Anything else, including 1, is a completed run.
#
# Excluded packages are PRINTED, never silently dropped: an exclusion is an unmeasured package, not
# a clean one.
cd /home/kalsprite/dev/odin
PORT="${1:-}"; LIST="${2:-}"; TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# ARGUMENT GUARD (LEDGER #385). Omitting the LIST argument used to make `done < "$LIST"` fail with
# "No such file or directory", the loop body never run, and the script still print
#   PARITY-DONE packages=0 compared=0 excluded=0 count_mismatches=0 text_mismatches=0 ...
# -- three zeroes that read exactly like a clean sweep. That is #380's failure mode (a summariser
# that cannot tell "nothing was wrong" from "nothing ran") reappearing in a second instrument.
# Abort loudly instead: a harness that measured nothing must never emit a DONE line.
if [ -z "$PORT" ] || [ ! -x "$PORT" ]; then
  echo "PARITY-ABORTED: port binary '$PORT' missing or not executable. usage: parity.sh <PORT_BIN> <PKGLIST>" >&2
  exit 2
fi
if [ -z "$LIST" ] || [ ! -r "$LIST" ]; then
  echo "PARITY-ABORTED: package list '$LIST' missing or unreadable. usage: parity.sh <PORT_BIN> <PKGLIST>" >&2
  exit 2
fi

# CONCURRENCY GUARD (lockfile, not pgrep).
# Running two full parities at once makes slow packages exceed their per-package timeout, and a
# TIMEOUT is reported as EXCLUDED -- i.e. UNMEASURED. On 2026-08-03 a concurrent plain+vet run
# excluded core/rexcode/isa/mips/tablegen/generated on a TIMEOUT; run alone it completes in ~1s,
# rc=0. That is the #275 failure mode one level up: contention manufacturing an exclusion that
# reads like a clean result.
#
# The first version of this guard used `pgrep -f parity.*\.sh` and FIRED ON ITSELF, because the
# invoking wrapper's command line also contains the script path. A warning that always fires is
# worse than no warning -- it trains you to ignore it. Hence a lockfile keyed on a real PID.
PARITY_LOCK=/tmp/.odin_parity_running
if [ -f "$PARITY_LOCK" ] && kill -0 "$(cat "$PARITY_LOCK" 2>/dev/null)" 2>/dev/null; then
  echo "WARNING: parity run PID $(cat "$PARITY_LOCK") is still active. Concurrent runs cause" >&2
  echo "         spurious TIMEOUTs, reported as EXCLUDED (unmeasured). Prefer sequential runs." >&2
fi
echo $$ > "$PARITY_LOCK"
trap 'rm -rf "$TMP"; rm -f "$PARITY_LOCK"' EXIT

# STARTUP REAP. The trap above frees this run's TMP on a normal exit -- but a trap cannot run when
# the process is SIGKILLed, and these runs do get killed (five shells by hand on 2026-08-09 alone,
# plus anything cut short by a wedged machine). Those TMPs leak by construction, and /tmp here is a
# 94 GB tmpfs, so a leak is RAM. By 2026-08-09 that had reached 58.7 GB in 18,317 abandoned dirs and
# wedged every shell on the box. A startup sweep is the only thing that bounds it; see the age and
# signature guards in reap_scratch.sh for why this is safe beside a concurrent sibling.
. .claude/tools/reap_scratch.sh
reap_scratch


# THE ORACLE MUST EXIST. On 2026-08-05 the ./odin binary vanished mid-tick (cause unknown).
# A missing oracle does not error here -- `timeout 180 ./odin check ...` just fails, the captured
# output is empty, and every package reads as "oracle=0". Against a port that reports normally
# that manufactures a mismatch on every package; against a port that also reports nothing it
# manufactures a CLEAN SWEEP. Both readings are fiction, and the second is the dangerous one.
#
# This is the #275/#385 family again: an instrument reporting a result for work it did not do.
# Guard it the same way -- abort loudly rather than print a number nobody can trust.
if [ ! -x ./odin ]; then
  echo "PARITY-ABORTED reason=oracle-missing: ./odin is absent or not executable." >&2
  echo "         Rebuild it with ./build_odin.sh release before trusting any parity number." >&2
  exit 2
fi

# HANG STATE CAPTURE (#301). parity.sh used to record THAT a package died and never WHY, so the
# one timeout it has ever caught -- riscv/tools, 2026-08-05 -- was undiagnosable after the fact and
# had to be closed by refuting hypotheses instead of by reading evidence. A bare rc=124 in a log is
# not a bug report.
#
# `timeout` kills the process, which destroys exactly the state worth having. So the run is polled
# instead, and if it overruns, per-thread state is dumped BEFORE the kill. /proc/<pid>/task/*/wchan
# is the load-bearing field: it names the kernel function each thread is blocked in, which
# distinguishes a futex deadlock (the #299/#25/#278 family) from a spin from real work. It needs no
# ptrace, so it survives ptrace_scope=1 where gdb -p does not; eu-stack is attempted too but is
# expected to fail under that setting and its failure is not an error.
PARITY_HANGDIR="${PARITY_HANGDIR:-$TMP/hangs}"
mkdir -p "$PARITY_HANGDIR"

capture_hang() {
  local pid="$1" label="$2" pkg="$3"
  local f="$PARITY_HANGDIR/hang-$(echo "$pkg" | tr '/' '_')-$label.txt"
  {
    echo "=== $label pid=$pid pkg=$pkg -- still alive after ${PARITY_TIMEOUT}s ==="
    date -u +"captured %Y-%m-%dT%H:%M:%SZ"
    echo "--- process ---"
    grep -E '^(State|Threads|VmRSS):' "/proc/$pid/status" 2>/dev/null
    echo "--- threads (state, wchan = where it is blocked) ---"
    for t in /proc/$pid/task/*; do
      [ -d "$t" ] || continue
      echo "  tid=${t##*/} state=$(awk '{print $3}' "$t/stat" 2>/dev/null)" \
           "wchan=$(cat "$t/wchan" 2>/dev/null || echo '?')" \
           "comm=$(cat "$t/comm" 2>/dev/null)"
    done
    echo "--- eu-stack (best effort; ptrace_scope=1 denies this, which is expected) ---"
    eu-stack -p "$pid" 2>&1 | head -80
  } > "$f" 2>&1
  echo "         HANG STATE -> $f" >&2
}

# run_guarded <outfile> <label> <pkg> <cmd...> -- like `timeout`, but dumps thread state first.
PARITY_TIMEOUT="${PARITY_TIMEOUT:-180}"
run_guarded() {
  local out="$1" label="$2" pkg="$3"; shift 3
  "$@" > "$out" 2>&1 &
  local pid=$! waited=0 fast=0
  # ADAPTIVE POLL. A flat `sleep 1` would add a full second to EVERY package -- ~11 minutes over a
  # 323-package sweep -- because almost every run finishes in well under a second. So poll at 50ms
  # for the first 2 seconds (which covers essentially all real runs), then fall back to 1s for the
  # long tail, where a second of granularity against a 180s budget costs nothing.
  while kill -0 "$pid" 2>/dev/null && [ "$waited" -lt "$PARITY_TIMEOUT" ]; do
    if [ "$fast" -lt 40 ]; then
      sleep 0.05; fast=$((fast+1))
      [ "$fast" -eq 40 ] && waited=2
    else
      sleep 1; waited=$((waited+1))
    fi
  done
  if kill -0 "$pid" 2>/dev/null; then
    capture_hang "$pid" "$label" "$pkg"
    kill -9 "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
    return 124
  fi
  wait "$pid"
}

# died <rc> -- true if the run did not complete (timeout or fatal signal), false otherwise.
died() { [ "$1" -eq 124 ] || [ "$1" -ge 128 ]; }
why()  { [ "$1" -eq 124 ] && echo "TIMEOUT" || echo "SIG$(($1-128))"; }

# ------------------------------------------------------------------------------------------------
# #594 STEP 2 (LEDGER #766): BOUNDED FAN-OUT.
#
# Step 1 (#765) gave every package its own scratch dir and was verified inert over a full 323-package
# sweep. That was the precondition: with the old shared fixed-name scratch, two concurrent workers
# would have compared one package's ORACLE output against another's PORT output -- silently, and
# surfacing as a TEXT row, the one GATED column.
#
# THE OTHER TWO BLOCKERS, and how they are handled here:
#
#  * COUNTERS. They used to be shell variables incremented in the loop body. Under `&` the body runs
#    in a SUBSHELL and every increment is lost at the join -- the script would print
#    `PARITY-DONE ... 0 0 0` and exit 0, a green gate that measured nothing (#380/#385's family).
#    So each worker now writes a one-word VERDICT FILE, and the parent tallies after the join.
#    Nothing is counted in a subshell.
#
#  * OUTPUT ORDER. Findings used to print in list order, which is what makes two sweeps
#    line-comparable -- the technique that caught every regression in this batch. Interleaved
#    parallel output would destroy that. Workers therefore write their rows to a per-package file
#    and the parent cats them IN LIST ORDER at the join.
#
# THE TIMEOUT PROBLEM, AND WHY THIS DOES NOT JUST RAISE IT.
# This script's own concurrency-guard comment records the precedent: a concurrent plain+vet run
# excluded core/rexcode/isa/mips/tablegen/generated on a TIMEOUT that completes in ~1s alone. A
# spurious timeout is reported EXCLUDED, i.e. UNMEASURED, and `compared` silently drops (#275). That
# is the exact failure this change could mass-produce.
#
# Simply multiplying PARITY_TIMEOUT by the width would trade one bad property for another: a genuine
# deadlock (#25/#41/#141 are real here) would then take width x 180s to surface, every time.
#
# So instead: **a death under concurrency is not admissible evidence.** Any package whose oracle or
# port run times out or takes a signal during the parallel pass is put on a RETRY LIST and re-run
# SEQUENTIALLY, alone, at the normal timeout. Only a second death makes it EXCLUDED. Contention and
# a real hang are thereby distinguished by measurement rather than assumed apart -- and `excluded=0`
# stays a meaningful acceptance criterion instead of becoming noise.
#
# WIDTH is deliberately conservative. The machine has 32 cores and #301 was loadavg 88; the PORT is
# itself a threaded checker, so W workers do not use W cores. Default 6, override with PARITY_JOBS.
PARITY_JOBS="${PARITY_JOBS:-6}"

mapfile -t PKGS < <(grep -v '^[[:space:]]*$' "$LIST")

# check_one <idx> <pkg> -- the entire former loop body, writing a verdict + rows instead of
# mutating shell state. Runs in a background subshell; must touch nothing the parent reads.
check_one() {
  local n="$1" p="$2" D orc prc tag o q
  D="$TMP/pkg$n"
  mkdir -p "$D"
  : > "$D/out"

  run_guarded "$D/o.raw" oracle "$p" ./odin check "$p" -no-entry-point; orc=$?
  run_guarded "$D/p.raw" port   "$p" "$PORT" "$p";                      prc=$?

  if died "$orc" || died "$prc"; then
    tag=""
    died "$orc" && tag="oracle=$(why "$orc") "
    died "$prc" && tag="${tag}port=$(why "$prc")"
    printf 'DIED %s\n' "$tag" > "$D/verdict"
    return 0
  fi

  # Pattern covers LABELLED and UNLABELLED diagnostics alike. `error_no_newline`
  # (check_stmt.cpp:1363/1635) emits "file(pos) Unhandled switch case: ..." with no "Error:" /
  # "Warning:" label at all, so a label-requiring pattern dropped that entire class and a
  # divergence in it would have read as agreement. Requiring non-empty text after the position
  # naturally excludes the "first at <pos>" continuation lines, whose text there is empty.
  #
  # ADOPTED ONLY AFTER MEASURING (#290): the same binary was run through the old and new patterns
  # over all 225 packages and the finding lines were BYTE-IDENTICAL, while a probe carrying an
  # unlabelled diagnostic went 2 -> 3 captured. Free, and strictly more sensitive. Per #275, an
  # instrument change that silently alters what is counted is never adopted without that diff.
  grep -oP '(?<=/odin/)[^ ]*\.odin\(\d+:\d+\) \S.*' < "$D/o.raw" | sort > "$D/o"
  grep -oP '(?<=/odin/)[^ ]*\.odin\(\d+:\d+\) \S.*' < "$D/p.raw" | sort > "$D/p"
  o=$(wc -l < "$D/o"); q=$(wc -l < "$D/p")
  if [ "$o" != "$q" ]; then
    printf 'COUNT\n' > "$D/verdict"
    printf "COUNT  %-46s oracle=%-6s port=%s\n" "$p" "$o" "$q" >> "$D/out"
  elif ! diff -q "$D/o" "$D/p" >/dev/null; then
    # ATTRIB vs TEXT (LEDGER #318). Strip the file(line:col) prefix and compare the MESSAGE
    # TEXTS alone. If those agree as a multiset, both compilers reported the same diagnostics
    # and disagree only about WHICH SITE to blame.
    #
    # !! AN ATTRIB IS NOT AUTOMATICALLY BENIGN. !! #179 was precisely an attribution bug and it
    # was a REAL DEFECT -- the port anchored an unnamed import at the `import` keyword instead
    # of the path, and that accounted for 88/88 of the vet-mode divergences. This split exists
    # so the two classes are DISTINGUISHABLE at a glance, not so ATTRIB can be skipped. Both
    #
    # ONE KNOWN-NOISE CLASS, measured (LEDGER #407). A single ATTRIB on a core/rexcode/isa/*/tools
    # package is ORACLE NONDETERMINISM, not a port defect. Those packages have two files that BOTH
    # declare `main`, so "Redeclaration of 'main'" must pick one file to blame and one for the
    # `at ...` continuation, and C++ does not pick stably under full-sweep load.
    # Proven by running THIS SCRIPT with the oracle in the PORT slot (a wrapper doing
    # `odin check "$1" -no-entry-point`), making every comparison oracle-vs-oracle:
    #     oracle vs ITSELF   1 event / 6 sweeps   (rsp/tools)
    #     #404 port build    2 events / 12 sweeps (mos65816/tools, mos6502/tools)
    # -- an identical ~17% rate, so the port arm is fully accounted for by oracle noise.
    #
    # THE COUNT MISMATCH ON x86/tools IS THE SAME FINDING, and it is now MECHANISM-COMPLETE
    # (LEDGER #582). Do not re-investigate it; it is not a missing rule.
    #   That package has FOUR files each declaring `main`. scope_insert never inserts the colliding
    #   entity, so every collision pairs (new, incumbent); redeclaration_error then SORTS the pair
    #   by position (checker.cpp, "order the pair by position") and prints the LATER as the anchor.
    #   print_all_errors then MERGES neighbouring errors that share a position (error.cpp, "merge
    #   neighbouring errors") -- and for two redeclarations whose sorted anchors coincide, the
    #   second contributes no new text and is REMOVED outright.
    #   The oracle's incumbent varies by collection race, so ~19 runs in 20 two pairs normalise to
    #   the same anchor and one is merged away: 2 printed. The port's insertion order is FIXED
    #   (#271), so its three anchors are always distinct, nothing merges, and 3 are printed.
    #   Measured: oracle 20 runs -> 19x{2 diagnostics}, 1x{3}; port 20 runs -> 20x{3}, byte-identical.
    #   The port implements BOTH the sort and the merge (error.odin, "merge neighbouring errors").
    #   Matching the oracle here would mean reproducing a RACE, i.e. undoing #271. The port emits
    #   the strictly more complete result. IRREDUCIBLE BY DESIGN.
    # Do NOT revert a change over one of these, and do not re-run the A/B: it cannot separate
    # anything, because line 88 re-runs the oracle every sweep rather than using a cached
    # reference, so a mismatch never says WHICH SIDE moved. #197/#201/#173/#185 are the same
    # family. A COUNT or TEXT mismatch here would be a different matter entirely.
    # still demand the #301/#313 discrimination: re-run the package in isolation, and against
    # the PREVIOUS binary, before attributing it to anything.
    #
    # The known-nondeterministic family: the ten core/rexcode/isa/*/tools packages each have
    # 2-4 files declaring `main`, so "Redeclaration of 'main'" can be blamed on any of them and
    # C++'s file order decides which. Measured 2 events across one plain+vet sweep pair.
    sed -E 's/^[^ ]*\.odin\([0-9]+:[0-9]+\) //' "$D/o" | sort > "$D/om"
    sed -E 's/^[^ ]*\.odin\([0-9]+:[0-9]+\) //' "$D/p" | sort > "$D/pm"
    if diff -q "$D/om" "$D/pm" >/dev/null; then
      printf 'ATTRIB\n' > "$D/verdict"
      printf "ATTRIB %-46s (%s diagnostics, same TEXT, different site)\n" "$p" "$o" >> "$D/out"
    else
      printf 'TEXT\n' > "$D/verdict"
      printf "TEXT   %-46s (%s diagnostics, same count, different text)\n" "$p" "$o" >> "$D/out"
    fi
    diff "$D/o" "$D/p" | head -6 | sed 's/^/         /' >> "$D/out"
  else
    printf 'OK\n' > "$D/verdict"
  fi
  return 0
}

# --- PASS 1: bounded fan-out -------------------------------------------------------------------
n=0
for p in "${PKGS[@]}"; do
  n=$((n+1))
  check_one "$n" "$p" &
  # Throttle. `wait -n` returns as soon as ANY child finishes, which keeps the pipe full without
  # the barrier a `wait` every W would impose.
  while [ "$(jobs -rp | wc -l)" -ge "$PARITY_JOBS" ]; do wait -n 2>/dev/null || break; done
done
wait

# --- PASS 2: RETRY THE DEAD, SEQUENTIALLY ------------------------------------------------------
# A death under concurrency is not evidence (see the header). Re-run alone before believing it.
n=0; retried=0; retry_rescued=0
for p in "${PKGS[@]}"; do
  n=$((n+1))
  case "$(cat "$TMP/pkg$n/verdict" 2>/dev/null)" in
    DIED*)
      retried=$((retried+1))
      printf "RETRY  %-46s died under fan-out; re-running alone\n" "$p" >&2
      check_one "$n" "$p"
      case "$(cat "$TMP/pkg$n/verdict" 2>/dev/null)" in
        DIED*) ;;
        *) retry_rescued=$((retry_rescued+1)) ;;
      esac
      ;;
  esac
done
[ "$retried" -gt 0 ] && printf "RETRY-SUMMARY retried=%s rescued=%s still_dead=%s\n" \
  "$retried" "$retry_rescued" "$((retried-retry_rescued))"

# --- JOIN: tally and emit IN LIST ORDER ---------------------------------------------------------
cnt_mismatch=0; txt_mismatch=0; att_mismatch=0; excluded=0
n=0
for p in "${PKGS[@]}"; do
  n=$((n+1))
  v=$(cat "$TMP/pkg$n/verdict" 2>/dev/null)
  case "$v" in
    OK)      ;;
    COUNT)   cnt_mismatch=$((cnt_mismatch+1)) ;;
    ATTRIB)  att_mismatch=$((att_mismatch+1)) ;;
    TEXT)    txt_mismatch=$((txt_mismatch+1)) ;;
    DIED*)   excluded=$((excluded+1))
             printf "EXCLUDED %-44s %s\n" "$p" "${v#DIED }" ;;
    # A MISSING verdict means the worker never wrote one -- it was killed, or check_one hit an
    # unhandled path. That is NOT a pass. Count it as unmeasured and say so, or the fan-out could
    # silently shrink `compared` exactly as #275 describes.
    *)       excluded=$((excluded+1))
             printf "EXCLUDED %-44s NO-VERDICT (worker produced no result)\n" "$p" ;;
  esac
  [ -s "$TMP/pkg$n/out" ] && cat "$TMP/pkg$n/out"
done
n=${#PKGS[@]}
compared=$((n-excluded))
echo "PARITY-DONE packages=$n compared=$compared excluded=$excluded count_mismatches=$cnt_mismatch text_mismatches=$txt_mismatch attrib_mismatches=$att_mismatch"

# ------------------------------------------------------------------------------------------------
# EXIT GATE (#749). Until this was added, the script ended on the bare `echo` above and ALWAYS
# EXITED 0: it printed its mismatch counts and told its caller NOTHING. Jon: "if its got an error
# in the checker port it needs announced from tool." THE EXIT STATUS IS THE ANNOUNCEMENT; a count
# in a summary line is not.
#
# WHY ONLY `text_mismatches` IS GATED -- the baseline is NOT clean, and forcing a zero-gate onto a
# nonzero baseline builds a gate that fails every run, which gets ignored and then removed (#215).
# Measured over three recorded sweeps (batch718b/batch720/batch740):
#   text_mismatches  = 0, 0, 0   <- deterministic, 0 in every sweep since #331. THE INVARIANT.
#   count_mismatches = 1, 1, 2   <- NOT even stable; core/rexcode/isa/x86/tools is a known open
#                                   divergence and the column moves run to run.
#   attrib_mismatches= 2, 2, 2   <- core/rexcode/isa/{ppc,rsp}/tools: ORACLE nondeterminism,
#                                   proven by an oracle-vs-oracle control (#341). Not ours to fix.
# count and attrib therefore stay REPORTED but UNGATED. When either is driven to 0 and held there,
# tighten this gate -- do not gate them on the strength of one green run (#213).
if [ "$compared" -eq 0 ]; then
  echo "PARITY-ABORTED 0 of $n packages were compared -- the numbers above are NOT a measurement" >&2
  exit 1
fi
if [ "$txt_mismatch" -ne 0 ]; then
  echo "PARITY-FAILED $txt_mismatch package(s) produce DIFFERENT DIAGNOSTIC TEXT -- see the TEXT rows above" >&2
  exit 1
fi
exit 0
