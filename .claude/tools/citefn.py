#!/usr/bin/env python3
"""
citefn.py -- anchor the port's C++ citations to FUNCTION NAMES, and keep them honest.

THE PROBLEM. The port cites C++ by line number: `// C++ Reference: check_expr.cpp:6798`. Every
master merge shifts those lines, and nothing notices -- the citation still parses, still looks
authoritative, and now points at unrelated code. That has been repaired by hand at least four times
(#134 found 4 drifts, #494-#502 corrected 4 more, and two more turned up while working #575/#577).
Hand-repair does not scale to 3,594 citations and does not survive the next merge.

WHY NOT JUST REPLACE THE LINE WITH A NAME. Because the line number carries information the name
does not. `check_call_arguments_internal` is ~400 lines; this session used the distinction between
:6798 (the empty-variadic dummy) and :6835 (the default fill) to port #579 B correctly. Replacing
both with the function name would have destroyed exactly the detail that made the work possible.

SO THE ANCHOR IS ADDITIVE:

    check_expr.cpp:6798   ->   check_expr.cpp check_call_arguments_internal:6798

The NAME is the durable anchor; the LINE stays as precision. Drift then degrades gracefully -- and,
more importantly, becomes MECHANICALLY DETECTABLE: --check asks whether line 6798 is still inside
check_call_arguments_internal. That question needs no baseline file and no memory of what the
citation used to mean, which is what makes it survive merges. The rewrite exists to make the gate
possible; the gate is the point.

MODES
    --report   (default) resolve every citation, classify, print counts. Changes nothing.
    --suspect  rank citations whose resolved C++ function looks unrelated to the Odin procedure
               containing them. This is the DRIFT WORKLIST and it must be worked BEFORE --apply.
    --apply    rewrite the unambiguously resolvable citations. Idempotent.
    --check    GATE: every anchored citation must still contain its line. exit 1 if any drifted.

--apply IS SEQUENCED AFTER --suspect ON PURPOSE, and this is the sharpest edge in the tool.
Anchoring records "line N is inside function F" as an assertion. If the citation had ALREADY
drifted, that assertion is false and the rewrite launders it into something --check will certify as
clean forever. This is not hypothetical: the first random sample of eight resolutions turned up
`types.cpp:4436-4474` cited from the port's type_size_of Struct arm, resolving to
type_align_of_internal -- the real struct-size code is in type_size_of_internal, ~180 lines further
on. Rewriting first would have made that permanent and invisible.

WHAT IT REFUSES TO DO
  - guess. A citation whose line falls outside every function (file-scope tables, enum bodies,
    macro blocks) is REPORTED, never rewritten. Same for a range that spans two functions: the
    anchor would be a lie about one end of it.
  - operate on an implausible population. globalmove.py's lesson (#566 attempt 2): a tool whose
    input set silently collapsed to nothing will happily rewrite the whole tree into noise. If the
    function index or the citation count looks wrong, it aborts instead.
"""
import os, re, sys, glob, collections

REPO = "/home/kalsprite/dev/odin"
SRC = os.path.join(REPO, "src")
CHECKER = os.path.join(REPO, "core/odin/checker")

# Odin's src/ is extremely regular: essentially every top-level definition is `gb_internal ...`.
# Measured on check_expr.cpp: 190 lines start with `gb_internal `, and exactly one other top-level
# definition shape exists. Anchoring on that keeps the index simple and its failure mode loud --
# if this stops matching, the index empties and the guard below aborts.
DEF_RE = re.compile(r'^(?:gb_internal|gb_global|gb_inline)\s+(.*)$')
# `gb_internal GB_COMPARE_PROC(entity_variable_pos_cmp) {` -- the macro forms name the function
# INSIDE the parens, so the "identifier before the paren" rule would yield the MACRO name and make
# every such citation resolve to `GB_COMPARE_PROC`. That is the bug the earlier throwaway version of
# this tool had to be taught about; it is encoded here instead of relearned.
MACRO_RE = re.compile(r'\b([A-Z][A-Z_0-9]{3,})\s*\(\s*([a-zA-Z_][a-zA-Z_0-9]*)\s*\)')
NAME_RE = re.compile(r'\b([a-zA-Z_][a-zA-Z_0-9]*)\s*\(')

