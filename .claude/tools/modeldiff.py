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
import atexit, collections, os, re, shutil, subprocess, sys, tempfile

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
# `tidepn` (|decl.type_info_deps|, schema v3) is a GATE as of #701. It is NOT in STATE_IGNORED.
#
# It is the ONLY differential coverage of the ~51 add_type_info_type call sites and of the min-dep
# consumer wired in #638. None of those emits a diagnostic, so no other gate in this tree can see
# them: every defect it found was invisible to 323 green parity packages.
#
# PROMOTION HISTORY, kept because the first attempt was wrong and the reason matters:
#   #692  PROMOTED on a floor of 0 measured over three runs -- but on only THREE PACKAGES
#         (core/unicode, core/strings, core/mem), none of which imports core:reflect. The first
#         full-corpus run came back 786 entities / 117 packages. DEMOTED in #695.
#   #694  `#soa` types were never registered at all                        786/117 -> 435/53
#   #697  the variadic `..any` path substituted a bare add_type_info_type for C++'s
#         check_assignment, so the `any` TARGET type was never registered
#         by any call site in the port                                     435/53  -> 23/17
#   #700  check_comparison's two typeid arms register BOTH operand types in C++ and only ONE in
#         the port, so every `typeid` compared against a type lost the
#         `typeid` entry                                                   23/17   -> 1/1
#   #701  the type-assertion `any` branch registered BEFORE assigning o.type, so it picked up the
#         `any` source; C++ assigns first and both of its calls land on
#         the asserted type                                                1/1     -> 0/0
#
# PROMOTED here on the evidence #692 did not have:
#   - the FULL 323-package sweep reads 0, not a sample (#115)
#   - measured TWICE, independently, both 0
#   - a POSITIVE CONTROL: the pre-#701 binary still reports the
#     `my_custom_flag_checker  tidepn: ref=1 port=2` row, so the gate is proven to detect the
#     defect it just closed rather than being trivially green (#538/#623)
#
# If this ever goes red, the row names the entity and the direction. Escalate a COUNT to a SET
# before theorising (#111): a temporary per-entity dep-NAME emit on both dumps identified #699's
# two defects in one run. C++'s TypeSet element is `TypeInfoPair`, so the iteration variable is
# `tt.type`, not `tt`.
#
# `type` STAYS IGNORED and is a different case entirely: the two implementations render types through
# independent printers, so it is cosmetically divergent BY CONSTRUCTION rather than by an unmeasured
# floor. No amount of measurement promotes it (#108).
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
            kv_pre = {}
            for tok in fs[6:]:
                if "=" in tok:
                    _k, _v = tok.split("=", 1)
                    kv_pre[_k] = _v
            # #623. Key on the source POSITION, not the context-derived PKG. `pkg` comes from the
            # CHECKER CONTEXT in both implementations (C++ src/checker.cpp:2259 `e->pkg = c->pkg`),
            # so two entities that were declared in different files can land on the same key and
            # register as a one-sided PRESENCE that is really a collision. That is what #560
            # recorded as unresolvable; it is resolvable, just not in the checker. Position is
            # unique per declaration, so the collision cannot form.
            _pos = kv_pre.get("pos", "")
            key = (_pos, fs[2], norm_kind(fs[3]), fs[4], fs[5])
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
            # #560 was the worked example, under the OLD pkg-based key: (_weierstrass, fe,
            # Variable, 8, 8) carried TWO entities on each side -- `for fe in arg1` locals in
            # identical bodies across four _fiat field packages. Entity `pkg` is context-derived
            # in BOTH implementations (C++ checker.cpp:2251 `e->pkg = c->pkg`, the only Entity pkg
            # assignment in src/), so for a body reachable from two packages the attribution
            # follows check order and neither side is canonically right.
            #
            # #623 REMOVED THE CAUSE rather than tolerating it: the key is now the source POSITION,
            # which is unique per declaration, so distinct entities can no longer share a key.
            # Measured after the swap: unpairable 29 -> 0 across all 323 packages, spread 0 over
            # 3 runs. This branch is therefore currently UNREACHED. It is kept because it is a
            # correctness guard, not a gate -- if a future dump format made positions non-unique
            # again, the alternative is silent arbitrary pairing. Do not read its 0 as a result.
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
    # #649: THIS LINE WEDGED THE MACHINE. modelsweep.sh invokes this script ONCE PER PACKAGE
    # (modelsweep.sh:139-142, a `while read -r pkg` loop over 323 packages), and the mkdtemp here
    # used to have no cleanup at all -- so every full model sweep leaked 323 directories, each
    # holding an ~8 MB p.txt/r.txt pair. /tmp here is a 94 GB TMPFS, i.e. RAM, so those bytes are
    # taken from the machine: by 2026-08-09 it was 18,317 dirs and 58.7 GB, and every shell on the
    # box started returning rc=1, `true` included.
    # atexit rather than a `finally`: main() has several `sys.exit`/early-return paths, and a
    # cleanup that only covers the fall-through path is the same bug with a smaller blast radius.
    tmp = tempfile.mkdtemp()
    atexit.register(shutil.rmtree, tmp, ignore_errors=True)
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
        # #623 HYBRID. Presence is computed over entities with a REAL source position only.
        # Synthesised entities dump pos=<instantiation> -- they have no position, so pos-keying
        # buckets ALL of them together and their #468 multiplicity differences surface as PRESENCE,
        # which is precisely the noisy class presence exists to exclude. Measured: pos-keying alone
        # left presence_entities=5, ALL FIVE `<instantiation>`. They are still counted as excess
        # (na/nb), so they remain visible as MULTIPLICITY -- nothing is dropped, only reclassified.
        _synth = lambda k: k[0].startswith("<")
        pa = {k for k in ea if k not in b and not _synth(k)}
        pb = {k for k in eb if k not in a and not _synth(k)}
        npres = len(pa) + len(pb)
        # STATE = per-field disagreement on entities both sides have in equal number. New in v2:
        # v1 compared four facts (name/kind/size/align) and could not express "same entity, wrong
        # constant value" or "same entity, different flags" at all. #546 lived exactly there.
        state, unpairable = split_state(fa, fb, ea, eb)
        ns = sum(state.values())
        # Ordered most-specific first. LAYOUT outranks STATE because a size/align disagreement is
        # the higher-severity finding and #514's signature; STATE outranks MULTIPLICITY because
        # multiplicity is the known, accepted #468 residue and must not mask a real field defect.
        # #622. PRESENCE HAD NO ARM HERE AT ALL. A package whose only divergence was presence fell
        # through to `else` and was labelled MULTIPLICITY -- the bucket this file's own comment at
        # the npres computation calls "inherently noisy, report-only" -- while presence is the one
        # it calls "STABLE, gateable". The stable signal was being filed under the noisy label, so
        # `grep PRESENCE` over a sweep found nothing and the 5 affected packages were unreachable.
        # Ranked AFTER state deliberately: this promotes presence above the noise floor without
        # reordering any severity that was already established (LAYOUT > STATE unchanged).
        if nl:                        status = "LAYOUT-DIFFER"
        elif ns:                      status = "STATE-DIFFER"
        elif npres:                   status = "PRESENCE"
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
        # #622. Name the presence divergences. Without this the count is unactionable: it says 10
        # entities exist on one side only and gives no way to learn which.
        # NOT gated on SUMMARY: modelsweep invokes this with --summary, and the LAYOUT detail lines
        # below print unconditionally. Gating presence on `not SUMMARY` meant the names never reached
        # the sweep -- the exact gap #622 exists to close. Caught by verifying the output instead of
        # assuming the patch worked.
        if npres:
            for k in sorted(pa)[:12]:
                print(f"     PRESENCE ref-only  {k}")
            for k in sorted(pb)[:12]:
                print(f"     PRESENCE port-only {k}")
            if len(pa) > 12 or len(pb) > 12:
                print(f"     PRESENCE ... truncated (ref-only={len(pa)} port-only={len(pb)})")
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
            # #807: this line used to print `ref={va[:44]} port={vb[:44]}` -- it truncated the TAIL,
            # which is the one place the values are guaranteed to be EQUAL. core/testing's two
            # entities printed as
            #     ref=customlinkagestrong|customlinkname|procbodyc port=customlinkagestrong|...|procbodyc
            # i.e. TWO IDENTICAL STRINGS for a pair this comparator had just classified as DIFFERENT,
            # because len("customlinkagestrong|customlinkname|procbodyc") == 44 EXACTLY and the real
            # divergence sits at char 45+. That reads as a comparator false positive and is not one.
            # Elide the COMMON PREFIX instead, so the differing region is always on screen. A value
            # that is a strict PREFIX of the other is a real and distinguishable case (one side has an
            # extra sorted flag), so it gets an explicit marker rather than printing as empty.
            i = 0
            while i < len(va) and i < len(vb) and va[i] == vb[i]:
                i += 1
            head = f"...[{i} common]" if i > 8 else ""
            ta, tb = va[i:], vb[i:]
            sa = head + (ta[:60] if ta else "<ENDS HERE>")
            sb = head + (tb[:60] if tb else "<ENDS HERE>")
            print(f"     STATE x{v} {pkg}.{nm} ({kind}) {fld}: ref={sa} port={sb}")
        for k, v in sorted(ea.items())[:6]: print(f"     REF-ONLY  x{v} {k}")
        for k, v in sorted(eb.items())[:6]: print(f"     PORT-ONLY x{v} {k}")
        for (nm, kind, s, al, rpkg, ppkg), v in sorted(attrib.items())[:6]:
            print(f"     ATTRIBUTION x{v} {nm} ({kind}) ref_pkg={rpkg} port_pkg={ppkg}")
    print(f"MODELDIFF-DONE packages={len(pkgs)} differing={bad} layout_differing={layout_bad} "
          f"state_entities={state_total} state_packages={state_pkgs}")
    return 1 if bad else 0

if __name__ == "__main__":
    sys.exit(main())
