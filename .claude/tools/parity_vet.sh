#!/usr/bin/env bash
# VET-MODE oracle-vs-port PARITY. Same contract as parity.sh, but both sides run with -vet and
# both Error and Warning lines are captured.
#
# The port side must be a triage_vet-style harness (one that sets build_context.vet_flags to C++'s
# VetFlag_All). See LEDGER #176: until this existed, no vet-gated diagnostic had ever been compared
# against the reference, which hid a stub that disabled the entire proc-body vet surface.
#
# This is the only instrument anchored to the REFERENCE rather than to the port's own history.
# swdiff.py compares port-run-N to port-run-N+1 and therefore cannot see a divergence that has
# always been present (see LEDGER #269). Run BOTH after every change.
#
# KNOWN ORACLE-NONDETERMINISTIC FAMILY (LEDGER #313, corrected by #318). TEN packages are
# susceptible, not one -- every core/rexcode/isa/*/tools directory (arm32, arm64, mips, mos6502,
# mos65816, ppc, ppc_vle, riscv, rsp, x86). Each has 2-4 files declaring `main`, so "Redeclaration
# of 'main'" can be attributed to any of them and C++'s file order decides which.
#
# My first estimate, "~1 run in 60", was measured under six artificial CPU spinners and UNDERSTATES
# a real sweep: the plain+vet pair that followed produced TWO events, in mips/tools and
# mos65816/tools respectively. Expect roughly one ATTRIB per full sweep from this family.
#
# CORRECTED (#313, after #327). The line that used to sit here said "in isolation all ten are
# stable and agree with the port (15/15 measured)". That was luck, not stability. Measuring 25 runs
# each on core/rexcode/isa/mos65816/tools:
#
#     PORT   (pre-#327 and post-#327 binaries alike):  gen_mnemonic_builders 25/25   -- DETERMINISTIC
#     ORACLE (./odin build, fresh each run):           gen_mnemonic_builders 22/25
#                                                      dump_verify_input      3/25   -- NOT stable
#
# The ORACLE is the nondeterministic party, picking the minority file ~12% of the time; a 15/15
# clean sample had ~15% prior probability, so the old note simply never caught it. The port is
# deterministic and lands on the oracle's majority every time, which is the best a deterministic
# implementation can do against a nondeterministic reference.
#
# CONSEQUENCE FOR READING SWEEPS: this harness re-runs the oracle on every invocation (see the
# `odin check` below), so an ATTRIB from this family is resampled noise, NOT a signal about the
# port binary. Do not compare an old and a new port binary on these packages and attribute the
# difference to the change -- I did exactly that after #327, got p ~ 0.008 from Fisher's exact, and
# was wrong, because the test assumed the port was the only variable when it is provably constant.
# To test a port change here, measure WHAT THE PORT PICKS (as above), not whether the pair matches.
#
# Same class as #197 and #201: the reference is nondeterministic, so a fixed-expectation comparator
# cannot score it. These report as ATTRIB rather than TEXT.
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

# ARGUMENT GUARD (LEDGER #385) -- see parity.sh for the full note. A missing LIST made the read loop
# fail and the script still printed a three-zeroes PARITY-DONE line indistinguishable from a clean
# sweep. Abort instead of summarising nothing.
if [ -z "$PORT" ] || [ ! -x "$PORT" ]; then
  echo "PARITY-VET-ABORTED: port binary '$PORT' missing or not executable. usage: parity_vet.sh <VET_PORT_BIN> <PKGLIST>" >&2
  exit 2
fi
if [ -z "$LIST" ] || [ ! -r "$LIST" ]; then
  echo "PARITY-VET-ABORTED: package list '$LIST' missing or unreadable. usage: parity_vet.sh <VET_PORT_BIN> <PKGLIST>" >&2
  exit 2
fi

