#!/usr/bin/env bash
# modelsweep.sh -- run the model comparison across the WHOLE pkglist (#538).
#
# WHY THIS EXISTS. modeldiff.py was a manual tool pointed at named packages, and only about 11 of
# the 323 in pkglist.txt had ever had a full dump-to-dump comparison. Everything else rested on
# modelcmp.sh, which is probe-based -- it covers what someone thought to write down, not the model.
#
# #514 is the proof that the difference matters. At that point modelcmp had 114 probes green,
# parity was 323/323 green and corpus 198 green, while EVERY matrix type in the language was
# mis-aligned. The defect produced no diagnostic, so every text-anchored gate was structurally
# blind to it, and the probe set happened to contain no matrix. It surfaced only when modeldiff was
# swept over ten packages by hand. This makes that sweep a gate instead of an errand.
#
# THE CLASSIFICATION IS THE POINT, not the coverage. #468 (polymorphic instantiation multiplicity)
# is a KNOWN, accepted residue and it shows up as excess-on-both-sides in most packages. A sweep
# that reported "differing" for both that and a real layout disagreement would be a permanent field
# of red in which nothing could be seen. modeldiff now separates them:
#
#   LAYOUT-DIFFER  same (pkg,name,kind) present on BOTH sides with different size/align.
#                  A DEFECT. This is #514/#475/#416's signature exactly.
#   MULTIPLICITY   entities present on one side only -- which instantiations exist, not what
#                  any type measures. Expected; #468.
#   MODEL-MATCH    neither.
#
# USAGE
#   modelsweep.sh <REF_BIN> <PORT_BIN> [PKGLIST]
#     REF_BIN   instrumented C++ compiler from build_ref.sh (honours ODIN_DUMP_MODEL)
#     PORT_BIN  a triage_st build (honours -dump-model:)
#     PKGLIST   defaults to .claude/tools/pkglist.txt
#
# TWO TRAPS INHERITED FROM THE TOOLS BELOW, both already handled in modeldiff.py and restated here
# so nobody re-introduces them in a rewrite:
#   1. The ref binary resolves ODIN_ROOT from its own location, so a scratchpad build cannot find
#      core/ or base/ and fails with a CONSTANT message. That message hashes equal across packages
#      and reads as agreement (#475). modeldiff passes ODIN_ROOT explicitly.
#   2. The port MUST run -no-threads. #344 established its entity-set variance is entirely
#      threading-driven; without the flag BOTH sides drift run to run and a real divergence hides
#      in the noise (#512 records exactly that mistake).
#
# CRASHES ARE PARTITIONED, NOT COUNTED AS AGREEMENT (#275's lesson from parity.sh: "225/225 clean"
# was really 219 compared and 6 unmeasured). A package whose dump is missing on either side is
# EXCLUDED and named, never silently scored.
#
# PROGRESS GOES TO STDERR, one line per package, and the reason for the split matters: STDOUT is
# what a gate reads (the MODELSWEEP-DONE line and any LAYOUT detail), so mixing 323 progress lines
# into it would break every consumer that greps the summary. The first version of this script
# printed NOTHING until it finished -- about three minutes for the full list -- and silence that
# long is indistinguishable from a hang, which is how a run gets killed and reported as a timeout
# that never happened. Set MODELSWEEP_QUIET=1 to suppress it.
set -u

REPO=/home/kalsprite/dev/odin
# --repeat=N (#569) -- strip it out before the positional args are read, so it may appear anywhere.
REPEAT_N=""
_kept=()
for _a in "$@"; do
    case "$_a" in
        --repeat=*) REPEAT_N="${_a#--repeat=}" ;;
        *)          _kept+=("$_a") ;;
    esac
done
set -- "${_kept[@]}"

REF=${1:?usage: modelsweep.sh [--repeat=N] <REF_BIN> <PORT_BIN> [PKGLIST]}
PORT=${2:?usage: modelsweep.sh <REF_BIN> <PORT_BIN> [PKGLIST]}
PKGLIST=${3:-$REPO/.claude/tools/pkglist.txt}
PER_PKG_TIMEOUT=${PER_PKG_TIMEOUT:-120}

