#!/usr/bin/env python3
"""modeldiff.py -- compare the SEMANTIC MODEL of the C++ reference against the port (#475/#509).

WHY THIS EXISTS. Every other gate in .claude/tools is anchored on TEXT the compiler prints, so a
divergence that produces no diagnostic is invisible to all of them. #416 (type_align_of missing its
Bit_Field arm) and #475 (type_align_of's Bit_Set arm truncated to `return 8`) both sat behind 323
green parity packages for exactly that reason. This compares STATE.

USAGE
    modeldiff.py <REF_BIN> <PORT_BIN> <pkg> [pkg...]
        REF_BIN   instrumented C++ compiler from build_ref.sh; honours ODIN_DUMP_MODEL=<path>
        PORT_BIN  the port; honours -dump-model:<path>

TWO COMPARATOR BUGS ARE BAKED OUT HERE, both of which produced confident wrong answers when this
was written ad-hoc (LEDGER #509):

  1. MULTISET, NOT DICT. Keying on (pkg, name, kind) collapses every local called `c`, `r` or `_`
     onto one key and then compares two arbitrary representatives. That manufactured four
     "divergences" in core/strings that do not exist. Counting is the only correct treatment when
     names repeat, and in a checker's entity list they repeat constantly.

  2. INVALID TYPES ARE EXCLUDED AT THE SOURCE, not here -- both dumps already skip them. Recorded
     because the reason is not obvious: is_type_typed(t_invalid) is TRUE in BOTH implementations
     (t_invalid is a Basic with no Untyped flag, LEDGER #43), so a guard on is_type_typed alone
     lets builtins and proc-groups through and asks for the alignment of an invalid type. Neither
     compiler DECIDES that: C++ falls through its Basic switch to 8, the port to 1. Two
     fallthroughs, no semantics, and 130 fake divergences on the first run.

NORMALISATION, deliberately minimal -- each item is a REPRESENTATION difference, not a semantic one:
    kind names   C++ "TypeName" vs port "Type_Name"   -> strip underscores, lowercase
    package      port renders "bytes#7" (name + id)   -> strip the "#id" suffix
Type STRINGS are not compared at all: the two implementations render types through independent
printers, so spelling differences would swamp the signal. Size and align are the semantic content.

OUTPUT: one line per package, plus the excess entries on each side when they differ. A package with
excess on BOTH sides usually means instantiation multiplicity (#468), not a layout defect -- check
whether -no-threads shrinks it before treating it as one.
"""
import collections, os, re, subprocess, sys, tempfile

SUMMARY = False
REPO = "/home/kalsprite/dev/odin"

def norm_kind(k): return k.replace("_", "").lower()

# ---- SCHEMA v2 READER (LEDGER #544) ---------------------------------------------------------
# ONE reader for BOTH sides. Before v2 there were two, because the dumps had different column
# orders and the C++ side emitted neither flags nor state nor position. They now share a fixed
# positional prefix
#     entity <TAB> pkg <TAB> name <TAB> kind <TAB> size=N <TAB> align=N
# followed by omit-when-default KEY=VALUE fields, so one parser serves both and any future field
# is picked up on both sides at once instead of drifting.
#
# The `type=` field is READ AND DISCARDED for comparison. That is not an oversight: the two
# implementations render types through independent printers, so a cosmetic spelling difference
# would swamp every other signal. It is still emitted because it groups instantiations within one
# side, which is what separated "N duplicates" from "N distinct types" in #510.
STATE_IGNORED = {"type"}

