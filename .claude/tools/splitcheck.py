#!/usr/bin/env python3
"""
splitcheck.py -- mir's FIRST condition on #566 (task #572): the two classes of type global must be
distinguishable BY ACCESS SYNTAX, and that must be enforced rather than assumed.

THE INVARIANT. resetaudit.py already partitions the `t_*: ^Type` globals into two classes by
DERIVING the partition (assigned outside init_basic_types = checker-owned; assigned only inside it =
target-derived). #566 moves the checker-owned class onto the Checker struct. After that move the
partition is legible at every use site:

    checker-owned   ALWAYS qualified   c.t_type_info      ctx.checker.t_objc_id
    target-derived  ALWAYS bare        t_int              t_bool

mir's point is that "legible" is worth nothing if nothing checks it. A reader who sees a bare `t_x`
must be able to conclude "this outlives the Checker" without going and looking it up.

TWO DIRECTIONS, AND ONLY ONE OF THEM GATES.

  derived_qualified > 0  -- FAILS. A target-derived global read off a Checker means one of the
      basics has been moved or rewritten by mistake. This is not hypothetical: globalmove.py's
      argv-leak bug (LEDGER, #566 tooling) made resetaudit read "--report" as a directory, so the
      glob matched nothing, every global looked unassigned, and all 162 were classified
      checker-owned. Running --apply in that state would have rewritten t_int, t_bool and the
      endian variants into `c.t_*` -- and the compiler would have ACCEPTED it in the ~200 procedures
      that do have a Checker in scope. This column is the detector for that class of accident, and
      it is meaningful TODAY, before #566, because it must be 0 in both worlds.

  owned_bare > 0  -- REPORTED, does not gate. Before #566 this is simply the size of the remaining
      work (every checker-owned global is still a bare package global). Gating on it would leave
      this tool permanently red until #566 lands, which per #483 makes it prove exactly as little
      as a tool that never fails. When #566 lands, owned_bare reaching 0 is the completion
      criterion -- and from that point the number is the regression detector, because a
      newly-added bare read of a checker-owned global would push it off 0.

So: run it now to guard the dangerous direction, and read owned_bare as the #566 burn-down.

WHAT IS NOT A REFERENCE. Declaration sites, not uses:
  - types.odin's `t_x: ^Type` package declarations,
  - checker.odin's `t_x: ^Type,` struct fields (once #566 lands),
  - the assignments inside reset_runtime_type_globals, which are teardown rather than use.

usage: splitcheck.py [CHECKER_DIR]
exit 0 = no target-derived global is read off a Checker
exit 1 = at least one is
"""
import os, re, sys, glob, collections

CHECKER = sys.argv[1] if len(sys.argv) > 1 else "/home/kalsprite/dev/odin/core/odin/checker"

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import resetaudit as R
# resetaudit resolves CHECKER from sys.argv[1] at MODULE level, so importing it here would make it
# read OUR argument -- fine when we were given a directory, wrong when we were not. Set it
# explicitly either way; globalmove.py learned this the expensive way.
R.CHECKER = CHECKER

# The comment scanner is imported, not re-derived. It encodes a specific bug: entity_helpers.odin
# has a LINE comment containing `/*`, so looking for `/*` before `//` swallows the rest of the file
# and silently drops every later reference. One implementation, one place to be right.
from globalmove import strip_comments

FIELD_DECL_RE = re.compile(r'^\s*(t_[a-zA-Z_0-9, ]+)\s*:\s*\^Type')
PROC_RE = re.compile(r'^([a-zA-Z_][a-zA-Z_0-9]*)\s*::\s*proc')


FIELD_LINE = re.compile(r'^\t(t_[a-zA-Z_0-9]+)\s*:\s*\^Type\s*,')


