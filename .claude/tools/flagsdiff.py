#!/usr/bin/env python3
"""flagsdiff.py -- untruncated, BIT-LEVEL breakdown of the dump-model `flags` divergence (#547).

WHY: every view I had of this residual truncated the flag string at 40-44 chars, so
`ref=customlinkagestrong|customlinkname|procb port=customlinkagestrong|customlinkname|procb`
read as "identical" when the differing bits were past the cutoff. #547's framing ("used/require
missing on runtime procs") came from such a view and must be re-derived, not trusted.

Reuses modeldiff's read_dump/split_state -- a second comparator is how #509's phantoms were made.

usage: flagsdiff.py <REF_BIN> <PORT_BIN> [PKGLIST]
"""
import collections, os, subprocess, sys, tempfile

REPO = "/home/kalsprite/dev/odin"
sys.path.insert(0, os.path.join(REPO, ".claude", "tools"))
import modeldiff

ref, port = sys.argv[1], sys.argv[2]
pkglist = sys.argv[3] if len(sys.argv) > 3 else os.path.join(REPO, ".claude/tools/pkglist.txt")
pkgs = [l.strip() for l in open(pkglist) if l.strip() and not l.startswith("#")]

tmp = tempfile.mkdtemp()
ref_only_bits = collections.Counter()   # bit set by ref, not by port
port_only_bits = collections.Counter()  # bit set by port, not by ref
pattern = collections.Counter()         # (frozenset ref-only, frozenset port-only) -> count
examples = {}
by_kind = collections.Counter()
entities = collections.Counter()        # entity name -> times it differs

for i, p in enumerate(pkgs, 1):
    rp, pp = os.path.join(tmp, "r.txt"), os.path.join(tmp, "p.txt")
    for f in (rp, pp):
        if os.path.exists(f): os.remove(f)
    env = dict(os.environ, ODIN_ROOT=REPO, ODIN_DUMP_MODEL=rp)
    subprocess.run([ref, "check", p, "-no-entry-point", "-thread-count:1"], env=env,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, cwd=REPO)
    subprocess.run([port, p, f"-dump-model:{pp}", "-no-threads"],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, cwd=REPO)
    if not (os.path.exists(rp) and os.path.exists(pp)):
        continue
    a, fa, sa = modeldiff.read_dump(rp)
    b, fb, sb = modeldiff.read_dump(pp)
    if sa != sb: continue
    # split_state returns (attributable, unpairable) since #553; the second element counts keys
    # where per-field blame cannot be assigned. Ignored here -- flagsdiff reports only the flags
    # column, and an unattributable key contributes no flags evidence either way.
    _st, _unpairable = modeldiff.split_state(fa, fb, a - b, b - a)
    for k, v in _st.items():
        pkg, nm, kind, fld, va, vb = k
        if fld != "flags": continue
        ra = set(x for x in va.split("|") if x)
        pa = set(x for x in vb.split("|") if x)
        ro, po = frozenset(ra - pa), frozenset(pa - ra)
        for bit in ro: ref_only_bits[bit] += v
        for bit in po: port_only_bits[bit] += v
        pattern[(ro, po)] += v
        by_kind[kind] += v
        entities[f"{pkg}.{nm}"] += v
        examples.setdefault((ro, po), f"{pkg}.{nm} ({kind})\n        ref ={va}\n        port={vb}")
    print(f"[{i}/{len(pkgs)}] {p}", file=sys.stderr)

print("=== BITS the REFERENCE sets and the PORT does not ===")
for bit, n in ref_only_bits.most_common(): print(f"  {bit:28s} {n}")
print("=== BITS the PORT sets and the REFERENCE does not ===")
for bit, n in port_only_bits.most_common() or [("(none)", 0)]:
    print(f"  {bit:28s} {n}")
print("=== DISTINCT PATTERNS (ref-only bits -> port-only bits) ===")
for (ro, po), n in pattern.most_common():
    print(f"  x{n:6d}  ref_extra={sorted(ro) or '-'}  port_extra={sorted(po) or '-'}")
    print(f"        e.g. {examples[(ro,po)]}")
print("=== by entity KIND ===")
for k, n in by_kind.most_common(): print(f"  {k:16s} {n}")
print(f"=== DISTINCT ENTITIES involved: {len(entities)} ===")
for nm, n in entities.most_common(20): print(f"  {nm:60s} {n}")
