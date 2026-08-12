#!/usr/bin/env bash
# reap_scratch.sh -- reap THIS TOOLSET'S OWN leaked scratch directories, at the START of a run.
#
# WHY THIS EXISTS. On 2026-08-09 /tmp reached 63 GB of 94 GB and the shell wedged environment-wide.
# 58.7 GB of it was 18,317 abandoned scratch directories, each holding one `p.txt`/`r.txt` pair.
#
# TWO SEPARATE LEAKS PRODUCED THEM, and only one of them is fixable by a trap:
#
#   1. THE BIG ONE -- modelsweep.sh invokes modeldiff.py ONCE PER PACKAGE (modelsweep.sh:139-142,
#      a `while read -r pkg` loop over 323 packages) and modeldiff.py called tempfile.mkdtemp()
#      with NO cleanup whatsoever. Every full model sweep therefore leaked 323 directories. ~57
#      sweeps over four days is the 18,317. That one is fixed AT SOURCE in modeldiff.py (and in
#      statefields.py / flagsdiff.py / schemacov.py, which share the pattern one dir per run).
#
#   2. THE UNFIXABLE-BY-TRAP ONE -- parity.sh and parity_vet.sh already do the right thing
#      (`TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT`). A trap cannot run when the process is
#      SIGKILLed, and these runs ARE killed: five shells were killed by hand on 2026-08-09 alone,
#      and any run cut short by a wedged machine leaks its TMP by construction. No amount of trap
#      discipline bounds that. Only a sweep at STARTUP does. Hence this file.
#
# WHY /tmp AND NOT DISK. /tmp here is a 94 GB tmpfs -- RAM. Bytes left in it are bytes taken from
# the machine, which is why this became a wedge rather than a disk-space warning.
#
# SAFETY, in order of importance:
#
#   AGE GUARD. Only directories untouched for $REAP_AGE_MIN minutes (default 60) are considered.
#   This is what makes the reaper safe next to a CONCURRENT run: parity.sh warns about concurrent
#   runs but does not prevent them, and modelsweep.sh takes no lock at all, so a live sibling's
#   scratch must never be reachable. A package that takes an hour inside one directory would be a
#   180s-timeout failure long before this could touch it.
#
#   SIGNATURE GUARD. Only directories that actually contain p.txt or r.txt are removed. /tmp is
#   shared with unrelated software (editors, browsers, Go builds, other people's mktemp dirs); a
#   name-only match like `tmp*` would eventually delete somebody else's work. The signature is what
#   makes "mine" a fact rather than an assumption.
#
#   DEPTH GUARD. -maxdepth 1 only. Nothing nested, nothing outside /tmp's top level.
#
# It reports what it removed. A reaper that cleans silently is indistinguishable from one that is
# broken, which is the #10 lesson (never read an empty result as a clean one) applied to a tool
# whose whole job is to make things disappear.
REAP_AGE_MIN="${REAP_AGE_MIN:-60}"
REAP_DIR="${REAP_DIR:-/tmp}"

reap_scratch() {
	local n bytes
	local list
	list=$(find "$REAP_DIR" -maxdepth 1 -type d -name 'tmp*' -mmin "+$REAP_AGE_MIN" \
	            \( -exec test -e '{}/p.txt' \; -o -exec test -e '{}/r.txt' \; \) -print 2>/dev/null)
	[ -z "$list" ] && return 0
	n=$(printf '%s\n' "$list" | wc -l)
	bytes=$(printf '%s\n' "$list" | xargs -d '\n' -r du -sc --block-size=1M 2>/dev/null | tail -1 | cut -f1)
	printf '%s\n' "$list" | xargs -d '\n' -r rm -rf
	echo "REAPED-SCRATCH dirs=$n mib=${bytes:-?} older_than_min=$REAP_AGE_MIN"
}

# Usable both as `source reap_scratch.sh` (then call reap_scratch) and as a standalone command.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
	reap_scratch
fi
