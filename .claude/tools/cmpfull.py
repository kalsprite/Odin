#!/usr/bin/env python3
"""cmpfull.py <PORT_BIN> <PROBE_DIR> [...] -- compare the port's diagnostics against the oracle.

Rebuilt 2026-08-02 after the original was lost with /tmp. Runs BOTH compilers on each probe
directory and compares their diagnostics after normalisation.

Verdicts:
  FULL-MATCH     identical normalised diagnostics, in order
  FULL-DIFFER    both ran, diagnostics differ
  ORACLE-CRASHED oracle did not produce usable output
  PORT-CRASHED   port died (signal / non-zero with no header)

Normalisation keeps only real diagnostic lines -- `<path>(line:col) <Kind>: <message>` -- with
the path reduced to a basename. The oracle additionally echoes the offending source line and a
caret ruler after each diagnostic; the port does not print those, so they are dropped. Note the
port emits diagnostic CONTINUATION lines (e.g. "\tData refers to") as ordinary `Error:` lines,
and so does the oracle, which is why they survive normalisation rather than being filtered as
decoration.
"""
import re, subprocess, sys, os
import concurrent.futures

DIAG = re.compile(r"^(?P<path>[^()]+)\((?P<line>\d+):(?P<col>\d+)\)\s+(?P<kind>Error|Warning|Syntax Error|Note):\s?(?P<msg>.*)$")
# A diagnostic line with no file(line:col) prefix at all.
NOPOS = re.compile(r"^\s*(Error|Warning|Syntax Error|Note):\s")

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
ODIN = os.path.join(REPO, "odin")


# A caret ruler. The oracle TRUNCATES long ones with a trailing "...", and may point at a
# span with several carets, so allow both plus surrounding whitespace.
CARET = re.compile(r"^\s*[\^~]+[\s\^~]*(\.\.\.)?\s*$")


def normalise(text):
    out = []
    lines = text.splitlines()
    i = -1
    while True:
        i += 1
        if i >= len(lines):
            break
        raw = lines[i]
        line = raw.rstrip()
        if not line or line.startswith("### "):
            continue
        # The ORACLE echoes the offending source line and underlines it with a caret ruler; the
        # port prints neither. Drop every (echo, caret) PAIR wherever it appears -- not just
        # after a diagnostic. C++ shows a second echo/caret under a continuation note (e.g. the
        # "previous type case at ..." of a duplicate), and an earlier version of this rule only
        # handled the pair directly following a diagnostic, which left those stray echoes in and
        # produced false FULL-DIFFERs on namedret_bad and switch_exhaust.
        if i + 1 < len(lines) and CARET.match(lines[i + 1]) and line.strip():
            i += 1
            continue

        m = DIAG.match(line)
        if m:
            out.append("{}({}:{}) {}: {}".format(
                os.path.basename(m.group("path")), m.group("line"), m.group("col"),
                m.group("kind"), m.group("msg").strip()))
            continue
        if NOPOS.match(line):
            out.append("<nopos> " + line.strip())
            continue
        if raw[:1] in (" ", "\t"):
            # Continuation detail. Collapse internal whitespace: the oracle column-aligns the
            # overload table with padding that carries no meaning.
            out.append("<cont> " + " ".join(line.split()))
        # otherwise: banners, allocator noise
    return out


def _unused_normalise(text):
    out = []
    for raw in text.splitlines():
        line = raw.rstrip()
        if not line or line.startswith("### "):
            continue
        m = DIAG.match(line)
        if not m:
            # A diagnostic with NO source position still counts -- dropping it hid a real
            # defect once (the port emitted a positionless "Cannot determine polymorphic type"
            # where C++ emitted a positioned "Parameter 'x' ... is missing"), and the probe
            # read as a match. Every C++ diagnostic carries a position, so a positionless one
            # is itself a divergence and must be visible.
            if NOPOS.match(line):
                out.append("<nopos> " + line.strip())
            # otherwise: source echo, caret ruler, allocator noise, banners
            continue
        out.append("{}({}:{}) {}: {}".format(
            os.path.basename(m.group("path")), m.group("line"), m.group("col"),
            m.group("kind"), m.group("msg").strip()))
    return out


