#!/usr/bin/env python3
"""
ordprobe -- does DECLARATION ORDER change the verdict?

Odin is order-independent at file scope, so permuting top-level declarations must
not change accept/reject or the diagnostics. Any permutation that does is a defect.

CONFOUND CONTROL (LEDGER #407/#409): the C++ checker is nondeterministic run-to-run
(`5 << 3j` splits ~50/50; attribution flips under load). So a difference between two
permutations is NOT evidence of order-dependence on its own. Every permutation is run
REPS times; a permutation whose own verdict varies is marked UNSTABLE and excluded from
the order-dependence judgement, and reported separately as nondeterminism.

Verdict = (rc, sorted multiset of normalised diagnostic lines). Position prefixes are
stripped, because permuting declarations legitimately moves line numbers.
"""
import itertools, re, subprocess, sys, os, tempfile, shutil

REPO = "/home/kalsprite/dev/odin"
ORACLE = [os.path.join(REPO, "odin"), "check", "@DIR@", "-no-entry-point"]
REPS = 3

POS = re.compile(r'^.*?\.odin\(\d+:\d+\)\s*')

def norm(txt):
    out = []
    for ln in txt.splitlines():
        ln = ln.strip()
        if not ln or ln.startswith("###"):
            continue
        if ".odin(" in ln:
            ln = POS.sub("", ln)
            out.append(ln)
    return tuple(sorted(out))

def run(cmd, d):
    cmd = [c.replace("@DIR@", d) for c in cmd]
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=120,
                           errors="replace", cwd=REPO)
        return p.returncode, (p.stdout or "") + (p.stderr or "")
    except subprocess.TimeoutExpired:
        return -9, "<<TIMEOUT>>"

def verdict(cmd, decls, tmp):
    """Run one permutation REPS times. Returns (verdict, stable?)."""
    d = os.path.join(tmp, "p")
    shutil.rmtree(d, ignore_errors=True)
    os.makedirs(d)
    with open(os.path.join(d, "a.odin"), "w") as f:
        f.write("package p\n\n" + "\n\n".join(decls) + "\n")
    seen = set()
    for _ in range(REPS):
        rc, txt = run(cmd, d)
        if txt == "<<TIMEOUT>>":
            return ("TIMEOUT", ()), True
        seen.add((0 if rc == 0 else 1, norm(txt)))
    if len(seen) > 1:
        return sorted(seen)[0], False
    return seen.pop(), True


def probe(name, decls, cmd, label):
    n = len(decls)
    perms = list(itertools.permutations(range(n)))
    if len(perms) > 24:
        perms = perms[:24]
    results, unstable = {}, []
    for pm in perms:
        v, stable = verdict(cmd, [decls[i] for i in pm], TMP)
        if not stable:
            unstable.append(pm)
            continue
        results.setdefault(v, []).append(pm)
    tag = "ORDER-DEPENDENT" if len(results) > 1 else "stable"
    print(f"[{label}] {name}: {len(perms)} perms, {len(results)} distinct verdict(s), "
          f"{len(unstable)} unstable -> {tag}")
    if name.startswith("_control"):
        # The control MUST fail to compile. If it "passes", nothing was compiled and every
        # other line in this run is meaningless -- abort rather than report a false green.
        vs = list(results.keys())
        ok = len(vs) == 1 and vs[0][0] == 1 and any("Undeclared name" in d for d in vs[0][1])
        print(f"    control verdict: rc={vs[0][0] if vs else '?'} "
              f"diags={list(vs[0][1])[:2] if vs else []}")
        if not ok:
            sys.exit("ABORT: positive control did not fail as expected -- "
                     "the harness is not compiling anything; all results above are vacuous.")
        print("    control OK -- the harness really compiles and really sees diagnostics")
    if len(results) > 1:
        for v, pms in sorted(results.items(), key=lambda kv: -len(kv[1])):
            rc, diags = v
            print(f"    rc={rc} x{len(pms)} e.g. order {pms[0]}")
            for dl in list(diags)[:3]:
                print(f"        {dl[:110]}")
            if not diags:
                print("        <accepted, no diagnostics>")
    if unstable:
        print(f"    !! NONDETERMINISTIC permutations (verdict varied across {REPS} runs): {unstable[:4]}")
    return len(results) > 1, bool(unstable)


