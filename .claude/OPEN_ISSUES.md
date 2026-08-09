# Open issues log

Running log of defects found mid-task, written at discovery time so nothing depends on my memory or on a
task title being accurate. Each entry states what was VERIFIED vs what is ASSUMED, because the recurring
failure in this port is a confident claim resting on unread code (#603, #530, #511).

Convention: an entry stays here until it is either fixed-and-gated or closed with evidence. "Blocked by"
means I stopped deliberately rather than guessing.

---

## ENVIRONMENT (not a defect): the machine is saturated by an EXTERNAL workload

Recorded because it changes how every result on this box must be read, and because #301 was closed on
exactly this evidence once before.

At 2026-08-09 ~17:35 loadavg reached **120.94 on 32 cores**, climbing from 39 -> 65 -> 121 over six
minutes. The root suite launched for the #611+#612 batch had **6:23 elapsed and 3 seconds of CPU** -- it
is starved, not stuck, and not failing.

The load is NOT mine. `ps` shows dozens of concurrent
`odin run /tmp/tmp.JDdOstHGYZ/cNNN/ref -out:.../ref.bin` processes with incrementing counters
(c474...c485 and rising) -- a differential-testing loop in a temp directory this session never created,
plus a 3-day-old `odin` process. My own sweeps had already reported SWEEPS-COMPLETE before this began.

CONSEQUENCES, stated so nothing gets misread later:
- The root suite result for #611/#612 is **UNMEASURED**, not red. Per #301, a timeout or a slow run under
  external load is not evidence about the build. It must be re-run when load drops.
- `crosstarget.sh` (#614) was AUTHORED this tick but deliberately NOT RUN. Verifying a new gate on a
  saturated machine would produce a result I could not trust in either direction, and an unverified gate
  is not a gate (#483).
- No semantic change was landed while this was true.

WHAT TO DO NEXT TIME THIS APPEARS: check `uptime` AND the CPU-time-vs-elapsed ratio of the process you
care about before concluding anything. A process with minutes of wall time and seconds of CPU is being
starved; that is a scheduling fact, not a finding about the checker.

---

## #614 DONE: crosstarget.sh built, verified, and PROVEN TO GO RED

`.claude/tools/crosstarget.sh <PORT_BIN>` -- oracle-vs-port comparison for probes needing a non-host
`-target` and optionally a specific `-microarch`. Closes the hole that left #611's fix protected by
hand-produced evidence with nothing re-running it.

- Clean run: **6/6 MATCH, rc=0**.
- **POSITIVE CONTROL FIRES:** pinning `arch := Target_Arch_Kind.Amd64` in `microarch_default_features`
  (reproducing the #612 defect) turns **4 of 6 probes DIFFER and the gate exits rc=1**. Reverted; anchor
  count re-verified as 1; gate back to 6/6 rc=0; vet 0.
- **Not every member is sensitive to that particular fault, and the header says so.** mp611 and mp611d
  still MATCHED under the control: with the arch pinned, the enabled set still lacks `atomics`, so the
  gate fires identically and those two cannot see it. They pin the default-microarch direction instead.
  Claiming all six were load-bearing would have been the easy overstatement.

Shaped around the two traps this session paid for: the oracle side uses `odin build -build-mode:obj`
because `odin check` silently rejects `-microarch`, and the script **fails loudly on "Unknown flag"**
rather than scoring a non-run as a match. Manifest is explicit, exclusions are named and printed.

---

## #611 FIXED (parity pending): wasm atomics gate + a reimplemented operand block behind it

**Status: cheap gates green. parity / parity_vet / root suite for THIS change NOT yet run.**

Unblocked by #612. Landed:
- The atomics gate at both sites, per `check_builtin.cpp check_builtin_procedure:8467-8470` and
  `:8524-8527`, message byte-identical to C++ including the `-target-features:"atomics"` text.
- Both arch messages corrected to C++'s "is only allowed on wasm targets".
- Both WRONG citations replaced (7868-7871 / 7925-7928 pointed at the odin_calling_convention arm).
- All three FALSE stated reasons deleted.

**AND a bigger defect the missing gate was HIDING.** Once the gate stopped bailing, the operand block
became reachable and proved to be a reimplementation with three divergences from
`check_builtin.cpp:8472-8513` / `:8529-8558`:
1. WRONG TYPES -- pointer checked against `^i32` and `expected`/`waiters` against `i32`; C++ uses `^u32`
   and `u32`. `base/runtime/wasm_allocator.odin:302` passes a `^u32`, so the port REJECTED code in its
   own runtime that the reference accepts.
2. WRONG MESSAGES -- generic `check_assignment` text instead of C++'s bespoke per-operand messages.
3. WRONG ORDER -- C++ checks ALL args, THEN converts ALL, THEN validates; the port interleaved, which
   changes which diagnostic wins when more than one operand is bad.
All three rewritten to C++'s shape.

### Instrument correction, recorded because it produced a FALSE PASS

I first reported "oracle under -microarch:bleeding-edge: no atomics error". That was **not established**.
`odin check` does NOT accept `-microarch:` -- it printed "Unknown flag for 'odin check'" and emitted no
`Error` lines, and my grep for `Error` read that as clean. Same shape as #558/#520: the instrument, not
the subject. Redone with `odin build -build-mode:obj`, which does accept the flag.

### Evidence, after the correction

Probe `$S/mp611d` (result assigned, so the `require_results` diagnostic cannot confound):
- default microarch (`generic`, no atomics): oracle and port both emit the identical error at 4:9.
- `-microarch:bleeding-edge` (atomics present): both clean.

STATED LIMIT: the bleeding-edge oracle side is `odin build`, because `odin check` refuses the flag, so
that half is not a same-command byte comparison. The default-microarch half IS same-diagnostic across
both oracle commands, which is what supports treating them as comparable.

`triage_st` gained `-microarch:` for this (it had only `-target:`), the same blind spot `-target:` had
before #572.

**RESOLVED, the messages are now VERIFIED.** The earlier "could not make them fire" was the SAME
`-microarch` false pass described above -- the probes ran under `odin check`, which rejected the flag, so
nothing was ever checked. Re-run under `odin build -build-mode:obj -microarch:bleeding-edge`, all five
bespoke messages fire and are byte-identical to the oracle, columns included:
    p.odin(4:46)  'wasm_memory_atomic_wait32' expected ^u32 for the memory pointer, got 'p' of type ^f32
    p.odin(4:99)  'wasm_memory_atomic_wait32' expected u32 for the 'expected' value, got 'e' of type f32
    p.odin(5:102) 'wasm_memory_atomic_wait32' expected i64 for the timeout, got 't' of type f32
    p.odin(6:101) 'wasm_memory_atomic_notify32' expected u32 for the 'waiters' value, got 'w' of type f32
    p.odin(7:98)  'wasm_memory_atomic_notify32' expected ^u32 for the memory pointer, got 'q' of type ^f32
One bad operand per call, because C++ returns after the first failure. Probes at `$S/mp611e`, `$S/mp611f`.

GATE-COVERAGE GAP, stated not hidden: these probes need `-target:js_wasm32 -microarch:bleeding-edge`, and
corpus.sh is host-target only, so they CANNOT join the corpus as it stands. They are reproducible by hand
but nothing re-runs them. A cross-target probe gate is the missing instrument (same shape as the gap
#572 closed for `-target:`).

---

## #611 ORIGINAL FINDING (kept for the record)

**Status: BLOCKED on #612. Do not add the gate before #612 lands -- it would trade an under-rejection for
an over-rejection.**

Found by grepping the checker for TODO/UNMEASURED markers carrying NO task number, i.e. debt written at
the site but never captured anywhere a reader would look.

Sites: `check_builtin.odin:6740` (`wasm_memory_atomic_wait32`), `:6805` (`wasm_memory_atomic_notify32`).

Four defects, all VERIFIED by reading both sides:

1. **UNDER-REJECTION x2.** C++ gates both builtins:
   `if (!check_target_feature_is_enabled(str_lit("atomics"), nullptr))` -> error
   `"'%.*s' requires target feature 'atomics' to be enabled, enable it with -target-features:\"atomics\" or choose a different -microarch"`
   (`check_builtin.cpp:8467-8470` and `:8524-8527`). The port has neither the gate nor the message.

2. **FALSE STATED REASON x3.** The port claims the gate "requires frontend integration to populate the
   features set" (`check_builtin.odin:6741`, `:6806`) and, at `build_settings.odin:1583-1586`, that
   "check_target_feature_is_enabled is not implemented here". Both are stale: the port HAS the counterpart
   at `build_settings.odin:1423` (`target_feature_is_enabled`), #543 landed the machinery, and
   `check_builtin.odin:7344` already calls it. Standing policy: a documented divergence whose stated
   REASON is false counts as wrong.

3. **CITATION DEFECT x2** -- instances 7 and 8 of RIGHT-FILE-WRONG-FUNCTION. Cited
   `check_builtin.cpp:7868-7871` and `:7925-7928`; 7868-7871 is the `odin_calling_convention` arm
   (`operand->mode = Addressing_Constant; type = t_odin_calling_convention`), unrelated. Real sites are
   8460-8470 and 8517-8527.

4. **MESSAGE DRIFT x2.** C++: `"is only allowed on wasm targets"`. Port: `"is only available on
   WebAssembly targets"`.

**Why it is blocked.** The gate's answer comes from the enabled feature set, and the port computes that
set wrongly for wasm -- see #612. Adding the gate on top of a set that is empty for wasm would reject
these builtins under `-microarch:bleeding-edge`, where C++ ACCEPTS them. An over-rejection is a worse
defect than the under-rejection it replaces, and it would be invisible to parity (which runs neither flag).

---

## #612 FIXED, gated: microarch feature data is now GENERATED, not hand-copied

**Status: parity 323/323 count=1 text=0 attrib=2 (known-noise baseline). parity_vet + root suite still
outstanding at the time of writing -- see the bottom of this entry for the live state.**

### What was wrong

`core/odin/checker/build_settings.odin` hand-maintained data that C++ generates, and it had drifted in two
independent ways.

1. `microarch_default_features` was a flat `switch microarch` with four arms (`x86-64`, `x86-64-v2`,
   `generic-rv64`, `generic`, default `""`). C++ (`llvm_backend.cpp get_default_features:66-116`, table in
   `build_settings_microarch.cpp`) computes an ARCH OFFSET
   (`for i < bc->metrics.arch: off += target_microarch_counts[i]`) and only then matches the microarch NAME
   within that arch's slice. The same name means different features per arch: both amd64 and wasm32 define
   `generic`. Since the port's `get_default_microarchitecture` returns `generic` for five of the seven
   arches, wasm32, wasm64p32, arm32, arm64 and i386 were all told they had the x86-64 feature set --
   `sse`, `sse2`, `x87` and the rest. Not a near-miss.
   Whole arches were also simply absent: wasm32/wasm64p32 have four microarchs each in C++
   (`bleeding-edge`, `generic`, `lime1`, `mvp`), and `bleeding-edge` is the only wasm row carrying
   `atomics` -- exactly what #611 needs.

2. `target_features_list`, the validation set behind `-target-features` and
   `@(enable_target_feature)`/`@(require_target_feature)`, was stale against LLVM 22 on ALL SEVEN real
   arches, in BOTH directions at once: 34 arm64 and 55 riscv64 names C++ accepts and the port rejected
   (over-rejection), plus `tme`, `zcz`, `nacl-trap` and `amx-transpose` the port accepted and C++ rejects
   (under-rejection).

Reachable, not theoretical: `build_context.microarch` is a real port field read by
`get_final_microarchitecture`. Parity is host-target only, so no gate here could have seen it.

### The fix

`.claude/tools/gen_microarch.py` generates `core/odin/checker/build_settings_microarch.odin` (197 KB, 517
entries) from `src/build_settings_microarch.cpp`. Hand-copying a 200 KB generated table IS the defect, so
the fix is to stop doing it rather than to correct this instance.

Derived from the C++ FILE, not from a fresh LLVM query: parity compares the port against the ORACLE BINARY,
so the table the oracle compiled in is the thing to agree with, and an independent query could drift from
the checked-in one. `gen_microarch.py --check` is the staleness gate.

Reading C++ properly also caught two behaviours the flat switch got wrong beyond the arch bug:
`generic-rv64` on riscv64 is OVERRIDDEN by C++ (`:89-106`, its own note: "so we don't default to a potato
feature set") and is NOT the table row the port was returning; and `-microarch:native` asks LLVM for the
host string, which the checker cannot answer, now a stated divergence rather than a wrong table hit.

Three FALSE STATED REASONS deleted: `build_settings.odin:1583-1586` claimed
`check_target_feature_is_enabled` "is not implemented here because it requires target_features_set ... not
available in standalone checker" (the counterpart has existed at `:1423` since #543), and the SCOPE note
claimed the four hand-written arms covered "every microarch the checker can select without an explicit
-microarch: flag" (they did not).

### Evidence

ORACLE-VERIFIED, cross-target. Probe `$S/mp612` on `-target:js_wasm32`, default microarch `generic`: the
oracle passes `has_target_feature("bulk-memory")` and fails `("sse2")`. The port now emits the identical
single error at 6:1.

POSITIVE CONTROL FIRES. Pinning `arch := Target_Arch_Kind.Amd64` moves the error 6:1 -> 5:1: the port then
claims `sse2` IS available and `bulk-memory` is NOT, on a wasm target -- the old defect exactly. So the
probe is sensitive and the arch read is load-bearing. Reverted; anchor count re-verified as 1.

### Carried forward, stated not hidden

- `MICROARCH_LLVM_MAJOR :: 22` is stamped into the generated file. The C++ source holds FOUR tables behind
  `#if LLVM_VERSION_MAJOR >= 22 / == 21 / == 20 / #else` and they genuinely differ (arm64: 98/91/82/69
  microarchs). The port has no LLVM dependency and cannot choose. Rebuild the oracle against another LLVM
  and the generator MUST be re-run; the stamp plus `--check` is what keeps that from being silent.
- The port still has no `target_features_string` input, so C++'s SECOND writer of `target_features_set`
  (`main.cpp:4262-4280`, the `-target-features:` flag, normalised to `+f` with the opposite sign removed)
  has no counterpart. That belongs to #591. It matters for #611, whose C++ error message NAMES that flag.
- UNMEASURED: how many checker-visible decisions consume this today beyond `has_target_feature` (#543) and
  the target-feature attributes.

### Gate state

Cheap gates green: vet 0, corpus 206 FULL-MATCH, entrypoint 10/10 + state 5/5, splitcheck 0/0,
citefn --check drifted=0, gen_microarch --check OK. Parity 323/323 count=1 text=0 attrib=2 -- baseline.
parity_vet and the root suite were still running when this was written; NOT signed off until they report.

---


## #613 IMPLEMENTED (parity pending): call-site target-feature checks + the ORDERING that made them impossible

**Status: all cheap gates green. parity / parity_vet / root suite RUNNING or NOT YET RUN.**

Landed against C++ `check_expr.cpp check_call_expr:8955-9041`:
- `check_target_feature_is_superset_of` written (`build_settings.odin`), C++ `build_settings.cpp:2232-2243`.
  It had no port counterpart at all, which is why the `#force_inline` rules could not be expressed.
- The require branch now asks the GLOBAL enabled set (not the caller's), calls
  `check_target_feature_is_valid_for_target_arch` (a helper the port already had and never used here),
  and uses C++'s two message texts. The invented Suggestion line is gone.
- The whole `enable_target_feature` branch added: invalid-for-target, plus both `#force_inline` rules
  (file-scope ban, and the superset requirement with its "Suggested Example:" continuation).

**THE ORDERING WAS THE REAL BLOCKER, and it was worse than the task described.** C++ runs
inlining -> `#must_tail` -> target features, because the target-feature block READS `is_call_inlined`.
The port had the inlining validation sitting AFTER the target-feature block, so the flag did not exist
when it was needed -- that is why the `#force_inline` half was absent rather than merely wrong. Fixed by
moving the inlining resolution ahead of `#must_tail`, matching C++'s order exactly.

That move also surfaced three more defects in the block being moved:
- Its `.None` arm was **missing entirely**: a call with NO directive is still an inlined call when the
  CALLEE is declared `#force_inline`. The port only ever inspected `call.inlining`.
- Wrong message: "Cannot force inline a procedure marked as '#force_no_inline'" vs C++'s
  "'#force_inline' cannot be applied to a procedure that has been marked as '#force_no_inline'".
- A dead `else if` branch carrying a note musing about a warning C++ does not emit -- port-only
  speculation, deleted.

**TWO MORE WRONG CITATIONS (taxonomy instances 9 and 10), both RIGHT-FILE-WRONG-FUNCTION:** the inlining
block cited `check_polymorphic_record_type:8327-8374` and the target-feature block
`check_polymorphic_record_type:8421-8453`; both live in `check_call_expr`. The `#must_tail` citation was
also RIGHT-FUNCTION-WRONG-LINES (8934-8947 -> 8991-9006). All three corrected.

### Evidence: all five diagnostics FIRE and are byte-identical

Probes p613a-p613e, added to **corpus.sh** -- corpus 206 -> **211 FULL-MATCH**.

CORRECTION TO THE PLAN: these were expected to need `crosstarget.sh` like #611's. They do not -- every
one fires on the HOST target with no flags, so they belong in corpus.sh. Assuming otherwise would have
put them where nothing exercised them.

**p613d nearly proved nothing.** With an ordinary proc, the file-scope probe hit "Procedures requiring a
'context' cannot be called at the global scope" FIRST on BOTH sides -- it MATCHED while saying nothing
about the rule under test. Only `proc "contextless"` reaches the rule. Recorded in corpus.sh beside the
probe, because a matching probe that tests nothing is the failure mode this whole gate set exists to
avoid.

---

## #613 ORIGINAL FINDING (kept for the record)

**Status: READ against C++, NOT yet implemented. Deferred deliberately -- parity and parity_vet were
mid-run on the #611+#612 tree when this was found, and landing a semantic change would have invalidated
sweeps already in flight.**

Port `check_expr.odin:10928-10967` vs C++ `check_expr.cpp:9008-9041`. C++ has TWO branches; the port has a
reduction of one. Six defects:

1. **WRONG DATA SOURCE** -- the original TODO, now confirmed. The port reads the CALLER's
   `enable_target_feature` through `ctx.curr_proc_decl`; C++ reads the GLOBAL enabled set via
   `check_target_feature_is_enabled`. #612 made the port's global set correct per architecture, so the
   counterpart `target_feature_is_enabled(f, enabled_target_features())` is now available and right.
2. **MISSING** `check_target_feature_is_valid_for_target_arch` on the require path -- and the port already
   HAS that helper at `build_settings.odin:1573`. It simply never calls it here.
3. **WRONG MESSAGE.** Port: "Procedure requires target feature '%s' which is not enabled".
   C++: "Calling this procedure requires target feature '%s' to be enabled".
4. **INVENTED SUGGESTION** the reference does not emit on this path.
5. **THE ENTIRE `enable_target_feature` BRANCH IS ABSENT** -- three more diagnostics, including both
   `#force_inline` rules (file-scope ban, and the superset requirement whose reason C++ states outright:
   LLVM cannot inline a call with a superset of features).
6. A site comment claims the port "just warn[s] ... to match C++ behavior". C++ calls `error()` on both
   paths, so "warn" mischaracterises it.

`check_target_feature_is_superset_of` has no port counterpart at all.

This is the third consecutive defect in this family found by reading rather than by a gate, and the second
where the port's own explanatory comment was the thing that hid it.