def read_dump(path):
    """Returns (layout_counter, per_key_field_lists, schema_string).

    layout_counter keys on (pkg, name, kind, size, align) exactly as v1 did, so split_layout /
    split_attribution / the presence-vs-multiplicity split all keep working unchanged.
    per_key_field_lists additionally carries the FULL field set per entity, which is what makes
    state comparison possible at all.
    """
    c = collections.Counter()
    fields = collections.defaultdict(list)
    schema = None
    inside = False
    with open(path) as f:
        for l in f:
            if l.startswith("## schema"):
                schema = l.strip()
                continue
            if l.startswith("## sorted"): inside = True; continue
            if l.startswith("## end"):    inside = False
            if not inside or not l.startswith("entity\t"): continue
            fs = l.rstrip("\n").split("\t")
            if len(fs) < 6:
                continue
            # The port renders the package as `name#id` (#464); C++ has no id column. Strip it so
            # the two are comparable -- the id earns its place WITHIN one side, not across.
            pkg = re.sub(r"#\d+$", "", fs[1])
            key = (pkg, fs[2], norm_kind(fs[3]), fs[4], fs[5])
            c[key] += 1
            kv = {}
            for tok in fs[6:]:
                if "=" in tok:
                    k, v = tok.split("=", 1)
                    if k not in STATE_IGNORED:
                        kv[k] = v
            fields[key].append(tuple(sorted(kv.items())))
    return c, fields, schema

def split_state(fa, fb, ea, eb):
    """Field-level disagreements on entities BOTH sides have in the same multiplicity.

    WHY THE MULTIPLICITY GUARD. A key can carry several entities -- typically a generic
    declaration AND its instantiations. Pairing them requires knowing WHICH entity is which, and
    when the counts differ there is no honest pairing available. Comparing sorted lists of
    different lengths, or indexing [0] of each, manufactures differences: doing exactly that
    produced 30 phantom mismatches (poly/instr/pos) during #544's first measurement, which
    "resolved" only because an unrelated change altered one side's sort order. So: compare as a
    MULTISET, and only attribute per-FIELD blame when the counts agree.
    """
    out = collections.Counter()
    unpairable = collections.Counter()
    for key in set(fa) & set(fb):
        if key in ea or key in eb:
            continue                      # already accounted as presence/multiplicity
        ma, mb = collections.Counter(fa[key]), collections.Counter(fb[key])
        if ma == mb:
            continue
        if len(fa[key]) != len(fb[key]):
            unpairable[key] += 1          # not pairable; multiplicity already reports it
            continue
        if len(fa[key]) != 1:
            # EQUAL counts but MORE THAN ONE entity under the key. The guard above only caught
            # unequal counts; this case fell through to sorted()/zip(), which pairs by sort order
            # and therefore pairs ARBITRARILY. That is the same manufacture-a-difference the
            # docstring warns about, one case further along.
            #
            # #560 is the worked example: key (_weierstrass, fe, Variable, 8, 8) carries TWO
            # entities on each side -- `for fe in arg1` locals in identical bodies across four
            # _fiat field packages. The four positions are IDENTICAL on both sides; only which
            # entity pairs with which differs, and the zip reported that as a `pos` divergence.
            # It is not one. Entity `pkg` is context-derived in BOTH implementations
            # (C++ checker.cpp:2251 `e->pkg = c->pkg`, the only Entity pkg assignment in src/),
            # so for a body reachable from two packages the attribution follows check order, and
            # neither side is canonically right.
            #
            # Counted, NOT dropped: `ma != mb` already told us these keys differ. Reporting them
            # separately keeps that visible while removing them from the number a gate reads.
            unpairable[key] += 1
            continue
        for ta, tb in zip(sorted(fa[key]), sorted(fb[key])):
            da, db = dict(ta), dict(tb)
            for f in set(da) | set(db):
                if da.get(f) != db.get(f):
                    out[(key[0], key[1], key[2], f, str(da.get(f)), str(db.get(f)))] += 1
    return out, unpairable

