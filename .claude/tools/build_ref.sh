#!/usr/bin/env bash
# build_ref.sh -- build an INSTRUMENTABLE copy of the C++ reference compiler (#475).
#
# WHY THIS EXISTS. Several questions can only be answered by the reference compiler telling us
# something it currently does not print:
#   #475  a -dump-model equivalent, so the semantic MODEL can be diffed between implementations
#         rather than inferred from diagnostic text (modelcmp.sh's ceiling)
#   #507  per-worker task counts and dependency-propagation order, to promote the dep-tree
#         double-enqueue finding from INFERRED to reproduced
#
# Both were blocked on the same thing: `./build_odin.sh` hardcodes `-o odin` at line 170, so
# running it OVERWRITES the oracle that every gate in .claude/tools trusts. That is the single
# most destructive accident available in this tree -- parity.sh, corpus.sh, modelcmp.sh and
# doccmp.sh all compare against ./odin, and a silently instrumented oracle would corrupt every
# number they report without failing anything.
#
# TWO PROPERTIES THIS SCRIPT GUARANTEES:
#
#   1. IT NEVER WRITES ./odin. The only output is $ODIN_OUT, and the oracle's checksum is verified
#      unchanged before and after. If the checksum moves, the script aborts loudly.
#   2. IT NEVER TOUCHES THE REPO'S src/. The build runs from a COPY under the scratchpad, so any
#      instrumentation lives outside the repository entirely and cannot be committed by accident.
#      This matters because the tree is routinely dirty with port changes; an edited src/*.cpp
#      sitting alongside them is one `git add -A` away from being committed, and the standing rule
#      is that C++ changes are a local instrument only.
#
# USAGE
#     .claude/tools/build_ref.sh <SRCDIR> <OUTBIN> [mode]
#         SRCDIR  directory CONTAINING a src/ tree (e.g. a scratchpad copy you have patched)
#         OUTBIN  absolute path for the built binary
#         mode    build_odin.sh mode, default `release`
#
#     # pristine baseline:
#     mkdir -p $S/ref && cp -r src $S/ref/src
#     .claude/tools/build_ref.sh $S/ref $S/odin_ref
#
# RUNNING THE RESULT: the binary resolves ODIN_ROOT from its own location, so a scratchpad build
# cannot find core/ or base/. Always invoke it as
#     ODIN_ROOT=/home/kalsprite/dev/odin $S/odin_ref check <pkg> -no-entry-point
# Without that it fails with "Cannot find the library collection 'base'" -- which, note, is a
# CONSTANT error string, so a harness that only hashes output would score every package identical
# and read as a clean comparison. That is exactly how this was nearly mis-measured on first use.
#
# COST: ~45s (unity build, one clang++ invocation, so `nice` is enough to stay polite on a shared
# machine -- there is no -j to tune).

set -eu
REPO=/home/kalsprite/dev/odin
SRCDIR="${1:?usage: build_ref.sh <SRCDIR> <OUTBIN> [mode]}"
OUTBIN="${2:?usage: build_ref.sh <SRCDIR> <OUTBIN> [mode]}"
MODE="${3:-release}"

[ -d "$SRCDIR/src" ] || { echo "build_ref: '$SRCDIR' has no src/ tree" >&2; exit 2; }
case "$OUTBIN" in
  /*) ;;
  *) echo "build_ref: OUTBIN must be an ABSOLUTE path (got '$OUTBIN')" >&2; exit 2;;
esac
if [ "$OUTBIN" = "$REPO/odin" ]; then
  echo "build_ref: REFUSING to write $REPO/odin -- that is the oracle every gate compares against." >&2
  exit 2
fi

ORACLE_SUM_BEFORE=$(md5sum "$REPO/odin" | cut -d' ' -f1)

# Patched builder: the ONLY change is the output path, so all of build_odin.sh's LLVM detection and
# flag assembly is reused verbatim rather than reconstructed (reconstructing it by hand is how
# flag drift creeps in). run_demo is neutered because it would exec ./odin.
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
sed -e 's|-o odin$|-o "$ODIN_OUT"|' \
    -e 's|^\t\./odin run examples/demo.*|\t: # run_demo disabled for out-of-tree build|' \
    "$REPO/build_odin.sh" > "$TMP/b.sh"

( cd "$SRCDIR" && ODIN_OUT="$OUTBIN" nice -n 15 bash "$TMP/b.sh" "$MODE" ) >"$TMP/log" 2>&1 || {
  echo "build_ref: BUILD FAILED, tail of log:" >&2; tail -20 "$TMP/log" >&2; exit 1; }

ORACLE_SUM_AFTER=$(md5sum "$REPO/odin" | cut -d' ' -f1)
if [ "$ORACLE_SUM_BEFORE" != "$ORACLE_SUM_AFTER" ]; then
  echo "build_ref: FATAL -- the oracle $REPO/odin CHANGED during this build." >&2
  echo "           before=$ORACLE_SUM_BEFORE after=$ORACLE_SUM_AFTER" >&2
  echo "           Every gate that compares against it is now untrustworthy. Rebuild it." >&2
  exit 3
fi

echo "build_ref: OK -> $OUTBIN"
echo "build_ref: oracle unchanged ($ORACLE_SUM_AFTER)"
echo "build_ref: run it as  ODIN_ROOT=$REPO $OUTBIN check <pkg> -no-entry-point"
