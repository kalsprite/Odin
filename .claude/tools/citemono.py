#!/usr/bin/env python3
"""citemono.py -- find citations that point at the WRONG LINES inside the RIGHT function.

WHY THIS EXISTS. citefn.py --check can only verify that a citation is SELF-CONSISTENT: that line N
really does fall inside the function the anchor names. It cannot tell whether N is the line the comment
beside it describes. In a large C++ function those are different claims, and only the second is worth
anything to a reader. That gap has now produced four separate defects:
    #606  six citations resolved cleanly inside check_builtin_procedure (~3000 lines) and ALL SIX ranges
          were wrong -- min/max cited at quaternion construction, overflow arithmetic at concatenate.
    #607  seven resolved inside generate_minimum_dependency_set_internal and all seven were wrong --
          ":3007 clears is_init" was add_to_set, ":3037 appends" was the disabled-proc warning.
    #608/#609  check_proc_decl: 15 wrong of 44, i.e. 34% of what #595's --apply had cemented, every one
          passing --check from the day it was written.

THE DETECTOR. Port code order normally tracks C++ order, because the port was written by walking the
reference. So list a procedure's citations as (port line, C++ line) in PORT order and flag every
BACKWARDS jump. On check_proc_decl this flagged 15 of 44 and every one was genuinely wrong -- 15/15, no
false positives. It requires no reading to run, which is what makes it worth having.

KNOWN LIMIT, AND IT IS A BIG ONE -- READ THIS BEFORE BELIEVING A HIGH COUNT. The premise is that port
order tracks C++ order. That holds for LINEAR functions, which is where it was measured (check_proc_decl,
15/15 with no false positives). It FAILS COMPLETELY for SWITCH-DISPATCH functions: if the port's switch
arms are in a different order from C++'s, every citation that crosses the reordering registers as an
inversion while being perfectly correct. #611 found exactly this in check_expr_base_internal -- 23 of its
31 citations "inverted", and all 23 are artifacts: both sides dispatch over AST node kinds, 41 of 78
common-arm pairs are discordant (C++ puts BadExpr first and the port puts it last), and six inverted
citations spot-checked by content were all exactly right. So the tool now flags SWITCH-DISPATCH
procedures, and a high count in one of those means NOTHING until the arm orders are compared.

THIS IS A REPORT, NOT A GATE, and the distinction is deliberate. Beyond switch reordering, some
inversions are legitimate one-offs: Odin requires a nested procedure declared before use, so wherever
the port hoists a local helper its citation sits above the C++ call sites it points at
(check_proc_decl's is_valid_instrumentation_call, documented at its site). A gate firing on those would
be noise, and a gate tuned until it stops firing is the #483 failure. So: exit 0 always, print what to
look at, and disposition each group -- at the site for one-offs, or in citemono_dispositioned.txt for a
whole-group explanation like switch reordering.

Inversions are computed per (odin proc, cpp file, cpp function) group -- comparing line numbers across
two different C++ functions is meaningless.

USAGE
    citemono.py                 every procedure with anchored citations, worst first
    citemono.py --triaged       only procedures listed in citefn_triaged.txt (the claimed-read set)
    citemono.py --proc NAME     one procedure, with every citation printed in port order
"""
import os, sys, glob, collections, importlib.util

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("citefn", os.path.join(HERE, "citefn.py"))
cf = importlib.util.module_from_spec(spec); spec.loader.exec_module(cf)

def collect():
    """[(odin_file, odin_proc, cpp_file, cpp_func, port_line, lo, hi)] for every ANCHORED citation."""
    out = []
    for path in sorted(glob.glob(os.path.join(cf.CHECKER, "*.odin"))):
        base = os.path.basename(path)
        text = open(path).read()
        owners = cf.proc_by_line(text)
        for ln, raw in enumerate(text.split("\n"), 1):
            for m in cf.CITE_RE.finditer(raw):
                if not m.group(2):
                    continue                      # bare: nothing to be inconsistent with
                proc = owners[ln - 1] if ln - 1 < len(owners) else "<file>"
                lo = int(m.group(3)); hi = int(m.group(4)) if m.group(4) else lo
                out.append((base, proc, m.group(1), m.group(2), ln, lo, hi))
    return out

DISPOSITIONED = os.path.join(HERE, "citemono_dispositioned.txt")

