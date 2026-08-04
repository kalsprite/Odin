#!/usr/bin/env python3
"""specvalid.py -- validate the spec suite's POSITIVE expectations against the REFERENCE compiler.

The spec tests were written against a spec document and, until now, were never executed. A
`check_should_pass(t, `SRC`, "ID")` asserts the checker accepts SRC. That assertion is only
meaningful if the REFERENCE compiler accepts SRC too. Where the oracle rejects it, the TEST is
wrong and the port is right to reject -- a bad expectation, not a port defect.

This partitions failures into "fix the test" vs "fix the checker" without hand-triage.

  usage: specvalid.py <tmpdir> [package-dir ...]
  output: one line per should-pass case whose ORACLE error count is non-zero.
"""
import re, subprocess, sys, pathlib, os

tmp = pathlib.Path(sys.argv[1]); tmp.mkdir(parents=True, exist_ok=True)
pkgs = sys.argv[2:] or sorted(str(p) for p in pathlib.Path("core/odin/checker/tests").glob("spec_*") if p.is_dir())

# check_should_pass(t, `...`, "ID")  -- backtick literal, optional trailing msg
# The id is an Odin string literal and MAY CONTAIN ESCAPED QUOTES -- e.g.
# "DIR-ATTR-007: @(private=\"file\") attribute". An `[^"]*` id pattern stops at the backslash-quote
# and desynchronises every LATER match in the file, which reported DIR-ATTR-008 as a bad
# expectation when its source is fine. Match escapes explicitly. LEDGER #345.
PAT = re.compile(r'check_should_pass\(\s*t\s*,\s*`(?P<src>.*?)`\s*(?:,\s*"(?P<id>(?:[^"\\]|\\.)*)")?\s*\)', re.S)

bad = ok = skipped = 0
for pkg in pkgs:
    for f in sorted(pathlib.Path(pkg).glob("*.odin")):
        text = s = f.read_text()
        for i, m in enumerate(PAT.finditer(text)):
            src = m.group('src'); tid = m.group('id') or f"{f.name}#{i}"
            # SECOND BLIND SPOT (LEDGER #346). Some tests build the source by CONCATENATION so they
            # can embed a backtick raw string:   `...  r := ` + "`raw`" + `  ...`
            # The backtick match cannot span that, so the capture is garbage and gets reported as a
            # bad expectation -- RT-TYPE-013 was exactly this, and its real source is clean. An
            # instrument that silently mis-reads is worse than one that admits it cannot read:
            # skip and SAY SO, so the count is honest rather than quietly wrong.
            if '+ "' in m.group(0) or '" +' in m.group(0):
                print(f"SKIPPED-CONCATENATED  {tid}  (source built by concatenation, not checked)")
                skipped += 1
                continue
            d = tmp / f"c{abs(hash(tid)) % 10**9}"; d.mkdir(exist_ok=True)
            (d / "a.odin").write_text(src)
            r = subprocess.run(["./odin", "check", str(d), "-no-entry-point"],
                               capture_output=True, text=True, timeout=120)
            errs = [l for l in (r.stdout + r.stderr).splitlines() if " Error: " in l]
            if errs:
                bad += 1
                print(f"BAD-EXPECTATION  {tid}")
                print(f"    oracle rejects it too: {errs[0].split(' Error: ',1)[1].strip()}")
            else:
                ok += 1
print(f"SPECVALID-DONE should_pass_cases={ok+bad} oracle_accepts={ok} BAD_EXPECTATIONS={bad} skipped_concatenated={skipped}")
