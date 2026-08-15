#!/usr/bin/env bash
# entrypoint.sh <PORT_BIN> [PROBE_ROOT] -- compare the ENTRY-POINT surface against the oracle.
#
# WHY THIS GATE EXISTS, and why corpus.sh/parity.sh cannot replace it.
#
# Every other diagnostic gate here runs the oracle with -no-entry-point, and triage_st sets
# build_context.no_entry_point = true to match (LEDGER #329). That is correct for those gates: the
# two sides must be measured under one configuration. But C++ puts the ENTIRE entry-point surface
# behind !no_entry_point --
#     checker.cpp:7790     the check_entry_point block
#     check_decl.cpp:1528  every rule about `main` (signature, calling convention, redeclaration)
# -- so those sweeps structurally cannot see any of it. #589 found the consequence: init_scope was
# never written and no package was ever stamped .Init, so info.entry_point was nil for every
# consumer and C++'s "no main" diagnostic had no working counterpart. 323 packages, 206 probes and
# a 146-test suite were all green throughout.
#
# THE FLAG ASYMMETRY is the whole reason this is a separate script. The oracle checks `main` BY
# DEFAULT and needs no flag; the port's harness disables it by default and needs -entry-point to
# undo that. cmpfull.py takes (port_bin, probes...) with no per-side flag argument, so this cannot
# be expressed as corpus membership -- an entry-point probe added to corpus.sh would be measured
# with the surface switched off, i.e. vacuously (#483: a gate that cannot fail proves nothing).
#
# SELF-SUFFICIENT BY DESIGN: unlike corpus.sh, whose probes live in an ephemeral scratchpad and go
# MISSING-PROBE in a fresh session, this writes its own probes before running. The sources are
# three lines each; there is no reason for the gate to depend on state a previous session left.
#
# POSITIVE CONTROL (#483). Both halves of the fix were proven load-bearing by reverting each one
# alone and re-running:
#   * root seed kind .Init -> .Normal  ==>  ep_const/ep_var go SILENT (the "'main' is reserved"
#     check reads pkg.kind directly, at type_info.odin). ep_nomain still fires, because the
#     init_fullpath half of checker.cpp:268 still satisfies the scope flag.
#   * info.init_fullpath write removed ==>  ordinary packages are unaffected, but `base/runtime`
#     as the requested package loses its entry point entirely (the runtime seed claims the queue
#     slot, so that package keeps kind .Runtime and only the fullpath comparison can identify it).
# Neither control alone turns the whole gate red, which is exactly why both were run. To re-arm
# either, make the one-line edit and rebuild the harness to a THROWAWAY output path.

set -u
# #906: the checker library no longer walks up from CWD to find `base/runtime` (#898 removed it,
# because a LIBRARY's answer must not depend on the caller's working directory). Tools that only
# `cd` into the repo were relying on that walk-up BY ACCIDENT and now report "Undeclared name:
# append" -- runtime never loaded. The harness conforms to the library: export the root.
export ODIN_ROOT="${ODIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
PORT="${1:-}"
ROOT="${2:-/tmp/claude-1000/-home-kalsprite-dev-odin/5ae0f352-0d85-4f59-825d-514e4ce56a75/scratchpad}"
if [ -z "$PORT" ]; then echo "usage: entrypoint.sh <PORT_BIN> [PROBE_ROOT]" >&2; exit 2; fi
if [ ! -x "$PORT" ]; then echo "entrypoint.sh: '$PORT' is not executable" >&2; exit 2; fi

P="$ROOT/eprobes"
mkdir -p "$P" || exit 2

# --- probe sources -----------------------------------------------------------------------------
# One per C++ rule, so a regression names the rule it broke rather than just lowering a count.
w() { mkdir -p "$P/$1" && printf '%s' "$2" > "$P/$1/main.odin"; }

