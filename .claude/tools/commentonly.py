#!/usr/bin/env python3
"""commentonly.py OLD NEW -- prove a change touched ONLY comments.

WHY THIS IS A SCRIPT AND NOT A sed ONE-LINER. It has now been got wrong three times, each time
reporting CODE-CHANGED for a change that was purely comments:
  * #599: `sed 's,^\\s*//.*,,'` strips only FULL-LINE comments, so 4 files with TRAILING comments on
    code lines were flagged.
  * #605: `sed 's,//.*,,'` strips line comments but not /* */ BLOCKS, so a file-header block was flagged.
  * #607: stripping both still left BLANK LINES where multi-line comments had been added, so a
    whole-text equality test was flagged.
A proof tool that cries wolf gets ignored, and "it's probably just comments" is exactly the reasoning
that lets a real code change through. So: strip block comments, strip line comments, then compare the
sequence of NON-BLANK lines. Adding or removing comment lines shifts blank lines around and must not
count; changing a single character of code must.

CAVEAT, stated rather than hidden: a `//` or `/*` inside a STRING LITERAL is stripped too. That can only
cause a FALSE PASS if real code changed after such a token on the same line. Odin's checker sources do
contain diagnostic strings with slashes, so if this ever reports COMMENT-ONLY on a change you expected to
be semantic, do not trust it -- read the diff.
"""
import re, sys

def norm(path):
    s = open(path, encoding="utf-8", errors="replace").read()
    s = re.sub(r'/\*.*?\*/', '', s, flags=re.S)   # block comments
    s = re.sub(r'//[^\n]*', '', s)                # line comments
    return [ln.rstrip() for ln in s.split("\n") if ln.strip()]

if len(sys.argv) != 3:
    print("usage: commentonly.py OLD NEW", file=sys.stderr); sys.exit(2)
a, b = norm(sys.argv[1]), norm(sys.argv[2])
if a == b:
    print("COMMENT-ONLY  %s (%d code lines, unchanged)" % (sys.argv[2], len(a)))
    sys.exit(0)
import difflib
print("CODE-CHANGED  %s" % sys.argv[2])
for l in difflib.unified_diff(a, b, "old", "new", lineterm="", n=1):
    if not l.startswith(("---", "+++", "@@")):
        print("   " + l)
sys.exit(1)
