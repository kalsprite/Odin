#!/usr/bin/env python3
"""missing.py -- reference diagnostic strings with NO counterpart in the port.

The inverse of invented.py. invented.py finds text the port can emit that the oracle never does
(over-rejections, invented messages). This finds text the ORACLE can emit that the port never
does -- i.e. candidate UNDER-REJECTIONS: checks C++ performs and the port silently skips.

WHY IT EXISTS. Every corpus-anchored instrument (parity.sh, parity_vet.sh, cmpfull.py,
sweep_det.sh) can only see a divergence that some package in the corpus actually triggers. Three
defects closed on 2026-08-03 were invisible to all of them and were found by static comparison
instead:
    #176  a MODE never run            (vet)
    #281  a CONSTRUCT never used      (untyped float / typed int division)
    #282  a COMBINATION never written (disabled @(fini))
An under-rejection is the hardest case for a reference-anchored test, because the port emits
NOTHING -- there is no wrong text to compare. Static scanning is the only cheap way in.

SCOPE. Only the C++ translation units the port actually covers are scanned. llvm_backend*.cpp,
linker, main.cpp usage text and friends are excluded: their absence from the port is by design,
not a gap, and including them buries the signal.

CAVEATS, and they matter as much as invented.py's:
  - A hit is a CANDIDATE, not a verdict. The port legitimately rewords some diagnostics, and the
    normaliser cannot see through a message assembled from pieces.
  - LIKE invented.py, THIS CANNOT TELL CODE FROM PROSE. It takes the next quoted string after an
    error(/warning( token, so a commented-out C++ diagnostic reads as live.
  - A missing string does NOT prove a missing CHECK -- the port may perform the same check and
    phrase it differently. Confirm with a REPRO that the oracle rejects and the port accepts.
    That repro is the actual deliverable; the scan only says where to look.
"""
import re, sys, pathlib

ROOT = pathlib.Path("/home/kalsprite/dev/odin")

# C++ files the port is a port OF. Anything else is out of scope by construction.
IN_SCOPE = {
    "checker.cpp", "check_expr.cpp", "check_type.cpp", "check_decl.cpp",
    "check_stmt.cpp", "check_builtin.cpp", "parser.cpp", "tokenizer.cpp",
    "types.cpp", "entity.cpp", "exact_value.cpp",
}

CALL = re.compile(r'\b(?:error|warning|syntax_error|error_node|error_token|error_line|'
                  r'syntax_error_pos|error_no_newline)\w*\s*\(')

def strings_in(text):
    out = []
    for m in CALL.finditer(text):
        tail = text[m.end():m.end()+400]
        s = re.search(r'"((?:[^"\\]|\\.)*)"', tail)
        if s:
            out.append((text[:m.start()].count("\n") + 1, s.group(1)))
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

port = set()
for p in (ROOT / "core/odin/checker").glob("*.odin"):
    for _, s in strings_in(p.read_text(errors="ignore")):
        port.add(norm(s))
for sub in ("core/odin/parser", "core/odin/ast"):
    for p in (ROOT / sub).glob("*.odin"):
        for _, s in strings_in(p.read_text(errors="ignore")):
            port.add(norm(s))

hits = []
for p in sorted((ROOT / "src").glob("*.cpp")):
    if p.name not in IN_SCOPE:
        continue
    for line, s in strings_in(p.read_text(errors="ignore")):
        n = norm(s)
        if len(n) < 12 or n == "%s":
            continue
        if n not in port:
            hits.append((p.name, line, s))

only = sys.argv[1] if len(sys.argv) > 1 else None
for name, line, s in hits:
    if only and only not in name:
        continue
    print(f"  {name}:{line}: {s[:100]}")
print(f"reference-only diagnostics: {len(hits)}  "
      f"(CANDIDATES -- each needs a repro the oracle rejects and the port accepts)")