# HARNESS SELF-CHECK -- THIS IS WHERE #511 HAPPENED.
# This sweep requires the VET harness (.claude/tools/triage_vet). Handed the PLAIN harness (triage_st)
# it still runs to completion over all 323 packages and reports a plausible-looking summary -- but the
# port side emits no vet diagnostics at all, so the numbers describe the ARGUMENT, not the checker.
# #511 was filed as a defect on exactly that and had to be retracted; the same mistake recurred against
# corpus_vet.sh (#621), which is why both now check. An unmeasured run must never be scoreable (#483).
# The probe: $S/vetctl yields vet diagnostics under -vet on the oracle. Oracle lines > 0 and port
# lines == 0 means this is not a vet harness. Cost is one small package, paid before a multi-minute sweep.
_VETPROBE="/tmp/claude-1000/-home-kalsprite-dev-odin/5ae0f352-0d85-4f59-825d-514e4ce56a75/scratchpad/vetctl"
if [ -d "$_VETPROBE" ]; then
  _o=$(timeout 120 ./odin check "$_VETPROBE" -vet -no-entry-point 2>&1 | grep -cE "Error:|Warning:")
  _v=$(timeout 120 "$PORT" "$_VETPROBE"                            2>&1 | grep -cE "Error:|Warning:")
  if [ "$_o" -gt 0 ] && [ "$_v" -eq 0 ]; then
    echo "PARITY-VET-ABORTED: '$PORT' produced NO diagnostics on the vetctl probe while the oracle produced $_o." >&2
    echo "  This is the PLAIN harness, not the VET harness. Build and pass triage_vet:" >&2
    echo "     ./odin build .claude/tools/triage_vet -out:<path> -o:minimal" >&2
    echo "  Refusing to sweep -- see #511/#621. Not a regression; a wrong argument." >&2
    exit 2
  fi
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

# STARTUP REAP -- see the identical block in parity.sh for the reasoning. A trap cannot run on a
# SIGKILL, so the leak it leaves is unbounded without a sweep at startup.
. .claude/tools/reap_scratch.sh
reap_scratch


# THE ORACLE MUST EXIST. On 2026-08-05 the ./odin binary vanished mid-tick (cause unknown).
# PER_PKG_TIMEOUT (default 180) overrides the per-package timeout, matching modelsweep.sh which
# already had it. WHY IT MATTERS (#301): under external load a package can exceed the timeout and
# be partitioned as EXCLUDED = UNMEASURED, which reads like a regression and is not one. Raising
# the timeout is the honest response to a loaded machine; lowering the standard of evidence is not.
# A run at loadavg 94 on 32 cores produced exactly one such exclusion and cost a full re-run.
#
# A missing oracle does not error here -- the timeout'd `./odin check ...` just fails, the captured
# output is empty, and every package reads as "oracle=0". Against a port that reports normally
# that manufactures a mismatch on every package; against a port that also reports nothing it
# manufactures a CLEAN SWEEP. Both readings are fiction, and the second is the dangerous one.
#
# This is the #275/#385 family again: an instrument reporting a result for work it did not do.
# Guard it the same way -- abort loudly rather than print a number nobody can trust.
if [ ! -x ./odin ]; then
  echo "PARITY-VET-ABORTED reason=oracle-missing: ./odin is absent or not executable." >&2
  echo "         Rebuild it with ./build_odin.sh release before trusting any parity number." >&2
  exit 2
fi

# died <rc> -- true if the run did not complete (timeout or fatal signal), false otherwise.
died() { [ "$1" -eq 124 ] || [ "$1" -ge 128 ]; }
why()  { [ "$1" -eq 124 ] && echo "TIMEOUT" || echo "SIG$(($1-128))"; }