def split_attribution(ea, eb):
    """Move same-entity-different-PACKAGE pairs out of the excess counters (#513).

    An entity that both sides have, agreeing on name/kind/size/align but disagreeing on which
    PACKAGE owns it, otherwise surfaces as TWO findings -- one REF-ONLY and one PORT-ONLY -- and
    reads as "each implementation has something the other lacks". It is one entity and one
    disagreement, about attribution.

    This is not hypothetical: C++ files core/c/libc/stdio.odin's nested `stream_proc` and
    `unknown_or_eof` under `posix`, deterministically (5/5 runs), where the port files them under
    `libc` -- the package whose file declares them, which is the defensible answer. Same family as
    #469. Mutates ea/eb in place and returns the extracted pairs.
    """
    by_rest = {}
    for (pkg, nm, k, s, al), v in list(ea.items()):
        by_rest.setdefault((nm, k, s, al), []).append((pkg, v))
    out = collections.Counter()
    for (pkg_b, nm, k, s, al), vb in list(eb.items()):
        cands = by_rest.get((nm, k, s, al))
        if not cands:
            continue
        pkg_a, va = cands[0]
        n = min(va, vb)
        if n <= 0:
            continue
        out[(nm, k, s, al, pkg_a, pkg_b)] += n
        ea[(pkg_a, nm, k, s, al)] -= n
        eb[(pkg_b, nm, k, s, al)] -= n
        if ea[(pkg_a, nm, k, s, al)] <= 0: del ea[(pkg_a, nm, k, s, al)]
        if eb[(pkg_b, nm, k, s, al)] <= 0: del eb[(pkg_b, nm, k, s, al)]
        cands.pop(0)
    return out

def split_layout(ea, eb):
    """Move same-(pkg,name,kind)/different-(size,align) pairs out of the excess counters.

    THIS IS THE FINDING THE INSTRUMENT EXISTS FOR, and until now it was not separated from the
    noise. #514 is the worked example: core/math/linalg reported excess_port=48 "including six
    PORT-ONLY constants that turned out not to be port-only at all -- C++ had them with different
    alignment". Because the multiset key includes size and align, ONE entity whose alignment
    disagrees appears as TWO excess entries, one on each side, and is indistinguishable by count
    from two unrelated presence differences.

    That distinction is cheap here and decisive across 323 packages: #468 instantiation
    multiplicity is a KNOWN, accepted residue that shows up as excess on both sides in most
    packages, so a sweep that lumps the two together reports a permanent sea of red in which a real
    layout defect is invisible. Layout disagreement is a defect; multiplicity is a difference in
    WHICH polymorphic instantiations exist. Mutates ea/eb in place and returns the pairs.
    """
    by_id = {}
    for (pkg, nm, k, s, al), v in list(ea.items()):
        by_id.setdefault((pkg, nm, k), []).append((s, al, v))
    out = collections.Counter()
    for (pkg, nm, k, s_b, al_b), vb in list(eb.items()):
        cands = by_id.get((pkg, nm, k))
        if not cands:
            continue
        s_a, al_a, va = cands[0]
        if (s_a, al_a) == (s_b, al_b):
            continue
        n = min(va, vb)
        if n <= 0:
            continue
        out[(pkg, nm, k, s_a, al_a, s_b, al_b)] += n
        ea[(pkg, nm, k, s_a, al_a)] -= n
        eb[(pkg, nm, k, s_b, al_b)] -= n
        if ea[(pkg, nm, k, s_a, al_a)] <= 0: del ea[(pkg, nm, k, s_a, al_a)]
        if eb[(pkg, nm, k, s_b, al_b)] <= 0: del eb[(pkg, nm, k, s_b, al_b)]
        cands.pop(0)
    return out


