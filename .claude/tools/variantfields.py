#!/usr/bin/env python3
"""variantfields.py -- read-but-never-written audit over Entity VARIANT payload fields.

WHY THIS EXISTS SEPARATELY FROM #347's SWEEP: #347 closed "read but never written" as a NEGATIVE
RESULT (zero real defects). That conclusion did not survive. Counterexamples since:
    #545  a variant payload field that was genuinely dead
    #348  Entity_Builtin.pkg -- an INVENTED write-only field, deleted
    #562  an invented `type_info_deps` early-return guard, existing only to support dead recursion
    (unnumbered) Entity_Procedure.body -- zero writers, zero readers, no C++ counterpart
The likeliest explanation is that #347 swept top-level struct fields and never descended into the
Entity_* variant payloads, so this re-runs the audit with the variants as the explicit target.

A field counts as WRITTEN if it appears as an assignment target in either form Odin allows:
    e.field = / += / |= ...      selector assignment
    Entity_X{ field = ... }      composite-literal initialisation   <-- easy to miss; many
                                 entities are built entirely this way, so ignoring it would
                                 manufacture false "never written" hits.

Limits, stated rather than hidden: this is textual, so a field written only through a pointer
alias or a generic helper reads as unwritten. Every hit needs eyeballing before it is called a
defect -- the output is a WORKLIST, not a verdict.

usage: variantfields.py
"""
import os, re, subprocess, sys, collections

REPO = "/home/kalsprite/dev/odin"
SEM = os.path.join(REPO, "core/odin/ast/semantic_types.odin")
ROOTS = ["core/odin/checker", "core/odin/ast", "core/odin/parser"]

# ---- collect Entity_* variant fields -----------------------------------------
src = open(SEM).read().split("\n")
fields = collections.defaultdict(list)   # struct -> [field]
cur = None
for line in src:
    m = re.match(r"^(Entity_[A-Za-z_]*) :: struct \{", line)
    if m:
        cur = m.group(1); continue
    if cur and line.startswith("}"):
        cur = None; continue
    if cur:
        fm = re.match(r"^\s+([a-z_][a-z0-9_]*)\s*:\s*[^=]", line)
        if fm and not line.strip().startswith("//"):
            fields[cur].append(fm.group(1))

# ---- grep the tree once per field --------------------------------------------
files = []
for r in ROOTS:
    for dp, _, fn in os.walk(os.path.join(REPO, r)):
        files += [os.path.join(dp, f) for f in fn if f.endswith(".odin")]
blob = {}
for f in files:
    try: blob[f] = open(f).read()
    except Exception: pass

def counts(name):
    w = r_ = 0
    sel_assign = re.compile(r"\.%s\s*(?:[-+|&^*/]|<<|>>)?=(?!=)" % re.escape(name))
    lit_assign = re.compile(r"(?:^|[{,(\s])%s\s*=(?!=)" % re.escape(name))
    read = re.compile(r"\.%s\b" % re.escape(name))
    for f, s in blob.items():
        for line in s.split("\n"):
            t = line.strip()
            if t.startswith("//"):
                continue
            if sel_assign.search(line) or lit_assign.search(line):
                w += 1
            if read.search(line):
                r_ += 1
    return w, r_

print("=== Entity VARIANT payload fields: writes vs reads ===")
suspects = []
for st in sorted(fields):
    for fl in fields[st]:
        w, r_ = counts(fl)
        if w == 0:
            suspects.append((st, fl, w, r_))
            print("  NEVER-WRITTEN  %-22s %-24s writes=%-4d reads=%d" % (st, fl, w, r_))
print()
print("VARIANTFIELDS-DONE structs=%d fields=%d never_written=%d" %
      (len(fields), sum(len(v) for v in fields.values()), len(suspects)))