# ------------------------------------------------------------------------------------------------
# #594 STEP 2 (LEDGER #767): BOUNDED FAN-OUT -- the same change already VERIFIED 2/2 in parity.sh
# (#766). See that file's header for the full rationale; the short form:
#   * counters move OUT of the loop body into per-package VERDICT FILES, because under `&` the body
#     is a SUBSHELL and every increment would be lost -> `PARITY-VET-DONE ... 0 0 0` + exit 0, a
#     green gate that measured nothing;
#   * output is buffered per package and emitted IN LIST ORDER at the join, because sweep-to-sweep
#     line comparison is the technique that catches regressions here;
#   * the timeout is NOT multiplied by the width. A death under concurrency is not admissible
#     evidence: that package is re-run SEQUENTIALLY, ALONE, at the normal timeout, and only a SECOND
#     death is EXCLUDED. This script's own concurrency-guard note records a concurrent run excluding
#     core/rexcode/isa/mips/tablegen/generated on a TIMEOUT it clears in ~1s alone -- exactly the
#     failure fan-out could otherwise mass-produce, and a spurious timeout reads EXCLUDED = UNMEASURED
#     (#275).
#   * a MISSING verdict counts as EXCLUDED `NO-VERDICT`, never as a pass.
PARITY_JOBS="${PARITY_JOBS:-6}"

mapfile -t PKGS < <(grep -v '^[[:space:]]*$' "$LIST")

check_one() {
  local n="$1" p="$2" D orc prc tag o q
  D="$TMP/pkg$n"
  mkdir -p "$D"
  : > "$D/out"

  timeout "${PER_PKG_TIMEOUT:-180}" ./odin check "$p" -vet -no-entry-point > "$D/o.raw" 2>&1; orc=$?
  timeout "${PER_PKG_TIMEOUT:-180}" "$PORT" "$p"                           > "$D/p.raw" 2>&1; prc=$?

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
    # ATTRIB vs TEXT -- see the long note in parity.sh (LEDGER #318). Summary: same message
    # multiset, different blamed site.
    #
    # !! AN ATTRIB IS NOT AUTOMATICALLY BENIGN. !! #179 was an attribution bug and a REAL
    # DEFECT, accounting for 88/88 of the vet-mode divergences at the time. The split makes the
    # classes distinguishable; it does not make either one skippable.
    sed -E 's/^[^ ]*\.odin\([0-9]+:[0-9]+\) //' "$D/o" | sort > "$D/om"
    sed -E 's/^[^ ]*\.odin\([0-9]+:[0-9]+\) //' "$D/p" | sort > "$D/pm"
    if diff -q "$D/om" "$D/pm" >/dev/null; then
      printf 'ATTRIB\n' > "$D/verdict"
      printf "ATTRIB %-46s (%s diagnostics, same TEXT, different site -- still investigate)\n" "$p" "$o" >> "$D/out"
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
  while [ "$(jobs -rp | wc -l)" -ge "$PARITY_JOBS" ]; do wait -n 2>/dev/null || break; done
done
wait

# --- PASS 2: retry the dead, SEQUENTIALLY ------------------------------------------------------
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
    *)       excluded=$((excluded+1))
             printf "EXCLUDED %-44s NO-VERDICT (worker produced no result)\n" "$p" ;;
  esac
  [ -s "$TMP/pkg$n/out" ] && cat "$TMP/pkg$n/out"
done
n=${#PKGS[@]}
compared=$((n-excluded))
echo "PARITY-VET-DONE packages=$n compared=$compared excluded=$excluded count_mismatches=$cnt_mismatch text_mismatches=$txt_mismatch attrib_mismatches=$att_mismatch"

# ------------------------------------------------------------------------------------------------
# EXIT GATE (#749). Same defect and same reasoning as parity.sh -- this ended on a bare `echo` and
# ALWAYS EXITED 0. Vet-mode baseline measured at batch740: count=1 text=0 attrib=2.
# `text_mismatches` is the deterministic column and the only one gated; see parity.sh for the full
# rationale and the per-column evidence (#215, #341).
if [ "$compared" -eq 0 ]; then
  echo "PARITY-VET-ABORTED 0 of $n packages were compared -- the numbers above are NOT a measurement" >&2
  exit 1
fi
if [ "$txt_mismatch" -ne 0 ]; then
  echo "PARITY-VET-FAILED $txt_mismatch package(s) produce DIFFERENT DIAGNOSTIC TEXT -- see the TEXT rows above" >&2
  exit 1
fi
exit 0
