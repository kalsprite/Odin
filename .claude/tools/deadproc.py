import re,glob
files=glob.glob('core/odin/checker/*.odin')
raw={f:open(f).read() for f in files}
def strip(s):
    s=re.sub(r'/\*.*?\*/','',s,flags=re.S)
    s=re.sub(r'//[^\n]*','',s)
    s=re.sub(r'"(?:[^"\\\n]|\\.)*"','""',s)
    return s
code={f:strip(s) for f,s in raw.items()}
defs={}
for f,s in code.items():
    for m in re.finditer(r'^([a-z_][a-z0-9_]*)\s*::\s*proc',s,re.M):
        defs.setdefault(m.group(1),[]).append((f,raw[f][:0].count('\n'),m.start()))
allcode="\n".join(code.values())
dead=[]
for name,locs in defs.items():
    n=len(re.findall(r'\b'+re.escape(name)+r'\b',allcode))
    if n<=len(locs):
        dead.append((name,locs))
print(f"procs: {len(defs)}   never referenced in code (comments/strings ignored): {len(dead)}")
for name,locs in sorted(dead):
    for f,_,off in locs:
        line=code[f][:off].count('\n')+1
        print(f"  {f}:{line}  {name}")