def run(cmd, timeout=180):
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout,
                           errors="replace", cwd=REPO)
        return p.returncode, (p.stdout or "") + (p.stderr or "")
    except subprocess.TimeoutExpired:
        return -9, "<<TIMEOUT>>"


def compare(port_bin, probe):
    orc, otxt = run([ODIN, "build", probe, "-out:/dev/null"])
    if otxt == "<<TIMEOUT>>":
        return "ORACLE-CRASHED", 0, ["oracle timeout"]
    if orc not in (0, 1):
        return "ORACLE-CRASHED", 0, ["oracle rc=%d" % orc]

    prc, ptxt = run([port_bin, probe])
    if ptxt == "<<TIMEOUT>>" or prc < 0:
        return "PORT-CRASHED", 0, ["port rc=%d" % prc]

    o, p = normalise(otxt), normalise(ptxt)
    if o == p:
        return "FULL-MATCH", len(o), []
    delta = []
    for i in range(max(len(o), len(p))):
        a = o[i] if i < len(o) else "<missing>"
        b = p[i] if i < len(p) else "<missing>"
        if a != b:
            delta.append("  oracle: " + a)
            delta.append("  port  : " + b)
        if len(delta) >= 12:
            delta.append("  ...")
            break
    return "FULL-DIFFER", len(o), delta


# LEDGER #866 -- #594 STEP 3: BOUNDED FAN-OUT, the last of the three tools named in that task.
#
# THE PRECONDITION #765 LEFT OPEN, NOW ANSWERED BY OBSERVATION RATHER THAN INFERENCE.
# #765 read this file and found no scratch path anywhere -- both compilers' output is held in local
# variables -- but flagged ONE caveat it did not test: `compare()` invokes the oracle as
# `odin build <probe> -out:/dev/null`, a FIXED path shared by every probe, and whether `odin build`
# also writes SIBLING INTERMEDIATES next to `-out:` was never checked. A shared intermediate is
# exactly the silent cross-contamination that #765's blocker 1 describes.
#
# It does write them, and NOT next to `-out:`: watched with inotify, one successful build creates
# ~17 object files in /tmp named `null-<package>-<hex>.o` -- `null` from the `-out:` basename, and
# critically including `runtime-*` entries that EVERY Odin build produces. On the shared name alone
# these would collide between any two concurrent builds.
#
# They do not collide, because the hex is an ASLR-randomised address, measured varying per run:
#     null-runtime-core-7f8f3d687ee8.o / -7f3972e76058.o / -7f6f7a2c5418.o
# Two concurrent builds are two processes with independent ASLR, so they cannot share a name.
#
# Two negative results that were NOT sufficient evidence, recorded so they are not repeated:
#   * a post-hoc `find` sees nothing -- the intermediates are deleted at the end of the build, so
#     the window in which they could collide has already closed by the time you look;
#   * `find / -xdev` misses them outright -- /tmp is a SEPARATE tmpfs, which is where they live.
# Only watching DURING the run answers this question.
#
# A FAILING build never reaches code emission and writes no intermediates at all, so testing this
# on an error probe (which is most of the corpus) also proves nothing. It was tested on a probe
# that compiles cleanly.
#
# WIDTH. Deliberately modest, and NOT chosen to saturate the machine: `user+sys` for a serial sweep
# is ~4x its wall time, so both compilers are already threaded and W workers do not use W cores.
# #649 is the other reason -- that was a tmpfs exhaustion (58.7 GB of 94 GB), and fanning out
# multiplies the SIMULTANEOUS intermediate footprint.
CMPFULL_JOBS = int(os.environ.get("CMPFULL_JOBS", "6"))