# check_entry_point succeeds: `main` found, correct type. Must be SILENT on both sides -- the
# only probe here that proves the surface does not OVER-report.
w ep_ok 'package ep_ok
main :: proc() {
}
'
# checker.cpp:7794-7806 -- scope_lookup_current finds nothing.
# "Undefined entry point procedure 'main'", anchored on the `package` keyword of the first file.
w ep_nomain 'package ep_nomain
helper :: proc() {
}
'
# checker.cpp:5306-5309 -- a non-procedure named `main` in the init package. Reads pkg.kind
# DIRECTLY, so this is the probe the .Init stamp is load-bearing for.
w ep_const 'package ep_const
main :: 42
'
# Same rule, different Entity kind (variable rather than constant).
w ep_var 'package ep_var
main: int
'
# check_decl.cpp:1530-1534 -- param_count != 0.
w ep_params 'package ep_params
main :: proc(x: int) {
}
'
# check_decl.cpp:1530-1534 -- result_count != 0. Separate probe because the condition is an OR and
# one probe cannot show both disjuncts are wired.
w ep_results 'package ep_results
main :: proc() -> int {
	return 0
}
'
# check_decl.cpp:1549-1552 -- non-bedrock custom calling convention.
w ep_cc 'package ep_cc
main :: proc "c" () {
}
'
# The kind DISTINCTION: check_decl.cpp:1529 applies the signature rule to any package that is not
# Runtime, but only Package_Init gets the entry_point write. So `main` in an IMPORTED package must
# still be rejected for its signature, while the root's own `main` is the entry point. A single
# package cannot express this.
mkdir -p "$P/ep_import/sub"
printf 'package ep_import\nimport "./sub"\nmain :: proc() { sub.use() }\n' > "$P/ep_import/main.odin"
printf 'package sub\nmain :: proc(x: int) {\n}\nuse :: proc() {\n}\n' > "$P/ep_import/sub/sub.odin"

# probe|extra flags passed to BOTH sides. -bedrock selects C++'s other calling-convention arm
# (check_decl.cpp:1536-1547), which accepts "odin"/"contextless" and recovers to Odin -- a
# different rule and a different message from the non-bedrock arm, so it needs its own probe.
w ep_bedrock_cc 'package ep_bedrock_cc
main :: proc "stdcall" () {
}
'
w ep_bedrock_ok 'package ep_bedrock_ok
main :: proc "contextless" () {
}
'

CORPUS=(
  ep_ok
  ep_nomain
  ep_const
  ep_var
  ep_params
  ep_results
  ep_cc
  ep_import
  "ep_bedrock_cc|-bedrock"
  "ep_bedrock_ok|-bedrock"
)

cd "$REPO" || exit 2
PORT_BIN="$PORT" PROBE_DIR="$P" python3 - "${CORPUS[@]}" <<'PY'
import os, subprocess, sys, importlib.util

# Reuse cmpfull.py's normalise so this gate and the corpus agree on what "same output" means --
# same diagnostic tuple extraction, same caret/source-line handling. Re-implementing it would let
# the two gates drift apart silently.
spec = importlib.util.spec_from_file_location("cmpfull", ".claude/tools/cmpfull.py")
cf = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cf)

port_bin = os.environ["PORT_BIN"]
probe_dir = os.environ["PROBE_DIR"]

def run(cmd):
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=180)
        return p.stdout + p.stderr
    except subprocess.TimeoutExpired:
        return "<TIMEOUT>"

match = differ = 0
for spec_str in sys.argv[1:]:
    name, _, extra = spec_str.partition("|")
    flags = extra.split() if extra else []
    d = os.path.join(probe_dir, name)

    # The oracle needs NO flag: `odin check` validates `main` by default.
    # The port needs -entry-point to undo triage_st's -no-entry-point default.
    o = cf.normalise(run(["./odin", "check", d] + flags))
    # triage_st prints a "### <path> files=..." banner that the oracle has no counterpart for.
    pr = [l for l in cf.normalise(run([port_bin, "-entry-point", d] + flags))
          if not l.startswith("###")]

    if o == pr:
        match += 1
        print("MATCH      %s" % name)
    else:
        differ += 1
        print("DIFFER     %s" % name)
        for l in o:
            if l not in pr: print("    oracle-only: %s" % l)
        for l in pr:
            if l not in o: print("    port-only:   %s" % l)