[ -x "$REF"  ] || { echo "modelsweep: REF_BIN not executable: $REF";  exit 2; }
[ -x "$PORT" ] || { echo "modelsweep: PORT_BIN not executable: $PORT"; exit 2; }
[ -r "$PKGLIST" ] || { echo "modelsweep: cannot read pkglist: $PKGLIST"; exit 2; }

# Guard the oracle the way build_ref.sh does. A REF_BIN that IS ./odin would mean comparing the
# port against an uninstrumented binary that never writes a dump -- every package would come back
# EXCLUDED and the run would look like an environment problem rather than a misuse.
if [ "$(readlink -f "$REF")" = "$(readlink -f "$REPO/odin")" ]; then
    echo "modelsweep: REF_BIN is the oracle ./odin, which has no -dump-model. Use build_ref.sh."
    exit 2
fi

# --repeat=N: run the WHOLE sweep N times and report the OBSERVED RANGE of the ungated counters.
#
# WHY (#569): unpairable / multiplicity_packages / model_match_packages MOVE BETWEEN IDENTICAL
# RUNS -- measured, same binaries back to back: multiplicity 136 vs 137, model_match 187 vs 186.
# The source is the ORACLE's own nondeterminism in polymorphic instantiation identity and package
# attribution (#468, #469). Two of my own claims were retracted for quoting a single value of one
# of these as before/after evidence. A bare number is not evidence; a number WITH its measured
# floor is. The GATED columns are deterministic and are reported as single values -- if one of
# those ever shows a range, that is itself a finding and the run says so.
if [ -n "$REPEAT_N" ]; then
    [ "$REPEAT_N" -ge 2 ] 2>/dev/null || { echo "modelsweep: --repeat=N needs N>=2"; exit 2; }
    _tmp=$(mktemp)
    _rc_any=0
    for _i in $(seq 1 "$REPEAT_N"); do
        echo "modelsweep: repetition $_i/$REPEAT_N ..." >&2
        "$0" "$REF" "$PORT" "$PKGLIST" > "$_tmp.$_i" 2>/dev/null || _rc_any=1
        grep -h MODELSWEEP-DONE "$_tmp.$_i" >> "$_tmp"
    done
    python3 - "$_tmp" "$REPEAT_N" <<'PYEOF'
import re, sys, collections
rows = [l for l in open(sys.argv[1]) if "MODELSWEEP-DONE" in l]
n = int(sys.argv[2])
if len(rows) != n:
    print("MODELSWEEP-REPEAT-DONE ERROR: got %d of %d runs" % (len(rows), n)); sys.exit(2)
vals = collections.defaultdict(list)
for l in rows:
    for k, v in re.findall(r"(\w+)=(\d+)", l):
        vals[k].append(int(v))
GATED = ["layout_packages","layout_entities","state_packages","state_entities","schema_mismatch"]
UNGATED = ["unpairable","multiplicity_packages","model_match_packages","presence_packages","presence_entities"]
print("=== GATED (must be deterministic) ===")
bad = []
for k in GATED:
    lo, hi = min(vals[k]), max(vals[k])
    flag = "" if lo == hi else "   <-- MOVED, this is itself a finding"
    if lo != hi: bad.append(k)
    print("  %-22s %d%s" % (k, lo, flag))
print("=== UNGATED (range is the noise floor -- never quote one value alone) ===")
for k in UNGATED:
    lo, hi = min(vals[k]), max(vals[k])
    print("  %-22s %d..%d   (spread %d)" % (k, lo, hi, hi - lo))
print("MODELSWEEP-REPEAT-DONE runs=%d gated_moved=%d" % (n, len(bad)))
sys.exit(1 if bad else 0)
PYEOF
    _prc=$?
    rm -f "$_tmp" "$_tmp".*
    [ "$_rc_any" -eq 0 ] && [ "$_prc" -eq 0 ]
    exit $?
fi

