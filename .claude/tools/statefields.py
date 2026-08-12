#!/usr/bin/env python3
"""statefields.py -- corpus-wide breakdown of dump-model STATE disagreements BY FIELD.

WHY: modeldiff prints sorted(state)[:10] and modelsweep prints head -60 of that, both capped by
ENTITY NAME. So "the only field left is flags" read off either one is a claim about the first N
names, not about the corpus. #556 needed the untruncated answer for the `value` column.

This deliberately imports modeldiff's own read_dump/split_state rather than re-deriving them --
a second comparator is how #509's phantom divergences got manufactured.

usage: statefields.py <REF_BIN> <PORT_BIN> [PKGLIST]
"""
import atexit, collections, os, shutil, subprocess, sys, tempfile

REPO = "/home/kalsprite/dev/odin"
sys.path.insert(0, os.path.join(REPO, ".claude", "tools"))
import modeldiff

ref, port = sys.argv[1], sys.argv[2]
pkglist = sys.argv[3] if len(sys.argv) > 3 else os.path.join(REPO, ".claude/tools/pkglist.txt")

pkgs = [l.strip() for l in open(pkglist) if l.strip() and not l.startswith("#")]
tmp = tempfile.mkdtemp()
atexit.register(shutil.rmtree, tmp, ignore_errors=True)  # #649: leaked without this; /tmp is a tmpfs, so a leak is RAM
by_field = collections.Counter()
by_field_pkgs = collections.defaultdict(set)
examples = {}
skipped = []

for i, p in enumerate(pkgs, 1):
    rp, pp = os.path.join(tmp, "r.txt"), os.path.join(tmp, "p.txt")
    for f in (rp, pp):
        if os.path.exists(f): os.remove(f)
    env = dict(os.environ, ODIN_ROOT=REPO, ODIN_DUMP_MODEL=rp)
    subprocess.run([ref, "check", p, "-no-entry-point", "-thread-count:1"], env=env,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, cwd=REPO)
    subprocess.run([port, p, f"-dump-model:{pp}", "-no-threads"],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, cwd=REPO)
    if not os.path.exists(rp) or not os.path.exists(pp):
        skipped.append(p); continue
    a, fa, sa = modeldiff.read_dump(rp)
    b, fb, sb = modeldiff.read_dump(pp)
    if sa != sb:
        skipped.append(p + " (schema)"); continue
    # split_state returns (attributable, unpairable) since #553 -- the second element counts keys
    # whose entity counts differ or exceed one per side, where per-field blame cannot be assigned.
    state, _unpairable = modeldiff.split_state(fa, fb, a - b, b - a)
    for k, v in state.items():
        _pkg, nm, kind, fld, va, vb = k
        by_field[fld] += v
        by_field_pkgs[fld].add(p)
        examples.setdefault(fld, f"{_pkg}.{nm} ({kind}) ref={va[:40]} port={vb[:40]}")
        if fld in os.environ.get("DETAIL_FIELDS","").split(","):
            print(f"DETAIL {fld} x{v} {p} :: {_pkg}.{nm} ({kind}) ref={va[:60]} port={vb[:60]}")
    print(f"[{i}/{len(pkgs)}] {p}", file=sys.stderr)

print("=== STATE disagreements by FIELD, whole corpus, untruncated ===")
for fld, n in by_field.most_common():
    print(f"  {fld:12s} entities={n:6d} packages={len(by_field_pkgs[fld]):4d}   e.g. {examples[fld]}")
if not by_field:
    print("  (none)")
print(f"SKIPPED={len(skipped)} {' '.join(skipped)}")
