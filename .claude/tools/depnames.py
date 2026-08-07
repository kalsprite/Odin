#!/usr/bin/env python3
"""depnames.py -- compare the add_package_dependency ROSTER between C++ and the port (#547).

WHY IT IS A SCRIPT AND NOT A GREP. The first version of this audit was an inline regex and it
had two defects that each manufactured phantom findings:

  (a) it matched only `add_package_dependency(c, ...)`. C++ also calls it with `ctx` in some
      translation units, so those sites were counted as MISSING from C++ and their port
      counterparts as PORT-ONLY -- 14 fabricated "port invented this" entries.
  (b) the required-ness comparison looked for the literal token `true`. The port passes a named
      constant (`REQUIRE`), so all 16 required sites read as differing.

Both are the same mistake: an extractor tuned to one spelling of the same thing. This version
matches ANY identifier as the context argument and normalises the required flag by VALUE, and it
prints the raw counts first so a wrong extractor shows up as an implausible total rather than as
a confident list of defects.

Signatures (verified identical in shape):
    C++ : add_package_dependency(CheckerContext *c, char const *package_name,
                                 char const *name, bool required=false)
    port: add_package_dependency(ctx: ^Checker_Context, package_name: string,
                                 name: string, required := false)

usage: depnames.py [CPP_SRC_DIR] [PORT_DIR]
"""
import os, re, sys

CPP_SRC  = sys.argv[1] if len(sys.argv) > 1 else \
    "/tmp/claude-1000/-home-kalsprite-dev-odin/5ae0f352-0d85-4f59-825d-514e4ce56a75/scratchpad/ref/src"
PORT_DIR = sys.argv[2] if len(sys.argv) > 2 else "/home/kalsprite/dev/odin/core/odin/checker"

# [try_to_]add_package_dependency( <ident> , "<pkg>" , "<name>" [, <required>] )
#
# The `try_to_` prefix must be CAPTURED, not ignored. C++ has TWO functions: the plain one
# asserts the entity exists (GB_ASSERT_MSG), the try_to_ one returns silently when it does not.
# An earlier version of this regex matched `add_package_dependency(` as a substring of
# `try_to_add_package_dependency(`, so the 11 objc/block names registered through the tolerant
# variant were compared against the strict roster -- same class of mistake as (a) and (b) above.
CALL = re.compile(
    r'\b(try_to_)?add_package_dependency\s*\(\s*[A-Za-z_&][A-Za-z0-9_.>-]*\s*,\s*'
    r'"([^"]*)"\s*,\s*"([^"]*)"\s*(?:,\s*([^)]*?)\s*)?\)')

# Tokens that mean "required" on either side. The port's REQUIRE is a constant; C++ writes true.
TRUTHY = {"true", "REQUIRE", "required"}


def scan(root, exts, skip_dirs=()):
    """-> {(pkg, name): required}, plus the raw call count so a broken regex is visible."""
    out, total = {}, 0
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in skip_dirs]
        for fn in filenames:
            if not fn.endswith(exts):
                continue
            path = os.path.join(dirpath, fn)
            try:
                text = open(path, encoding="utf-8", errors="replace").read()
            except OSError:
                continue
            for line in text.splitlines():
                s = line.strip()
                # Skip commented-out calls -- C++ keeps a disabled roster in checker.cpp and
                # counting it would invent work that upstream deliberately does not do.
                if s.startswith("//") or s.startswith("/*") or s.startswith("*"):
                    continue
                for m in CALL.finditer(line):
                    total += 1
                    tolerant = bool(m.group(1))
                    pkg, name, req = m.group(2), m.group(3), (m.group(4) or "").strip()
                    key = (pkg, name)
                    is_req = req in TRUTHY
                    # A name registered required at ANY site is required.
                    prev_req, prev_tol = out.get(key, (False, tolerant))
                    out[key] = (prev_req or is_req, prev_tol and tolerant)
    return out, total


cpp, cpp_calls = scan(CPP_SRC, (".cpp", ".hpp", ".h"))
# tests/ holds Odin fixtures, not checker source; walking it would count fixture text as roster.
port, port_calls = scan(PORT_DIR, (".odin",), skip_dirs=("tests", "docs"))

print(f"cpp_calls={cpp_calls} cpp_distinct={len(cpp)}   "
      f"port_calls={port_calls} port_distinct={len(port)}")

missing   = sorted(set(cpp) - set(port))
port_only = sorted(set(port) - set(cpp))
req_diff  = sorted(k for k in set(cpp) & set(port) if cpp[k][0] != port[k][0])
# Registered through the TOLERANT variant in C++ but the STRICT one in the port (or vice versa).
# The port currently has no try_to_ equivalent at all, so every such name shows here.
tol_diff  = sorted(k for k in set(cpp) & set(port) if cpp[k][1] != port[k][1])


def tag(d, k):
    req, tol = d[k]
    return ("  [required]" if req else "") + ("  [try_to_]" if tol else "")


print(f"\n=== IN C++, NOT IN PORT ({len(missing)}) ===")
for k in missing:
    print(f"  {k[0]}.{k[1]}{tag(cpp, k)}")
print(f"\n=== IN PORT, NOT IN C++ ({len(port_only)}) ===")
for k in port_only:
    print(f"  {k[0]}.{k[1]}{tag(port, k)}")
print(f"\n=== REQUIRED-NESS DIFFERS ({len(req_diff)}) ===")
for k in req_diff:
    print(f"  {k[0]}.{k[1]}: cpp={cpp[k][0]} port={port[k][0]}")
print(f"\n=== STRICT-vs-TOLERANT VARIANT DIFFERS ({len(tol_diff)}) ===")
for k in tol_diff:
    print(f"  {k[0]}.{k[1]}: cpp_try_to={cpp[k][1]} port_try_to={port[k][1]}")

print(f"\nDEPNAMES-DONE missing={len(missing)} port_only={len(port_only)} "
      f"req_diff={len(req_diff)} tol_diff={len(tol_diff)}")
sys.exit(1 if (missing or port_only or req_diff or tol_diff) else 0)
