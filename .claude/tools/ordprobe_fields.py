#!/usr/bin/env python3
"""
ordprobe2 -- does the order of FIELDS INSIDE a struct / MEMBERS INSIDE an enum
change the verdict? (Jeroen's report.)

Only order-INVARIANT properties are probed: whether the program is ACCEPTED, and which
diagnostics appear. Cases are built so that field/member order cannot legitimately change
the answer -- no size_of/offset_of assertions, no explicit enum values, no #packed. If a
permutation flips acceptance, that is a defect.

Same confound control as ordprobe: REPS runs per permutation; a permutation whose own
verdict varies is UNSTABLE and excluded from the order judgement (LEDGER #407/#409).
"""
import itertools, re, subprocess, sys, os, tempfile, shutil
REPO="/home/kalsprite/dev/odin"; ORACLE=[os.path.join(REPO,"odin"),"check","@DIR@","-no-entry-point"]; REPS=3
POS=re.compile(r'^.*?\.odin\(\d+:\d+\)\s*')
def norm(t):
    o=[]
    for l in t.splitlines():
        l=l.strip()
        if not l or l.startswith("###"): continue
        if ".odin(" in l: o.append(POS.sub("",l))
    return tuple(sorted(o))
def run(d):
    c=[x.replace("@DIR@",d) for x in ORACLE]
    try:
        p=subprocess.run(c,capture_output=True,text=True,timeout=120,errors="replace",cwd=REPO)
        return p.returncode,(p.stdout or "")+(p.stderr or "")
    except subprocess.TimeoutExpired: return -9,"<<TIMEOUT>>"
def verdict(src,tmp):
    d=os.path.join(tmp,"p"); shutil.rmtree(d,ignore_errors=True); os.makedirs(d)
    open(os.path.join(d,"a.odin"),"w").write(src)
    seen=set()
    for _ in range(REPS):
        rc,t=run(d)
        if t=="<<TIMEOUT>>": return ("TIMEOUT",()),True
        seen.add((0 if rc==0 else 1,norm(t)))
    return (sorted(seen)[0],False) if len(seen)>1 else (seen.pop(),True)
# (name, template with {} for the permuted body, parts, joiner)
CASES=[
 ("_control_err","package p\nS :: struct {{ {} }}\nBad :: nope_xyzzy\n",
   ["a: int","b: f32","c: bool"],", "),
 ("struct_fields","package p\nS :: struct {{ {} }}\nuse :: proc() {{ s: S; _=s.a; _=s.b; _=s.c }}\n",
   ["a: int","b: ^S","c: [4]u8"],", "),
 ("struct_using","package p\nInner :: struct {{ q: int }}\nS :: struct {{ {} }}\n"
                 "use :: proc() {{ s: S; _=s.q; _=s.z }}\n",
   ["using i: Inner","z: int","w: f64"],", "),
 ("enum_members","package p\nE :: enum {{ {} }}\nB :: bit_set[E]\n"
                 "use :: proc(e: E) {{ switch e {{ case .A: case .B: case .C: }} }}\n",
   ["A","B","C"],", "),
 ("union_variants","package p\nA1::struct{{v:int}}\nB1::struct{{v:f32}}\nC1::struct{{v:bool}}\n"
                   "U :: union {{ {} }}\nuse :: proc(u: U) {{ switch _ in u {{ case A1: case B1: case C1: }} }}\n",
   ["A1","B1","C1"],", "),
 ("bitfield","package p\nBF :: bit_field u32 {{ {} }}\n",
   ["a: u8 | 3","b: u8 | 5","c: u16 | 9"],", "),
]
TMP=tempfile.mkdtemp(prefix="ord2_")
anyo=anyn=False
try:
    for name,tpl,parts,j in CASES:
        perms=list(itertools.permutations(range(len(parts))))[:24]
        res={}; uns=[]
        for pm in perms:
            v,st=verdict(tpl.format(j.join(parts[i] for i in pm)),TMP)
            if not st: uns.append(pm); continue
            res.setdefault(v,[]).append(pm)
        tag="ORDER-DEPENDENT" if len(res)>1 else "stable"
        print(f"{name}: {len(perms)} perms, {len(res)} verdict(s), {len(uns)} unstable -> {tag}")
        if name.startswith("_control"):
            vs=list(res.keys())
            ok=len(vs)==1 and vs[0][0]==1 and any("Undeclared name" in d for d in vs[0][1])
            print(f"    control: rc={vs[0][0] if vs else '?'} diags={list(vs[0][1])[:2] if vs else []}")
            if not ok: sys.exit("ABORT: control did not fail -- results vacuous")
            print("    control OK")
        if len(res)>1:
            anyo=True
            for v,pms in sorted(res.items(),key=lambda kv:-len(kv[1])):
                print(f"    rc={v[0]} x{len(pms)} e.g. {pms[0]}  {list(v[1])[:2] or '<accepted>'}")
        if uns: anyn=True; print(f"    !! NONDETERMINISTIC perms: {uns[:4]}")
finally: shutil.rmtree(TMP,ignore_errors=True)
print(f"\nSUMMARY: order-dependence={'YES' if anyo else 'no'} nondeterminism={'YES' if anyn else 'no'}")