def main():
    if len(sys.argv) < 3:
        print(__doc__); sys.exit(2)
    port_bin, probes = sys.argv[1], sys.argv[2:]
    tally = {}

    # Results are collected into a list INDEXED BY POSITION and printed after the join, so output
    # stays in list order. That is not cosmetic: two sweeps being line-comparable is the technique
    # that caught every regression in this batch, and interleaved parallel output would destroy it.
    results = [None] * len(probes)
    todo = []
    for i, probe in enumerate(probes):
        if not os.path.isdir(probe):
            results[i] = ("MISSING", None)
        else:
            todo.append(i)

    if CMPFULL_JOBS > 1 and len(todo) > 1:
        with concurrent.futures.ThreadPoolExecutor(max_workers=CMPFULL_JOBS) as ex:
            # subprocess.run releases the GIL while waiting, so threads (not processes) are the
            # right primitive here -- no pickling, and the tally stays in one address space.
            futs = {ex.submit(compare, port_bin, probes[i]): i for i in todo}
            for f in concurrent.futures.as_completed(futs):
                results[futs[f]] = ("OK", f.result())
    else:
        for i in todo:
            results[i] = ("OK", compare(port_bin, probes[i]))

    # RETRY THE DEAD, SEQUENTIALLY (the #766 lesson, carried over verbatim in spirit).
    # A death under concurrency is not admissible evidence: contention can manufacture a timeout,
    # and a spurious ORACLE-CRASHED/PORT-CRASHED is scored as a NON-MATCH, which makes this tool
    # exit 4 and turns corpus.sh red for a reason that is not a port defect. So any probe that died
    # during the parallel pass is re-run ALONE before its verdict is believed. Only a second death
    # counts. This costs two extra compiler runs per genuine crash and nothing at all otherwise.
    if CMPFULL_JOBS > 1:
        for i in todo:
            if results[i][1][0] in ("ORACLE-CRASHED", "PORT-CRASHED"):
                print("RETRY  %-34s died under fan-out; re-running alone"
                      % os.path.basename(probes[i]), file=sys.stderr)
                results[i] = ("OK", compare(port_bin, probes[i]))

    for i, probe in enumerate(probes):
        kind, payload = results[i]
        if kind == "MISSING":
            print("%-34s MISSING-DIR" % os.path.basename(probe))
            tally["MISSING"] = tally.get("MISSING", 0) + 1
            continue
        verdict, n, delta = payload
        tally[verdict] = tally.get(verdict, 0) + 1
        print("%-34s lines=%-4d %s" % (os.path.basename(probe), n, verdict))
        for d in delta:
            print(d)
    print("---")
    for k in sorted(tally):
        print("%s=%d" % (k, tally[k]))

    # LEDGER #747 (Jon: "if its got an error in the checker port it needs announced from tool").
    # Until now this function ended here, so Python exited 0 no matter what the tally said -- a run
    # reporting FULL-DIFFER=2 was indistinguishable, to any caller, from a clean one. A divergence
    # between port and oracle is the most direct form of "an error in the checker port" there is,
    # and the EXIT STATUS is the only part of this output a caller actually reads.
    #
    # The code is 4, deliberately NOT 1 or 2:
    #   1  is what Python itself exits on an uncaught exception -- i.e. the comparator CRASHED
    #   2  is the usage error above
    #   4  divergences found: the comparator RAN and the run is a real measurement, and it FAILED
    # corpus.sh depends on that distinction; collapsing them would make every divergence read as
    # "comparator failed -- NOTHING below is a measurement", which is the opposite of the truth.
    bad = sum(v for k, v in tally.items() if k != "FULL-MATCH")
    if bad:
        detail = ", ".join("%s=%d" % (k, tally[k]) for k in sorted(tally) if k != "FULL-MATCH")
        print("CMPFULL-DIVERGENCE %d of %d probes are not FULL-MATCH (%s)"
              % (bad, sum(tally.values()), detail), file=sys.stderr)
        sys.exit(4)


if __name__ == "__main__":
    main()