npkgs=$(grep -cvE '^[[:space:]]*(#|$)' "$PKGLIST")
total=0; compared=0; excluded=0; layout_pkgs=0; multi_pkgs=0; match_pkgs=0; layout_entities=0
presence_pkgs=0; presence_entities=0; state_pkgs=0; state_entities=0; schema_bad=0; unpairable=0
excluded_names=""; layout_names=""
detail=$(mktemp)
statedetail=$(mktemp)

while read -r pkg; do
    case "$pkg" in ""|\#*) continue;; esac
    total=$((total+1))
    out=$(timeout "$PER_PKG_TIMEOUT" python3 "$REPO/.claude/tools/modeldiff.py" --summary \
              "$REF" "$PORT" "$pkg" 2>&1)
    line=$(printf '%s\n' "$out" | grep '^PKG ' | head -1)
    if [ -z "$line" ]; then
        # No summary line: the package was SKIPPED inside modeldiff (a dump missing, i.e. one side
        # failed to run) or this invocation timed out. Either way it was not measured.
        excluded=$((excluded+1)); excluded_names="$excluded_names $pkg"
        [ -z "${MODELSWEEP_QUIET:-}" ] && printf '[%3d/%3d] %-34s EXCLUDED\n' "$total" "$npkgs" "$pkg" >&2
        continue
    fi
    compared=$((compared+1))
    status=$(printf '%s' "$line" | sed -n 's/.*status=\([A-Z-]*\).*/\1/p')
    nl=$(printf '%s' "$line" | sed -n 's/.*layout=\([0-9]*\).*/\1/p')
    npres=$(printf '%s' "$line" | sed -n 's/.*presence=\([0-9]*\).*/\1/p')
    nstate=$(printf '%s' "$line" | sed -n 's/.*state=\([0-9]*\).*/\1/p')
    nunp=$(printf '%s' "$line" | sed -n 's/.*unpairable=\([0-9]*\).*/\1/p')
    unpairable=$((unpairable+${nunp:-0}))
    state_entities=$((state_entities+${nstate:-0}))
    [ "${nstate:-0}" -gt 0 ] && state_pkgs=$((state_pkgs+1))
    presence_entities=$((presence_entities+${npres:-0}))
    [ "${npres:-0}" -gt 0 ] && presence_pkgs=$((presence_pkgs+1))
    [ -z "${MODELSWEEP_QUIET:-}" ] && printf '[%3d/%3d] %-34s %s\n' "$total" "$npkgs" "$pkg" "$status" >&2
    case "$status" in
        LAYOUT-DIFFER) layout_pkgs=$((layout_pkgs+1)); layout_entities=$((layout_entities+nl))
                       layout_names="$layout_names $pkg"
                       printf '%s\n' "$out" | grep -E '^PKG |LAYOUT x' >> "$detail" ;;
        STATE-DIFFER)  printf '%s\n' "$out" | grep -E '^PKG |STATE x' >> "$statedetail" ;;
        # #549: `status` is modeldiff's HIGHEST-SEVERITY label, not a set of facts -- it is
        # chosen by an elif chain (modeldiff.py:297-302, LAYOUT > PRESENCE > STATE > the rest).
        # So these two counters partition packages BY TOP FINDING: a package that has multiplicity
        # AND a state divergence is counted as STATE-DIFFER and appears in NEITHER of these.
        # They are exact only while state_packages and layout_packages are 0 -- which the #553
        # gate now enforces, so today the partition IS exact. If the gate ever goes red, treat
        # these two as undercounts until it is green again.
        MULTIPLICITY)  multi_pkgs=$((multi_pkgs+1)) ;;
        MODEL-MATCH)   match_pkgs=$((match_pkgs+1)) ;;
    esac
done < "$PKGLIST"

if [ "$layout_pkgs" -gt 0 ]; then
    echo "=== LAYOUT DISAGREEMENTS (size/align differ for the same entity) ==="
    cat "$detail"
    echo
