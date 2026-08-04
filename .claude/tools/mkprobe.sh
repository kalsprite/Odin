#!/usr/bin/env bash
# mkprobe.sh <name> [more names...] -- create EMPTY probe directories under the scratchpad.
#
# WHY THIS EXISTS (LEDGER #316, and then #321 when I hit it a second time).
#
# `mkdir -p $S/n7_foo` succeeds silently when the directory already holds files from an earlier
# probe with the same name. The next `odin build $S/n7_foo` then compiles BOTH files, and the
# output is dominated by the stale one -- typically as a package-name mismatch or a syntax error
# that has nothing to do with what is being probed.
#
# This has cost real time twice:
#   * #316, n7_label: a stale a.odin made the label probe report "Different package name", which
#     read as "the label case never reaches the checker". It does.
#   * #321, n7_mtail: same failure, same directory-reuse cause, one hour later -- after I had
#     written "delete-then-write, or probe in a fresh directory" into the ledger and then not
#     done it. A lesson recorded but not operationalised is a lesson not learned.
#
# The failure is nasty because the output LOOKS like a finding: a real diagnostic, at a real
# position, in a file you did not write.
#
# Usage:  mkprobe.sh n7_foo n7_bar   then write $S/n7_foo/m.odin as usual.
set -euo pipefail
S="${PROBE_ROOT:-/tmp/claude-1000/-home-kalsprite-dev-odin/5ae0f352-0d85-4f59-825d-514e4ce56a75/scratchpad}"

if [ $# -eq 0 ]; then
  echo "usage: mkprobe.sh <probe-name> [more...]" >&2
  exit 2
fi

for name in "$@"; do
  case "$name" in
    */*|.|..|"") echo "mkprobe: refusing suspicious probe name '$name'" >&2; exit 2 ;;
  esac
  d="$S/$name"
  if [ -e "$d" ] && [ ! -d "$d" ]; then
    echo "mkprobe: '$d' exists and is not a directory" >&2; exit 2
  fi
  # Report what is being discarded -- a silent wipe would hide the very collision this guards.
  if [ -d "$d" ]; then
    existing=$(find "$d" -maxdepth 1 -type f -printf '%f ' 2>/dev/null || true)
    [ -n "$existing" ] && echo "mkprobe: clearing stale $name/: $existing"
  fi
  rm -rf "$d"
  mkdir -p "$d"
done
