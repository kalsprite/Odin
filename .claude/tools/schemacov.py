#!/usr/bin/env python3
"""schemacov.py -- which dump-model schema fields does each side ACTUALLY emit?

WHY THIS EXISTS (#558). The v2 schema check in modeldiff.py compares the `## schema` LINE, which
is a hardcoded string constant on both sides. So it catches "the two schemas disagree" but is
structurally blind to the failure that actually happened:

    a field DECLARED in the schema string that the emitter never WRITES.

`objcsel` was listed in DUMP_MODEL_SCHEMA from the day schema v2 was written, and the port's
Procedure arm never emitted it. Result: every objc method compared as ref=<selector> port=None --
7680 phantom divergences across four darwin packages, the LARGEST apparent disagreement anywhere in
the model, produced entirely by the instrument. The schema check passed the whole time, because
both sides declared the field identically.

This is #509's rule ("suspect your instrument first") applied to the schema itself, and #405's
false-green shape one level up: a declared-but-unwritten field reads as agreement forever.

WHAT IT REPORTS
    REF-ONLY   emitted by the reference, never by the port  -> the #558 signature. Investigate.
    PORT-ONLY  emitted by the port, never by the reference   -> the mirror image.
    NEITHER    in the schema, emitted by neither side over these packages. NOT necessarily a bug:
               most dump fields are omit-when-default, so a field is absent simply because no
               entity in the sample set had a non-default value. It IS a coverage gap -- these are
               the fields for which this tool, and the state comparison generally, can say nothing.
               Widen the package list to shrink it.
    EXTRA      emitted but absent from the schema string -- the schema is stale.

USAGE
    schemacov.py <REF_BIN> <PORT_BIN> [pkg ...]
        REF_BIN   instrumented C++ compiler from build_ref.sh (honours ODIN_DUMP_MODEL)
        PORT_BIN  a triage_st build (honours -dump-model:)
        pkg       packages to sample; defaults to a spread chosen to exercise objc, foreign,
                  linkage, polymorphic and constant-heavy code

The same two traps as modeldiff apply and are handled here: the reference needs ODIN_ROOT set
explicitly (a scratchpad build cannot find core/, and the resulting error is CONSTANT so it hashes
equal and reads as agreement -- #475), and the port must run -no-threads (#344).
"""
import os, re, subprocess, sys, tempfile

REPO = "/home/kalsprite/dev/odin"

DEFAULT_PKGS = [
    "core/sys/darwin/Foundation",  # objc selectors, objc class names
    "vendor/darwin/Metal",         # objc, heavily
    "core/fmt", "core/os", "core/net", "core/time",
    "core/math/linalg",            # matrix/float constants
    "core/odin/checker", "core/sys/linux", "core/crypto",
    "core/reflect", "core/thread", "base/runtime",
    "core/encoding/json",
]

def dump_keys(path):
    """Every `k=` key that actually appears, ignoring the four positional columns."""
    ks = set()
    with open(path) as f:
        for line in f:
            if not line.startswith("entity\t"):
                continue
            # entity <tab> pkg <tab> name <tab> kind <tab> k=v ...
            for fld in line.rstrip("\n").split("\t")[4:]:
                m = re.match(r"([A-Za-z_]+)=", fld)
                if m:
                    ks.add(m.group(1))
    return ks

def schema_of(path):
    with open(path) as f:
        for line in f:
            if line.startswith("## schema"):
                return set(x for x in line.split()[-1].split(",") if x)
    return set()

def main():
    if len(sys.argv) < 3:
        sys.exit("usage: schemacov.py <REF_BIN> <PORT_BIN> [pkg ...]")
    ref, port = sys.argv[1], sys.argv[2]
    pkgs = sys.argv[3:] or DEFAULT_PKGS
    tmp = tempfile.mkdtemp()
    rk, pk, schema = set(), set(), set()
    measured = 0

    for p in pkgs:
        rp = os.path.join(tmp, "r.txt")
        pp = os.path.join(tmp, "p.txt")
        for f in (rp, pp):
            if os.path.exists(f):
                os.remove(f)
        env = dict(os.environ, ODIN_ROOT=REPO, ODIN_DUMP_MODEL=rp)
        subprocess.run([ref, "check", p, "-no-entry-point", "-thread-count:1"], env=env,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, cwd=REPO)
        subprocess.run([port, p, f"-dump-model:{pp}", "-no-threads"],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, cwd=REPO)
        if not (os.path.exists(rp) and os.path.exists(pp)):
            print(f"  SKIPPED {p} (a dump is missing -- one side failed to run)")
            continue
        measured += 1
        rk |= dump_keys(rp)
        pk |= dump_keys(pp)
        schema |= schema_of(rp)

    ref_only  = sorted(rk - pk)
    port_only = sorted(pk - rk)
    neither   = sorted(schema - (rk | pk))
    extra     = sorted((rk | pk) - schema)

    print(f"packages_measured={measured}/{len(pkgs)} schema_fields={len(schema)} "
          f"emitted_ref={len(rk)} emitted_port={len(pk)}")
    print(f"REF-ONLY  : {ref_only  or 'none'}")
    print(f"PORT-ONLY : {port_only or 'none'}")
    print(f"EXTRA     : {extra     or 'none'}")
    print(f"NEITHER   : {neither   or 'none'}   (coverage gap, not necessarily a defect)")
    print(f"SCHEMACOV-DONE one_sided={len(ref_only) + len(port_only)} extra={len(extra)} "
          f"uncovered={len(neither)}")
    # Only ONE-SIDED emission and EXTRA fields are failures. NEITHER is reported, never gated:
    # omit-when-default fields are legitimately absent when no sampled entity sets them, and
    # gating on it would make the tool red forever for a reason that is not a defect.
    return 1 if (ref_only or port_only or extra) else 0

if __name__ == "__main__":
    sys.exit(main())