def read_dispositioned():
    """{(odin_proc, cpp_func): reason} -- groups already examined and explained."""
    out = {}
    if not os.path.exists(DISPOSITIONED):
        return out
    for raw in open(DISPOSITIONED):
        line = raw.split("#", 1)[0].strip() if raw.lstrip().startswith("#") else raw.strip()
        if not line or line.startswith("#"):
            continue
        parts = [p.strip() for p in line.split("|", 2)]
        if len(parts) != 3:
            continue
        out[(parts[0], parts[1])] = parts[2]
    return out

_SWITCH_CACHE = {}
def is_switch_dispatch(odin_file, odin_proc):
    """Does this port procedure dispatch over a large switch? Then monotonicity is unreliable.

    Counted as: 6+ `case ^ast.X:` or `case .X:` arms inside the procedure. Six is arbitrary but the
    point is to separate 'a couple of branches' from 'a dispatch table whose order is a free choice'."""
    key = (odin_file, odin_proc)
    if key in _SWITCH_CACHE:
        return _SWITCH_CACHE[key]
    import re
    path = os.path.join(cf.CHECKER, odin_file)
    n = 0
    if os.path.exists(path):
        text = open(path).read()
        owners = cf.proc_by_line(text)
        for ln, raw in enumerate(text.split("\n"), 1):
            if ln - 1 < len(owners) and owners[ln - 1] == odin_proc:
                if re.match(r'\s*case (\^ast\.|\.)[A-Za-z_]', raw):
                    n += 1
    _SWITCH_CACHE[key] = n >= 6
    return _SWITCH_CACHE[key]


def inversions(rows):
    """rows in port order -> [(port_line, lo, previous_max)]"""
    inv, prev = [], 0
    for _f, _p, _cf, _fn, ln, lo, _hi in rows:
        if lo < prev:
            inv.append((ln, lo, prev))
        prev = max(prev, lo)
    return inv

def main():
    argv = sys.argv[1:]
    only_triaged = "--triaged" in argv
    one = None
    if "--proc" in argv:
        i = argv.index("--proc")
        if i + 1 >= len(argv):
            print("citemono: --proc needs a procedure name"); return 2
        one = argv[i + 1]

    triaged = set(p for (_f, p) in cf.read_triaged())
    disp = read_dispositioned()
    groups = collections.defaultdict(list)
    for r in collect():
        groups[(r[0], r[1], r[2], r[3])].append(r)

    results = []
    for key, rows in groups.items():
        odin_file, odin_proc, cpp_file, cpp_func = key
        if one and odin_proc != one:
            continue
        if only_triaged and odin_proc not in triaged:
            continue
        inv = inversions(rows)
        if inv or one:
            results.append((len(inv), len(rows), key, rows, inv))

    results.sort(key=lambda t: (-t[0], -t[1]))
    total_inv = sum(r[0] for r in results)

    for n_inv, n_cites, key, rows, inv in results:
        odin_file, odin_proc, cpp_file, cpp_func = key
        mark = "TRIAGED" if odin_proc in triaged else "untriaged"
        tags = [mark]
        if is_switch_dispatch(odin_file, odin_proc):
            tags.append("SWITCH-DISPATCH: monotonicity unreliable")
        reason = disp.get((odin_proc, cpp_func))
        if reason:
            tags.append("DISPOSITIONED")
        print("%-3d inversions / %-3d citations   %s %s -> %s %s   [%s]"
              % (n_inv, n_cites, odin_file, odin_proc, cpp_file, cpp_func, "; ".join(tags)))
        if reason:
            print("      reason: %s" % reason[:150])
            continue
        if one:
            prev = 0
            for _f, _p, _cf, _fn, ln, lo, hi in rows:
                flag = "  <-- INVERSION" if lo < prev else ""
                print("      port :%-6d cpp %d-%d%s" % (ln, lo, hi, flag))
                prev = max(prev, lo)
        else:
            for ln, lo, prev in inv:
                print("      port :%-6d cites %d after %d" % (ln, lo, prev))

    scope = "triaged procedures only" if only_triaged else "all anchored procedures"
    print("CITEMONO-DONE scope=%s groups_with_inversions=%d total_inversions=%d"
          % (scope, len([r for r in results if r[0]]), total_inv))
    print("  NOT A GATE -- some inversions are legitimate (a hoisted nested helper cites call sites")
    print("  BELOW it). Disposition each AT THE SITE so the next run already has the answer.")
    return 0

if __name__ == "__main__":
    sys.exit(main())
