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
    --apply    rewrite the unambiguously resolvable citations. Idempotent. REQUIRES A SCOPE --
               see SCOPING below. Refuses to run over the whole tree.
    --check    GATE: every anchored citation must still contain its line. exit 1 if any drifted.

SCOPING (#586). --apply will not run unscoped, because anchoring is an ASSERTION and anchoring an
untriaged citation that has already drifted makes a false assertion permanent (see the warning
below). The scope is the set of Odin procedures whose citations have actually been read:

    --apply                       scope = every proc listed in citefn_triaged.txt
    --apply --only=a,b,c          scope = exactly those procs
    --apply --only-file=x.odin    scope = every proc in that file that is ALSO in the triaged list

citefn_triaged.txt is the durable record of what has been read, one `file.odin proc_name` per line.
It is deliberately a checked-in file rather than a command-line list: the set only ever grows, each
addition is a claim that someone read those citations, and a reviewer can see who claimed what.
Adding a name to it without reading the citations defeats the entire tool.

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
import os, re, sys, glob, bisect, collections

REPO = "/home/kalsprite/dev/odin"
SRC = os.path.join(REPO, "src")
CHECKER = os.path.join(REPO, "core/odin/checker")

# Odin's src/ is MOSTLY regular: nearly every top-level definition is `gb_internal ...`.
#
# CORRECTED (#585). The original note here said "exactly one other top-level definition shape
# exists" -- but that was measured on check_expr.cpp alone and then generalised to all of src/,
# where it is false. The real count across src/*.cpp + src/*.hpp is 61 plain column-0 definitions
# with no gb_* prefix: big_int.cpp's MP_MALLOC/MP_REALLOC/MP_CALLOC/MP_FREE allocator shims,
# build_settings.cpp's get_vet_flag_from_name / get_feature_flag_from_name, bundle_command.cpp's
# bundle*, check_builtin.cpp's add_objc_proc_type, and others.
#
# That gap was not academic: a citation at check_builtin.cpp:219 points exactly at
# add_objc_proc_type, and because the index could not see it the citation resolved to None -- so
# --check could not validate it and --suspect reported it as drift. It was CORRECT all along.
# A gate that cannot see a target cannot vouch for it (#483).
#
# PLAIN_DEF_RE deliberately excludes control keywords (a column-0 `if (...) {` is rare but legal)
# and ALL-CAPS leading tokens, which are macro invocations rather than return types.
DEF_RE = re.compile(r'^(?:gb_internal|gb_global|gb_inline)\s+(.*)$')
PLAIN_DEF_RE = re.compile(
    r'^(?!gb_internal|gb_global|gb_inline|if|for|while|switch|else|do|return|case|struct|enum|union|class|typedef|template|extern|using|namespace)'
    r'(?![A-Z_]+\s*\()'
    r'([A-Za-z_][A-Za-z_0-9 *&<>:]*\**\s*[A-Za-z_][A-Za-z_0-9]*\s*\(.*)$'
)
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
                # #585: also index the 61 plain column-0 definitions with no gb_* prefix. Without
                # this, a citation into one of them resolves to None -- indistinguishable from
                # drift, and invisible to --check.
                m = PLAIN_DEF_RE.match(raw)
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
        # REGISTER EVERY SCANNED FILE, even with an EMPTY span list. Guarding this on `if spans`
        # made resolve() report 'unknown-file' for src/checker_builtin_procs.hpp -- a file that
        # EXISTS but is a pure table of builtin definitions with nothing this index can see. That
        # verdict reads like a DANGLING citation (a real defect worth chasing) when the truth is
        # benign: the citation points at table data, so it should be left bare like any other
        # file-scope reference. With the key present, resolve() says 'outside-any-function' instead,
        # and 'unknown-file' now means what it claims -- the file is not in src/ at all.
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


def corroborates(odin_name, cpp_name):
    """STRICT counterpart test, for the --anchor WRITE gate only. Never use related() here.

    related() is deliberately GENEROUS because it ranks a worklist: a false 'related' costs one
    missed drift, which is cheap. Using it as a write gate INVERTS that cost -- a false 'related'
    cements a wrong function name and --check then certifies it forever.

    That is not hypothetical; it is what the first --anchor run actually did. related() accepts any
    single shared token longer than 3 characters, so it paired:
        check_init_worker_data   with  calculate_global_init_order   (shared token: "init")
        check_procedure_bodies   with  check_procedure_later_from_entity
        get_target_arch_from_string with get_target_os_from_string
    -- 533 of 1,396 anchors rested on token intersection alone, and the sample above shows several
    were plainly wrong. The pass was reverted and re-run against this predicate instead.

    So: normalised EQUALITY or CONTAINMENT only. Containment is kept because the two codebases
    genuinely differ by suffix/prefix conventions that norm() cannot fully absorb
    (check_proc_body_internal vs check_proc_body), and both directions of containment are a
    substring relation over the WHOLE name, not an overlap of parts.

    A port procedure very often legitimately cites a HELPER of its counterpart rather than the
    counterpart itself, and no name rule can distinguish that from drift. Those citations therefore
    stay BARE and stay on the --suspect worklist to be READ. Leaving a true citation unanchored costs
    nothing but a line on a worklist; anchoring a false one costs a permanently green gate."""
    if not odin_name or not cpp_name or odin_name == "<file>":
        return False
    a, b = norm(odin_name), norm(cpp_name)
    return a == b or a in b or b in a


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


TRIAGED = os.path.join(os.path.dirname(os.path.abspath(__file__)), "citefn_triaged.txt")


def read_triaged():
    """set of (file.odin, proc_name) that have been read. See citefn_triaged.txt."""
    out = set()
    if not os.path.exists(TRIAGED):
        return out
    for raw in open(TRIAGED):
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        parts = line.split()
        if len(parts) != 2:
            print("citefn_triaged.txt: ignoring malformed line %r (want '<file.odin> <proc>')" % line)
            continue
        out.add((parts[0], parts[1]))
    return out


def proc_by_line(text):
    """1-based line -> owning top-level Odin proc name (or '<file>').

    A LEADING DOC-COMMENT BLOCK BELONGS TO THE PROCEDURE BELOW IT, not the one above. Walking
    downward naively attributes `// C++ Reference: ...` on the line above `foo :: proc` to whatever
    procedure happened to precede it -- so --apply silently skipped the two citations in
    get_constant_field_single's own doc comment and reported rewritten=0 (#585). The fix is a second
    pass that hands each unbroken run of comment/blank lines immediately above a proc header to that
    proc."""
    lines = text.split("\n")
    cur, out = "<file>", []
    for raw in lines:
        m = ODIN_PROC.match(raw)
        if m:
            cur = m.group(1)
        out.append(cur)
    # Second pass: reassign leading comment runs.
    for i, raw in enumerate(lines):
        m = ODIN_PROC.match(raw)
        if not m:
            continue
        j = i - 1
        while j >= 0:
            t = lines[j].strip()
            if t.startswith("//") or t == "":
                out[j] = m.group(1)
                j -= 1
            else:
                break
    return out


def line_of(offsets, pos):
    """1-based line number for a character offset, via the precomputed newline table."""
    return bisect.bisect_right(offsets, pos) + 1


def main():
    argv = sys.argv[1:]
    mode = argv[0] if argv else "--report"
    only = set()
    only_file = None
    for a in argv[1:]:
        if a.startswith("--only="):
            only = set(x.strip() for x in a[7:].split(",") if x.strip())
        elif a.startswith("--only-file="):
            only_file = a[12:]
        else:
            print("citefn: unknown argument %r" % a)
            return 2
    if mode == "--suspect":
        return suspects()

    # --anchor is the MECHANICAL bulk pass, and it is deliberately a different mode from --apply
    # rather than a wider scope for it, because the two make DIFFERENT CLAIMS.
    #
    #   --apply  asserts "a human read this procedure against C++". Scoped by citefn_triaged.txt.
    #   --anchor asserts only "the citation names the function its line numbers already point into".
    #
    # Nothing in --anchor's output may be taken as evidence the port is faithful. It does not add to
    # citefn_triaged.txt and must never be used to shrink the --suspect worklist.
    #
    # WHY IT IS SAFE TO RUN UNREAD, and why the naive version of this is not. Writing an anchor
    # derived from resolve() alone is circular: --check would then re-derive the same name from the
    # same lines and certify it forever, cementing a RIGHT-FILE-WRONG-FUNCTION citation (the class
    # that has now bitten three times -- #587, #592, #598 -- and is invisible to --check precisely
    # because bare citations assert no function). A blind bulk pass would have converted ~2,900
    # unchecked citations into ~2,900 apparently-checked ones. That is the #483 failure mode: a gate
    # that passes because it was taught the wrong answer.
    #
    # So --anchor requires TWO INDEPENDENT SIGNALS to agree before it writes:
    #   1. the cited lines resolve wholly inside exactly one C++ function (resolve() -> a name), AND
    #   2. that function's name corroborates the ENCLOSING ODIN PROCEDURE -- by normalised
    #      EQUALITY or CONTAINMENT (corroborates(), NOT related()), derived from the port side
    #      and knowing nothing about the line numbers.
    # Signal 2 is what breaks the circularity. Where the two disagree the citation is left BARE and
    # stays on the --suspect worklist for reading -- and those are exactly the ones a blind pass
    # would have got wrong.
    #
    # The FIRST version of this used related() for signal 2 and that was a real mistake, caught by
    # reading its output: it anchored `checker.cpp calculate_global_init_order` inside
    # check_init_worker_data because both names contain the token "init". 533 of 1,396 anchors
    # rested on token intersection alone. The pass was REVERTED and re-run against corroborates(),
    # which demands normalised equality or containment. Signal 2 is still corroboration rather than
    # proof, so the claim written stays weak -- "this citation points into function F", not "F was
    # ported correctly". That weaker claim is worth pinning anyway: from here on, a C++ edit that
    # moves F makes --check go red instead of the citation silently rotting.
    scope = None
    if mode == "--apply":
        triaged = read_triaged()
        if not triaged and not only:
            print("REFUSING: --apply needs a scope and citefn_triaged.txt is empty or missing.\n"
                  "  Anchoring asserts 'line N is inside function F'. Anchoring an UNTRIAGED\n"
                  "  citation that has already drifted makes that false assertion permanent, and\n"
                  "  --check will certify it clean forever. Add the procedures you have actually\n"
                  "  READ to %s, or pass --only=<proc,...>." % TRIAGED)
            return 2
        scope = set(p for (_f, p) in triaged) if triaged else set()
        if only:
            # --only NARROWS to an explicit list; it does not widen past what was read, unless
            # citefn_triaged.txt is absent entirely (handled above).
            unknown = only - scope if scope else set()
            if unknown:
                print("REFUSING: --only names %d procedure(s) absent from citefn_triaged.txt: %s\n"
                      "  --only narrows the triaged set, it does not widen it. If these really have\n"
                      "  been read, record that in the file first -- that is the audit trail."
                      % (len(unknown), " ".join(sorted(unknown))))
                return 2
            scope = only
        if only_file:
            scope = set(p for (f, p) in triaged if f == only_file) & (scope or set())
            if not scope:
                print("REFUSING: --only-file=%s selects no triaged procedure." % only_file)
                return 2
        print("CITEFN-APPLY scope: %d procedure(s) -- %s" % (len(scope), " ".join(sorted(scope))))

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
        # For --apply, we must know which Odin procedure each citation sits in. Built once per
        # file rather than per match: text[:m.start()].count("\n") inside the loop is O(n^2).
        writing = mode in ("--apply", "--anchor")
        procs = proc_by_line(text) if writing else None
        nl = [i for i, ch in enumerate(text) if ch == "\n"] if writing else None

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
            if writing:
                enclosing = procs[line_of(nl, m.start()) - 1]
                if mode == "--apply":
                    if enclosing not in scope:
                        stats["out-of-scope"] += 1
                        continue
                else:
                    # SIGNAL 2. Without this the pass is circular -- see --anchor above.
                    # STRICT predicate on purpose: related() is a ranking rule and is far too
                    # generous to write with. See corroborates().
                    if not corroborates(enclosing, name):
                        stats["uncorroborated"] += 1
                        continue
                out.append(text[pos:m.start()])
                out.append("%s %s:%s%s" % (cpp, name, lo, "-%d" % hi if hi else ""))
                pos = m.end()
                changed += 1

        if writing and changed:
            out.append(text[pos:])
            open(path, "w").write("".join(out))
            edits[base_odin] = changed

    print("CITEFN index: %d functions across %d src files" % (nfuncs, len(index)))
    print("  bare citations      %5d   resolvable %5d" % (stats["bare"], stats["resolvable"]))
    for k in ("outside-any-function", "range-spans-functions", "range-end-outside", "unknown-file"):
        if stats[k]:
            print("  %-22s%5d   (left alone, never guessed)" % (k, stats[k]))
    print("  already anchored    %5d   DRIFTED %d" % (stats["already-anchored"], stats["DRIFTED"]))

    # #615: this was `drifted[:40]`, a SILENT CAP. After the master merge it printed 40 of 54 and the
    # summary line said 54 -- so a reader who acted on the printed list would have "fixed" 40 and left 14
    # unexamined while believing the set was complete. A gate must never show less than it counts.
    for f, ln, cite, got in drifted:
        print("    DRIFT %-26s:%-5d %-46s now inside: %s" % (f, ln, cite, got))
    if mode == "--report":
        for f, ln, cite, why in unresolved[:25]:
            print("    SKIP  %-26s:%-5d %-46s %s" % (f, ln, cite, why))
    if mode == "--anchor":
        print("  uncorroborated      %5d   (resolvable, but the C++ name does NOT corroborate\n                              the enclosing Odin procedure -- left BARE, still on the\n                              --suspect worklist, because these are exactly the ones a\n                              blind pass would cement WRONGLY)" % stats["uncorroborated"])
        for f, n in edits.most_common():
            print("    anchored %-29s %5d" % (f, n))
        print("CITEFN-ANCHOR-DONE anchored=%d uncorroborated=%d\n  NOTE: anchoring is NOT reading. Nothing here belongs in citefn_triaged.txt."
              % (sum(edits.values()), stats["uncorroborated"]))
    if mode == "--apply":
        if stats["out-of-scope"]:
            print("  out-of-scope        %5d   (resolvable, but their procedure is not in the "
                  "triaged set -- left BARE on purpose)" % stats["out-of-scope"])
        for f, n in edits.most_common():
            print("    rewrote %-30s %5d" % (f, n))
        print("CITEFN-APPLY-DONE rewritten=%d" % sum(edits.values()))

    print("CITEFN-DONE mode=%s drifted=%d" % (mode, stats["DRIFTED"]))
    if mode == "--check":
        return 1 if stats["DRIFTED"] else 0
    return 0


if __name__ == "__main__":
    sys.exit(main())