# A citation: `check_expr.cpp:6798` or `check_expr.cpp:6684-6700`, optionally already anchored.
CITE_RE = re.compile(
    r'\b([a-z_0-9]+\.(?:cpp|hpp))'          # 1 file
    r'(?:\s+([a-z_][a-z_0-9]*))?'           # 2 existing anchor, if any
    r':(\d+)(?:-(\d+))?'                    # 3 line, 4 range end
)


def build_index():
    """file -> sorted list of (start_line, end_line, name), 1-based inclusive."""
    index = {}
    for path in sorted(glob.glob(os.path.join(SRC, "*.cpp")) + glob.glob(os.path.join(SRC, "*.hpp"))):
        base = os.path.basename(path)
        lines = open(path, errors="replace").read().split("\n")
        defs = []
        for i, raw in enumerate(lines, 1):
            m = DEF_RE.match(raw)
            if not m:
                continue
            rest = m.group(1)
            if "(" not in rest:
                continue                      # a variable, not a function

            # FORWARD DECLARATIONS ARE NOT DEFINITIONS, and treating them as such is not cosmetic.
            # src/ has 507 of them. Each would open a span that runs to the NEXT definition, so
            # every citation landing in the declaration block ahead of it -- exactly where the
            # prototypes cluster -- would be attributed to whichever prototype happened to precede
            # it. The header may wrap, so scan forward to whichever of `;` or `{` comes first
            # rather than testing this line alone.
            j, verdict = i, None
            while j <= len(lines) and j < i + 12:
                t = lines[j - 1].rstrip()
                if t.endswith("{"):
                    verdict = "def"
                    break
                if t.endswith(";"):
                    verdict = "decl"
                    break
                j += 1
            if verdict != "def":
                continue

            mm = MACRO_RE.search(rest)
            name = mm.group(2) if mm else None
            if name is None:
                cands = NAME_RE.findall(rest)
                if not cands:
                    continue
                name = cands[0]
            defs.append((i, name))
        spans = []
        for k, (start, name) in enumerate(defs):
            # End at the first column-0 `}` after the definition -- Odin's src closes every
            # top-level function that way -- but never run past the next definition.
            limit = defs[k + 1][0] - 1 if k + 1 < len(defs) else len(lines)
            end = limit
            for j in range(start, min(limit, len(lines)) + 1):
                if lines[j - 1].rstrip() == "}":
                    end = j
                    break
            spans.append((start, end, name))
        if spans:
            index[base] = spans
    return index


def resolve(index, base, lo, hi):
    """Return (name, reason). name is None when the citation must be left alone."""
    spans = index.get(base)
    if spans is None:
        return None, "unknown-file"
    def owner(n):
        for s, e, nm in spans:
            if s <= n <= e:
                return nm
        return None
    a = owner(lo)
    if a is None:
        return None, "outside-any-function"
    if hi is not None:
        b = owner(hi)
        if b is None:
            return None, "range-end-outside"
        if b != a:
            return None, "range-spans-functions"
    return a, "ok"


ODIN_PROC = re.compile(r'^([a-zA-Z_][a-zA-Z_0-9]*)\s*::\s*proc\b')


def norm(n):
    """Strip the affixes that differ between the two implementations by convention only."""
    for suf in ("_internal", "_impl", "_expr", "_stmt", "_type"):
        if n.endswith(suf) and len(n) > len(suf) + 3:
            n = n[: -len(suf)]
    for pre in ("check_", "odin_", "ast_", "is_", "type_"):
        if n.startswith(pre) and len(n) > len(pre) + 3:
            n = n[len(pre):]
    return n


def related(odin_name, cpp_name):
    """Is the C++ function plausibly the counterpart of the Odin procedure citing it?

    Deliberately GENEROUS. This ranks a worklist for a human to read, so a false 'related' costs a
    missed drift while a false 'unrelated' costs wasted reading -- and the second is the one that
    makes a list get ignored. A port procedure very often cites a HELPER of its counterpart rather
    than the counterpart itself, which no name rule can see; that is why this only ever ranks."""
    if not odin_name or not cpp_name:
        return True
    a, b = norm(odin_name), norm(cpp_name)
    if a == b or a in b or b in a:
        return True
    ta = set(t for t in a.split("_") if len(t) > 3)
    tb = set(t for t in b.split("_") if len(t) > 3)
    return bool(ta & tb)