fi
[ -n "$excluded_names" ] && { echo "EXCLUDED (unmeasured, not agreement):$excluded_names"; echo; }
if [ -s "$statedetail" ]; then
    echo "=== STATE DISAGREEMENTS (same entity, differing field) ==="
    head -60 "$statedetail"
    echo
fi
rm -f "$detail" "$statedetail"

# layout_packages is the number that decides pass/fail. multiplicity_packages is reported, not
# judged: it is #468, a difference in which polymorphic instantiations exist, and it is expected to
# be non-zero on most packages.
# layout_* and presence_* are the STABLE, gateable numbers. multiplicity_/model_match_ are
# reported but NOT judged: LEDGER #541 measured the reference emitting a duplicate entity in ~5% of
# runs, which moves those two counts without changing which entities exist.
# NOISE FLOOR -- READ BEFORE CITING ANY COUNTER.
#   unpairable, multiplicity_packages and model_match_packages MOVE BETWEEN IDENTICAL RUNS.
#   Measured control, same port binary + same reference, back to back:
#       RUN1 multiplicity=136 model_match=187 unpairable=32
#       RUN2 multiplicity=137 model_match=186 unpairable=32
#   The source is the ORACLE's own nondeterminism in polymorphic instantiation identity and
#   package attribution (#468, #469) -- the #197/#341 family. These three counters are REPORTED,
#   never gated, and must NOT be cited as before/after evidence for a change unless a same-binary
#   repetition control has established the floor first. Two claims were retracted for exactly this
#   (see LEDGER "CORRECTION -- modelsweep's unpairable ... are NOT admissible evidence").
#
#   The GATED columns -- layout_*, state_*, schema_mismatch -- are deterministic and trustworthy.
#
#   USE --repeat=N (N>=3) TO MEASURE THE FLOOR YOURSELF before quoting any ungated counter.
#   Measured 3x on one binary over the full 323-package corpus (#569):
#       GATED    layout 0, state 0, schema 0            spread 0 on all -- deterministic
#       UNGATED  unpairable 24..28                      spread 4
#                multiplicity_packages 136..138         spread 2
#                model_match_packages  185..187         spread 2
#                presence_packages 5..5, entities 10..10  spread 0 in this sample (NOT proof)
#   N=2 IS NOT ENOUGH: an earlier 2-run control reported unpairable spread 0, which N=3 refuted.
#
# STATE IS NOW GATED (#553). The residual that kept it report-only -- runtime entities where C++
# sets `used`/`require` and the port did not -- reached ZERO in #561, measured corpus-wide by
# flagsdiff.py (7427 -> 0 across all of #547).
#
# WHAT `state` COVERS, and what it deliberately does not. Per-field blame is attributed only for
# keys carrying EXACTLY ONE entity on each side. Where a key carries several -- a generic
# declaration plus its instantiations, or same-named locals in identical bodies -- there is no
# honest pairing, and modeldiff now counts those as `unpairable` instead of zipping sorted lists
# and reporting the arbitrary pairing as a field difference. #560 is the worked example: two `fe`
# for-loop locals per side under one key, IDENTICAL positions, reported as a `pos` divergence
# purely by sort-order pairing. Entity `pkg` is context-derived in BOTH implementations
# (C++ checker.cpp:2251), so for a body reachable from two packages neither side is canonically
# right and there is no rule to port.
#
# `unpairable` is REPORTED, never judged -- it is the honest name for "these keys differ but blame
# is not attributable". It is not a pass: it is the uncovered axis, and #468 is where it lives.
echo "MODELSWEEP-DONE packages=$total compared=$compared excluded=$excluded" \
     "layout_packages=$layout_pkgs layout_entities=$layout_entities" \
     "state_packages=$state_pkgs state_entities=$state_entities schema_mismatch=$schema_bad" \
     "presence_packages=$presence_pkgs presence_entities=$presence_entities" \
     "multiplicity_packages=$multi_pkgs model_match_packages=$match_pkgs" \
     "unpairable=$unpairable"
[ "$layout_pkgs" -eq 0 ] && [ "$state_entities" -eq 0 ]