print("ENTRYPOINT-DONE members=%d match=%d differ=%d" % (match + differ, match, differ))
sys.exit(1 if differ else 0)
PY
diag_rc=$?

# --- state half -------------------------------------------------------------------------------
# EXPECTATION-BASED, NOT ORACLE-BASED, and that distinction is load-bearing: C++ has no flag that
# prints its resolved entry point, so there is nothing to compare against. Everything above is
# evidence from the reference compiler; this section is only as good as the reasoning behind its
# expectations, which come from reading checker.cpp:268 and checker.cpp:7790.
#
# It exists because the diagnostic probes above cannot reach the init_fullpath half of the fix. See
# entryprobe/main.odin for why base/runtime is the case that needs it and why a diagnostic probe
# scores it MATCH regardless.
EP="$REPO/.claude/tools/entryprobe"
EPBIN="${ENTRYPROBE_BIN:-$ROOT/entryprobe_bin}"
state_rc=0
if [ ! -x "$REPO/odin" ]; then
  echo "ENTRYPOINT-STATE SKIPPED -- ./odin not built, cannot build entryprobe (NOT a pass)" >&2
  state_rc=1
elif ! "$REPO/odin" build "$EP" -out:"$EPBIN" -o:minimal >/dev/null 2>&1; then
  echo "ENTRYPOINT-STATE SKIPPED -- entryprobe failed to build (NOT a pass)" >&2
  state_rc=1
else
  # probe|expected-root|expected-entry-point|expected-errors|extra-flags
  #
  # base/runtime is the whole reason this section exists: with kind `.Runtime` rather than `.Init`,
  # only `pkg.fullpath == info.init_fullpath` can identify it, and both compilers are silent on it.
  # `main` genuinely lives there (base/runtime/entry_unix.odin), so nil here is a real regression.
  #
  # The last two rows are mirc's LIBRARY case (#590), and they must be read as a PAIR: the same
  # package with no `main` produces 1 error as a program and 0 as a library. Either row alone proves
  # nothing -- entry_point is nil in both, so only the error count distinguishes "the diagnostic was
  # correctly suppressed" from "the surface went dead again".
  STATE=(
    "$P/ep_ok|ep_ok|main|0|"
    "$P/ep_ok|ep_ok|<nil>|0|-no-entry-point"
    "base/runtime|runtime|main|0|"
    "$P/ep_nomain|ep_nomain|<nil>|1|"
    "$P/ep_nomain|ep_nomain|<nil>|0|-no-entry-point"
  )
  smatch=0; sdiffer=0
  for spec in "${STATE[@]}"; do
    IFS='|' read -r sp exp_root exp_ep exp_err sflags <<< "$spec"
    out="$("$EPBIN" "$sp" $sflags 2>&1)"
    got_root="$(printf '%s\n' "$out" | sed -n 's/^root=//p')"
    got_ep="$(printf '%s\n' "$out" | sed -n 's/^entry_point=//p')"
    got_err="$(printf '%s\n' "$out" | sed -n 's/^errors=//p')"
    label="$(basename "$sp")${sflags:+ $sflags}"
    if [ "$got_root" = "$exp_root" ] && [ "$got_ep" = "$exp_ep" ] && [ "$got_err" = "$exp_err" ]; then
      smatch=$((smatch+1))
      printf "STATE-OK    %-28s root=%s entry_point=%s errors=%s\n" "$label" "$got_root" "$got_ep" "$got_err"
    else
      sdiffer=$((sdiffer+1))
      printf "STATE-BAD   %-28s expected root=%s entry_point=%s errors=%s -- got root=%s entry_point=%s errors=%s\n" \
        "$label" "$exp_root" "$exp_ep" "$exp_err" "${got_root:-<none>}" "${got_ep:-<none>}" "${got_err:-<none>}"
    fi
  done
  echo "ENTRYPOINT-STATE-DONE members=${#STATE[@]} ok=$smatch bad=$sdiffer"
  [ $sdiffer -ne 0 ] && state_rc=1
fi

[ $diag_rc -ne 0 ] || [ $state_rc -ne 0 ] && exit 1
exit 0
