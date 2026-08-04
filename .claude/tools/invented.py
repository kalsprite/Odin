#!/usr/bin/env python3
"""invented.py -- port diagnostic strings that have NO counterpart in src/*.cpp.

An "invented message" is text the port can emit that the reference never emits under any input.
It is the sharpest static signal of a reimplemented-rather-than-ported code path, because a
faithful port cannot produce words the oracle does not have.

Method: extract format strings from error*/warning*/syntax_error* calls on both sides, normalise
away the format-specifier differences (C++ '%.*s' vs Odin '%s', '%lld' vs '%d', ...), and report
port strings whose normalised form appears nowhere in C++.

CAVEATS, and they matter:
  - Odin-side helper text (Suggestion lines, "\\t" continuations) is often assembled differently
    even when the user-visible output matches. A hit is a CANDIDATE, not a verdict.
  - The port legitimately owns a few messages the C++ CHECKER lacks because C++ emits them from
    the parser or the backend, which are different files. Check src/parser.cpp too before judging.
  - Confirm against a REPRO before deleting or rewording anything. progress#285 records what
    "correct in isolation" costs when the line is unreachable.
  - IT CANNOT TELL CODE FROM PROSE. The scan finds a `warning(`/`error(` token and then takes the
    next quoted string within 400 chars, so a COMMENT that quotes a removed diagnostic is reported
    as if the diagnostic were still live. On 2026-08-03 "Empty defer block has no effect" was
    flagged this way: the warning had already been deleted for parity (LEDGER 315) and the string
    survived only inside the comment recording its removal. Both compilers emit 0 diagnostics
    there. Always open the site before believing the hit.

Despite those caveats this is a productive instrument: the same 2026-08-03 run surfaced the matrix
count and matrix indexing families (#165) and the untyped-float division over-rejection (#281),
which the full 225-package parity run could NOT see because no core package uses that construct.
"""
import re, sys, pathlib

ROOT = pathlib.Path("/home/kalsprite/dev/odin")

CALL = re.compile(r'\b(?:error|warning|syntax_error|error_node|error_token|error_line|'
                  r'syntax_error_pos|error_no_newline)\w*\s*\(')

def strings_in(path, text):
    out = []
    for m in CALL.finditer(text):
        tail = text[m.end():m.end()+400]
        s = re.search(r'"((?:[^"\\]|\\.)*)"', tail)
        if s:
            out.append((path, text[:m.start()].count("\n") + 1, s.group(1)))
    return out

def norm(s):
    # Escape sequences are LITERAL here -- strings are lifted from source text, so "\\n" is two
    # characters, not a newline. Without this the normaliser collapses real whitespace but not
    # "\\n", so every C++ message ending in "\\n" failed to match its port counterpart and was
    # reported as a gap. Probe linkdup: "Non unique linking name for procedure '%.*s'\\n" is
    # present in BOTH compilers and was a false positive until this line existed.
    s = s.replace("\\n", " ").replace("\\t", " ")
    s = s.replace("%.*s", "%s").replace("%lld", "%d").replace("%td", "%d")
    s = s.replace("%llu", "%d").replace("%u", "%d").replace("%i", "%d")
    s = re.sub(r"%[-0-9.#+ ]*[a-zA-Z]", "%s", s)
    s = re.sub(r"\s+", " ", s).strip().rstrip(".")
    return s.lower()

cpp = set()
for p in (ROOT / "src").glob("*.cpp"):
    for _, _, s in strings_in(p, p.read_text(errors="ignore")):
        cpp.add(norm(s))

hits = []
for p in sorted((ROOT / "core/odin/checker").glob("*.odin")):
    for path, line, s in strings_in(p, p.read_text(errors="ignore")):
        n = norm(s)
        if len(n) < 12 or "%s" == n:
            continue
        if n not in cpp:
            hits.append((p.name, line, s))

for name, line, s in hits:
    print(f"  {name}:{line}: {s[:100]}")
print(f"invented-message candidates: {len(hits)}  (verify each against src/parser.cpp and a REPRO)")
