#!/usr/bin/env python3
"""flakecmp.py <OUTDIR> <RUNS>  -- compare N sweep logs for self-inconsistency.

Split out of flake.sh so it can be exercised on its own with a POSITIVE CONTROL. A
determinism screen that silently never fires is worse than none: it reports "stable" for
both a stable checker and a broken comparator, and those are the two cases you most need
to tell apart. Run it against deliberately-differing inputs before trusting a clean result.

Reads <OUTDIR>/flake_run1.txt .. flake_runN.txt as written by sweep_det.sh.
"""
import sys, os


def split_packages(path):
    """Split a sweep log into {package: block}.

    Each package's output starts with '### <path> files=...' from the triage harness.
    TIMEOUT/CRASH markers are '### TIMEOUT <pkg>' / '### CRASH <pkg>' and are kept as their
    own blocks so an unstable package stays visible instead of being merged into whatever
    package happened to precede it.
    """
    pkgs, cur, buf = {}, None, []
    for line in open(path, errors='replace'):
        if line.startswith('### '):
            if cur is not None:
                pkgs[cur] = ''.join(buf)
            rest = line[4:].strip()
            if rest.startswith('TIMEOUT ') or rest.startswith('CRASH '):
                cur = rest.split(None, 1)[1]
                buf = [line]
                continue
            cur = rest.split(' files=')[0].strip()
            buf = [line]
        elif line.startswith('SWEEP-DONE'):
            continue
        else:
            buf.append(line)
    if cur is not None:
        pkgs[cur] = ''.join(buf)
    return pkgs


def main():
    out, runs = sys.argv[1], int(sys.argv[2])
    runsets = []
    for i in range(1, runs + 1):
        p = os.path.join(out, 'flake_run%d.txt' % i)
        if not os.path.exists(p):
            print('MISSING run file %s' % p)
            return 2
        runsets.append(split_packages(p))

    allpkgs = set()
    for r in runsets:
        allpkgs |= set(r.keys())

    unstable, missing = [], []
    for pkg in sorted(allpkgs):
        blocks = [r.get(pkg) for r in runsets]
        if any(b is None for b in blocks):
            missing.append(pkg)
            continue
        if len(set(blocks)) != 1:
            unstable.append(pkg)

    for pkg in missing:
        print('ABSENT-IN-SOME-RUN  %s' % pkg)
    for pkg in unstable:
        print('UNSTABLE            %s' % pkg)
        ls = [runsets[i][pkg].splitlines() for i in range(runs)]
        for ln in range(max(len(x) for x in ls)):
            vals = {(x[ln] if ln < len(x) else '<absent>') for x in ls}
            if len(vals) != 1:
                for i, x in enumerate(ls):
                    print('    run%d: %s' % (i + 1, x[ln] if ln < len(x) else '<absent>'))
                break

    print('FLAKE-DONE packages=%d runs=%d unstable=%d absent=%d'
          % (len(allpkgs), runs, len(unstable), len(missing)))
    return 0


if __name__ == '__main__':
    sys.exit(main())
