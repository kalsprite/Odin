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


# died <rc> -- true if the run did not complete (timeout or fatal signal), false otherwise.
died() { [ "$1" -eq 124 ] || [ "$1" -ge 128 ]; }
why()  { [ "$1" -eq 124 ] && echo "TIMEOUT" || echo "SIG$(($1-128))"; }

cnt_mismatch=0; txt_mismatch=0; att_mismatch=0; n=0; excluded=0
while read -r p; do
  [ -z "$p" ] && continue
  n=$((n+1))

  timeout 180 ./odin check "$p" -no-entry-point > "$TMP/o.raw" 2>&1; orc=$?
  timeout 180 "$PORT" "$p"                      > "$TMP/p.raw" 2>&1; prc=$?

  if died "$orc" || died "$prc"; then
    excluded=$((excluded+1))
    tag=""
    died "$orc" && tag="oracle=$(why "$orc") "
    died "$prc" && tag="${tag}port=$(why "$prc")"
    printf "EXCLUDED %-44s %s\n" "$p" "$tag"
    continue
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
  grep -oP '(?<=/odin/)[^ ]*\.odin\(\d+:\d+\) \S.*' < "$TMP/o.raw" | sort > "$TMP/o"
  grep -oP '(?<=/odin/)[^ ]*\.odin\(\d+:\d+\) \S.*' < "$TMP/p.raw" | sort > "$TMP/p"
  o=$(wc -l < "$TMP/o"); q=$(wc -l < "$TMP/p")
  if [ "$o" != "$q" ]; then
    cnt_mismatch=$((cnt_mismatch+1))
    printf "COUNT  %-46s oracle=%-6s port=%s\n" "$p" "$o" "$q"
  elif ! diff -q "$TMP/o" "$TMP/p" >/dev/null; then
    # ATTRIB vs TEXT (LEDGER #318). Strip the file(line:col) prefix and compare the MESSAGE
    # TEXTS alone. If those agree as a multiset, both compilers reported the same diagnostics
    # and disagree only about WHICH SITE to blame.
    #
    # !! AN ATTRIB IS NOT AUTOMATICALLY BENIGN. !! #179 was precisely an attribution bug and it
    # was a REAL DEFECT -- the port anchored an unnamed import at the `import` keyword instead
    # of the path, and that accounted for 88/88 of the vet-mode divergences. This split exists
    # so the two classes are DISTINGUISHABLE at a glance, not so ATTRIB can be skipped. Both
    # still demand the #301/#313 discrimination: re-run the package in isolation, and against
    # the PREVIOUS binary, before attributing it to anything.
    #
    # The known-nondeterministic family: the ten core/rexcode/isa/*/tools packages each have
    # 2-4 files declaring `main`, so "Redeclaration of 'main'" can be blamed on any of them and
    # C++'s file order decides which. Measured 2 events across one plain+vet sweep pair.
    sed -E 's/^[^ ]*\.odin\([0-9]+:[0-9]+\) //' "$TMP/o" | sort > "$TMP/om"
    sed -E 's/^[^ ]*\.odin\([0-9]+:[0-9]+\) //' "$TMP/p" | sort > "$TMP/pm"
    if diff -q "$TMP/om" "$TMP/pm" >/dev/null; then
      att_mismatch=$((att_mismatch+1))
      printf "ATTRIB %-46s (%s diagnostics, same TEXT, different site -- still investigate)\n" "$p" "$o"
    else
      txt_mismatch=$((txt_mismatch+1))
      printf "TEXT   %-46s (%s diagnostics, same count, different text)\n" "$p" "$o"
    fi
    diff "$TMP/o" "$TMP/p" | head -6 | sed 's/^/         /'
  fi
done < "$LIST"
compared=$((n-excluded))
echo "PARITY-DONE packages=$n compared=$compared excluded=$excluded count_mismatches=$cnt_mismatch text_mismatches=$txt_mismatch attrib_mismatches=$att_mismatch"