def classify():
    """(checker_owned, target_derived), read from where each class now LIVES.

    Before #566 both classes were package globals in types.odin and had to be told apart by
    DERIVING which procedure assigned them (resetaudit's rule). After #566 the distinction is
    structural and needs no inference: the checker-owned ones are fields of the Checker struct, the
    target-derived ones are the globals that remain. Reading the structure is strictly better than
    re-deriving it -- there is no rule left to get wrong.

    The pre-#566 derivation is kept below as a FALLBACK so this tool still works on a tree where the
    move has not happened (a bisect, or a revert). It is selected by absence of the field block, not
    by a flag, so it cannot be chosen by mistake."""
    types_path = os.path.join(CHECKER, "types.odin")
    checker_path = os.path.join(CHECKER, "checker.odin")

    owned = set()
    if os.path.exists(checker_path):
        inside = False
        for line in open(checker_path):
            if line.startswith("Checker :: struct {"):
                inside = True
                continue
            if inside:
                if line.startswith("}"):
                    break
                m = FIELD_LINE.match(line)
                if m:
                    owned.add(m.group(1))

    declared = R.declared_globals(types_path)
    if owned:
        # Post-#566: whatever still stands as a package global is target-derived by construction.
        return owned, set(declared)

    # Pre-#566 fallback: one pool, split by which procedure assigns each name.
    assigned = R.assignment_procs(declared)
    derived = set()
    for n in declared:
        procs = assigned.get(n, set())
        # A never-assigned global has no evidence either way. Treat it as checker-owned: that is
        # the conservative side, since it puts the name in the burn-down column rather than in the
        # gating one, and so cannot manufacture a failure out of missing information.
        if procs == {R.TARGET_DERIVED_PROC}:
            derived.add(n)
        else:
            owned.add(n)
    return owned, derived


def main():
    owned, derived = classify()
    if len(owned) + len(derived) < 100:
        print("REFUSING: only %d globals classified (expected ~162). types.odin is probably not "
              "where this tool was pointed." % (len(owned) + len(derived)))
        return 2

    names = owned | derived
    bare = {n: re.compile(r'(?<![a-zA-Z_0-9.])' + n + r'(?![a-zA-Z_0-9])') for n in names}
    qual = {n: re.compile(r'(?<=\.)' + n + r'(?![a-zA-Z_0-9])') for n in names}

    counts = collections.Counter()
    violations = []          # target-derived read off a Checker -- the gating column
    owned_bare_where = collections.Counter()

    for f in sorted(glob.glob(os.path.join(CHECKER, "*.odin"))):
        base = os.path.basename(f)
        cur, blk = "<file-scope>", False
        for lineno, raw in enumerate(open(f).read().split("\n"), 1):
            m = PROC_RE.match(raw)
            if m:
                cur = m.group(1)
            code, blk = strip_comments(raw, blk)
            if FIELD_DECL_RE.match(code) or cur == "reset_runtime_type_globals":
                continue     # declaration or teardown, not a use
            for n in names:
                # The two patterns are already DISJOINT: `bare` carries a `(?<![a-zA-Z_0-9.])`
                # lookbehind, so a dot-qualified occurrence never matches it. Subtracting nq from nb
                # (as this did) is a double count -- harmless while every reference was bare, since
                # nq was 0, and it went NEGATIVE the moment globalmove rewrote them: owned bare=-189.
                # A counter that can go negative is not measuring what its name says.
                nq = len(qual[n].findall(code))
                nb = len(bare[n].findall(code))
                if n in derived:
                    counts["derived_bare"] += nb
                    counts["derived_qualified"] += nq
                    if nq:
                        violations.append((base, lineno, n, raw.strip()))
                else:
                    counts["owned_bare"] += nb
                    counts["owned_qualified"] += nq
                    if nb:
                        owned_bare_where[base] += nb

    print("SPLITCHECK checker_owned=%d target_derived=%d" % (len(owned), len(derived)))
    print("  owned    bare=%-5d qualified=%-5d   <- bare is the #566 burn-down, not a failure"
          % (counts["owned_bare"], counts["owned_qualified"]))
    print("  derived  bare=%-5d qualified=%-5d   <- qualified MUST be 0"
          % (counts["derived_bare"], counts["derived_qualified"]))

    if counts["owned_bare"]:
        for f, c in owned_bare_where.most_common():
            print("    still-bare  %-34s %4d" % (f, c))
    for f, lineno, n, txt in violations:
        print("    TARGET-DERIVED READ OFF A CHECKER  %s:%d  %s  |  %s" % (f, lineno, n, txt[:70]))

    print("SPLITCHECK-DONE derived_qualified=%d owned_bare=%d"
          % (counts["derived_qualified"], counts["owned_bare"]))
    return 1 if counts["derived_qualified"] else 0


if __name__ == "__main__":
    sys.exit(main())
