#!/usr/bin/env python3
"""blockcmp.py -- oracle-vs-port parity over WHOLE DIAGNOSTIC BLOCKS, not just anchor lines.

WHY (#573, closing #155). parity.sh extracts diagnostics with
    grep -oP '(?<=/odin/)[^ ]*\\.odin\\(\\d+:\\d+\\) \\S.*'
which keeps ONLY the anchor line. Every tab-indented continuation -- the source echo, the caret,
`Suggestion:`, `Note:`, and the max/min-value explanations -- is discarded BEFORE comparison. So a
port that emits the right anchor and the wrong help text scores as a perfect match.

That is not theoretical. S-004 (2026-08-07): the port's check_cast_error_suggestion was missing its
final arm, so `i64(1e100)` printed "cannot be represented as the type 'i64'" but NOT the
"The maximum value that can be represented by 'i64' is ..." line that follows it. Corpus-wide
parity read 0/0/0 with that live, and 0/0/0 after fixing it. The gate could not tell the two
states apart.

WHAT A BLOCK IS. An anchor line (same pattern parity.sh uses) plus every following line up to the
next anchor. Blocks are compared as a SORTED MULTISET, matching parity.sh's choice so that a pure
ORDERING difference is not reported here -- ordering is swdiff/flake.sh's job (see parity.sh's
header).

KNOWN INTERACTION -- #197/#341. The ORACLE is nondeterministic on some Suggestion lines: corpus.sh
records vt_nopkg2/vt_nopkg3 emitting one in 3/20 and 19/20 runs respectively. A block comparator
sees that where the anchor comparator did not, so genuine oracle flake can surface here.

RE-RUN ANY SINGLE-PACKAGE DIFFERENCE BEFORE CALLING IT A DEFECT -- and note that the rule is NOT
limited to Suggestion lines, which is how #575 was nearly mis-triaged as a regression. That one is
a REDECLARATION pair whose anchor and `at` continuation SWAP: C++'s redeclaration_error anchors on
whichever declaration was collected first, and collection races. Measured 2/30 threaded, 0/20 at
-thread-count:1; the port is 30/30 stable. It surfaced here on a sweep where the same two packages
had been clean moments earlier, and 6/6 re-runs were clean after. See UPSTREAM-575.

The oracle is deliberately run THREADED, with no -thread-count:1, because parity.sh:150 invokes it
that way and the project's target is parity INCLUDING multi-threaded operation. Pinning one thread
here would suppress #575-class flake at the cost of hiding real threaded divergence -- do not.

usage: blockcmp.py <PORT_BIN> [PKGLIST]
"""
import os, re, subprocess, sys, collections

REPO = "/home/kalsprite/dev/odin"
# Match ANY path, not just one containing '/odin/'. parity.sh's lookbehind is a display
# normalisation for in-repo packages; copying it here made the tool match NOTHING on a
# scratchpad probe and score two empty lists as equal -- caught by the positive control.
# Both binaries are handed the same package path, so raw paths compare fine.
ANCHOR = re.compile(r'^(\S*\.odin\(\d+:\d+\)) (\S.*)$')

def blocks(text):
    out, cur = [], None
    for line in text.split("\n"):
        m = ANCHOR.match(line)
        if m:
            if cur is not None: out.append("\n".join(cur))
            cur = ["%s %s" % (m.group(1), m.group(2).rstrip())]
        elif cur is not None:
            cur.append(line.rstrip())
    if cur is not None: out.append("\n".join(cur))
    return sorted(out)

# #906: ODIN_ROOT must be passed explicitly. `cwd=REPO` used to supply it BY ACCIDENT -- the checker
# library walked up from the working directory looking for base/runtime -- and #898 removed that
# walk-up because a library's answer must not depend on the caller's cwd. Without this the port
# reports "Undeclared name: append" and every comparison is noise.
_ENV = dict(os.environ, ODIN_ROOT=REPO)


def run(cmd):
    r = subprocess.run(cmd, cwd=REPO, env=_ENV, capture_output=True, text=True, timeout=180)
    return r.stdout + r.stderr

port = sys.argv[1]
pkglist = sys.argv[2] if len(sys.argv) > 2 else os.path.join(REPO, ".claude/tools/pkglist.txt")
pkgs = [l.strip() for l in open(pkglist) if l.strip() and not l.startswith("#")]

n = differ = same = 0
for p in pkgs:
    n += 1
    try:
        ob = blocks(run(["./odin", "check", p, "-no-entry-point"]))
        pb = blocks(run([port, p]))
    except subprocess.TimeoutExpired:
        print("TIMEOUT %s" % p); continue
    if ob == pb:
        same += 1
        continue
    differ += 1
    oc, pc = collections.Counter(ob), collections.Counter(pb)
    only_o = list((oc - pc).elements()); only_p = list((pc - oc).elements())
    print("BLOCK-DIFFER %-44s oracle_only=%d port_only=%d" % (p, len(only_o), len(only_p)))
    for b in only_o[:2]: print("   ORACLE-ONLY | " + b.replace("\n", "\n               | "))
    for b in only_p[:2]: print("   PORT-ONLY   | " + b.replace("\n", "\n               | "))
print("BLOCKCMP-DONE packages=%d block_match=%d block_differ=%d" % (n, same, differ))
sys.exit(1 if differ else 0)
