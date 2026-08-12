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


def main():
    if len(sys.argv) < 3:
        print(__doc__); sys.exit(2)
    port_bin, probes = sys.argv[1], sys.argv[2:]
    tally = {}
    for probe in probes:
        if not os.path.isdir(probe):
            print("%-34s MISSING-DIR" % os.path.basename(probe)); tally["MISSING"] = tally.get("MISSING", 0) + 1
            continue
        verdict, n, delta = compare(port_bin, probe)
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
