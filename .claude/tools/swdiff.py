#!/usr/bin/env python3
"""swdiff.py <BASE.txt> <NEW.txt> -- partitioned sweep diff.

Only packages that are neither error-capped nor crashed/timed-out on EITHER side are
comparable; everything else is partitioned out and reported as a count. Comparing
without that partition is how a capped package's truncation gets mistaken for a
diagnostic change.
"""
import re, sys

HDR = re.compile(r"^### (\S+) files=(\d+) errors=(\d+) warnings=(\d+) limit=(\w+) raw_diags=(\d+)")
BAD = re.compile(r"^### (CRASH|TIMEOUT) (\S+)")


def load(p):
    pkgs, cur = {}, None
    for line in open(p, errors="replace"):
        m = BAD.match(line)
        if m:
            k = m.group(2)
            pkgs.setdefault(k, {"errors": -1, "limit": False, "lines": []})["bad"] = True
            cur = None
            continue
        m = HDR.match(line)
        if m:
            cur = m.group(1)
            pkgs[cur] = {"errors": int(m.group(3)), "limit": m.group(5) == "true",
                         "lines": [], "bad": False}
            continue
        if cur:
            pkgs[cur]["lines"].append(line.rstrip())
    for v in pkgs.values():
        v.setdefault("bad", False)
    return pkgs


def main():
    a, b = load(sys.argv[1]), load(sys.argv[2])
    keys = set(a) | set(b)
    both = [k for k in keys if k in a and k in b]
    capped = [k for k in both if a[k]["limit"] or b[k]["limit"]]
    bad = [k for k in both if a[k]["bad"] or b[k]["bad"]]
    stable = [k for k in sorted(both) if k not in capped and k not in bad]
    ec = [k for k in stable if a[k]["errors"] != b[k]["errors"]]
    td = [k for k in stable if a[k]["lines"] != b[k]["lines"]]
    print("keys=%d both=%d capped=%d unstable=%d STABLE=%d" % (
        len(keys), len(both), len(capped), len(bad), len(stable)))
    print("unstable(base)=%d unstable(new)=%d" % (
        sum(1 for k in both if a[k]["bad"]), sum(1 for k in both if b[k]["bad"])))
    print("error-count differences: %d" % len(ec))
    for k in ec[:25]:
        print("   ", k, a[k]["errors"], "->", b[k]["errors"])
    print("diagnostic-text differences: %d" % len(td))
    for k in td[:25]:
        sx, sy = set(a[k]["lines"]), set(b[k]["lines"])
        print("   ", k)
        for l in list(sx - sy)[:3]:
            print("      -", l[:150])
        for l in list(sy - sx)[:3]:
            print("      +", l[:150])
    print("stable totals: base=%d new=%d" % (
        sum(a[k]["errors"] for k in stable), sum(b[k]["errors"] for k in stable)))

    # #750/#761: THE COVERAGE ABORT, AND DELIBERATELY NOTHING ELSE.
    #
    # This tool must NOT be gated on its difference counts. It is HISTORY-anchored (#269): it
    # answers "did this change alter port behaviour anywhere?", so after an intentional fix a
    # nonzero `diagnostic-text differences` is THE POINT, not a failure. parity.sh is the
    # reference-anchored gate and is where divergence-from-the-oracle is judged. Run both.
    #
    # What CAN go silently wrong is coverage. Every package is partitioned out if it is
    # error-capped or crashed/timed-out on EITHER side, so a run in which everything was
    # partitioned away prints `error-count differences: 0 / diagnostic-text differences: 0` --
    # which is exactly what a clean run prints. Measured on two EMPTY sweeps:
    #     keys=0 both=0 capped=0 unstable=0 STABLE=0 / 0 / 0   RC=0
    # A missing or non-executable binary handed to sweep_det.sh produces precisely this shape,
    # because every package is then recorded `### CRASH` and excluded. To its credit this tool
    # already PRINTED `STABLE=0` -- it was only the exit status that could not say so (#745: the
    # exit status IS the announcement).
    if not stable:
        print("SWDIFF-ABORTED 0 packages were comparable (keys=%d both=%d capped=%d unstable=%d)"
              " -- every difference count above is zero because NOTHING WAS COMPARED"
              % (len(keys), len(both), len(capped), len(bad)), file=sys.stderr)
        return 2
    return 0


sys.exit(main())