def main():
    if len(sys.argv) < 4:
        sys.exit("usage: modeldiff.py <REF_BIN> <PORT_BIN> <pkg> [pkg...]")
    global SUMMARY
    args = sys.argv[1:]
    if "--summary" in args:
        SUMMARY = True
        args.remove("--summary")
    if len(args) < 3:
        sys.exit("usage: modeldiff.py [--summary] <REF_BIN> <PORT_BIN> <pkg> [pkg...]")
    ref, port, pkgs = args[0], args[1], args[2:]
    tmp = tempfile.mkdtemp()
    bad = 0
    layout_bad = 0
    state_total = 0
    state_pkgs = 0
    for p in pkgs:
        rp, pp = os.path.join(tmp, "r.txt"), os.path.join(tmp, "p.txt")
        for f in (rp, pp):
            if os.path.exists(f): os.remove(f)
        env = dict(os.environ, ODIN_ROOT=REPO, ODIN_DUMP_MODEL=rp)
        # -thread-count:1 pins the REFERENCE the way -no-threads pins the port, and for the same
        # reason. #468/#509 established that threading only ever ADDS polymorphic instantiations on
        # the C++ side, so an unpinned reference makes the multiplicity counts wander run to run:
        # two full sweeps with identical binaries moved NINE packages between MULTIPLICITY and
        # MODEL-MATCH (LEDGER #539). Pinning both sides is symmetric and is what #509 did by hand
        # when it wanted an answer that held still. It does NOT eliminate the residue -- core/bufio
        # goes 1707 -> 1703 against the port's 1704, so a few entities genuinely differ -- but it
        # makes the number REPRODUCIBLE, which is the difference between a gate and a thermometer.
        subprocess.run([ref, "check", p, "-no-entry-point", "-thread-count:1"], env=env,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, cwd=REPO)
        # -no-threads is REQUIRED, not an optimisation. #344 established that the port's entity-set
        # variance is entirely threading-driven and that the single-threaded dump is byte-identical
        # across runs (5/5). Without it BOTH sides of this comparison drift run to run, and the
        # excess counts wander by several entities -- which is exactly how a real divergence hides
        # inside noise, and how noise gets written up as a divergence. Pinning the port makes it the
        # fixed side, so anything that moves between runs is the reference (#468 instantiation
        # multiplicity) rather than an open question about the port.
        subprocess.run([port, p, f"-dump-model:{pp}", "-no-threads"],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, cwd=REPO)
        if not os.path.exists(rp) or not os.path.exists(pp):
            print(f"{p:34s} SKIPPED (a dump is missing -- one side failed to run)")
            continue
        a, fa, schema_a = read_dump(rp)
        b, fb, schema_b = read_dump(pp)
        # SCHEMA ENFORCEMENT. This is the property a shared binary struct would have provided and
        # the reason v2 emits a schema line at all: if one implementation gains or loses a field,
        # the comparison must REFUSE rather than silently compare a smaller model and report
        # agreement. #405's false-green shape, applied to the schema itself.
        if schema_a != schema_b:
            print(f"{p:34s} SCHEMA-MISMATCH -- refusing to compare")
            print(f"     ref : {schema_a}")
            print(f"     port: {schema_b}")
            bad += 1
            continue
        ea, eb = a - b, b - a
        # ORDER MATTERS: layout first. split_attribution matches on (name,kind,size,align) across
        # DIFFERENT packages, so if it ran first it could pair up one half of a layout disagreement
        # with an unrelated entity elsewhere and report an attribution difference that is really a
        # size/align one. Layout is the same-package, same-name case and is strictly more specific.
        layout = split_layout(ea, eb)
        attrib = split_attribution(ea, eb)
        nl = sum(layout.values())
        na, nb = sum(ea.values()), sum(eb.values())
        # PRESENCE vs MULTIPLICITY. Measured on core/reflect (LEDGER #541): the reference emits a
        # duplicate `runtime.resize_dynamic_array` in ~5% of runs -- the key SET is identical, only
        # the COUNT moves. Both are excess under a multiset, so a run-to-run comparison of the
        # excess totals wanders while nothing about which entities exist has changed.
        #   presence   = keys one side has and the other lacks ENTIRELY.  STABLE, gateable.
        #   multiplicity = same key, different count.  #468, inherently noisy, report-only.
        # Splitting them is what lets the sweep gate on something that holds still.
        pa = {k for k in ea if k not in b}
        pb = {k for k in eb if k not in a}
        npres = len(pa) + len(pb)
        # STATE = per-field disagreement on entities both sides have in equal number. New in v2:
        # v1 compared four facts (name/kind/size/align) and could not express "same entity, wrong
        # constant value" or "same entity, different flags" at all. #546 lived exactly there.
        state, unpairable = split_state(fa, fb, ea, eb)
        ns = sum(state.values())
        # Ordered most-specific first. LAYOUT outranks STATE because a size/align disagreement is
        # the higher-severity finding and #514's signature; STATE outranks MULTIPLICITY because
        # multiplicity is the known, accepted #468 residue and must not mask a real field defect.
        if nl:                        status = "LAYOUT-DIFFER"
        elif ns:                      status = "STATE-DIFFER"
        elif na == nb == 0:           status = "MODEL-MATCH"
        else:                         status = "MULTIPLICITY"
        if nl or ns or na or nb: bad += 1
        if nl: layout_bad += 1
        state_bad_pkgs = 1 if ns else 0
        state_total += ns
        state_pkgs += state_bad_pkgs
        extra = f"  attribution={sum(attrib.values())}" if attrib else ""
        if SUMMARY:
            print(f"PKG {p} status={status} ref={sum(a.values())} port={sum(b.values())} "
                  f"layout={nl} state={ns} presence={npres} excess_ref={na} excess_port={nb} "
                  f"attribution={sum(attrib.values())} unpairable={sum(unpairable.values())}")
        else:
            nunp = sum(unpairable.values())
            unp = f"  unpairable={nunp}" if nunp else ""
            print(f"{p:34s} {status}  ref={sum(a.values()):5d} port={sum(b.values()):5d} "
                  f"layout={nl} state={ns} presence={npres} excess_ref={na} excess_port={nb}{extra}{unp}")
        for k, v in sorted(layout.items())[:8]:
            pkg, nm, kind, s_a, al_a, s_b, al_b = k
            print(f"     LAYOUT x{v} {pkg}.{nm} ({kind})  ref {s_a} {al_a}  port {s_b} {al_b}")
        # PER-FIELD TOTALS BEFORE THE CAPPED SAMPLE. The list below is sorted by ENTITY NAME and
        # truncated, so it is a SAMPLE, not a summary -- anything alphabetically later than the
        # first ten names is invisible in it. #556 nearly reported "the value column is entirely
        # closed, only flags remains" off exactly that truncation, while `objcsel` (7680 entities,
        # the largest divergence in the whole model) sat just past the cap. These totals are
        # uncapped and are what a reader should believe; the sample below is only a pointer to
        # detail. Use statefields.py for the full corpus-wide breakdown.
        if state:
            per_field = collections.Counter()
            for (pkg, nm, kind, fld, va, vb), v in state.items():
                per_field[fld] += v
            print("     STATE-BY-FIELD " +
                  "  ".join(f"{f}={n}" for f, n in per_field.most_common()))
        for k, v in sorted(state.items())[:10]:
            pkg, nm, kind, fld, va, vb = k
            print(f"     STATE x{v} {pkg}.{nm} ({kind}) {fld}: ref={va[:44]} port={vb[:44]}")
        for k, v in sorted(ea.items())[:6]: print(f"     REF-ONLY  x{v} {k}")
        for k, v in sorted(eb.items())[:6]: print(f"     PORT-ONLY x{v} {k}")
        for (nm, kind, s, al, rpkg, ppkg), v in sorted(attrib.items())[:6]:
            print(f"     ATTRIBUTION x{v} {nm} ({kind}) ref_pkg={rpkg} port_pkg={ppkg}")
    print(f"MODELDIFF-DONE packages={len(pkgs)} differing={bad} layout_differing={layout_bad} "
          f"state_entities={state_total} state_packages={state_pkgs}")
    return 1 if bad else 0

if __name__ == "__main__":
    sys.exit(main())