def suspects():
    index = build_index()
    hits = collections.Counter()
    where = collections.defaultdict(list)
    for path in sorted(glob.glob(os.path.join(CHECKER, "*.odin"))):
        base_odin = os.path.basename(path)
        cur = "<file>"
        for ln, raw in enumerate(open(path).read().split("\n"), 1):
            m0 = ODIN_PROC.match(raw)
            if m0:
                cur = m0.group(1)
            for m in CITE_RE.finditer(raw):
                if m.group(2):
                    continue
                lo = int(m.group(3))
                hi = int(m.group(4)) if m.group(4) else None
                nm, why = resolve(index, m.group(1), lo, hi)
                if nm and not related(cur, nm):
                    hits[(cur, m.group(1), nm)] += 1
                    where[(cur, m.group(1), nm)].append((base_odin, ln))
    print("CITEFN-SUSPECT pairs=%d citations=%d" % (len(hits), sum(hits.values())))
    print("  (ranked by cluster size: a systematic drift repeats, a one-off usually does not)")
    for (op, cpp, cf), n in hits.most_common(30):
        f, ln = where[(op, cpp, cf)][0]
        print("  %3d  %-34s cites %-18s %-34s  e.g. %s:%d" % (n, op, cpp, cf, f, ln))
    return 0


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else "--report"
    if mode == "--suspect":
        return suspects()
    index = build_index()
    nfuncs = sum(len(v) for v in index.values())
    if nfuncs < 2000:
        print("REFUSING: function index has only %d entries across %d files, which is implausible "
              "for src/. The definition pattern has probably stopped matching; rewriting against an "
              "empty index would strip or mislabel every citation." % (nfuncs, len(index)))
        return 2

    stats = collections.Counter()
    drifted, unresolved = [], []
    edits = collections.Counter()

    for path in sorted(glob.glob(os.path.join(CHECKER, "*.odin"))):
        base_odin = os.path.basename(path)
        text = open(path).read()
        out, pos, changed = [], 0, 0

        for m in CITE_RE.finditer(text):
            cpp, anchor, lo, hi = m.group(1), m.group(2), int(m.group(3)), m.group(4)
            hi = int(hi) if hi else None
            name, why = resolve(index, cpp, lo, hi)

            if anchor:
                stats["already-anchored"] += 1
                if name is None or name != anchor:
                    stats["DRIFTED"] += 1
                    drifted.append((base_odin, text[:m.start()].count("\n") + 1,
                                    m.group(0), name or why))
                continue

            stats["bare"] += 1
            if name is None:
                stats[why] += 1
                unresolved.append((base_odin, text[:m.start()].count("\n") + 1, m.group(0), why))
                continue
            stats["resolvable"] += 1
            if mode == "--apply":
                out.append(text[pos:m.start()])
                out.append("%s %s:%s%s" % (cpp, name, lo, "-%d" % hi if hi else ""))
                pos = m.end()
                changed += 1

        if mode == "--apply" and changed:
            out.append(text[pos:])
            open(path, "w").write("".join(out))
            edits[base_odin] = changed

    print("CITEFN index: %d functions across %d src files" % (nfuncs, len(index)))
    print("  bare citations      %5d   resolvable %5d" % (stats["bare"], stats["resolvable"]))
    for k in ("outside-any-function", "range-spans-functions", "range-end-outside", "unknown-file"):
        if stats[k]:
            print("  %-22s%5d   (left alone, never guessed)" % (k, stats[k]))
    print("  already anchored    %5d   DRIFTED %d" % (stats["already-anchored"], stats["DRIFTED"]))

    for f, ln, cite, got in drifted[:40]:
        print("    DRIFT %-26s:%-5d %-46s now inside: %s" % (f, ln, cite, got))
    if mode == "--report":
        for f, ln, cite, why in unresolved[:25]:
            print("    SKIP  %-26s:%-5d %-46s %s" % (f, ln, cite, why))
    if mode == "--apply":
        for f, n in edits.most_common():
            print("    rewrote %-30s %5d" % (f, n))
        print("CITEFN-APPLY-DONE rewritten=%d" % sum(edits.values()))

    print("CITEFN-DONE mode=%s drifted=%d" % (mode, stats["DRIFTED"]))
    if mode == "--check":
        return 1 if stats["DRIFTED"] else 0
    return 0


if __name__ == "__main__":
    sys.exit(main())
