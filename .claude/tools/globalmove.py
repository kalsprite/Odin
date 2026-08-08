#!/usr/bin/env python3
"""
globalmove.py -- rewrite `t_X` -> `c.t_X` / `ctx.checker.t_X` for #566.

WHY THIS IS A TOOL AND NOT A ONE-OFF. Attempt 1 was reverted at 36 compile errors; the rewrite
itself was fine (144 of 170 references converted correctly). Re-deriving the script is where the
bugs come back, so it lives here with both of attempt 1's bugs already fixed.

BUG 1, FIXED HERE -- multi-line procedure headers. Attempt 1 matched
`^(\\w+)\\s*::\\s*proc\\s*\\(([^)]*)` which stops at the first `)`. A procedure whose parameter list
spans lines therefore did not update `sig`, so the NEXT reference inherited the PREVIOUS
procedure's signature and got the wrong receiver: it wrote `ctx.checker.t_source_code_location`
into check_decl.odin:1304, which has no `ctx`. This version accumulates the header across lines
until parens balance.

BUG 2, FIXED HERE -- `"^Checker" in sig` SUBSTRING-matches `^Checker_Info` and `^Checker_Context`.
Attempt 1's planning scan used that test and therefore counted Checker_Info-taking procedures as
already having a Checker. It hid a whole procedure (`populate_builtin_package_scope`) from the
"needs threading" list -- 7 procedures, not 6. The regexes below anchor on a non-identifier
boundary.

ORDER MATTERS, and it is not the obvious one:
  1. thread the procedures that have no Checker FIRST (see --report), so that by the time this
     runs there is no exclusion list and no special cases;
  2. run this;
  3. DELETE THE GLOBALS. This is the safety net, not the cleanup: while the globals still exist a
     missed rewrite compiles silently and the migration is half-done with no signal. With them
     gone the compiler enumerates every miss.

Never migrate readers before writers. The fields are nil until the init procedures populate them,
so a half-migrated tree is silently WRONG rather than broken -- which is exactly why steps 2-5 are
one atomic cut rather than an incremental sequence.

usage:
    globalmove.py --report          list procedures that still need a Checker parameter
    globalmove.py --apply           perform the rewrite (run --report first, and thread those procs)
"""
import os, re, sys, glob, collections

CHECKER = "/home/kalsprite/dev/odin/core/odin/checker"
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import resetaudit as R

# resetaudit resolves its CHECKER from sys.argv[1] at MODULE level, so importing it here made it
# read OUR flag ("--report") as a directory: the glob matched nothing, every global looked
# unassigned, and all 162 were classified checker-owned instead of 89. Running --apply in that
# state would have rewritten the target-derived basics (t_int, t_bool, the endian variants) into
# `c.t_*` as well -- a corruption the compiler would have accepted in the ~200 procs that do have a
# Checker. Caught only because --report is the default and prints `owned=`; that number is the
# canary, so read it every time.
R.CHECKER = CHECKER

# A procedure header may span lines; accumulate until parens balance.
PROC_START = re.compile(r'^([a-zA-Z_][a-zA-Z_0-9]*)\s*::\s*proc\b')
# `[(,]` not just `,`: sig is the WHOLE header line here, so the FIRST parameter is preceded by
# the open paren. Requiring ^ or , silently missed every proc whose Checker is parameter one --
# which is nearly all of them (reported 32 procs needing threading instead of 8).
CHK = re.compile(r'(?:^|[(,])\s*([a-zA-Z_][a-zA-Z_0-9]*)\s*:\s*\^Checker(?![_a-zA-Z])')
CTX = re.compile(r'(?:^|[(,])\s*([a-zA-Z_][a-zA-Z_0-9]*)\s*:\s*\^Checker_Context')
DECL = re.compile(r'^t_[a-zA-Z_0-9, ]+:\s*\^Type')


def owned_globals():
    tp = os.path.join(CHECKER, "types.odin")
    declared = R.declared_globals(tp)
    assigned = R.assignment_procs(declared)
    return {n for n in declared
            if assigned.get(n, set()) != {R.TARGET_DERIVED_PROC}}