CASES = {
    # POSITIVE CONTROL. Must report rc=1 with an "Undeclared name" diagnostic in EVERY
    # permutation. If this comes back accepted-with-no-diagnostics the harness is compiling
    # nothing and every other "stable" line below is vacuous (cf. LEDGER #405, #408).
    "_control_err": [
        "CtlA :: struct { z: int }",
        "CtlB :: no_such_name_xyzzy",
    ],
    # mutually-referencing struct types
    "struct_xref": [
        "Foo :: struct { b: ^Bar, n: int }",
        "Bar :: struct { f: ^Foo, m: int }",
        "Baz :: struct { using f: Foo }",
    ],
    # enum + bit_set over it + array sized by a member
    "enum_bitset": [
        "E :: enum { A, B, C }",
        "S :: bit_set[E]",
        "Arr :: [len(E)]int",
        "V : S : {.A, .C}",
    ],
    # constants deriving from one another
    "const_chain": [
        "A :: B + 1",
        "B :: C * 2",
        "C :: 3",
        "D :: [A]int",
    ],
    # struct whose size feeds a constant, plus #assert
    "size_assert": [
        "P :: struct { x: i32, y: i32 }",
        "SZ :: size_of(P)",
        "#assert(SZ == 8)",
        "Q :: struct { p: P, tail: [SZ]u8 }",
    ],
    # polymorphic proc + where clause + instantiation
    "poly_where": [
        "Vec :: struct($N: int, $T: typeid) { data: [N]T }",
        "sum :: proc(v: Vec($N, $T)) -> T where N > 0 { return v.data[0] }",
        "use :: proc() { v: Vec(3, int); _ = sum(v) }",
    ],
    # union + variant referencing a later type
    "union_order": [
        "U :: union { A1, B1 }",
        "A1 :: struct { v: int }",
        "B1 :: struct { u: ^U }",
    ],

    # --- UNTYPED-CONSTANT cases. This is where the known gremlins live (rule_engine #1/#3/#4,
    # LEDGER #408), so order-sensitivity is most likely to show here. Any permutation that
    # flips a verdict is order-dependence; a permutation that flips ACROSS ITS OWN REPS is
    # nondeterminism and is reported separately.
    "untyped_mixed": [
        "UA :: 1",
        "UB :: UA + 1.5",
        "UC :: UB * 2",
        "UD : f64 : UC",
    ],
    "untyped_shift": [
        "SA :: 5",
        "SB :: 3",
        "SC :: SA << SB",
        "SD : i32 : SC",
    ],
    "untyped_cplx": [
        "KA :: 2i",
        "KB :: KA + 1",
        "KC : complex64 : KB",
    ],
    "untyped_rune_str": [
        "RA :: 'x'",
        "RB :: RA + 1",
        "RC : rune : RB",
        "RD :: \"s\"",
    ],
    "enum_backing": [
        "BE :: enum u8 { X = BV, Y }",
        "BV :: 3",
        "BS :: bit_set[BE; u8]",
    ],
}

if __name__ == "__main__":
    TMP = tempfile.mkdtemp(prefix="ordprobe_")
    only = sys.argv[1] if len(sys.argv) > 1 else None
    anyorder = anynd = False
    try:
        for nm, decls in CASES.items():
            if only and only != nm:
                continue
            o, nd = probe(nm, decls, ORACLE, "oracle")
            anyorder |= o
            anynd |= nd
    finally:
        shutil.rmtree(TMP, ignore_errors=True)
    print(f"\nSUMMARY: order-dependence={'YES' if anyorder else 'no'} "
          f"nondeterminism={'YES' if anynd else 'no'}")
