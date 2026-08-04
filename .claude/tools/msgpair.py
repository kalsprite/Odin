#!/usr/bin/env python3
"""msgpair.py -- find messages where C++ names the offending type/expression and the port may not.

Extracts diagnostic format strings from src/*.cpp and from the port, then reports C++ messages
whose text minus a trailing operand clause (", got '%s'" and friends) exactly matches a port
message. Run from the repo root.

CAVEAT, and it is the whole point: a hit is NOT a defect. C++ frequently has BOTH a bare and an
operand-bearing variant at DIFFERENT call sites, and so does the port. Deciding whether a given
port site is faithful requires comparing the CALL PATHS, not the strings. This tool narrows the
search; it does not answer it.
"""
import re, glob, collections

def strings(files, funcs):
    out = []
    pat = re.compile(r'\b(?:%s)\s*\(\s*[^,"]*,?\s*"((?:[^"\\]|\\.)*)"' % "|".join(funcs))
    for f in files:
        for line in open(f, errors="replace"):
            for m in pat.finditer(line):
                out.append((f, m.group(1)))
    return out

cpp  = strings(glob.glob("src/*.cpp"), ["error","warning","error_line","syntax_error"])
port = strings(glob.glob("core/odin/checker/*.odin") + glob.glob("core/odin/parser/*.odin"),
               ["error","error_node","error_pos","error_line","warning","warning_node",
                "syntax_error","syntax_error_pos"])

def norm(s):
    return (s.replace("%.*s","\x00").replace("%s","\x00")
             .replace("%td","\x01").replace("%lld","\x01").replace("%d","\x01"))

pn = collections.defaultdict(list)
for f,s in port: pn[norm(s)].append((f,s))

seen, hits = set(), []
for f,s in cpp:
    for suf in [", got '%s'", ", got %s", " '%s'", ": '%s'", " %s"]:
        if s.endswith(suf):
            stem = s[:-len(suf)]
            if norm(stem) in pn and s not in seen:
                seen.add(s); hits.append((s, pn[norm(stem)][0]))
            break

print("candidates: %d  (verify each against the CALL PATH before changing anything)" % len(hits))
for cppmsg,(pf,pmsg) in hits:
    print("  C++ : %s" % cppmsg)
    print("  port: %s   [%s]" % (pmsg, pf.split('/')[-1]))