def strip_comments(line, in_block):
    """Return (code, in_block).

    Scans left to right for whichever delimiter comes FIRST. Looking for `/*` before `//` is a real
    bug, not a style point: entity_helpers.odin:43 is a LINE comment that contains `/*` --
    `// core/crypto/aes and core/crypto/_aes/* became an undeclared name.` -- and treating that as
    an unterminated block comment swallowed the entire rest of the file, so 17 references there were
    silently skipped while the tool reported 0 remaining."""
    if in_block:
        j = line.find("*/")
        if j < 0:
            return "", True
        line, in_block = line[j + 2:], False
    while True:
        i, k = line.find("/*"), line.find("//")
        if k >= 0 and (i < 0 or k < i):
            return line[:k], False
        if i < 0:
            return line, False
        j = line.find("*/", i + 2)
        if j < 0:
            return line[:i], True
        line = line[:i] + line[j + 2:]


def walk(path, owned, pat):
    """Yield (index, raw_line, code, proc_name, signature) for one file."""
    lines = open(path).read().split("\n")
    cur, sig, blk = "<file>", "", False
    pending = None                      # accumulating a multi-line header
    for idx, raw in enumerate(lines):
        if pending is not None:
            pending += " " + raw
            if pending.count("(") <= pending.count(")"):
                sig, pending = pending, None
        else:
            m = PROC_START.match(raw)
            if m:
                cur = m.group(1)
                if raw.count("(") > raw.count(")"):
                    pending = raw          # header continues on later lines
                    sig = raw
                else:
                    sig = raw
        code, blk = strip_comments(raw, blk)
        yield idx, raw, code, cur, sig
    return


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else "--report"
    owned = owned_globals()

    # HARD GUARD, not advice. An empty `owned` makes the alternation `()`, which matches the EMPTY
    # STRING at every position -- so `pat.sub` inserts the receiver between every pair of characters
    # and destroys every file it touches. That is not hypothetical: it happened. types.odin's
    # declarations had already been deleted by an earlier step, so owned_globals() legitimately
    # returned nothing, and --apply rewrote the entire package into `ctx.checker.` noise. Recovered
    # only from a backup taken minutes earlier.
    #
    # The lesson is not "read the owned= line". I had ALREADY written that instruction into this
    # file's header, and then ran --apply without reading it one step later. A safeguard that
    # depends on the operator noticing is not a safeguard; it has to refuse.
    if len(owned) < 50:
        print("REFUSING: owned=%d is implausible (expected ~89). types.odin has probably already had"
              % len(owned))
        print("its declarations removed, which makes the match pattern empty and the rewrite")
        print("destructive. Restore the tree and re-run --report before touching anything.")
        return 2
    # `(?<![a-zA-Z_0-9.])` -- the DOT matters. Without it a second --apply turns the
    # already-migrated `c.t_type_info` into `c.c.t_type_info`, so the tool is not idempotent
    # and cannot be re-run after a partial pass.
    pat = re.compile(r'(?<![a-zA-Z_0-9.])(' + "|".join(sorted(owned)) + r')(?![a-zA-Z_0-9])')
    need = collections.Counter()
    rewritten = 0

    for f in sorted(glob.glob(os.path.join(CHECKER, "*.odin"))):
        if os.path.basename(f) == "checker.odin":
            continue                     # holds the field block; contains declarations, not uses
        out, dirty = [], False
        for idx, raw, code, cur, sig in walk(f, owned, pat):
            if DECL.match(raw) or cur == "reset_runtime_type_globals" or not pat.search(code):
                out.append(raw)
                continue
            mx, mc = CTX.search(sig), CHK.search(sig)
            if mx:
                repl = mx.group(1) + ".checker."
            elif mc:
                repl = mc.group(1) + "."
            else:
                need[cur] += len(pat.findall(code))
                out.append(raw)
                continue
            new = raw.replace(code, pat.sub(lambda m: repl + m.group(1), code)) if code.strip() else raw
            rewritten += len(pat.findall(code))
            dirty = True
            out.append(new)
        if mode == "--apply" and dirty:
            open(f, "w").write("\n".join(out))

    if mode == "--apply":
        print("GLOBALMOVE rewrote=%d still_need_threading=%d" % (rewritten, sum(need.values())))
    for p, c in need.most_common():
        print("  NEEDS A CHECKER PARAMETER  %-38s %3d refs" % (p, c))
    print("GLOBALMOVE-DONE owned=%d procs_needing_threading=%d" % (len(owned), len(need)))
    return 1 if need else 0


if __name__ == "__main__":
    sys.exit(main())
