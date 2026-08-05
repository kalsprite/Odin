# Checker port LEDGER (reconstructed 2026-08-02)

## Why this file is short

The original `LEDGER.md` (~10k lines) lived in the session scratchpad under `/tmp`, which was
cleared mid-session on 2026-08-02. It is not recoverable. This file restarts the ledger inside
the repo, under `.claude/`, so a `/tmp` wipe cannot take it again.

The numbered task list (#1-#249) survived in the harness task store and remains the index of
what was found and fixed. This file records what the task titles do not carry: measurement
state, standing method, and the facts that were only in the ledger prose.

## Measurement stack: LOST, partially rebuilt

Destroyed with `/tmp`: the 598-probe corpus, `sweep_det.sh`, `corpus.sh`, `cmpfull.py`,
`verdicts.sh`, `misroute.py`, `doccmp.sh`, `flake.sh`, `citefn.py`, `citecheck.py`,
`gotscan.py`, the `doc_st/` harness, `parseprobe/`, `tokprobe/`, `mutprobe/`, and every built
binary.

Rebuilt so far:
- `triage_st/` -- reconstructed from `check_package_from_path`'s documented API
  (`package_resolver.odin:872`). Prints `### <pkg> files=N errors=N warnings=N limit=B
  raw_diags=N` then `print_package_diagnostics`.
- `sweep_det.sh` + `pkglist.txt` -- 225 packages under `core/` and `base/`, excluding
  `tests/`, `example[s]/`, `base/builtin`, `base/intrinsics`, and `_`-prefixed dirs.

**The old baselines no longer apply.** Bare sweep 7 / vet 54 / corpus 592 FULL-MATCH were
measured against a *169-package* list and a 598-probe corpus that no longer exist. The current
225-package list is a different population; its baseline is errors=1349, crashes=3. Do not
compare the two.

Rebuilt 2026-08-02, in the repo so a `/tmp` wipe cannot take them again:
- `.claude/tools/cmpfull.py` -- oracle-vs-port comparator. Runs BOTH compilers per probe dir,
  normalises to `basename(line:col) Kind: message`, drops the oracle's source-echo and caret
  lines, keeps diagnostic continuation lines. Verdicts FULL-MATCH / FULL-DIFFER /
  ORACLE-CRASHED / PORT-CRASHED. Validated with a fake port (`/bin/true`) that must produce
  FULL-DIFFER on a probe with diagnostics.
  **Caveat:** a `lines=0` FULL-MATCH is weak evidence -- an empty-vs-empty comparison matches
  even a fake port. Only nonzero-line matches carry weight.
- `.claude/probes/` -- corpus restarted at 7 probes (expand, expand_arity, layout, layout_bad,
  declcycle, declcycle3, cyclediag). The original 598 are gone and are not reconstructible.

Still missing: the bulk of the probe corpus, the doc/state comparator (`doccmp.sh`), the
determinism screen (`flake.sh`), and the citation checkers.

## Standing method

- Build: `./odin build $S/triage_st -out:$S/st_<tag> -o:minimal` from repo root, `set -o pipefail`.
- Required check: `odin check . -vet -strict-style -no-entry-point` in `core/odin/checker/`.
- NEVER `git stash` / `git checkout --` / `git restore` / `git reset --hard`. To get a baseline
  binary: `cp` the modified files to a scratch backup, `git show HEAD:<path> > <path>`, build,
  then restore from the backup.
- Do not commit `src/` (C++) changes -- leave them for review.

### Verification rules earned the hard way

1. **A clean instrument proves nothing until a control shows it can go dirty.** Three separate
   instruments have reported success while measuring nothing. Always run a positive (or
   negative) control before believing a zero.
2. **A count of zero deserves the same suspicion as a count that is too low.** A tool invoked on
   a missing directory printed one error line that greps rendered as `MATCH=0 DIFFER=0`.
3. **A comment asserting a behaviour is evidence about when it was written, not about now.**
   Six stale artefacts found, one of them load-bearing (see below).
4. **A stalled sweep is the known deadlock, not a regression -- but verify, don't assume.**
   #25/#41/#141 can hang a single package indefinitely. Concurrency raises the odds; it is NOT
   required -- one occurrence hung `core/encoding/xml` with the sweep running completely alone,
   and all three binaries then did that package 10/10 clean standalone. So "run sweeps alone"
   reduces the rate, it does not eliminate it, and an earlier version of this rule implying
   concurrency was the cause was wrong. sweep_det.sh now applies a 120s per-package timeout and
   records `### TIMEOUT`, so one hang no longer costs the whole run. Whenever a stall appears
   after a change that touched threading, re-test that package on old and new binaries before
   concluding anything.
5. Call order != line order when deciding whether C++ code runs before or after a phase.

### Recurring defect classes

- **Invented code**: behaviour with no C++ counterpart (bails, early exits, fallbacks, limits).
  Often "better" than C++ and therefore wrong; one was defended in a comment.
- **Compensating pair**: two deviations that cancel. Auditing either half alone "verifies" it
  against the other.
- **Duplicated state**: the port stores one conceptual field twice, and writes update one half.
  See below -- this was a whole class, not a bug.

## 2026-08-02: entity type storage collapsed to one field

C++ `Entity` has exactly one `Type *type` (`src/entity.cpp:170`); no member of the
discriminated union at `entity.cpp:196` declares a `type`. The port had duplicated it onto four
variants (`Entity_Constant`, `Entity_Variable`, `Entity_Type_Name`, `Entity_Procedure`), so
`e.type` and `entity_type(e)` could disagree, and any write touching one half was invisible to
the other.

#192 and #162 were each a single instance of that split, fixed one site at a time. Instrumenting
the disagreement directly found a third: `core/sys/darwin/Foundation`, 200 hits, all
`Type_Name`, all `base=invalid type variant=<real type>`. The declaration-cycle recovery at
`entity_helpers.odin:1406` writes `t_invalid` to the base field only, so `entity_type` kept
returning the stale pre-cycle type that C++ discards. Positive control (skipping the variant
write in `set_entity_type`) produced 769/379 hits, so the zeros elsewhere were real.

Fix: `entity_type` reads `e.type` -- the single store, as C++ has. The variant `type` fields are
now write-only duplicates. Three direct reads of the copy were rerouted (`types.odin:3711`,
`check_type.odin:1083` and `:1102`).

Deliberately NOT changed: `entity_type`'s kind gate. C++ has no gate; widening it changes
behaviour for the kinds that carry no type (`Import_Name`, `Package_Name`, `Builtin`, `Label`,
`Proc_Group`) and is a separate change with its own measurement.

The comment at `types.odin:1652` asserted the exact opposite -- that struct fields carry *only*
a variant type and `Entity.type` is nil. True when written, false after #192. Had I trusted it I
would not have made this change. Corrected in place.

### Verification

Established:
- `odin check . -vet -strict-style -no-entry-point` clean.
- `#assert` probe on struct / `#raw_union` / `#packed` / `offset_of` matches the oracle, with a
  negative control that errors on wrong values.
- Full-tree sweep, baseline vs fixed, restricted to the 197 packages that neither crashed nor
  hit the error cap in either run: **error totals identical (466 = 466), zero error-count
  differences, zero reproducible diagnostic-text differences.** The change is output-preserving
  on everything measurable.

**NOT established: that the change alters ANY observable diagnostic.** Uncapped
declaration-cycle probes (`declcycle`, `declcycle3`, `cyclediag`) are byte-identical between the
baseline and fixed binaries. The fix is justified structurally (C++ has one type field) and by
the 200 instrumented real disagreements in Foundation, but no probe built so far discriminates
it. It removes a latent inconsistency; treat it as such, not as a behavioural fix.

Also not established: that Foundation's declaration-cycle diagnostics now match C++. That package
hits the error cap (`limit=true`), and under the cap it is nondeterministic in BOTH binaries
(three distinct output hashes in three runs each) because which diagnostics survive truncation
depends on thread scheduling. Its text cannot be diffed. Confirming the cycle behaviour needs an
uncapped reduction plus an oracle comparison -- neither exists yet.

### Two false alarms during this work, both recorded so they are not re-derived

1. The first sweep stalled 12 minutes on `core/container/priority_queue` and I called it a
   regression. It is not: both binaries run that package clean 20/20 with zero timeouts. The
   stall was the known intermittent threaded-checker deadlock (#25/#41/#141), triggered by
   running two sweeps plus other commands concurrently. **Run sweeps alone.**
2. The raw sweep diff showed a seemingly new error class
   (`'e' of type '^u8' has no field 'flags'`, `core/rexcode/isa/arm32`). Pre-existing --
   identical on both binaries. It only looked new because that package is cap-truncated, so the
   surviving subset varies. Two further "differences" (`core/rexcode/isa/riscv`,
   `core/crypto/mlkem`) did not reproduce either; they were stderr from crashing sibling
   processes interleaving into the output file during the concurrent run.

## 2026-08-02 (later): the duplicated-storage class is CLOSED

Three accessors read an entity's type. All now read the single store `Entity.type`:
- `entity_type` (entity.odin)
- `get_entity_type` (check_expr.odin:290) -- was returning the VARIANT copy for
  Constant/Variable/Type_Name and `entity.type` for Procedure, with a comment noting they
  disagreed. This is what made check_cycle's `curr.type = t_invalid` invisible, so after a
  declaration cycle the port served the stale pre-cycle type and emitted assignment errors the
  oracle never produces. Fixing it made `.claude/probes/cyclediag` FULL-MATCH. (#254)
- 8 further reads via bound variables (`var_field.type`, `type_const.type`,
  `proc_variant.type`) in types.odin (incl. the type_align_of/type_size_of layout path),
  check_type.odin and check_expr.odin.

A grep for every form of variant-copy read now returns nothing. The variant `type` fields are
write-only duplicates; deleting them is a separate mechanical change.

Verified: vet clean; corpus 7/7 FULL-MATCH; partitioned sweep vs a CLEAN baseline over 193
stable packages -- error totals identical (518 = 518), zero error-count differences, and every
apparent text difference proved identical or flaky when re-run directly.

### Correction worth keeping

I reported mid-investigation that the change had introduced nondeterminism on
`core/crypto/aead` (baseline 1 hash / 8 runs, new build 2 / 8). That was wrong. Over 20 runs
each: baseline 3/20 crashes, t457 4/20, t458 3/20 -- indistinguishable. The package has a
PRE-EXISTING intermittent double-free/segfault; my 8-run baseline sample simply caught none.

**Method rule: crash- and flake-rate comparisons need >=20 runs per binary.** Eight is not
enough to distinguish a ~15% intermittent failure from a clean one, and a small clean sample
reads as "stable" when it is not. This is the third false alarm of this shape (after the
priority_queue stall and the cap-truncated `^u8` class).

**Method consequence:** a sweep diff is only meaningful over packages that are neither
`limit=true` nor crashed. Always partition before comparing; the raw totals (1349 vs 1337) are
dominated by cap and crash noise and mean nothing.

## 2026-08-02: corpus grown to 22 probes; comparator blind spot fixed

Added 15 probes across enums, bit_sets, switch exhaustiveness, unions, maps, slices, call
arity, variadics, casts, constant overflow, deref, polymorphic procs, return mismatch,
using-subtyping and compound literals. Result: 21/22 FULL-MATCH, 1 FULL-DIFFER (#255).

**Comparator blind spot, found and fixed the same tick.** cmpfull.py's normaliser dropped any
line without a `file(line:col)` prefix. The port emits at least one diagnostic with NO position
at all, so `polyproc` initially read as a near-match with the port's line simply invisible --
the instrument was hiding the very defect the probe existed to find. The normaliser now keeps
positionless diagnostics as `<nopos> Error: ...`.

This is the fourth instrument-measures-nothing incident. The pattern is always the same shape:
a filter written for one purpose (drop the oracle's source-echo lines) silently discards a
category that matters. **When writing a normaliser, enumerate what it DISCARDS and justify each
class, rather than only checking that what it keeps looks right.**

## 2026-08-02: positionless-diagnostic sweep -- bounded to ONE site

Question raised by #255: the port emitted a diagnostic with no `file(line:col)` at all. Is that
a class?

Instrumented `error_va` (error.odin), the single funnel every diagnostic passes through, to
report any emit whose `pos.file == "" || pos.line == 0`. Positive control: the known polyproc
case fires. Result:

- 22 probes: 1 hit, the known one.
- 225 packages: **0 hits.**

So it is a single site, not a class -- the path only arises on a polymorphic call with a
missing argument, which healthy code does not contain. #255 stays a single-site fix; no sweep of
`error()` call sites is warranted.

The instrumentation was removed afterwards (error.odin restored from backup); an instrumented
binary is not a valid baseline and must never be the thing a measurement is taken with.

## 2026-08-02: #255 fixed -- polymorphic instantiation now gated on missing arguments

C++ check_expr.cpp:
  :6835-6844  missing-parameter check -> err = CallArgumentError_ParameterMissing
  :6931       if (pt->is_polymorphic && !pt->is_poly_specialized && err == CallArgumentError_None)
  :6933           find_or_generate_polymorphic_procedure_from_parameters(...)

The port ran the instantiation FIRST (check_expr.odin:10063) and gated it on nothing; its own
missing-parameter check sits later, at :10460. `poly_operands` is sized to the parameter count
and only supplied slots are written (poly_visited records which), so an omitted argument reached
determine_type_from_polymorphic as a zero-valued Operand -- mode .Invalid, type nil, expr nil --
and printed `Cannot determine polymorphic type from parameter: '<no type>' to '$T'` with NO
source position, instead of C++'s "Parameter 'x' of type '$T' is missing in procedure call".

Fix: before instantiating, skip if any required parameter is unvisited (ignoring the variadic
slot and any parameter with a default -- the same exclusions C++'s err computation makes).
Falling through reaches the existing :10460 check, which already had both of C++'s messages and
was simply unreachable.

Verified: corpus 22/22 FULL-MATCH; partitioned sweep vs clean baseline over 198 stable packages
-- 518 = 518 errors, zero count differences, every apparent text difference identical or flaky
on re-run; polymorphic-heavy packages (linalg, queue, small_array, slice, strings) identical to
baseline; vet clean.

### The ordering claim, retracted twice and finally settled

Filed first as an ordering problem. Then "corrected" to a missing nil-expr fixup
(check_type.cpp:2140-2145) with a note that ordering was the wrong reading. That correction was
WRONG: C++ genuinely gates instantiation on err == None, so ordering was right all along. The
nil-expr fixup is a real but SECONDARY gap -- porting it alone would only have repositioned a
message C++ never prints.

What went wrong: I reversed myself on the strength of a well-written C++ comment that explained
a nearby mechanism, without checking whether the gate existed. A comment explaining mechanism A
is not evidence about mechanism B. Same failure shape as trusting a stale comment -- see the
types.odin:1652 incident.

**Method rule reinforced: a hypothesis about control flow is settled by instrumenting the
control flow, not by reading adjacent code.** Every step of this one that stuck came from
marking call sites and counting; every step that had to be retracted came from reading.

## 2026-08-02: corpus 22 -> 37 probes; 6 findings, one of them a deterministic CRASH

Added 15 probes: matrix, #soa, bit_field, distinct, #optional_ok, or_else, or_return, defer,
labels, where-clauses, enum backing types, #assert, contextless context, ternary, proc groups.
Result: 31 FULL-MATCH, 5 FULL-DIFFER, 1 PORT-CRASHED.

**#256 -- deterministic crash on ANY field access on an #soa aggregate.** `x: #soa[]S; _ = x.a`
is valid Odin (oracle rc=0, zero diagnostics); the port panics with "sync.Wait_Group negative
counter", 3/3 runs, on st_base too, so pre-existing. Bisected: the trigger is a selector on any
#soa form (slice / array / dynamic), valid field or not; plain slices are fine; #soa without a
selector is fine.

**#257 -- five message/position divergences** (matrix x3 invented messages, bit_field granularity
+ an extra diagnostic, enum type-vs-value field message, or_return wording, defer column).

### The lesson: sweep-clean is not feature-clean

The 225-package sweep has been clean through every change today, and it never once touched this
crash. Packages that mention #soa either do not take a field of one, or already crash/cap for
unrelated reasons. A whole language feature was completely broken and the primary instrument said
nothing.

**Corpus breadth finds what sweep depth cannot.** The sweep measures regression against a
baseline over code that happens to exist; the corpus measures conformance over code chosen to
exercise a feature. Both are needed, and a clean sweep must never be reported as evidence that a
feature works. Every fix verified "by sweep" today should be read as "did not regress what the
stdlib exercises", nothing stronger.

## 2026-08-02: #256 fixed -- the #soa crash was a deliberately skipped C++ guard

`x: #soa[]S; _ = x.a` -- valid Odin, oracle rc=0 with zero diagnostics -- aborted the port with
"sync.Wait_Group negative counter". Deterministic, all #soa forms, valid field or not,
pre-existing on st_base.

Cause: complete_soa_type omitted C++'s early return (check_type.cpp:2966-2968,
`if (t->Struct.fields_wait_signal.futex.load()) return true;`). The port had a comment there
calling it "this optimization" and skipping it because "Wait_Group doesn't expose load
directly". Both claims were false: it is the IDEMPOTENCE guard, and :404 in the same file
already reads `sync.atomic_load(&...fields_wait_signal.counter)`. Without it the whole body
re-ran on every call including the unconditional wait_group_done, so the second completion drove
the counter 1 -> 0 -> -1. Two callers legitimately reach the same type: inline completion at
:411 and the selector path at check_expr.odin:4876.

Verified: crash gone; soa_bad FULL-MATCH; corpus 32 MATCH / 5 DIFFER; partitioned sweep over 194
stable packages 459 = 459 errors, zero count differences, all 8 apparent text differences
identical on direct re-run; vet clean.

### The comment was the camouflage

This is the third time today a wrong comment protected a defect from scrutiny (types.odin:1652
asserting struct fields carry only a variant type; the check_type.cpp:2140 fixup comment that
made me retract a correct diagnosis). Here the comment did two things at once: it dropped a
required C++ line AND gave a plausible-sounding reason, so anyone auditing would read the note,
accept it, and move on.

**Rule: a comment explaining why C++ code was NOT ported is a defect report until proven
otherwise.** Grep for that shape deliberately -- "we skip", "not needed", "optimization",
"simplified" -- and re-derive the claim from the C++ source rather than the note.

## 2026-08-02: #257 closed (3 fixed, 2 split); corpus 39 probes

Fixed and verified: defer diagnostic positions (ALL THREE sites -- C++ reports at the `defer`
token, the port used the deferred statement); or_return message restored to C++'s form
(check_expr.cpp:10138, whose trailing operand is the construct name so one site serves
or_return/or_else); enum type-field message (the port HAD C++'s .Type branch but emitted the
VALUE form inside it, printing "'F' of type 'F' has no field 'A'" -- naming F twice -- instead
of "Type 'F' has no field 'A'", and lacked the polymorphic variant entirely).

Verified: corpus 34 MATCH / 3 DIFFER at the time; partitioned sweep vs clean baseline over 193
stable packages 494 = 494 errors, zero count differences; the nine apparent text differences all
resolved to identical over 20 runs per binary; vet clean on checker AND parser.

Split out, because each probe had exposed one symptom of a much wider divergence:
- #258 check_binary_matrix: ELEVEN invented messages where C++ has exactly ONE (nine
  `goto matrix_error` -> a single error at check_expr.cpp:4305). Probe touched three.
- #259 bit_field: an invented per-field capacity check whose comment cites "C++ lines 1147-1155"
  -- a range that contains no such check -- plus skip-vs-clamp recovery, six reworded messages,
  and TWO UNDER-REJECTIONS found only by writing probes for the unprobed cases: a u128 field
  type and a 65-bit width are both accepted silently.

### Two rules earned here

1. **A probe finds a symptom, not a defect's extent.** Both splits looked like "three messages"
   until the enclosing function was compared against C++ wholesale. After any message
   divergence, diff the WHOLE function's diagnostic surface -- count error() calls on each side
   -- before scoping the fix.
2. **A C++ citation in a port comment is a claim, not evidence.** #259's check cites a range
   that does not contain it. Spot-check citations against the cited lines; citefn.py finds
   drifted line NUMBERS but cannot tell that a cited range says something else entirely.

## 2026-08-02: #258 done -- eleven invented matrix diagnostics collapsed to C++'s one

C++ check_binary_matrix (src/check_expr.cpp) has exactly ONE error(, at :4305, reached by NINE
`goto matrix_error`. The port had ELEVEN hand-written messages: dimension mismatch,
inner-dimension mismatch, element-type mismatch (x2), non-numeric scalar (x3), matrix/matrix
division, "requires both operands to be matrices", and an operator catch-all. None exist in C++.

All eleven now route through a single `matrix_error` helper mirroring C++'s label. That also
restores behaviour the port had dropped: C++ sets x->type = t_invalid and x->mode =
Addressing_Invalid on every failure path, where the port's bare `return false` left the
operand's type intact.

Separately, the element-type diagnostic's POSITION: C++ reports it at `column.expr`
(check_type.cpp:3149) -- the column-count expression, not the element. For `matrix[2,2]string`
the oracle points at the second `2`. That looks like a C++ slip and the tempting move is to
"correct" it, but its sibling "Matrix types are limited to a maximum of %d elements" uses
column.expr too and the port ALREADY matched C++ there (:3547). This site was the outlier, not
C++. Same disposition as #185 and #201.

Verified: matrix_bad FULL-MATCH; corpus 36 MATCH / 3 DIFFER (all three remaining are #259);
partitioned sweep over 196 stable packages 518 = 518 errors, zero count differences, crash
counts equal, all seven apparent text differences identical in DIAGNOSTIC counts across five
runs per binary; vet clean; linalg/math/simd identical to baseline.

### What found these

Every one of #255-#259 was found by the probe corpus. The 225-package sweep has been clean
through all of them and found none. The corpus was rebuilt from ZERO this morning after the
/tmp wipe and reached 39 probes; that rebuild has been worth more than any single fix.
Sweep answers "did I break what exists"; corpus answers "does the feature conform". Only the
second finds latent divergence.

## 2026-08-02: #259 done -- the entire bit_field diagnostic surface rebuilt; CORPUS NOW 39/39

Grepping all twelve C++ bit_field message strings against the port returned 0 hits. The whole
surface was invented -- the same shape as #258's matrix collapse, but complete.

Rewrote the field loop against src/check_type.cpp:1060-1190. Restoring the twelve messages was
the easy half; the four BEHAVIOURAL divergences mattered more, and none of them would have been
found by porting message texts alone:

1. THREE UNDER-REJECTIONS closed. A `u128` field type, a 65-bit width, and a MISSING bit size
   were all accepted silently. C++ rejects each. (The missing-bit-size case: C++ errors and
   skips; the port defaulted to `8 * type_size_of(field_type)` and accepted the field.)
2. CLAMP, NOT SKIP. C++ clamps out-of-range widths (<=0 -> 1, >64 -> 64, >type -> type) and keeps
   building the entity, so the clamped width still counts toward the total. The port `continue`d,
   leaving the bit_field short a field and changing every downstream cascade.
3. The `|` typo check is an ERROR in C++ ("Wrap the expression in parentheses, e.g. (%s)"), not
   the port's invented WARNING. A program C++ rejects was compiling.
4. BACKING TYPE, ONE ERROR NOT TWO. C++ assigns `backing_type ? backing_type : t_u8` FIRST, then
   reports and returns void -- the type still exists, so nothing cascades. The port returned
   false from both arms, making the caller add "'bit_field string {...}' is not a type", a
   second diagnostic C++ never emits.

Also deleted the invented per-field capacity check (whose comment cited a C++ range containing
no such check) in favour of C++'s single post-loop total against the bit_field node.

Verified: all three bit_field probes FULL-MATCH; **corpus 39/39 FULL-MATCH, zero divergences**;
partitioned sweep over 198 stable packages 518 = 518 errors, zero count differences, all five
apparent text differences identical in diagnostic counts across five runs per binary; vet clean;
mem/sys-linux/os identical to baseline.

### The lesson that generalises

Two of the four behavioural divergences (the clamp, the t_u8 default) are invisible in a message
inventory. Had I ported only the twelve strings, the probes would STILL have differed and the
cause would have looked mysterious. **When a diagnostic surface turns out to be invented, the
messages are the symptom; read the C++ control flow around them and port that too.**

## 2026-08-02: comparator widened to continuation lines; append under-rejection narrowed, NOT solved

cmpfull.py was dropping every line without a `file(line:col)` prefix -- so "Given argument
types:", the bullet list, "Did you mean one of the following overloads?", the overload rows and
Note continuations were all invisible. Whole diagnostic BLOCKS went uncompared. Now kept as
`<cont> ...`; only the oracle's source echo + caret ruler are dropped.

Two artefact classes had to be handled first: caret rulers are TRUNCATED with a trailing "..."
on long spans, and echo/caret pairs also appear under continuation notes, so the drop rule must
fire on any caret line and take the line above it. Control (/bin/true as the port) still yields
FULL-DIFFER.

Corpus: 54 probes, 47 FULL-MATCH / 6 FULL-DIFFER.

**Honest qualification of earlier work:** `orreturn_bad` was reported FULL-MATCH when #257
landed; with continuations visible it DIFFERS (missing note "Procedure return value type: int").
Every FULL-MATCH claimed before this change means "the positioned diagnostic lines match", not
"the whole block matches". #255/#256/#258/#259 were re-run and still hold, but that is the
qualification their original verification deserved.

### The append under-rejection: three hypotheses eliminated, mechanism still open

`append(&d)` (array only, no values) is accepted by the port, rejected by the oracle.
ELIMINATED BY EXPERIMENT, not reasoning:
  - empty variadics are legal generally: `myv(&d)` with `args: ..int` compiles;
  - `#no_broadcast` does not change it: `myn(&d)` compiles;
  - it is not proc-group-plus-variadic: a 2-member group with a variadic member accepts `g(&d)`
    in BOTH compilers, polymorphic and non-polymorphic alike;
  - it is not append's signature features: a group reproducing `#no_broadcast` + `loc :=
    #caller_location` + `#optional_allocator_error` exactly is accepted by both;
  - `runtime.append_elems(&d)` called DIRECTLY is accepted by the oracle.

What is left is the GROUP COMPOSITION: the real `append` has 8 members, and C++'s message reads
"No procedures **or ambiguous** call". Leading hypothesis: two members are simultaneously viable
for `append(&d)` and tie, so C++ reports ambiguity, while the port finds only one viable.

SOLVED by that experiment. Minimal reproduction, no `append` involved:

    AE  :: proc(a: ^$T/[dynamic]$E, #no_broadcast arg: E, ...)
    AES :: proc(a: ^$T/[dynamic]$E, #no_broadcast args: ..E, ...)
    AFE :: proc "contextless" (a: ^$T/[dynamic; $N]$E, #no_broadcast args: ..E) -> int
    G   :: proc{AE, AES, AFE}
    d: [dynamic]int
    G(&d)        // oracle REJECTS (ambiguous), port ACCEPTS
    G(&d, 1)     // both accept
    G(&d, 1, 2)  // both accept

Two conditions are BOTH required, established by elimination:
  1. the call supplies ZERO variadic arguments, AND
  2. the group contains a second POLYMORPHIC member whose specialization should not match
     -- either `^$T/[dynamic; $N]$E` (fixed capacity) or `^$T/#soa[dynamic]$E`. Adding either
     one alone flips the oracle to rejecting; a non-matching NON-polymorphic member
     (`arg: $A/string`) does not.

MECHANISM: with an empty variadic, E is unconstrained by arguments. C++ evaluates group
candidates with no_polymorphic_errors / hide_polymorphic_errors set (check_expr.cpp:7558-7563,
which makes modify_type false), and under that leniency `^[dynamic]int` is accepted against BOTH
`^$T/[dynamic; $N]$E` and `^$T/#soa[dynamic]$E` -- so two candidates tie and C++ reports
ambiguity. The port's specialization check stays strict, rules those out, resolves to the single
remaining candidate, and accepts.

So the port is STRICTER than C++ here, and the "obviously correct" behaviour is the divergent
one. Matching C++ means reproducing its LENIENCY during group candidate evaluation -- which is
uncomfortable but is what parity requires. Confirm against check_type_specialization_to's
behaviour when modify_type is false before changing anything.

Do NOT special-case `append`. Whatever the rule is, it applies to every group.

## 2026-08-02: #260 item (4) root-caused -- missing overload list on a ZERO-ARGUMENT group call

Probe .claude/probes/procgroup_bad. The port emits the "Did you mean one of the following
overloads?" block for `g(1.5)` but NOT for `g()`.

ROOT CAUSE, exact:
  port  check_proc_group.odin:1171-1173 -- print_procedure_group_overloads early-returns
        `if len(procs) == 0 { return }`
  C++   check_expr.cpp:7688-7690 -- at the SAME point, REFILLS instead:
        `if (procs.count == 0) { procs = proc_group_entities_cloned(c, *operand); }`

With zero arguments `procs` is empty by the time the failure is reported, so the port returns
silently; C++ reconstructs the candidate list from the group entity and prints it. The port's
`proc_group_entities_cloned` EXISTS (referenced at check_proc_group.odin:233), so this is a
missing call, not missing machinery.

FIX: at the two failure sites that print the block (check_proc_group.odin ~1745 and ~1793),
refill `procs` from the operand before calling, mirroring C++. Do NOT simply delete the
early-return in the helper -- C++'s refill needs the operand, which the helper does not receive;
the refill belongs at the call site exactly as in C++.

This is the same shape as #256's skipped guard: a defensive early-return that looks harmless and
silently suppresses output C++ produces. Worth a sweep for other `if len(x) == 0 { return }`
guards in diagnostic-printing helpers.

## 2026-08-02: #260 item (4) FIXED -- proc-group overload list on a zero-argument call

C++ check_expr.cpp:7688-7690 REFILLS the candidate list when the filtering above has emptied it:
    if (procs.count == 0) { procs = proc_group_entities_cloned(c, *operand); }
The port had no refill, and print_procedure_group_overloads early-returns on an empty list, so
the entire "Did you mean one of the following overloads?" block vanished for `g()` while
appearing normally for `g(1.5)`. Fixed at the call site (check_proc_group.odin ~1744), mirroring
C++; procgroup_bad is now FULL-MATCH.

Verified: corpus 55 probes, 49 FULL-MATCH / 6 FULL-DIFFER, stable over two consecutive runs;
partitioned sweep over 195 stable packages 467 = 467 errors, zero count differences, all eight
apparent text differences identical in DIAGNOSTIC counts over five runs per binary; vet clean.

### Two corrections from this fix

1. I claimed TWO call sites needing the refill. There is ONE. I had inferred the second from a
   paired "No given arguments" emitter without checking -- that one belongs to the AMBIGUOUS
   path ("Ambiguous procedure group call"), a different diagnostic that does not print the list.
2. I read the candidate filter twice and concluded `procs` could not be empty for a zero-argument
   call, because the only restore sits inside the named-argument branch which `g()` never
   enters. One eprintf showed len_procs=0 for `g()` and 2 for `g(1.5)`. **Reading produced a
   confident wrong answer; measuring produced the right one, again.**

### A flaky probe is worse than no probe

`whereclause` appeared to REGRESS with this change. It did not: it was flaky on both binaries
with identical hash sets. The probe was malformed -- it used `intrinsics.type_is_integer`
without importing base:intrinsics, so the message depended on resolution order. Fixed to import
it; now single-hash over 8 runs. **Before believing a probe's verdict, confirm the probe itself
is deterministic** -- otherwise it manufactures phantom regressions and will eventually hide a
real one.

## #162 -- closed, premise was wrong

Titled "nil-typed parser-recovery operand leaks into call argument checking". The residual it
described (`takes3(**v)` reporting `'<no type>'`) is gone, but not for the stated reason: there
was no parser-recovery operand. The cause was `field.type` read raw in
`expand_values_tuple_type`, where struct fields need `entity_type(field)`. `<no type>` itself is
faithful -- C++ prints it at `types.cpp:5368` for a nil type; the defect was ever reaching it.
`probe_expand` is FULL-MATCH, and a control (`takes3(**arr)` with an 8-element array) confirms
the path is live and both sides agree on the expanded arity.

## Open, carried forward

See the task list for the full set. Highest-value items not yet closed:

- Rebuild the probe corpus -- without it there is no message-level parity instrument at all.
- #158: the 3 FULL-DIFFER survivors (identities lost with the corpus).
- #149: C++ names the offending type/expression, the port stops at the category (45 sites).
- #176/#177: no vet-gated diagnostic has ever been compared against the oracle.
- #131: open question -- port substitutes `check_has_break` for C++'s `check_has_break_expr`.
- `ast.unparen_expr` divergence: 71 call sites, 4 direct-deref; needs its own measured pass.
- Upstream (not the port): #119, #156, #159, #161, #166, #169, #174, #187, #189, #195, #206, #225.

## #260 continued -- four probes closed, and a fifth defect found while closing them

`union_bad`, `orreturn_bad`, `typeswitch_bad` and `intrinsics_bad` are all FULL-MATCH. Corpus
53/55 (was 49/55). Vet clean. The two survivors are `append_noval` and `builtin_arity`, both
blocked on the proc-group leniency item recorded above -- do NOT special-case `append`.

### Eight fixes, in four groups

**1. The builtin arity prologue (check_builtin.odin:26).** C++ reports at `ce->close` -- the
CLOSING PAREN -- and names the procedure with `expr_to_string(ce->proc)`, the SOURCE expression.
The port reported at the call node and substituted the builtin's own `info.name`, so
`intrinsics.type_is_integer(int, int)` read as column 7 / `'type_is_integer'` where C++ says
column 42 / `'intrinsics.type_is_integer'`. Both now match exactly.

Two side findings from the same read:

- C++'s `if (ce->inlining != ProcInlining_none)` guard did not exist in the port at all.
  `#force_inline len(x)` was silently accepted. Added; like C++ it does NOT early-return.
- The per-builtin `"'%s' requires exactly 1 argument, got %d"` checks in four type-intrinsic
  handlers were UNREACHABLE -- the generic prologue returns false before dispatch. Dead code
  that also worded the message differently from the one that actually fires. Removed.

**2. The type-intrinsic message family (5 sites).** C++ has exactly two shapes and the port had
neither:

- `type_is_*` and `type_has_nil` (the type_simple_boolean arm, check_builtin.cpp:7071-7088):
  `"Expected a type for '%s', got '%s'"`, and it does NOT abandon the operand -- the result is
  the constant `false` of type untyped bool so the enclosing expression keeps checking.
- `type_base_type` / `type_core_type` / `type_elem_type` (6771-6790): `"Expected a type for
  '%s'"` with no "got" clause, recovering by forcing `mode = Type`.

The port had one invented message (`"'%s' requires a type argument"`) for all five, and returned
false from every one. The recovery difference is the substantive half: C++'s cascade continues
into "Invalid type definition of untyped integer"; the port's stopped.

**3. or_return's return-type note (check_expr.odin:7120).** C++ wraps the headline in an
ERROR_BLOCK and follows it with `"\tProcedure return value type: %s"` (singular/plural by
variable count). The port emitted the headline alone -- the reader was told the assignment
failed but never what the target was. Also removed an INVENTED third arm
(`is_type_boolean(right_type) && type_has_nil(end_type)`) that C++ does not have: a real
under-rejection, leniency the port granted itself.

**4. Two continuation blocks emitted as diagnostics (check_expr.odin, convert_to_typed).** The
union arms built C++'s text correctly and then emitted it through `error()` instead of
`error_line()`. That makes a second POSITIONED diagnostic at the SAME position as the headline
-- and the same-position merge (progress#219) then swallowed it. So `'U' is a union which only
accepts the following types: 'int' or 'f32'` was constructed on every run and never reached the
user. Both arms (ambiguous and no-match) now use begin_error_block + error_line.

**5. Duplicate type case (check_stmt.odin:2463).** Three corrections in one diagnostic: C++
names the EXPRESSION not the resolved type; the trailing position is `cc->token.pos`, the
CURRENT case clause's own `case` keyword, not where the type was first seen; and C++ breaks out
of the type-expression loop where the port continued it. The port had implemented the intuitive
reading of "previous type case at" -- which is not what C++ does. The label pointing at the
duplicate rather than the original is an upstream oddity; parity means reproducing it.

### The comparator has a blind spot, and it hid this

`cmpfull.py` drops any line that is neither a positioned diagnostic, a positionless one, nor
indented. `'U' is a union which only accepts the following types:` is none of those -- it starts
at column 0 with a quote. So the comparator reported ONE missing line (the indented `'int' or
'f32'`) when TWO were missing. The verdict was right, the diagnosis it suggested was not.
Widening the rule pulls in allocator noise, so this is recorded rather than fixed: **when a
FULL-DIFFER names a missing continuation line, read the raw oracle output before believing the
line count.**

### Newly opened by this work

The port's `check_type_expr` is missing C++'s tail (check_type.cpp:4080-4102): the
`is_type_typed` gate that emits `"Invalid type definition of %s"`. Visible now that the type
intrinsics recover instead of bailing -- `c: intrinsics.type_base_type(3)` gets the C++ message
at 6:5 and nothing from the port. The port distributes `set_base_type` across the arms of
`check_type_internal` rather than doing it once in the caller, so this is a structural
difference, not a one-line gap. Not attempted this tick; filed rather than half-done.

## #261 part 1 -- the `*T` and `T[N]` recovery path, and a parser arm that never existed

Task #261 was filed as "check_type_expr is missing C++'s is_type_typed tail". Probing first
showed the tail is the SMALLER half of the gap. C++'s check_type_expr (check_type.cpp:4010-4108)
has five parts; the port had one.

### The parser rejected `*T` before the checker could explain it

C++ `parse_operand` (parser.cpp:2668) has

    case Token_Mul:
        return parse_unary_expr(f, true);

and `parse_unary_expr` (parser.cpp:3483) lists `Token_Mul` among its prefix operators with the
comment "Used for error handling when people do C-like things". Both are deliberate: a leading
`*` in TYPE position must PARSE so that check_type_expr can reject it by name and suggest `^T`.

The port had neither arm. `b: *int` died in the parser with TWO syntax errors ("Expected ';',
got *" and "Missing variable type or initialization") where C++ emits ONE checker diagnostic
plus the suggestion.

I confirmed the divergence is specific to `*` BEFORE touching anything: `-int`, `!int` and
`&int` all matched C++ exactly beforehand, and still do after. Without that control the fix
could have been a general "accept unary prefixes in type position", which would have been wrong.

Also added, from the same C++ block: `skip_possible_newline` after `Token_Not`. The port's
unary arm omitted it.

### Both "Suggestion:" continuations were missing

check_type_expr's failure path emitted `"'%s' is not a type"` alone. C++ wraps it in an ERROR
BLOCK and follows with `Suggestion: Did you mean '[%s]%s'?` for an IndexExpr and `Did you mean
'^%s'?` for a `*`-unary -- then RECOVERS by rebuilding the node the user meant (ast_array_type /
ast_pointer_type) and checking that, "to minimize error propagation of bad array syntax". Ported
including the recovery.

### Measured

`p_cte2` (`b: *int`) FULL-MATCH. `p_cte3` (`-int`/`!int`/`&int`) still FULL-MATCH. Corpus 53/55.
Both core/odin/checker and core/odin/parser vet clean. Partitioned sweep t469 -> t470: 198
stable packages, 0 error-count differences, 0 diagnostic-text differences, totals 518 == 518.
The three text deltas are the known #41/#141 heap corruption landing on a different package
between runs (3 unstable on each side).

### A wrong first instinct, caught by one number

`a: int[3]` still differs, but NOT on the suggestion line -- that now matches. C++'s headline is
`'int' is not an expression but a type`; the port's is `'int[3]' is not a type`. I assumed this
was the same-position merge choosing between two candidates, since both land on 3:5 and the port
HAS that message (check_expr.odin:4430). It is not: `raw_diags=1` shows the port only ever
produces one. The port's check_type_internal never checks the IndexExpr operand as an
expression, so the C++ headline has no counterpart to lose to. Belongs to #149 (C++ names the
offending thing, the port names the category), not here.

**The header's raw_diags count distinguishes "emitted then merged" from "never emitted".** That
is the cheapest available test for any suspected merge interaction, and it takes one run.

### Still open on #261

The tail proper: the `is_type_typed` gate emitting "Invalid type definition of %s", the Named-
with-null-base fixup, the polymorphic flag set, and check_rtti_type_disallowed. The port
distributes `set_base_type` across the arms of check_type_internal instead of doing it once in
the caller, so these need dispositioning individually rather than transcribing the block.

## #261 part 2 -- the tail proper: four operations, four different dispositions

Transcribing C++'s block would have been wrong. Each of the four tail operations needed its own
answer.

**1. The `is_type_typed` gate + `add_type_and_value` -- REAL, and bigger than the diagnostic.**
check_type.cpp:4095-4102 records the expression as a type (`add_type_and_value(ctx, e,
Addressing_Type, type, empty)`) when `(Named && base == nullptr) || is_type_typed(type)`, and
otherwise emits "Invalid type definition of %s" and forces t_invalid. `check_type.odin` had ZERO
`add_type_and_value` calls anywhere in the file -- the port never recorded type-and-value for a
type expression at all. Ported both branches. Note C++'s precedence: `(A && B) || C`.

**2. The Named-with-null-base fixup -- REAL.** check_type.cpp:4066-4078. A type ALIAS keeps its
null base deliberately (the declaration is a mini "cycle" filled in later); everything else is
forced to t_invalid. C++'s own diagnostic here is `#if 0`'d out with "IMPORTANT TODO(bill): Is
this a serious error?!", so this repairs silently. Ported.

**3. The polymorphic flags -- NOT PORTED, deliberately.** check_type.cpp:4081-4083 sets
`TypeFlag_Polymorphic` / `TypeFlag_PolySpecialized`. `grep -rn TypeFlag_ src/` finds the enum
definition and these two writes and NOTHING ELSE -- they are write-only in the C++ compiler
itself. Only `TypeFlag_InProcessOfCheckingPolymorphic` is live, and the port already has it as
`.In_Process_Of_Checking_Polymorphic`. Adding them would create exactly the write-only duplicated
state this port has repeatedly had to remove (#74, #103, #104). **A missing write is only a gap
if something reads it.**

**4. check_rtti_type_disallowed -- ported but NOT VERIFIED.** The port had 1 of C++'s 3 call
sites (check_decl); added check_type.cpp:4105. The third, check_expr.cpp:12686 ("An expression is
using a type, %s, which has been disallowed"), is still missing. This whole family only fires
under `-no-rtti` on the `any` type, and the triage harness does not expose that flag -- so this
one is ported by inspection and has no measurement behind it. Stated rather than implied.

Also added `set_base_type(named_type, type)` at the tail: a no-op on the success path because the
port's check_type_internal arms each call it before returning, but NOT a no-op on the new error
path, where C++ overwrites the arm's write with t_invalid.

### Measured

Corpus **55/55 FULL-MATCH** (two probes added: `typeintrin` from the type-intrinsic work,
`ctypemistake` for `*T`). Vet clean. Partitioned sweep t470 -> t471: 197 stable packages, 0
error-count differences, 0 diagnostic-text differences, totals 518 == 518.

The sweep's unstable count moved 3 -> 5, which is exactly the kind of number the ledger says not
to read from one run each. Measured instead, 20 runs per package per binary:

    core/crypto/mlkem   t470 0/20   t471 0/20
    core/text/match     t470 0/20   t471 0/20
    core/crypto/hkdf    t470 6/20   t471 4/20

mlkem and text/match are clean on both -- their sweep crashes were single-run noise. hkdf is the
known #41/#141 heap corruption at ~25% on both, slightly lower on the new binary. No regression.

### Verification gap: doccmp.sh is gone

#253 built a doc-output state comparator and measured 60/60 STATE-MATCH with it. It lived in /tmp
and did NOT survive the wipe -- `.claude/tools/` contains only cmpfull.py. That was the instrument
most likely to be sensitive to the new `add_type_and_value` writes, and it was unavailable for the
one change that most needed it. The diagnostic evidence is strong (197 packages byte-identical),
but doc-state is unmeasured for this change.

**Anything worth building twice belongs in `.claude/`, not /tmp.** cmpfull.py, the probe corpus
and LEDGER.md were moved after the wipe; doccmp.sh, sweep_det.sh, pkglist.txt, swdiff.py and
flake.sh were not. Rebuilding doccmp.sh and relocating the rest is now an action item.

### Repeated a recorded mistake

`defer delete(name)` on a `type_to_string` result aborted the checker with
`free(): invalid pointer`. LEDGER #142 is that exact crash. In this port `expr_to_string` results
ARE freed and `type_to_string` results are NOT. The rule is now a comment at the call site, not
only in this file -- a ledger entry did not stop me repeating it.

## #261 follow-up -- the TAV write is NOT additive, and the sweep could never have told me

Rather than reconstruct doccmp.sh (design lost with /tmp, and a badly-rebuilt instrument gives
false confidence -- see the flaky-probe rule), I measured the actual risk directly: does
check_type_expr's new `add_type_and_value` ever CLOBBER an existing different tav? `expr.tav` is
a plain field, so an overwrite is invisible to the diagnostic sweep unless something reads it.

Temporary instrumentation at the call site, three-way classification, then removed:

    package              total    NEW    SAME   CLOBBER  (of which DIFFSTR / SAMESTR)
    core/odin/parser     53839  31007    9674    13197        2294 / 10884
    core/math/linalg     10484   7313     640     2532         522 /  2010
    core/strings         11156   6370    2129     2631          66 /  2564
    core/fmt             37961  23263    6612     8155
    core/os              33107  20008    5950     7111
    core/crypto           2863   2643     159       61
    base/runtime          2775   2564     154       57

**~24% of the new writes overwrite an existing tav.** Every single clobber is `Type -> Type` --
the mode never changes, only the type pointer. That splits two ways:

**SAMESTR (~82% of clobbers)**: same type textually, different `^Type` instance. The port is
building duplicate Type objects for the same type; my write just swaps one equivalent instance
for another. Benign for anything comparing by name, NOT benign for anything comparing by pointer.

**DIFFSTR (~18%)**: genuinely different, and the direction is alarming -- the REPLACEMENT is
consistently the less-resolved value:

    int          -> $P              (resolved type overwritten by a polymorphic parameter)
    Fd           -> $T1
    rawptr       -> $T1
    $T/[3]$E     -> $T/[0]$E        (concrete count overwritten by zero)
    matrix[4, 4]$E -> matrix[0, 0]$E
    [dynamic]u8  -> invalid type    (valid overwritten by invalid)

That shape says a generic/uninstantiated re-check is running over the SAME AST node after the
instantiated one and winning. Whether C++ does the same at the same site is unknown: C++ writes
in the same place, but answering "does C++ clobber identically" needs the C++ side instrumented,
which is not done.

### Why this matters as a method point

The sweep says 197 packages byte-identical and the corpus says 55/55. Both are true and both are
blind here: nothing in the diagnostic path reads tav for these nodes. **A change can be
diagnostically invisible and still be wrong in state.** The instrument that would have caught it
(doccmp.sh) was the one lost with /tmp.

I am NOT reverting: the write is where C++ puts it, and removing it restores a different known
divergence (the port recorded no tav for type expressions at all). But the clobber is recorded as
a live hazard rather than filed as "verified clean", because it is not verified clean.

## #262 DOWNGRADED -- the clobber is C++-faithful, and my repro corrected two of my own claims

Narrowed the DIFFSTR clobbers to a 10-line repro:

    vdot :: proc(a, b: $T/[$N]$E) -> E { r: E; for i in 0..<N { r += a[i]*b[i] }; return r }
    main :: proc() {
        x: [3]f32;  y: [4]f32;  z: [3]f64
        _ = vdot(x, x);  _ = vdot(y, y);  _ = vdot(z, z)
    }

Instrumented output on the GENERIC declaration's own parameter nodes (line 2):

    col 20: [3]f32 -> $T/[0]$E     col 23: [3]f32 -> [0]$E     col 27: f32 -> $E
    col 20: [4]f32 -> $T/[0]$E     col 23: [4]f32 -> [0]$E     col 34: f32 -> f64

Two corrections to what I wrote last tick:

1. **"Valid overwritten by invalid" overstated it.** `[0]$E` is not corruption -- `$N` unresolved
   renders as 0, so that IS the uninstantiated signature's rendering (same as #75). The pattern is
   instantiated <-> generic alternation on shared nodes, not damage.
2. **My first two repro candidates produced ZERO clobbers.** A fixed count (`[3]$E`) does not do
   it, and `[$N]$E` with a SINGLE call does not either. It takes three instantiations. Had I
   reported the first "it doesn't reproduce" as evidence the effect was rare, that would have been
   wrong -- the effect needs a specific multiplicity, not a specific rarity.

### The answer: C++ does the same thing

C++ `check_expr.cpp:469` -- the FIRST `check_procedure_type` -- passes `pt->node` directly:

    bool success = check_procedure_type(&nctx, final_proc_type, pt->node, &operands);

The port does exactly this at `check_poly_proc.odin:220`. The `clone_ast(pt->node)` at
check_expr.cpp:521 belongs to the SECOND pass, guarded by C++'s own comment "LEAK NOTE: this is
technically a memory leak as it has to generate the type twice" -- and the port has that clone
too, at check_poly_proc.odin:278. Same function, same argument, same position in the flow, in
both compilers.

So both write instantiated types onto the generic declaration's shared AST nodes on the first
pass. **The clobbering is faithful, not a port defect.** #261's TAV write did not introduce the
aliasing; it only made an existing, C++-matching behaviour observable in `tav`.

### Caveat on the strength of this

This is STRUCTURAL correspondence -- matched call sites in both sources -- not a behavioural
measurement. Confirming it behaviourally needs the C++ side instrumented, which means a temporary
src/ edit and a full C++ rebuild. Not done. That is a weaker class of evidence than, say, the
20-runs-per-binary crash comparison, and is labelled as such rather than written up as "verified".

Corpus 55/55 on the de-instrumented build; vet clean; instrumentation fully removed.

## #260 -- two proc-group defects, the second hidden BY the first

The remaining `append_noval` / `builtin_arity` item. Bisected the rule with the oracle before
touching anything:

    solo(&d)   single polymorphic proc, zero varargs          ACCEPTED
    grpA(&d)   group, ONE polymorphic variadic member          ACCEPTED
    grpB(&d)   group, one poly-variadic + one concrete         REJECTED
    grpC(&d)   group, TWO poly-variadic members                REJECTED
    grpD(&d,1) two poly members, non-variadic, one argument    ACCEPTED

So the rejection is not about `append`, not about polymorphism, and not about variadics on their
own: it needs a group with MORE THAN ONE member where the only viable candidate would take zero
variadic arguments. C++ `check_expr.cpp:7411` confirms the shape -- `procs.count == 1` short-
circuits to `check_call_arguments_single` with ShowErrors, bypassing the scoring path entirely.
The port has that shortcut too (check_proc_group.odin:1460).

### Defect 1: the scoring loop iterated the array it appends to

C++ `check_expr.cpp:7549` is `for_array(i, procs)` -- `procs` is FIXED for the loop -- while
generated specializations are appended to the SEPARATE `proc_entities` (7578). The port looped
`for entity_proc, i in proc_entities` and appended to `proc_entities` in the body, so every
polymorphic candidate that produced a specialization was scored a SECOND time as another group
member. Instrumented on `proc{c1, c2}`:

    GRP 7:2 procs=2
    GRP 7:2 cand=0 ok=true  score=301
    GRP 7:2 cand=1 ok=false score=0
    GRP 7:2 cand=2 ok=true  score=301     <-- third evaluation from a two-member group

Two "valid" candidates with identical scores for what is one procedure.

### Defect 2: an out-of-bounds read that defect 1 was masking

Fixing the loop produced `Index 3 is out of range 0..<3` at check_proc_group.odin:1775 on the
FIRST run. Candidate indices address `proc_entities`, but the single-winner branch read
`procs[valid_candidates[0].index]`. C++ reads `proc_entities[valids[0].index]` (7992), as it does
at 7607, 7614 and 7943.

It had never crashed because the duplicate scoring kept `len(valid_candidates)` at 2, so the
single-winner branch was unreachable in exactly the cases that would have gone out of bounds.
**One defect was the reason the other was invisible.** Worth remembering as a shape: a fix that
immediately produces a crash is not necessarily wrong -- it may have removed the thing that was
suppressing a second defect.

### NOT fixed: the under-rejection itself

With the duplicate gone the port has ONE valid candidate instead of two, so it still accepts
`append(&d)` where C++ rejects. The remaining divergence is that the port's scoring finds a
zero-vararg polymorphic candidate viable at all; C++ finds neither candidate viable. That is the
leniency question and is larger than the two bookkeeping bugs above. `p_ap2` (`append(&d, 1)`,
the legal case) is FULL-MATCH, so the fix did not break the working path.

Do NOT special-case `append`. The bisect above shows the rule is about group arity, and whatever
it turns out to be it applies to every group.

### Upstream: C++ has the same wrong-array read, latent

`check_expr.cpp:7595` inside the `max_matched_features > 0` block reads
`procs[valids[i].index]` where every neighbouring site uses `proc_entities`. It needs both a
matched target feature and a generated entity to trigger, which is why it has not been hit.

### The hkdf crash-rate scare, resolved by more runs

The sweep for the two proc-group fixes moved `unstable` 5 -> 6, and at n=20 hkdf gave 3/20 on the
old binary against 6/20 on the new -- which reads as a doubling. It is not:

    n=20    t471  3/20    t475  6/20
    n=60    t471 10/60    t475 12/60
    pooled  t471 13/80 (16.3%)   t475 18/80 (22.5%)    z = 1.0, p ~ 0.32

No detectable difference, and both sit inside the 17-25% band #41/#141 has always shown. The
20-run samples were simply too small; the ledger rule (>=20 runs) is a floor for detecting a
LARGE effect, not enough to resolve a 6-point difference in a ~20% rate.

**Sharpened rule: n>=20 can tell "always" from "never"; it cannot tell 16% from 22%. If a
decision turns on a small change in an intermittent rate, budget n>=60 per binary.**

Both fixes stand: corpus 55/55, vet clean, sweep 194 stable packages with 0 error-count and 0
diagnostic-text differences, totals 463 == 463.

### The zero-vararg group rejection: mechanism found, fix NOT landed

C++ has a named error for exactly this case, `CallArgumentError_AmbiguousPolymorphicVariadic`,
emitted from two sites in check_call_arguments_internal:

  * check_expr.cpp:6919-6927, when `ordered_operands.count == 0 && param_count_excluding_defaults
    == 0` and the first parameter type is still polymorphic;
  * check_expr.cpp:6979-6991, after the parameter loop: if the procedure is variadic and the
    variadic parameter's slice ELEMENT type is STILL polymorphic, the candidate is rejected with
    "Ambiguous call to a polymorphic variadic procedure with no variadic input %s".

The port has NEITHER site. But adding the second one does not fix the case, and knowing WHY is
the useful part:

`pt` is rebound to the generated entity's proc type when instantiation succeeds
(check_expr.cpp:6937), so after a successful instantiation `elem` is concrete and the check does
not fire. It fires precisely when the element type could NOT be pinned down. In C++'s group
scoring path `ctx.no_polymorphic_errors = true` makes `modify_type` false, so the binding is
never recorded and `elem` stays `$E`. **The port's instantiation SUCCEEDS under the same flags**,
leaves `elem` concrete, and the check would be a no-op.

So the divergence is not a missing check -- it is that the port's
`find_or_generate_polymorphic_procedure_from_parameters` binds types in a mode where C++ refuses
to. That is the "leniency" the original note pointed at, now located precisely.

I wrote the 6979-6991 check, measured that it never fires (all four probes unchanged), and
REVERTED it. An unverified check that cannot fire is the dead-code defect this port keeps having
to delete; adding one while claiming the item was progressed would have been worse than leaving
the item open. Also note the check went into the NON-polymorphic fall-through path -- the
polymorphic branch returns at check_proc_group.odin:845, well before it -- so the port has two
exits where C++ has one flow, which any real fix has to reckon with.

Tree is back to the t475 state: corpus 55/55, vet clean.

### Root cause located: the flags are set, and the port binds anyway

Instrumented the instantiation's result inside check_call_arguments_internal's polymorphic branch
(check_proc_group.odin:708), for `grpC(&d)`:

    INST npe=true hpe=true elem=int poly=false

Both `no_polymorphic_errors` and `hide_polymorphic_errors` are TRUE at the point of instantiation
-- correctly propagated from the scoring loop -- and the instantiation still returned a proc type
whose variadic ELEMENT is `int`, fully bound. In C++ those same flags make `modify_type` false at
check_type.cpp:2093, `$E` stays unbound, and the ambiguous-variadic check at 6979-6991 then
rejects the candidate.

**So the divergence is not the missing check and not the flag plumbing. The port's instantiation
binds polymorphic types in a mode where C++ refuses to bind.** The flag reaches
`check_procedure_type` (check_poly_proc.odin:192 `nctx := old_ctx^`, unchanged before the call at
:220 -- the second pass that clears it is at :268-270, matching C++ 508-513), so the binding
happens BELOW check_procedure_type. The port does compute `modify_type := !ctx.no_polymorphic_errors`
at check_type.odin:4839, so the next question is whether that value is actually threaded into the
write path or recomputed/ignored deeper.

Two of my own assumptions died this tick, both by one measurement each:

1. "The polymorphic branch returns at :845 before my check" -- WRONG. `POLYEXIT` never fired for
   grpC: that return belongs to the NAMED-operand branch, which this call does not take. The check
   I reverted last tick was in the right function after all; it simply could not fire because
   `elem` was already `int`.
2. "The port might not be setting the flags" -- WRONG, measured true/true.

**Instrumenting the thing I was about to blame, before blaming it, cost one build each time and
prevented two wrong fixes.**

Next: instrument check_type.odin:4839 and the specialization write path to find where the bind
happens despite modify_type=false.

### Third hypothesis dead: determine_type_from_polymorphic does NOT bind

Instrumented the port's `determine_type_from_polymorphic` (check_type.odin:4185), printing
modify_type, the poly type before and after, and the operand, for `grpC(&d)`:

    DTFP mt=false r=true  poly=^$T/[dynamic]$E -> ^$T/[dynamic]$E  op=^[dynamic]int
    DTFP mt=false r=false poly=^$T/#soa[dynamic]$E -> ^$T/#soa[dynamic]$E  op=^[dynamic]int

`modify_type` is FALSE, correctly derived from `no_polymorphic_errors`, and the polymorphic type
is UNCHANGED across the call -- `^$T/[dynamic]$E` before and after. So this path does not bind,
and it returns the still-generic `poly_type` on success, exactly as C++ does.

Yet `INST` (previous tick) showed the finished instantiation carrying `elem=int`. So the
concretisation happens somewhere between `determine_type_from_polymorphic` returning a generic
type and `check_procedure_type` producing `final_proc_type` -- most likely when the parameter
entity or the `$E` scope entity is created from the resolved operand. That is the next probe.

Three hypotheses have now died, one measurement each:

  1. "the missing 6979-6991 check is the gap"    -- wrote it, it never fired, reverted
  2. "the flags are not propagated"              -- measured npe=true hpe=true
  3. "determine_type_from_polymorphic binds"     -- measured mt=false, type unchanged

Each cost one build. Each would have been a wrong fix shipped with a plausible-sounding
justification. **The cost of instrumenting before editing is one build; the cost of not doing it
is a wrong change that measures clean on the corpus, because the corpus cannot see state.**

Tree unchanged: instrumentation removed, vet clean, still the t475 code that measured 55/55 and
sweep-identical.

### check_type.cpp:2154-2161 -- one dead half, one live half

The port lacks C++'s `else if (!ctx->no_polymorphic_errors)` branch after
`determine_type_from_polymorphic` in the VALUE-parameter path (port: check_type.odin:4903;
C++: check_type.cpp:2149-2161). Split it in two before porting:

**`is_type_polymorphic_type = false` (2155) -- DEAD IN C++.** The variable is declared PER
PARAMETER inside the loop at check_type.cpp:1903, read once at 2149, cleared at 2155, and never
read again (`awk` over 2156-2260 finds no reference). Same class as `TypeFlag_Polymorphic`
(#261): a write nothing reads. The port's omission is a NON-GAP; porting it would add dead state.

**The partial-polymorphic-procedure error (2156-2160) -- LIVE, and the port has it NOWHERE.**

    Entity *proc_entity = entity_from_expr(op.expr);
    if (proc_entity != nullptr && op.value.kind == ExactValue_Procedure) {
        if (is_type_polymorphic(proc_entity->type, false)) {
            error(op.expr, "Cannot determine complete type of partial polymorphic procedure");
        }
    }

`grep` finds this string only in src/. It needs `determine_type_from_polymorphic` to SUCCEED and
the operand to be a constant PROCEDURE whose entity type is still polymorphic. My first probe
(`takes(gen, 3)` with `gen :: proc(a: $T, b: $U)`) does not reach it -- both compilers stop
earlier at "Cannot determine polymorphic type from parameter", and agree exactly. Filed rather
than guessed at; an unreproduced diagnostic is not something to write blind, having just reverted
one such check two ticks ago.

So this branch is NOT the zero-vararg cause either. Fourth hypothesis, fourth measurement,
fourth negative -- but two of the four turned into recorded non-gaps rather than nothing.

### Concretisation localised exactly: it is the SECOND pass

Bracketed both `check_procedure_type` calls inside the port's
`find_or_generate_polymorphic_procedure` for `grpC(&d)`:

    CPT  npe=true  success=true  elem=$E     first pass  (check_poly_proc.odin:220)
    CPT2 npe=false success=true  elem=int    second pass (check_poly_proc.odin:283)

The FIRST pass behaves exactly like C++: the flag is set, nothing binds, the variadic element
stays `$E`. The SECOND pass -- the one that deliberately clears `no_polymorphic_errors`
(check_poly_proc.odin:268-270, mirroring C++ 508-513) and re-checks a CLONE -- is where `E`
becomes `int`.

So the port's binding is not a leak of the flag anywhere; it is the second pass doing its job.
The chain is now fully mapped on the port side:

    scoring loop sets no_polymorphic_errors -> first pass respects it, leaves $E
      -> cache miss -> second pass CLEARS the flag by design -> binds E=int
        -> gen_entity type is concrete -> the 6979-6991 ambiguous-variadic check cannot fire
          -> candidate stays valid -> port accepts what C++ rejects

**The open question is now precise**: C++ reaches its second pass on a cache miss too
(check_expr.cpp:508+), and that pass also clears the flag, so on the face of it C++ should also
end up concrete. Either C++ does not reach `find_or_generate` at all for this call -- the guard
at check_expr.cpp:6929 is `pt->is_polymorphic && !pt->is_poly_specialized && err ==
CallArgumentError_None`, so something earlier in 6850-6929 may already have set `err` -- or its
second-pass cache lookup returns before binding. Deciding between those needs the C++ side
instrumented, i.e. a temporary src/ edit and a full C++ rebuild, which has not been done.

Five hypotheses, five measurements. This one was not a negative: it converted "somewhere in
instantiation" into a two-line answer and a single remaining question.

### The fork resolved one way: C++ DOES call find_or_generate here

Checked whether `err` is already set before C++'s guard at check_expr.cpp:6929
(`pt->is_polymorphic && !pt->is_poly_specialized && err == CallArgumentError_None`).

The only pre-guard assignment that could apply is check_expr.cpp:6678-6679:

    isize positional_operand_count = positional_operands.count;
    if (variadic) {
        positional_operand_count = gb_min(positional_operands.count, pt->variadic_index);
    } else if (positional_operand_count > pt->param_count) {
        err = CallArgumentError_TooManyArguments;
    }

For `grpC(&d)` the procedure IS variadic, so the `else if` is not reached and `err` stays None.
`ordered_operands.count` is 1, so the zero-operand branch at 6915 is skipped too. **C++ reaches
`find_or_generate_polymorphic_procedure_from_parameters` for this call, exactly as the port
does.**

That kills the first half of the fork. And since C++'s instantiation has the same two-pass shape
-- second pass clears `no_polymorphic_errors` and re-checks a clone -- C++ should also come back
with a concrete element type, and its 6979-6991 check should also fail to fire. Yet C++ rejects.

So the rejection is NOT where I have been assuming for the last three ticks. Something else in
C++'s path produces it, and I have now exhausted what static reading of src/ can settle: every
remaining candidate depends on runtime values (which cache lookup hits, what `err` holds at each
stage, whether the second pass is even reached).

**Next step is C++-side instrumentation**: a temporary edit to src/check_expr.cpp printing `err`,
the cache-hit path and the final `pt` element type for this call, a local rebuild, then revert.
The user's standing instruction is not to COMMIT src/ changes; building locally and reverting is
consistent with that, and it is now the only way to stop guessing. Deliberately deferred to a
fresh tick rather than started at the end of this one.

Six measurements in. The port side is fully mapped and two real defects came out of it
(duplicate scoring, wrong-array index). The C++ side is not mapped, and I am not going to
"conclude" it from reading -- that is exactly what produced four dead hypotheses.

## #260 ROOT CAUSE, measured on BOTH sides

Instrumented the C++ compiler itself (temporary edit to src/check_expr.cpp, local rebuild via
`build_odin.sh release-native`, then reverted; `./odin` backed up first and restored byte-identical,
since the build overwrites the oracle). Output for `grpC(&d)`, filtered to the polymorphic
candidates:

    XGUARD poly=1 polyspec=0 err=0        guard passes -- find_or_generate IS called
    XINST FAILED                          the instantiation returns FALSE
    XVAR elem=$E poly=1 err_before=2      err=2 == CallArgumentError_WrongTypes

The chain in C++:

  1. the guard at check_expr.cpp:6929 passes (`err == None`), so find_or_generate is attempted;
  2. it FAILS, so `err = CallArgumentError_WrongTypes` and `pt` is NEVER rebound;
  3. `pt` therefore still describes the GENERIC procedure, so the variadic element is `$E`;
  4. the ambiguous-variadic check at 6979-6991 fires on that `$E` and sets
     AmbiguousPolymorphicVariadic;
  5. both candidates die -> "No procedures or ambiguous call".

Against the port's measurements from the previous ticks:

    C++   find_or_generate -> FALSE   (pt stays generic, elem=$E, check fires, candidate dies)
    port  find_or_generate -> TRUE    (pt rebound, elem=int,  check cannot fire, candidate lives)

**That is the whole divergence, and it is one boolean.** The port's second pass -- which clears
`no_polymorphic_errors` by design, exactly as C++ does -- SUCCEEDS where C++'s fails. With zero
variadic operands there is no operand from which to determine `$E` for `args: ..E`; C++ treats
that as failure, while the port derives `E` from the `^$T/[dynamic]$E` specialization on the first
parameter and calls it determined.

Both earlier candidate explanations are now dead with evidence, not argument: C++ *does* reach
find_or_generate (XGUARD err=0), and the ambiguous-variadic check *is* the proximate rejector but
only because `pt` was never rebound.

**Method note.** Six ticks of port-side instrumentation narrowed this to "the port binds where C++
does not" but could not say why, because the answer lived in the other compiler's control flow.
One C++ rebuild settled it in a single run. When a parity question is about what the ORACLE does,
instrument the oracle -- reading its source produced four wrong answers first.

Hygiene: src/ is back to pristine (`git status --short src/` shows only the pre-existing untracked
src/tests) and ./odin is byte-identical to the pre-build backup and still reports the expected
diagnostic. No src/ change is staged or committed.

## #260 ROOT CAUSE, exact hunk -- three C++ rebuilds to get here

Instrumented every `return` in C++'s `find_or_generate_polymorphic_procedure` and every
`success = false` in its parameter-list check. For `grpC(&d)`:

    XFG H1st        (check_expr.cpp:473)  -- the FIRST check_procedure_type returns false
    XPL 2152        (check_type.cpp:2152) -- the ONLY failure site that fires, 18 hits

check_type.cpp:2152 is `if (type == t_invalid) success = false;` immediately after
`determine_type_from_polymorphic`. So C++'s determine_type_from_polymorphic returns t_invalid --
and it cannot be failing in `is_polymorphic_type_assignable`, because C++'s Generic arm
(check_expr.cpp:1439-1450) returns TRUE regardless of modify_type; modify_type only gates the
`gb_memmove` that writes the binding. It must be taking the EARLY return, the
`!is_operand_value(operand)` guard.

Why that guard trips is check_type.cpp:2140-2147, and this is the hunk the port is missing:

    Operand op = (*operands)[variables.count];
    if (op.expr == nullptr) {
        // NOTE(bill): 2019-03-30
        // This is just to add the error message to determine_type_from_polymorphic which
        // depends on valid position information
        op.expr = _params;
        op.mode = Addressing_Invalid;
        op.type = t_invalid;
    }

When the operand slot is EMPTY -- exactly the case for a variadic parameter with zero variadic
arguments -- C++ substitutes an INVALID operand. `determine_type_from_polymorphic` then fails its
`is_operand_value` guard, returns t_invalid, `success = false`, the whole instantiation fails, `pt`
is never rebound, the variadic element stays `$E`, and the ambiguous-variadic check rejects the
candidate.

The port (check_type.odin:4898-4908) reads the operand and calls
`determine_type_from_polymorphic` with NO such substitution, so an empty slot arrives as a
zero-valued operand that passes the guard.

**Note the comment.** bill wrote that substitution "just to add the error message ... which
depends on valid position information" -- presented as a diagnostics nicety. Its load-bearing
effect is to make the whole instantiation fail. A port that read the comment and skipped the hunk
as cosmetic would produce exactly the divergence observed. That is the strongest example this
session of why the port must follow C++'s CODE and not its stated intent.

Not implemented this tick: three C++ rebuilds already spent. The change is small and cited, and
gets the full corpus+sweep next tick.

Hygiene: src/ pristine (`git status --short src/` shows only pre-existing untracked src/tests),
./odin restored byte-identical to the pre-build backup and re-verified against p_grpC.

### Ported the hunk, measured it INERT, reverted -- and found the real blocker

Implemented C++'s empty-operand substitution (check_type.cpp:2141-2148) at the port's
check_type.odin:4898. Measured: all four group probes byte-identical. The substitution never fires.

Instrumented the site to find out why:

    XOP nvars=0 nops=0 polytype=false     x15
    XOP nvars=1 nops=0 polytype=false     x1

**`nops` is 0 on every single call.** The port's `check_get_params` is never handed any operands
at all, so the entire operand-driven block at check_type.odin:4898-4990 -- including the
polymorphic determination this whole investigation has been circling -- is DEAD CODE in practice.

That also corrects an attribution from two ticks ago. The `DTFP` lines I measured were NOT coming
from check_type.odin:4904 inside this block; they must be from the OTHER
`determine_type_from_polymorphic` call site, check_type.odin:1539 (the const-parameter path). I
reported them as evidence about the value-parameter path. They were evidence about a different
path that happens to call the same helper.

So the real gap is one level up again: **`operands` is not reaching `check_get_params`**. C++
threads `Array<Operand> const *operands` from find_or_generate -> check_procedure_type ->
check_procedure_param_list, and sizes it to `pt->param_count` so every parameter -- including an
unsupplied variadic slot -- has an entry. Whatever the port does with that argument, it arrives
empty.

The empty-operand substitution is necessary but NOT sufficient, and shipping it while it cannot
fire would have been the third inert check this session. Reverted. Corpus back to 55/55, vet
clean.

**Pattern, now three for three:** every time I have implemented a C++ hunk before measuring that
its precondition holds in the port, the hunk has been inert. The precondition IS the finding.

### RETRACTION: "operands never reach check_get_params" was my own instrumentation bug

Last tick I concluded the operand-driven block at check_type.odin:4898 was dead because every
`XOP` line read `nops=0`. **That was wrong, and the cause was the instrumentation, not the port.**
My python patch used `s.replace(old, new, 1)` on a pattern that occurs more than once in the file,
so the print landed at the FIRST match -- a different function -- not at 4898.

Re-measured with an anchor asserted unique (`assert s.count(anchor)==1`), at the entry to
check_get_params and at the value-parameter site:

    XGP nops=0  x450    XGP nops=2  x54    XGP nops=1  x3    XGP nops=3  x2
    XV nvars=1 nops=2 exprnil=false polytype=true   x20     <-- the variadic slot
    XV nvars=0 nops=2 exprnil=false polytype=true   x20

Operands DO reach check_get_params. The block is live. Everything I wrote last tick about it being
dead code is retracted, including the "three for three" claim about inert hunks -- that tally was
built on this bad measurement.

**The actual finding, now correctly measured:** for the variadic parameter (`nvars=1`, i.e. slot
index 1) the port has `nops=2` and `exprnil=FALSE`. C++'s `ordered_operands` is sized to
`pt->param_count` and leaves the unsupplied variadic slot with `expr == nullptr` -- which is
exactly what triggers check_type.cpp:2141-2148's invalid-operand substitution. The port's slot 1
carries a REAL expr for a call that supplied only one argument.

So the empty-operand substitution I ported was inert for a precise reason: the port never produces
an empty slot to substitute. The divergence is in how the operand array is built (check_proc_group
`check_unpack_arguments` / the `make([]Operand, len(positional_operands))` at :700), not in
check_get_params.

**Rule I broke and am writing down:** when patching by text substitution, assert the anchor is
unique. A silently misplaced probe does not fail loudly -- it produces confident, wrong data, and
I built a retracted conclusion plus a retracted meta-pattern on top of it. `assert
s.count(anchor)==1` costs nothing.

Tree: instrumentation removed, vet clean, corpus 55/55, eight checker/parser files modified as
before, nothing committed.

### Where the operand array is built -- the two constructions differ

    C++   check_expr.cpp:6666  ordered_operands = array_make<Operand>(temp, pt->param_count)
                               -- sized to PARAMETER count; unsupplied slots keep expr == nullptr,
                                  and check_expr.cpp:6931 passes THIS to find_or_generate.
    port  check_proc_group.odin:700
                               operands := make([]Operand, len(positional_operands))
                               copy(operands, positional_operands)
                               -- sized to whatever check_unpack_arguments produced.

Measured at the value-parameter site (anchor asserted unique this time), for p_grpC:

    XV nvars=1 nops=2 exprnil=false polytype=true   x20

So a polymorphic-typed parameter at slot index 1 sees a 2-entry operand array whose slot carries
a NON-nil expr. C++'s equivalent slot is nil for an unsupplied variadic argument, which is the
sole trigger for the invalid-operand substitution at check_type.cpp:2141-2148 -- and, through it,
for the instantiation failure that rejects the candidate.

CAVEAT on this measurement: p_grpC pulls in base:runtime, which has many polymorphic variadic
procedures of its own, so those 20 hits are not proven to be c1/c2 specifically. What is solid is
that the two array constructions differ in kind (parameter-count-sized with empty slots vs
argument-derived) and that at least one polymorphic variadic slot reaches the site non-nil. The
provenance of the port's extra entry is NOT yet pinned to a line.

Next: instrument with the candidate's own position so the c1/c2 rows are separable from runtime's,
and print where check_unpack_arguments put each entry.

### Isolated the port's behaviour exactly -- then the two-part fix STILL did not work

Tagged the instrumentation with the parameter list's own source position, so the candidates
separate from base:runtime's polymorphic variadics:

    XW p_grpC/m.odin:2  nvars=0 nops=1 exprnil=false      c1
    XW p_grpC/m.odin:3  nvars=0 nops=1 exprnil=false      c2

`nops=1`, and `nvars` never exceeds 0. With one operand the loop guard
`len(variables) < len(operands)` holds only for parameter 0, so **the port never visits the
variadic parameter at all** -- `$E` is never attempted, and the instantiation succeeds trivially.
C++ sizes its array to `pt->param_count`, visits parameter 1 with an empty slot, substitutes an
invalid operand, and fails. (The earlier `nops=2` rows were base:runtime's own procedures -- the
ambiguity flagged last tick was real, and tagging by position resolved it.)

That is a complete and isolated account of the port's behaviour. The obvious two-part fix --
pad the operand array to param_count at check_proc_group.odin:700, plus C++'s empty-operand
substitution at check_type.odin:4898 -- was implemented and **still did not reject**. Corpus stayed
55/55 and all three probes still accept.

REVERTED both halves. A change that does not do what its own comment claims is worse than no
change, however well-cited: the next reader would trust the comment. The mechanism reasoning
(`0 < 2` should now visit the variadic slot, whose zero-valued Operand has a nil expr, which
should trigger the substitution and fail determine_type_from_polymorphic) is sound on paper and
wrong in fact, which means one of its steps does not hold -- most likely `is_type_polymorphic_type`
is false for `..E`, or the padded slot is not reaching the branch I think it is.

Next: instrument the NEW code path rather than reason about it -- print at the padded site whether
the variadic parameter is visited, what `is_type_polymorphic_type` is for it, and whether the
substitution fires. Three ticks of this item have now ended in "the reasoning was sound and the
measurement disagreed"; only the measurement counts.

### The padding WORKS -- and exposes a fourth defect in the chain

Re-applied the operand-array padding WITH instrumentation attached (rather than shipping and
inferring), printing every parameter regardless of the guard:

    XZ m.odin:2 nvars=0 nops=2 guard=true  polytype=true  variadic=false     the `a` parameter
    XZ m.odin:2 nvars=1 nops=2 guard=true  polytype=FALSE variadic=TRUE      the `args` parameter

The padding did exactly what it was supposed to: `nvars=1` with `guard=true` means **the variadic
parameter is now visited**, which it never was before. So that half is validated, not inert.

But `is_type_polymorphic_type` is **FALSE** for `args: ..E`. The polymorphic branch is therefore
skipped, `determine_type_from_polymorphic` is never called for that parameter, and the
empty-operand substitution has nothing to act on. That is why the two-part fix failed last tick.

C++ sets the flag at check_type.cpp:1966-1968:

    type = check_type(ctx, type_expr);
    ctx->allow_polymorphic_types = prev;
    if (is_type_polymorphic(type)) {
        is_type_polymorphic_type = true;
    }

-- an unconditional `is_type_polymorphic(type)` test on the parameter's checked type. For `..E`
the port evidently either checks a different type (the slice vs the element) or takes a variadic
branch that skips the test. That is the next thing to measure, at check_type.odin:4575.

So the chain is now four links, three of them measured and one still open:

  1. operand array sized to argument count, not param_count   -- MEASURED, fix validated
  2. variadic parameter therefore never visited                -- MEASURED, fixed by (1)
  3. `is_type_polymorphic_type` false for `..E`                -- MEASURED, NOT yet fixed
  4. empty-operand substitution never reached                  -- follows from (3)

Reverted the padding again: it is necessary but not sufficient, and landing half a chain with a
comment claiming the whole thing would mislead the next reader. It goes in together with (3), as
one change with one verification.

**Method note that finally paid off:** this tick applied the change and the instrumentation in the
SAME build. Last tick I shipped the change, saw no effect, and had to reason about why -- and
reasoned wrongly. Instrumenting the change itself, not the code it replaces, is what turned a
dead end into a located defect.

### Link 3 located: C++ REWRITES the ellipsis node and falls through; the port branches and skips

C++ check_type.cpp:1922-1937 does not treat a variadic parameter as a separate case. It rewrites
the type expression and falls through into the shared chain:

    if (type_expr->kind == Ast_Ellipsis) {
        type_expr = type_expr->Ellipsis.expr;
        is_variadic = true;
        ...
        type_expr = ast_array_type(type_expr->file(), original_type_expr->Ellipsis.token,
                                   nullptr, type_expr);      // <-- becomes a SLICE node
    }
    if (type_expr->kind == Ast_TypeidType) { ... }
    else {
        type = check_type(ctx, type_expr);
        if (is_type_polymorphic(type)) { is_type_polymorphic_type = true; }   // 1966-1968
    }

So `args: ..E` reaches the SAME `is_type_polymorphic` test every other parameter does.

The port (check_type.odin:4511-4537) makes the ellipsis a sibling arm of an if/else-if/else
chain: it computes `param_type = make_slice_type(inner_type)` and the chain ends. The
`is_type_polymorphic` test lives only in the final `else` (4573-4576), which a variadic parameter
never reaches.

Measured, not inferred: an instrumentation print guarded by `is_field_variadic` at 4570 produced
ZERO lines across the whole run, while the later print at 4896 showed `variadic=true` for the same
parameter. The variadic arm does not reach 4570 at all.

**This is the same defect shape as several earlier findings: C++ normalises then shares one path;
the port special-cases and the shared tail is silently skipped.** (cf. #238 bit_field delegating to
the shared helper, #184's five mixture sites.)

Fix is now fully specified, two links, one change:

  1. check_proc_group.odin:700 -- size the operand array to `pt.param_count` (MEASURED to make the
     variadic parameter visited);
  2. check_type.odin:4511-4537 -- have the variadic arm run the same `is_type_polymorphic`
     test, i.e. set `is_type_polymorphic_type` when the constructed slice type is polymorphic.

Plus the empty-operand substitution at 4898, which becomes reachable once both hold. Lands next
tick as one change with corpus + sweep.

## #260 ZERO-VARARG UNDER-REJECTION: FIXED -- three links, one change

    p_grpC   FULL-MATCH   (was: port accepted where C++ rejected)
    p_pv     FULL-MATCH
    p_pv2    FULL-MATCH
    p_ap2    FULL-MATCH   the legal `append(&d, 1)` still passes
    p_ap1    FULL-DIFFER  under-rejection FIXED; residual is overload-list ORDER only

`append(&d)` now produces C++'s diagnostic. What remains on p_ap1 is the same three overloads in a
different sequence -- the separate "suggestion order" item already catalogued under #260, not the
acceptance bug.

### The three links

1. **check_proc_group.odin:700** -- the operand array was sized to the ARGUMENT count. C++
   (check_expr.cpp:6666) sizes `ordered_operands` to `pt->param_count`. With fewer arguments than
   parameters the loop guard `len(variables) < len(operands)` went false early and trailing
   parameters -- notably an unsupplied VARIADIC one -- were never visited.

2. **check_type.odin:4531** -- C++ (check_type.cpp:1922-1937) does not branch for a variadic
   parameter: it REWRITES the ellipsis into a slice node and falls through to the shared
   `is_type_polymorphic` test at 1966-1968. The port made the ellipsis a sibling arm, so `..E` was
   never classified polymorphic and `$E` was never determined.

3. **check_type.odin:4898** -- C++'s empty-operand substitution (check_type.cpp:2141-2148), which
   turns an unsupplied slot into an explicitly INVALID operand and thereby fails the
   instantiation. Reachable only once (1) and (2) hold.

### What it took, and what it cost

Ten ticks. Four hypotheses died with a measurement each; two attempted fixes were implemented,
measured inert, and reverted; one conclusion ("operands never reach check_get_params") was
retracted after the anchor-uniqueness bug was found in my own instrumentation. Three C++ compiler
rebuilds were needed because the decisive facts lived in the oracle's control flow, not its source
text.

The single practice that turned it around: **apply the change and its instrumentation in the SAME
build.** Every tick where I shipped a change and then reasoned about why it did nothing produced a
wrong answer. The tick where I instrumented the change itself produced `polytype=FALSE` and named
link 2 immediately.

Verification so far: corpus 55/55, vet clean, five group probes as above. Sweep in progress -- this
touches shared polymorphic machinery, so the partitioned diff decides whether it stands.

### REVERTED: the sweep caught an over-rejection the probes could not

The three-link change made all five group probes behave and left the corpus at 55/55 -- and it was
still WRONG. The partitioned sweep found two packages that went from clean to failing:

    core/debug/trace       0 -> 2 errors
    core/rexcode/ir/wasm   0 -> 1 error

Both are legitimate `append` calls that the ORACLE accepts:

    append(&command, SYMBOLIZER_PROGRAM, "--functions", "--exe", "")   4 variadic args
    append(b, u8(v), u8(v >> 8), u8(v >> 16), u8(v >> 24))             4 variadic args

The defect is in my padding, not in links 2 or 3. I wrote

    operand_count = max(len(positional_operands), param_count)

which KEEPS the surplus arguments in the array. The per-parameter loop then scores the variadic
parameter against `positional_operands[1]` -- a `string` against `[]E` -- which fails, and the
candidate is rejected. C++ sizes `ordered_operands` to EXACTLY `pt->param_count`
(check_expr.cpp:6666) and routes arguments past the variadic index into a SEPARATE
`variadic_operands` list; they never pass through the per-parameter loop at all. `max(...)` was my
invention, not C++'s, and it is wrong in the direction the probes could not see: every probe passed
FEWER arguments than parameters, so the surplus branch was never exercised.

Reverted all three links. core/debug/trace and core/rexcode/ir/wasm are back to 0 errors.

**This is the clearest demonstration this session of why the sweep is not optional.** Five probes
FULL-MATCH, corpus 55/55, vet clean, three C++-cited links, ten ticks of measurement behind it --
and the change still broke real library code. The probe corpus tests what I thought to write down;
the sweep tests what people actually wrote.

The fix is not abandoned, only its first link. Correct form: size to exactly `param_count`, and
copy only `min(len(positional_operands), param_count)` entries, so surplus variadic arguments stay
out of the per-parameter loop as they do in C++. That needs its own probe -- a group call with MORE
arguments than parameters -- added to the corpus BEFORE the next attempt, so this failure mode is
visible at probe speed rather than sweep speed.

### Probe added FIRST this time, and validated both ways

`.claude/probes/varsurplus` -- group calls that pass MORE arguments than parameters, taken from
the two packages the sweep caught:

    append(&cmd, "prog", "--functions", "--exe", "")
    append(&b, u8(v), u8(v >> 8), u8(v >> 16), u8(v >> 24))
    append(&n, 1, 2, 3)

Validated in BOTH directions before trusting it:

    st_t489 (reverted build)      FULL-MATCH    negative control
    st_t488 (over-rejecting)      FULL-DIFFER   positive control -- it catches the regression

The corpus had 55 probes and not one of them passed surplus arguments to a group. That is the gap
that let a change reach the sweep. **A probe corpus grows by adding the case that just escaped it,
and the case is only worth adding once it has been shown to fail on the broken build.**

### Link 1, correct form (from check_expr.cpp:6675-6699)

    isize positional_operand_count = positional_operands.count;
    if (variadic) {
        positional_operand_count = gb_min(positional_operands.count, pt->variadic_index);
    }
    positional_operand_count = gb_min(positional_operand_count, pt->param_count);
    for (isize i = 0; i < positional_operand_count; i++) {
        ordered_operands[i] = positional_operands[i];
        visited[i] = true;
    }
    auto variadic_operands = slice(..., positional_operand_count, positional_operands.count);

So the rule is not "pad to param_count" (my first attempt) and not "max(args, param_count)" (my
second, which over-rejected). It is:

  * array sized to `pt->param_count`;
  * for a VARIADIC procedure, fill only indices `[0, min(count, variadic_index))`;
  * the variadic slot itself is left EMPTY -- that is what makes the substitution fire;
  * everything from `variadic_index` onward goes to a SEPARATE `variadic_operands` list and never
    enters the per-parameter loop.

That accounts for both behaviours at once: zero variadic args leaves the slot empty (reject), and
four variadic args also leaves the slot empty but routes them elsewhere (accept). My `max(...)`
put them in the per-parameter loop, which is why real code broke.

Not implemented this tick -- the corrected rule needs the variadic_operands split too, which is
more than a sizing change. Next tick, with varsurplus in the corpus from the start.

### Attempt 3 also wrong -- but the guard probe caught it in seconds, not a sweep

Implemented link 1 exactly as check_expr.cpp:6675-6699 describes: array sized to param_count, fill
only `[0, min(count, variadic_index))` for a variadic procedure, leaving the variadic slot empty.

    varsurplus            FULL-DIFFER          <-- caught immediately
    core/debug/trace      0 -> 48 errors       worse than the version the sweep caught

Reverted. Both packages back to 0, varsurplus back to FULL-MATCH.

**The probe did its job.** Attempt 2 needed a full 225-package sweep to expose; attempt 3 was
exposed by one probe in under a second. That is the entire return on adding varsurplus before
touching the code.

### The mechanism, now understood -- and it explains why all three attempts failed

Parameters are checked IN ORDER, and earlier bindings change how later ones resolve:

  * `append(&cmd, "prog", ...)` -- parameter 0 is `^$T/[dynamic]$E`. In the pass where
    modify_type is TRUE, matching it against `^[dynamic]string` BINDS E = string. By the time
    parameter 1 (`..E`) is checked, `check_type` on the rewritten slice node yields `[]string`,
    which is NOT polymorphic. So `is_type_polymorphic_type` is false, determination is never
    attempted for the variadic slot, and its emptiness is harmless. C++ accepts.

  * `grpC(&d)` in the group scoring path -- modify_type is FALSE, so parameter 0 does NOT bind E.
    Parameter 1's slice stays `[]$E`, IS polymorphic, determination IS attempted, the empty slot
    becomes an invalid operand, and the instantiation fails. C++ rejects.

**Same code, opposite outcomes, decided entirely by whether an earlier parameter bound the
variable.** Every attempt of mine tried to make the variadic slot's treatment unconditional --
pad it, size it, empty it -- and each broke one side or the other, because the correct behaviour
is not a property of the slot at all. It is a property of what parameter 0 did first.

That also retroactively explains link 2: forcing the polymorphic test on the variadic arm is only
correct if the port's `check_type(ctx, inner_type_expr)` resolves an ALREADY-BOUND `$E` to its
binding, exactly as C++'s does. Whether it does is unmeasured, and is the next thing to check --
before any further attempt.

Three attempts, three reverts, one mechanism finally understood. The item stays open with a much
sharper question than it started with: does the port's check_type resolve a bound polymorphic
variable inside an ellipsis element type?

### Link 2's precondition HOLDS -- measured

Instrumented the port's variadic arm to print the ellipsis ELEMENT type as `check_type` returns
it, tagged by the parameter list's own position:

    grpC m.odin:2  nops=1  inner=int  poly=false     <-- E RESOLVED to its binding
    grpC m.odin:2  nops=1  inner=$E   poly=true      <-- same call, other pass: unbound
    grpC m.odin:2  nops=0  inner=$E   poly=true      <-- generic declaration check

**The port's `check_type` DOES resolve an already-bound `$E` inside an ellipsis element type**, so
link 2 -- running the shared `is_type_polymorphic` test on the variadic arm -- would produce
exactly C++'s split: `true` in the passes where nothing bound E, `false` in the pass where
parameter 0 bound it. The precondition I flagged as unmeasured last tick is satisfied. Link 2 is
valid.

Note the two `nops=1` rows for the SAME parameter with opposite outcomes. That is the two-pass
structure made visible: first pass `no_polymorphic_errors = true` leaves `$E`, second pass clears
the flag and binds `int`. It is the clearest single piece of evidence for the mechanism described
above.

So the failure of attempt 3 is isolated to **link 1's fill rule**, not link 2 and not link 3.
Something about sizing to param_count and leaving the variadic slot empty is wrong for the port
even though it is what C++'s code says -- most likely because the port's per-parameter loop and
C++'s do not agree on what an empty slot means further down, or because the port lacks C++'s
separate `variadic_operands` path entirely and the surplus arguments have nowhere else to go.

Next: measure what the port does with arguments past the variadic index today -- does any
equivalent of C++'s `variadic_operands` slice exist? If it does not, link 1 cannot be ported as a
sizing change at all, and the item needs re-scoping rather than a fourth attempt.

## #260 last item RE-SCOPED: the group path has a different control shape, not a wrong size

Answered the scoping question: does the port have C++'s `variadic_operands` split?

    check_expr.odin:10316-10444    variadic_operands: [dynamic]Operand    -- the SINGLE-call path
                                                                             has it
    check_proc_group.odin          "variadic_operands" appears ONCE, in a COMMENT, and nowhere
                                   in the code

So the port's GROUP path has no variadic split at all. It handles variadics with a saturating
parameter index instead (check_proc_group.odin:858-861):

    param_index := i
    if pt.variadic && pt.variadic_index >= 0 && i >= int(pt.variadic_index) {
        param_index = int(pt.variadic_index)      // every surplus argument re-scores the
    }                                             // SAME variadic parameter

C++ uses two arrays: `ordered_operands` sized to param_count with an empty variadic slot, plus a
separate `variadic_operands` slice for everything past variadic_index.

**That is why all three of my attempts failed.** I kept adjusting the SIZE of the port's single
array to make it behave like C++'s two-array structure. It cannot: index saturation and array
splitting are different control shapes, and no sizing rule reconciles them. Attempt 1 left the
variadic slot unvisited, attempt 2 fed it a surplus argument, attempt 3 left it empty and broke
the saturating loop's assumption that every index has an operand.

### Re-scoped

Closing the zero-vararg under-rejection properly means restructuring
`check_call_arguments_internal`'s variadic handling into C++'s two-array form -- `ordered_operands`
+ `variadic_operands` -- so that an unsupplied variadic slot can exist as an empty entry while
surplus arguments live elsewhere. That is a rewrite of the group path's argument marshalling, not
a patch. Links 2 and 3 are correct and already cited; they are blocked on link 1 being restructured
rather than resized.

Recorded as re-scoped rather than attempted a fourth time. Three reverts is enough evidence that
the shape, not the arithmetic, is what is wrong.

### What #260 delivered

  Closed:   builtin arity prologue (close-paren + expr_to_string name); #force_inline guard;
            5 type-intrinsic messages + non-abandoning recovery; or_return note + an invented
            leniency arm removed; two union continuation blocks that the same-position merge was
            swallowing; duplicate-type-case expr/position/break; proc-group duplicate scoring;
            proc-group wrong-array index (which the duplicate had been masking).
  Open:     the zero-vararg group under-rejection (re-scoped above) and the overload-list
            ordering residual on p_ap1.
  Byproducts: probes typeintrin, ctypemistake, varsurplus; upstream findings #263 and #264;
            the C++-side instrumentation technique; the n>=60 rule for intermittent rates.

## Overload-list ordering: FIXED (check_expr.cpp:7378-7404)

C++'s candidate filter removes with `array_unordered_remove`, which swaps the LAST element into
the vacated slot and does NOT advance the index. The surviving order is therefore a PERMUTATION of
the original, and that permutation is exactly what "Did you mean one of the following overloads?"
prints.

The port walked the list in REVERSE with `ordered_remove`, preserving the original order. Same
membership, different sequence -- so every overload list whose group had a candidate filtered out
printed in a different order from C++.

A second divergence in the same loop: C++ KEEPS non-procedure entries (`proc_index++; continue;`).
The port removed them. That is a membership difference, not just ordering.

Both corrected: forward index, `unordered_remove`, no advance on removal, non-procs retained.

Verified: corpus 56/56 FULL-MATCH (up from 55 -- varsurplus joined and this closed the `make`
ordering), vet clean, core/debug/trace and core/rexcode/ir/wasm still 0 errors, partitioned sweep
193 stable packages with 0 error-count and 0 diagnostic-text differences, totals 463 == 463.

Note the sweep shows no text differences from the ordering itself: no package in the 225 has a
FAILING proc-group call, so none of them prints an overload list. The sweep proves no regression;
the probe proves the improvement. **Neither instrument alone would have been sufficient** -- the
probe cannot show tree-wide safety, and the sweep cannot see a diagnostic no package emits.

builtin_arity's residual is now only the append under-rejection (re-scoped) and its cascade.

## #149 CANNOT BE CONFIRMED AS FRAMED -- "45 sites" is not supported by measurement

The task says "C++ names the offending type/expression, the port stops at the category -- 45 sites
enumerated". The enumeration itself did not survive the /tmp wipe; only the count did. Rather than
trust the number, I rebuilt a detector (now `.claude/tools/msgpair.py`) that extracts every
diagnostic format string from both compilers and reports C++ messages whose text, minus a trailing
operand clause, exactly matches a port message.

Result: **9 candidates, not 45.** And on inspection most are NOT defects:

    message                                C++ has bare?  C++ has "got"?  port has both?
    Expected an integer type for '%s'          -              yes             yes
    Expected a bit_set type for '%s'          yes             yes             yes
    Extra initial expression                  yes             yes             yes
    Array count must be a constant integer    yes             yes             yes
    '%s' expected a simd vector type          yes             yes             yes
    Expected a type for the argument '%s'     yes             yes             yes

C++ ITSELF carries both a bare and an operand-bearing variant of these, at different call sites --
and so does the port. So a port site emitting the bare form is faithful whenever it corresponds to
C++'s bare site. Deciding that requires comparing CALL PATHS, which string matching cannot do.

**#149 as written would have had me "fixing" faithful messages.** The remaining honest content is:
for each of the 9 candidate pairs, does each individual port call site correspond to the C++ site
with the same variant? That is a per-site audit of ~18 locations, not 45, and most will likely come
back faithful given the pattern above.

Retained the detector rather than the conclusion. Its docstring carries the caveat prominently,
because the tool's output reads like a defect list and is not one.

Also note what this says about stale task text: the count outlived the evidence for it. Several
message-fidelity fixes have landed since #149 was filed (#196, #205, #226, #232, #240, and this
session's #258/#259/#260 work), any of which could have closed sites silently. **A task whose
evidence was lost should be re-derived before it is worked, not worked from its summary.**

### #149 first genuine site fixed -- 1 of 9, and the other 8 need per-site audits

`Expected an integer type for '%s'` is the one candidate where C++ has **no bare variant at all**:
all three C++ sites (check_builtin.cpp:6302, 6345, 6520) carry ", got %s". The port had one correct
site (check_builtin.odin:1316) and one bare site (5911) whose guard
`!is_type_integer(x.type) || is_type_untyped(x.type)` is character-for-character C++'s at 6518.
Unambiguous defect; fixed.

Detector now reports 8 candidates, down from 9 -- so it tracks progress as well as finding work.

The remaining 8 all have a bare variant in C++ too, so each needs its call site matched against
C++'s before anything is changed. That is roughly 16 site comparisons. The pattern so far suggests
most will be faithful, and the value of the audit is as much in CLOSING the suspicion as in finding
defects.

Verified: corpus 56/56 FULL-MATCH, vet clean.

**Note the asymmetry that made this one safe to fix without a probe:** "C++ has no bare variant
anywhere" is a property of the whole C++ source, checkable by grep, and it makes every bare port
site a defect regardless of call path. Where C++ has both variants, no amount of grepping helps and
the call path is the only evidence. Sorting candidates by that test first is the cheap way to
separate the certain from the merely suspicious.

## #149 site 2 of N: simd_extract_lsbs/msbs (progress#242)

`check_builtin_simd.odin:check_builtin_simd_extract_bits` emitted the BARE
`'%s' expected a simd vector type` where C++ `check_builtin.cpp:1430` carries `, got '%s'`.
Fixed; also corrected a drifted citation at the same site (1248-1254 -> 1443-1446).

**How it was found, and the method that matters.** The simd family has ~34 bare sites in each
compiler and a handful of got-form sites. Counting them gave C++ FIVE got-sites and the port FOUR
-- an asymmetry of one. That asymmetry, not any per-site reading, located the defect.

**The shape-matching trap.** My first guess paired C++:1430 with the port site of identical SHAPE
(same guard, same args[0], same immediate return). Wrong builtin entirely: C++:1430 is
`simd_extract_msbs`, the port site was `sums_of_n`. In a family where 34 sites share one shape,
shape is worthless as an identity. **Match by builtin id through the dispatch table, never by
code shape.** A second misstep followed the same way: grepping the message text landed inside
`reduce_bitwise` (Reduce_And/Or/Xor), which is a DIFFERENT builtin whose bare form is correct.

**The bare neighbour is load-bearing.** C++ 1375-1392 (reduce_and/or/xor) is deliberately bare in
its simd-vector test and got-form in its element test. The port matches it exactly. The probe
asserts BOTH: `simd_reduce_or` must stay bare while `simd_extract_msbs` gains the type. Guarding
only the fixed site would have left a later "make the family consistent" edit unblocked.

**Probe `simdmsb` validated in both directions**: FULL-DIFFER on st_t494 (pre-fix), FULL-MATCH on
st_t495 (post-fix), with the reduce_or line matching in both.

**#149 count correction restated.** The task title still says "45 sites enumerated". That figure
was never supported. The detector finds 9 candidate pairs; 2 are now fixed and verified, and the
remainder must each be resolved by dispatch-table identity, because C++ carries BOTH variants
across this surface and grep alone cannot separate faithful from defective.

## Sweep: integer-type fix (t493 -> t494) CLEAN

stable=196, error-count differences 0, stable totals 518=518. The 5 reported
"diagnostic-text differences" are entirely crash-marker lines (`double free or corruption`,
`timeout: the monitored command dumped core`) across 5 packages -- the known #141 intermittent
port-only crash set reshuffling between runs. No checker diagnostic changed.

## #149 audit: 6 of 8 candidates dispositioned (progress#243)

Cheap test applied first -- "does C++ have a bare variant of this message ANYWHERE?" -- then
dispatch-table identity for the survivors.

FAITHFUL (C++ has BOTH variants; the port reproduces BOTH branches):
  - `Array count must be a constant integer`  C++ check_type.cpp:2829 got / 2871 bare
                                              port check_type.odin:6505 got / 6573 bare
  - `Extra initial expression`                C++ checker.cpp:4692 got / 4695 bare
                                              port check_collect.odin:635 got / 638 bare
  - `Expected a bit_set type for`             already dispositioned in-tree: the port folds C++'s
    three handlers into one and gates the ", got %s" tail on `id == .Type_Bit_Set_Backing_Type`,
    with a comment recording the oracle confirmation. Correct.
  - `Expected a type for '%s'` (decl_helpers) C++ counterparts checker.cpp:3808/4161 are BARE.
    The detector paired the port's bare sites against an UNRELATED C++ got-form in check_builtin.
  - `Expected a type, got %s`                 port HAS the got-form at check_expr.odin:7390,
    matching C++ check_expr.cpp:12442 (TypeCast). The detector's port-side hit
    (check_decl_helpers.odin:2091) is a different site -- see OPEN below.

FIXED: simd extract_lsbs/msbs (progress#242, above).

**#260 re-verified, not over-applied.** C++ has exactly ONE got-form `Expected a type for '%.*s'`
(check_builtin.cpp:7077) while the port now has TWO (check_builtin.odin:4723, 4885). That looked
like an over-application from my own #260 batch. It is not: C++:7071 is a SHARED case listing
`type_has_nil` alongside every `type_is_*` simple-boolean builtin, so one C++ site covers what the
port implements as two handlers. Same message, same condition, different decomposition.

## OPEN (2), both UNREPRODUCED -- do not record as dispositioned

1. **check_proc_group.odin:256 reports at `call_node`; C++ check_expr.cpp:6958 reports at
   `o->expr`.** A POSITION divergence, not a message one. Probe `typeargpos` could not reach it:
   the site sits behind `show_error`, which is FALSE during candidate scoring. A group call with
   several live candidates fails earlier with "No procedures or ambiguous call". Reaching it needs
   a group where exactly ONE candidate survives into the error-reporting pass.

2. **check_decl_helpers.odin:2091 `error(type_expr, "Expected a type")` may be INVENTED.** Its own
   comment says the C++ equivalent is just `e->type = check_type(...)`, and C++'s check_type
   already reports and returns t_invalid -- an extra bare diagnostic would be a spurious cascade
   line. `g: Nope.Missing` did NOT fire it (both compilers printed only the field error), so the
   guard's trigger condition is still unknown. Different defect class from #149 (invented, not
   truncated).

**Method note.** Probe `typeargpos` came back FULL-MATCH on the first attempt and it meant NOTHING
-- neither target path had executed. A FULL-MATCH is only evidence once the oracle's actual output
is read and shown to contain the diagnostic under test. Reading it is what revealed the direct-call
path emits an entirely different message ("Expected a type to assign to the type parameter").

## #266: 253 lines of invented, never-called helpers at the tail of check_decl_helpers.odin (progress#244)

Found while chasing open finding #2 from progress#243 (the suspected invented
`error(type_expr, "Expected a type")`). The answer was better than "invented diagnostic": the
whole enclosing procedure is dead, and so are its ten neighbours.

**Deleted, lines 1967-2219** -- a contiguous block of 11 procedures with ZERO call sites anywhere
in the package:

    destroy_decl_info      decl_info_set_parent   decl_info_is_nested   decl_info_get_entity
    check_init_variable_internal   check_variable_type   check_variable_foreign
    check_const_value      open_scope_with_flags  close_scope           scope_set_flags

**Every C++ citation in the block is fabricated.** They are suspiciously round ranges
(190-200, 210-220, 230-240, 300-350, 380-410, 430-460, 550-590, 670-690, 700-710, 720-730)
and none matches its claimed subject. Spot-checked four:
  - `check_decl.cpp:380-410` (cited by check_variable_type) is `remove_type_alias_clutter`
  - `check_decl.cpp:1660`    (cited by check_variable_type) is the non-unique-linking-name
                             error for PROCEDURES
  - `check_decl.cpp:190-200` is entity-variant memcpy in the polymorphic path
  - `check_decl.cpp:700-710` is ProcGroup addressing inside C++'s real check_init_variable
  - `check_decl.cpp:430-460` is enum-field cloning
The four procedures immediately AFTER the block (check_objc_methods, check_foreign_procedure,
init_core_load_directory_file, init_core_source_code_location) are live and correctly cited --
the rot is bounded to this block.

Verified: vet rc=0, build OK, corpus 58 FULL-MATCH / 2 FULL-DIFFER (unchanged -- the 2 are
append_noval and builtin_arity, still blocked on #260's re-scoped item). Sweep t496 running.
Backup at $S/check_decl_helpers.odin.bak.

**Why this matters beyond the line count.** `check_variable_type` polluted the #149 detector as a
bare-message candidate, and cost a probe cycle chasing a trigger condition that cannot exist.
Dead code does not just sit there -- it generates false leads for every future audit.

## New instrument: .claude/tools/deadproc.py

Lists package-level procs never referenced outside their own definition, with comments and string
literals stripped first (without stripping, a proc whose doc-comment repeats its own name hides).
Raw output is 165 names and is NOT a defect list -- it includes public API
(check_package_from_path, generate_documentation, odin_doc_write) and name-wired handlers
(syntax_error). **The signal is a CONTIGUOUS RUN of dead procs**, which is what an invented block
looks like; scattered singletons are usually API. Triage by that shape, then check citations.

## Sweep t494 -> t495 (simd fix) CLEAN

stable=194, error-count differences 0, totals 494=494. All 6 "diagnostic-text differences" are
crash markers (`realloc(): invalid old size`, `double free or corruption`, `timeout: dumped core`).
Unstable package counts across the last three sweeps: t493=6, t494=3, t495=7 -- bouncing, not
trending, consistent with #141's ~17% intermittent. A single sweep cannot resolve a crash-rate
change; do not read one asymmetric run as a regression.

## #267: inherited link_prefix/link_suffix was never dropped -- real over-rejection (progress#245)

**Symptom.** The port rejected `core/sys/darwin/CoreFoundation/CFString.odin:179` with
"'link_name' and 'link_prefix' cannot be used together"; the oracle accepts the file (rc=0, no
output). The idiom is `@(link_prefix="CF")` on a FOREIGN BLOCK plus `@(link_name=...)` on one
member inside it -- common across core/sys/darwin.

**Root cause.** C++'s `check_decl_attributes` (checker.cpp:4638-4650) ends with an epilogue the
port never had:

    if (ac->link_prefix.text == original_link_prefix.text) {   // still the INHERITED one
        if (ac->link_name.len > 0) { ac->link_prefix = {}; }   // decl set its own name -> drop it
    }                                                          // (same for link_suffix)

So an *inherited* prefix is silently discarded when the declaration supplies its own link_name;
only a prefix set on the SAME declaration reaches handle_link_name's conflict check. The port
inherited the prefix (correctly) but never dropped it, so every such declaration collided.

**The comparison is by DATA POINTER, not contents** (`.text ==`). A declaration that re-states the
same prefix text is an override -- a genuine conflict -- not an inheritance. Ported as
`raw_data(ac.link_prefix) == raw_data(original_link_prefix)`; a value compare would wrongly
forgive that case. The snapshot is also taken AFTER the `len(attributes) == 0` early return,
exactly as C++ does, so an attribute-free declaration keeps its inherited prefix (it needs it to
build the symbol name).

**Probe `linkpfx`, validated both directions.** Pre-fix (t496) the port emitted THREE errors where
the oracle emitted ONE; post-fix (t497) FULL-MATCH on that single genuine conflict. The probe
deliberately covers all four cases: inherited prefix + own link_name (accept), no link_name
(inherit), prefix AND link_name on the same declaration (still reject), and the suffix variant.
core/sys/darwin/CoreGraphics now reports errors=0, matching the oracle.

Corpus 59 FULL-MATCH / 2 FULL-DIFFER (unchanged known pair). Sweep t497 running.

**Why the sweep never caught this.** CoreGraphics is in the excluded unstable/crashed set, so
swdiff dropped it before comparing -- an over-rejection can hide indefinitely behind an
intermittent crash in the same package. The lead came from a CRASH-MARKER line number shifting in
an unrelated diff. **Packages excluded as unstable are unmeasured, not clean**; they need
occasional direct oracle-vs-port comparison.

## Sweep t495 -> t496 (dead-helper deletion) NEUTRAL, as intended

0 error-count differences, totals 494=494. The single non-crash text difference was
self-referential: a port assertion's own line number moving 2235 -> 1982, exactly the 253 deleted
lines. The `assert(t.kind == .Named)` in check_objc_methods is FAITHFUL -- C++ has the identical
GB_ASSERT and comment at check_decl.cpp:1057 -- so its intermittent firing is a #141-family
symptom, not an invented invariant.

## #267 VERIFIED by sweep t496 -> t497

error-count differences: exactly 3, all reductions, all darwin:
  core/sys/darwin/CoreFoundation 1 -> 0
  core/sys/darwin/CoreGraphics   1 -> 0
  core/sys/darwin/Security       2 -> 0
stable totals 518 -> 514 (-4, matching the four removed diagnostics exactly).
All three confirmed against the oracle directly: oracle_errors=0, port_errors=0 for each.
Every remaining text difference is a crash marker, except the port assertion's own line number
moving 1982 -> 2005 (my 23-line epilogue). No other package changed.

## MEASUREMENT GAP now being closed: the sweep's exclusions are UNMEASURED, not clean

#267 hid for the entire project behind swdiff's exclusion rule. The rule is right in itself --
a capped (truncated) or crashed diagnostic list cannot be text-compared -- but the consequence
was never stated: 22 capped + ~5-9 unstable packages out of 225 have NEVER been compared to the
oracle at all. That is ~12% of the corpus permanently invisible.

New instrument `.claude/tools/excluded_cmp.sh`: for each excluded package, run BOTH compilers
directly and print the two error counts. Counts survive truncation well enough to expose a gross
divergence (oracle=0, port=capped is unmissable) even when a text diff is impossible.
All 22 capped packages are under core/rexcode/isa.

## #268: is_valid_type_for_load was a "simplified" reimplementation -- ~34 spurious errors x 22 packages (progress#246)

Found immediately by the new excluded-package comparator (see #267's measurement gap). All 22
capped packages reported oracle=0-2 errors vs port=34-36. Not 22 defects -- ONE, cascading.

**Root cause.** C++ `is_valid_type_for_load` (check_builtin.cpp:2116-2136) delegates the element
test to `is_type_load_safe`, a RECURSIVE predicate that accepts bool/numeric/rune basics, bit_sets
(via underlying), structs whose fields are all load-safe with size > 0, and unions likewise, while
rejecting pointer/multipointer/slice/dynamic-array/proc/soa-pointer elements. The port inlined a
three-way test instead:

    if is_type_integer(elem) || is_type_float(elem) || is_type_boolean(elem) { return true }

so every slice-of-STRUCT, slice-of-enum, slice-of-rune and slice-of-bit_set was rejected.

**The port already had a faithful `is_type_load_safe`** at types.odin:2231 -- complete with the
bit_set underlying arm, struct-field recursion, union variants and the array-like panic. Nothing
called it. The fix is to delegate, exactly as C++ does; no new predicate was needed.

**The cascade is why the count was ~34 and near-identical across unrelated packages.**
`#load("tables/arm32.encode_forms.bin", []Encoding)` failed, so the operand kept its `[]u8`
default (check_builtin.cpp:2178 sets t_u8_slice first and only overwrites on success). Every
downstream use then mismatched against the real element type: "'r' of type 'u8' has no field
'start'", "Cannot assign ... of type 'u8' to 'Decode_Index'", "Undeclared name: k", 16 of the 34
being that one shape. Nested packages (arm32, arm32/tablegen, arm32/tablegen/generated) all
reported 34 because they share the same loaded tables.

Also fixed at the same site: the message dropped BOTH the comma after "string" and the ", got %s"
clause C++ carries (check_builtin.cpp:2191) -- a #149-family truncation. And the citation was
drifted (1772-1814 -> 2116-2136).

Verified: vet rc=0, core/rexcode/isa/arm32 34 errors -> 0, matching oracle=0 exactly.
Corpus 59 FULL-MATCH / 2 FULL-DIFFER (unchanged). Full excluded-comparison + sweep t498 running.

**The lesson #267 predicted, confirmed within one tick.** The exclusion rule that hid #267 was
hiding a second, much larger defect in the same blind spot. ~12% of the corpus had never been
compared. When a measurement instrument excludes inputs, the excluded set is where defects
accumulate -- precisely because nothing looks there.

## #268 VERIFIED, and far larger than the capped set suggested (sweep t497 -> t498)

18 additional packages -- NOT capped, fully inside the sweep's STABLE set -- also dropped to zero:
  arm64, arm64/tablegen, arm64/tablegen/generated            31 -> 0 each
  mos6502 x3  28 -> 0     mos65816 x3  24 -> 0
  ppc x3      31 -> 0     ppc_vle  x3  20 -> 0
  riscv x3    32 -> 0
stable totals 514 -> 16, with ZERO increases anywhere. All 22 formerly-capped packages now match
the oracle count-for-count (oracle=0-3, port=0-3, verified pairwise by excluded_cmp.sh).

## STRUCTURAL MEASUREMENT DEFECT: swdiff is a REGRESSION detector, not a PARITY detector

This is the important finding of the tick, bigger than #268 itself.

`swdiff.py` compares PORT-run-N against PORT-run-N+1. It answers "did my change break anything?"
It does NOT answer "does the port agree with the oracle?" Those 18 packages carried a stable
20-32 spurious errors EVERY run for the entire project. swdiff never flagged them -- not because
they were excluded (they were not; they were STABLE and compared every time) but because
**a constant divergence produces no delta**. The instrument is blind by construction to any
over-rejection that does not fluctuate.

So the corpus had THREE blind regions, not one:
  1. capped packages      -- excluded outright (#267's lesson, 22 packages)
  2. crashed/unstable     -- excluded outright (~5-9 packages, where #267 itself hid)
  3. STABLE-but-divergent -- compared, but only against the port's own past (18+ packages)
Region 3 is the largest and was the least suspected, because those packages appear in every
sweep's "STABLE" count and so read as healthy.

`.claude/tools/excluded_cmp.sh` is misnamed for what it turned out to be: it is the ONLY
oracle-vs-port instrument at package granularity. Now running over all 225 packages, not just the
excluded ones. cmpfull.py compares against the oracle but only over .claude/probes (hand-written
inputs); the 225-package corpus had NO oracle comparison at package scale until now.

**Rule.** A differential test against your own past output cannot find a defect you have always
had. Every measurement stack needs at least one instrument anchored to the REFERENCE, not to
history, and it must cover the whole corpus -- not the subset that happens to be comparable.

## #270: syscall/syscall_bsd platform gate never ported -- the only mismatch in the first full parity run (progress#247)

The first corpus-scale oracle-vs-port run (225 packages) found exactly ONE disagreement:
`core/sys/freebsd` oracle=31, port=0. An UNDER-rejection -- the opposite direction from #267/#268.

All 31 were the same message: `'syscall_bsd' is not supported on this platform (linux)`.
The port has no such message anywhere; `check_builtin_syscall` was a reimplementation, not a port.

**What C++ actually does** (check_builtin.cpp:6669-6716 syscall / 6720-6766 syscall_bsd):

    max_arg_count = 32                     // NOT 7
    switch (os) {
      case <supported>: switch (arch) { case <supported>: max_arg_count = 7; break; } break;
      default: error("'%s' is not supported on this platform (%s)"); break;   // reports, continues
    }
    if (args.count > max_arg_count) error(ast_end_token(call), "'%s' has a maximum of %td ...");

  syscall     -> darwin, linux            + i386/amd64/arm64
  syscall_bsd -> freebsd, netbsd, openbsd + amd64/arm64   (NO i386)

**Five divergences in one procedure:**
 1. No platform gate at all -- the whole "not supported on this platform" family was missing.
 2. `> 7` hardcoded, where C++ defaults to 32 and narrows to 7 only on a supported OS+arch. On an
    unsupported platform C++ still permits 32 args after reporting.
 3. Wrong max-arg message and position ("expects at most 7 arguments" at the call node, vs C++'s
    "has a maximum of %d arguments on this platform (%s), got %d" at the closing paren).
 4. `check_assignment` instead of convert_to_typed + is_type_uintptr, so the per-argument message
    was a generic assignment error rather than "Argument %d must be of type 'uintptr', got %s".
 5. An INVENTED minimum-argument check with an early return. builtin_proc_infos already has
    arg_count=1/variadic=true, so the shared prologue enforces it -- dead code of exactly the
    class #260 removed.
 Plus: every error path returned early. C++ reports and CONTINUES, always setting mode/type.

Also reproduced faithfully: C++ calls convert_to_typed twice on each loop argument, the first
guarded by `x.mode != Invalid` and the second unguarded (check_builtin.cpp:6681-6683). Left as-is
with a comment rather than folded, since folding changes behaviour when the operand is invalid.

Verified: vet rc=0, core/sys/freebsd oracle=31 / port=31 and the 31 diagnostics are
TEXT-IDENTICAL (sorted diff, empty). Corpus 59 FULL-MATCH / 2 FULL-DIFFER unchanged.
Full parity run + sweep t499 launched.

## The parity instrument earned its place immediately

First run: 225 packages, 1 mismatch, and that mismatch was a whole missing diagnostic family that
had been invisible to every sweep in the project's history -- because the port's count was a
*stable* 0 and swdiff only reports change. Corpus-scale parity is now 225/225 by error count.
Next refinement: compare message TEXT per package, not just counts (freebsd was checked by hand
this tick; it should be automatic).

## #270 VERIFIED, and the error cap is now unreachable corpus-wide (sweep t498 -> t499)

error-count differences: exactly ONE, `core/sys/freebsd 0 -> 31` -- the intended gate.
Full parity run: 225/225 packages agree with the oracle by error count, zero mismatches.

Side effect worth recording: **capped went 22 -> 0**. No package in the 225-package corpus now
hits the error cap, and STABLE rose to 213. The cap was never a corpus property; it was #268's
cascade. swdiff's exclusion set has shrunk to the intermittent-crash packages alone.

## Newly-visible (not new) ordering nondeterminism in core/rexcode/isa/*/tools

With capped=0, the tools packages entered the compared set for the first time and immediately
showed `Redeclaration of 'main'` pairs swapping which file is PRIMARY and which is the `at`
continuation, between two port runs. Five consecutive port runs and three oracle runs agree on the
first such diagnostic, so this is not a simple flake -- these packages contain MANY duplicate
`main` definitions and the pairing varies. Belongs to the #52/#219 iteration-order family, not to
anything changed this tick. Deliberately NOT chased further this tick: it is an ordering question,
and the instrument for ordering is flake.sh, not parity.sh.

## .claude/tools/parity.sh -- the instrument promoted to first class (#269)

Replaces the ad-hoc excluded_cmp.sh. For every package it compares oracle vs port on BOTH error
count AND sorted diagnostic TEXT, reporting COUNT/TEXT mismatches separately.

Text is compared as a SORTED MULTISET on purpose: a pure ordering difference between the two
compilers must NOT register here. Ordering is swdiff/flake.sh's concern; conflating the two is
what made the rexcode ordering noise look like a parity failure at first glance.

Run parity.sh AND swdiff after every change. They answer different questions and neither
subsumes the other:
  swdiff    -- "did this change alter port behaviour anywhere?"     (anchored to history)
  parity.sh -- "does the port agree with the oracle?"               (anchored to the reference)

## #271: text-parity is 223/225; the 2 residuals are a PORT-SIDE RACE on redeclaration order

First text-level parity run: 225 packages, count_mismatches=0, text_mismatches=2
(core/rexcode/isa/arm32/tools and .../ppc_vle/tools). Both are the same shape -- WHICH of two
duplicate `main` declarations is named as the redeclaration, and which becomes the original:

  oracle: gen_mnemonic_builders.odin(60:1) Error: Redeclaration of 'main' in this scope
  port  : dump_verify_input.odin(29:1)     Error: Redeclaration of 'main' in this scope

**Measured, not assumed:** port 4 runs -> 3x gen_mnemonic_builders, 1x dump_verify_input.
Oracle 3 runs -> 3x gen_mnemonic_builders. So the ORACLE IS DETERMINISTIC and the PORT IS NOT.
This is not a fixed ordering divergence to be corrected by matching C++'s sort; it is a race that
*usually* lands on the right answer.

Reading: whichever file's `main` is inserted into the package scope first becomes the original and
the other is reported. In the parallel checker that insertion order is decided by thread
scheduling. Belongs with #41 (race on procs_to_check) / #141 (port-only crashes) rather than with
#170's sort-TIMING dispositions -- those concluded C++'s ORDER was reproducible, which is exactly
what the port fails to be here.

Why it surfaced only now: these packages were `capped` until #268, so they had never been compared
against anything. Two blind spots stacked -- the cap hid the package, and swdiff's
history-anchoring would have hidden a stable divergence even after the cap lifted.

NOT chased further this tick. Next step is a run-count experiment (n>=20 per side, per LEDGER's
own rule that n=20 separates always from never but cannot resolve rates) to establish the port's
rate, then find the insertion site.

## #271 measured and localised, ROOT CAUSE NOT YET ESTABLISHED (progress#248)

**Rate (n=25 per side, core/rexcode/isa/ppc_vle/tools):**
  PORT   : 21x gen_mnemonic_builders.odin(60:1),  4x dump_verify_input.odin(29:1)   -> 16% divergent
  ORACLE : 25x gen_mnemonic_builders.odin(60:1),  0x other                          -> deterministic

**Mechanism located.** `redeclaration_error(name, prev, found)` reports at `prev.token` and cites
`found.token.pos`; callers pass (name, NEW_entity, existing). So the file named in the PRIMARY
line is whichever `main` was inserted into the package scope SECOND. The port's winner varies, so
its package-scope insertion order varies.

Entity collection runs on a thread pool in the port
(`check_collect_entities_all_worker_proc`, check_collect.odin). File ORDER is not the culprit:
collection iterates `sorted_files(pkg.files)` and additionally `slice.sort_by`s on basename before
dispatch.

**Open question, deliberately not guessed at.** C++ has the SAME shape -- `add_entity`
(checker.cpp:2089-2093) calls `scope_insert` and reports the redeclaration inline, and C++'s
collection is also a worker-pool (`check_collect_entities_all_worker_proc`, cited at
checker.cpp:5770-5775). Yet C++ measured 25/25 deterministic. So "the port is parallel and C++ is
not" is NOT established and must not be assumed. Candidate explanations still to test:
  (a) C++ gates the worker pool on thread_count / package size and falls back to serial here;
  (b) C++ file-scope entities land in the FILE scope during the parallel phase and only reach the
      package scope in the sequential exported_entity_queue drain (checker.cpp:2044 enqueue /
      5780 dequeue), making the collision order deterministic;
  (c) C++ is racy in principle but the window is never hit at n=25.
Distinguishing (a)/(b)/(c) is the next step -- by instrumenting the ORACLE, per the standing rule
that a question about what C++ does is answered by instrumenting C++, not by reading it.

Note (c) cannot be dismissed by n=25: that n separates "always" from "never" but cannot bound a
rate below ~10%. If the next step needs to rule (c) out, it needs n>=60 on the oracle.

## #271 continued: (a) and (c) RULED OUT; architecture confirmed present in both (progress#249)

**(c) ruled out.** Oracle n=60: 60/60 `gen_mnemonic_builders.odin(60:1)`. Against the port's
measured 4/25 (16%), the oracle being merely "lucky" is no longer tenable. The oracle is
deterministic here; the port is not.

**(a) ruled out.** C++ does NOT gate the collect worker pool. `check_collect_entities_all`
(checker.cpp:6093-6108) allocates per-thread data and calls `thread_pool_add_task` for EVERY file
unconditionally, then `thread_pool_wait()`. No thread_count or package-size fallback.

**(b) architecture confirmed -- but present in BOTH, so it is not by itself the answer.**
C++: parallel collect ENQUEUES into `pkg->exported_entity_queue`; the package-scope insert (and
therefore redeclaration_error) happens later in `check_export_entities_in_pkg`
(checker.cpp:6111-6123), `while (mpmc_dequeue(...)) add_entity(ctx, pkg->scope, ...)`.
C++ dispatches one task PER PACKAGE, so each package drains single-threaded.
Port: `check_export_entities` (check_import_export.odin:586) loops `for pkg in
sorted_packages(&c.info)` calling `check_export_entities_in_pkg` on the main thread -- also
single-threaded per package, and additionally ordered across packages.

So both compilers: parallel enqueue, serial per-package drain, insert order == QUEUE order.
The divergence must therefore be in the ENQUEUE order (or in something not yet examined), NOT in
the drain. Note C++ iterates `c->info.files` (an unordered map) when dispatching collect tasks and
is still deterministic, which is itself unexplained and worth not hand-waving past.

**Next step is instrumentation of the PORT, not more reading.** Log the dequeue sequence for
core/rexcode/isa/ppc_vle/tools across ~20 runs. Two outcomes, both decisive:
  - queue order varies  -> the race is in enqueue during parallel collect; fix there.
  - queue order stable  -> the race is elsewhere entirely and every theory above is wrong.
The port is rebuilt every tick anyway, so this costs nothing; instrumenting the ORACLE would need
a ~10min C++ rebuild plus a byte-identical restore of ./odin, and is not warranted until the port
side is known.

## #271 ROOT CAUSE FOUND: the enqueue order races, and C++'s effective order is ALPHABETICAL FILE ORDER (progress#250)

**Instrumented the port's drain** (temporary `DQ` log at the dequeue site, reverted after the
experiment; backup/restore via scratchpad, never git checkout). Dequeue order over 20 runs:

    16/20 : dump_verify_input.odin(29:1)  then gen_mnemonic_builders.odin(60:1)
     4/20 : gen_mnemonic_builders.odin(60:1) then dump_verify_input.odin(29:1)

So the QUEUE ORDER ITSELF VARIES -> the race is in ENQUEUE during parallel collect, exactly as
predicted. 4/20 = 20%, consistent with the 4/25 = 16% end-to-end rate.

**C++'s enqueue is equally parallel** -- checker.cpp:2229-2237 does `mpmc_enqueue` from inside the
collect worker, with bill's own comment "as multiple threads could be accessing this, it needs to
be wrapped". So C++ is not serialising here either. Its determinism is emergent, not structural.

**The decisive observation is WHICH order both compilers settle on.**
`redeclaration_error` names whichever entity is inserted SECOND. The oracle reports
gen_mnemonic_builders (60/60), so the oracle inserts dump_verify_input FIRST. Alphabetically
`dump_verify_input` < `gen_mnemonic_builders`. **C++'s effective publish order is sorted file
order** -- and the port's 16/20 majority case is the same order. The port is not using a different
rule; it is failing to hold the rule ~20% of the time under scheduling pressure.

**Fix direction (NOT yet implemented -- next tick).** Make the port's published order
deterministic and equal to sorted-file order. The port already sorts files at collect dispatch
(sorted_files + slice.sort_by on basename) and already drains packages sequentially in
sorted_packages order; only the queue's internal order is unpinned. Sorting each package's drained
entities by (file, token position) before insertion reproduces C++'s observed order exactly.

Note honestly: C++ gets this ordering as an EMERGENT property of its thread pool's FIFO dispatch,
not from an explicit sort. Adding an explicit sort to the port is therefore not a literal
transcription of C++ code -- it is reproducing C++'s observable behaviour, which is what
"100% parity for semantic analysis, including multi-threaded operation" requires. Recording the
distinction so a later reader does not mistake the sort for a citation-backed port.

## #271 FIXED: deterministic publish order in check_export_entities_in_pkg (progress#251)

The drain now collects the whole queue, sorts by (file basename, byte offset), then inserts.
Basename to match the collect dispatch's own comparator (check_collect.odin uses
filename_from_path); offset to preserve declaration order within a file. All files in a package
share a directory, so basename order and full-path order agree.

**Measured after the fix:**
  core/rexcode/isa/ppc_vle/tools  port 25/25 gen_mnemonic_builders.odin(60:1)   == oracle 60/60
  core/rexcode/isa/arm32/tools    port 15/15 (gen_mnemonic_builders 482, verify_against_llvm 479)
                                  == oracle 5/5, same pair in the same order
Before: 4/25 and 4/20 divergent respectively. Corpus 59 FULL-MATCH / 2 FULL-DIFFER unchanged.

**The comment at the site states plainly that this sort has NO C++ line to cite.** C++ reaches the
same order emergently through its thread pool's FIFO dispatch (checker.cpp:2229-2237 enqueues from
inside the parallel collect worker). A future reader auditing citations will find none here, and
the comment pre-empts the natural "this is invented, delete it" conclusion by recording the
measurement that motivated it. This is the correct handling for a behaviour-parity fix that is not
a code-parity fix -- the alternative, leaving the port 20% nondeterministic to stay
"literally faithful", would violate the actual objective.

**Method note.** The whole chain took five ticks and each step was an experiment, not a reading:
rate (n=25/60) -> eliminate (a) by reading dispatch, (c) by n=60 -> instrument the port's dequeue
(20 runs) to prove the queue order itself varies -> read WHICH order both settle on to recover the
rule. The rule (sorted-file order) was never stated anywhere in either codebase; it was recovered
from the oracle's behaviour. Reading C++ alone could not have produced it.

## MILESTONE: full corpus parity -- 225/225 packages, 0 count mismatches, 0 text mismatches

    parity.sh: PARITY-DONE packages=225 count_mismatches=0 text_mismatches=0

Every package in the 225-package corpus now agrees with the oracle on BOTH the number of
diagnostics and their exact sorted text. This is the first time that has been true, and it was
only measurable at all from progress#245 onward, when parity.sh was built.

Sweep t499 -> t500 confirms the change is precisely the intended one: 0 error-count differences,
stable totals 64 = 64, and the only diagnostic-text movement is the redeclaration pairs in
arm32/tools and mos65816/tools flipping from the racy order to the deterministic one that matches
the oracle.

**How much of this was invisible until the instruments existed.** Sequence over the last ~8 ticks:
  #267  over-rejection hidden behind an intermittent crash in the same package (excluded set)
  #268  ~34 errors x 22 capped packages, plus 20-32 x 18 STABLE packages, from ONE simplified
        predicate -- the stable ones invisible to swdiff because the divergence never changed
  #269  named the structural cause: swdiff is anchored to history, not to the reference
  #270  a whole missing diagnostic family (syscall platform gates), port count a stable 0
  #271  a 16-20% race, in packages that had never been compared to anything
None of these were findable by the measurement stack as it stood two hours ago. Four of the five
were long-standing, not regressions.

**Standing rule, now demonstrated rather than asserted:** run BOTH instruments after every change.
  swdiff    -- "did this change alter port behaviour anywhere?"  (anchored to history)
  parity.sh -- "does the port agree with the oracle?"            (anchored to the reference)
Neither subsumes the other. parity.sh found all five defects above; swdiff is what proves a fix
did not disturb the other 224 packages.

**Remaining known non-parity:** the 2 FULL-DIFFER probes (append_noval, builtin_arity), both
blocked on #260's re-scoped item -- the group path needs C++'s two-array variadic marshalling.
Those are hand-written probes, not corpus packages, so they do not appear in the 225/225 figure.
Corpus parity is not the same as full semantic parity and must not be reported as such.

## #260 last item: mechanism RE-DERIVED from scratch, with citations (progress#252)

Re-derived rather than worked from the summary, per the standing rule. The probes localise it
precisely: `append(&d)` -- one array argument, ZERO values.

    oracle: rejects at m.odin(4:2), "Given argument types: • ^[dynamic]int"
    port  : ACCEPTS line 4; its next error is line 5 (`append()`), where it prints
            "No given arguments"

So the port under-rejects the one-arg form. The "No given arguments" line belongs to `append()`
and is CORRECT there -- it is not evidence about line 4. (Earlier framing treated the empty
operand array as the line-4 defect; it is not.)

**Exact C++ mechanism** (check_expr.cpp:6666-6790, 6917-6935):
  1. `ordered_operands` is sized to `pt->param_count` (6666), NOT to the argument count.
  2. Positional args fill their slots; `variadic_operands` is the tail slice past
     `positional_operand_count` (6700).
  3. At the variadic slot with `vari_expand == false` and `variadic_operands.count == 0`
     (6771-6787), C++ synthesises a dummy operand: `mode = Value`, `expr = ident "nil"` at the
     call's position, and **`type = t_untyped_nil`**.
  4. That untyped-nil dummy is passed to
     `find_or_generate_polymorphic_procedure_from_parameters` (6933). For
     `append_elems :: proc(array: ^$T/[dynamic]$E, args: ..E)` the `..E` parameter cannot infer
     `E` from untyped nil, so generation FAILS, `pt` stays generic, and the
     ambiguous-polymorphic-variadic path rejects.

The rejection is therefore a CONSEQUENCE of feeding a deliberately un-inferable operand into
polymorphic generation -- not a separate arity rule. Three prior attempts failed because they
tried to express it as a count check (max(args,param_count); exact param_count; empty slot),
and counts cannot reproduce "poly generation must fail".

**DEAD CODE WARNING -- do not port.** `dummy_argument_count` (declared 6745, incremented 6785 and
6822) is NEVER READ anywhere in check_expr.cpp. It is write-only in C++. A faithful transcription
would add a variable that does nothing and invite a later reader to hunt for its consumer.
Same class as check_type.cpp:2155's dead `is_type_polymorphic_type = false` recorded under #264.

**Do NOT attempt a 4th partial.** The change is: size the group path's operand array to
param_count, split positional vs variadic as C++ does, and fill the empty variadic slot with the
untyped-nil dummy. That is the whole restructure, and it needs a full tick plus sweep + parity
(both, per #269) because attempt 2 regressed core/debug/trace 0->2 and attempt 3 0->48.

## #260: two-array marshalling IMPLEMENTED but INERT -- the gap is downstream (progress#253)

Implemented C++'s operand-array construction in the group path
(check_proc_group.odin, replacing the `make([]Operand, len(positional_operands))` at the
polymorphic-instantiation site): array sized to the PARAMETER count, positional args in their
slots, variadic slot always filled -- the variadic parameter's declared type when variadic args
exist, `t_untyped_nil` when they do not. Cites check_expr.cpp:6666-6700 and 6759-6788.
`dummy_argument_count` deliberately not ported (dead in C++, see progress#252).

**Result: NO behavioural change.** `append(&d)` is still accepted; append_noval and builtin_arity
are still FULL-DIFFER, byte for byte the same diff as before. vet rc=0, corpus 59 FULL-MATCH /
2 FULL-DIFFER unchanged.

**Regression canary CLEAN this time**, which is the one real gain: core/debug/trace oracle=0
port=0, where attempt 2 gave 0->2 and attempt 3 gave 0->48. So the shape is right even though the
effect is absent -- the earlier attempts were breaking things precisely because they were count
rules rather than this structure.

**What this proves, and it narrows the problem sharply.** The untyped-nil dummy now reaches
`find_or_generate_polymorphic_procedure_from_parameters` exactly as in C++, and the port's
instantiation STILL SUCCEEDS where C++'s fails. So the defect is NOT in marshalling at all --
it is in the port's polymorphic inference accepting `t_untyped_nil` as a binding for `$E` in
`..$E`. That is link 2 of the original three-link analysis, and it is now the ONLY link.

**Status of the change: kept, but explicitly UNVERIFIED-BENEFICIAL.** It is a faithful
transcription of a structure C++ demonstrably has, and the canary shows it is not harmful, but
there is currently NO measurement showing it changes any outcome. parity.sh + sweep t501 running
to establish corpus neutrality. If they are clean it stays as the necessary foundation; if they
are not, it comes out. Do not cite this as "fixed" anything.

**Next: the inference site.** Find where the port binds a polymorphic `$E` from a variadic operand
and establish why an untyped-nil operand satisfies it. Instrument in the SAME build as any change
(the rule from three earlier wrong post-hoc explanations).

## #260: marshalling change CONFIRMED NEUTRAL; and a READING that CONTRADICTS an earlier MEASUREMENT (progress#254)

**Neutrality settled.** parity.sh 225/225 (0 count, 0 text mismatches); sweep t500 -> t501 0
error-count differences. The two-array marshalling change is corpus-neutral, faithful in shape,
and the regression canary is clean. It stays as the foundation, still labelled inert.

**Traced the inference path in C++:**
  check_type.cpp:2139-2151  value param, polymorphic -> `determine_type_from_polymorphic(ctx, type, op)`
  check_type.cpp:1655       -> `is_polymorphic_type_assignable(ctx, poly_type, operand.type, ...)`
  check_expr.cpp:1438-1450  Type_Generic arm: if unspecialized, `default_type(source)` is memmoved
                            over the generic and it returns TRUE.
  types.cpp default_type    has arms for UntypedBool/Integer/Float/Complex/Quaternion/String/Rune
                            -- and NONE for UntypedNil. Untyped nil falls through unchanged.

**So on this reading C++ BINDS `$E` to untyped nil and generation SUCCEEDS at that point.**

That directly contradicts what I recorded in an earlier window from INSTRUMENTED measurement:
"C++'s find_or_generate FAILS (XFG H1st at check_expr.cpp:473, via XPL 2152), leaving pt generic
so the ambiguous-variadic check at 6979-6991 rejects."

**Measurement outranks reading, so the earlier result stands until re-measured.** Do not act on
this tick's reading. Either (a) the failure happens later than the Generic arm -- e.g. a
`^$T/[dynamic]$E` specialization check against an untyped-nil E, or a validity check on the
generated type -- and 473 is that later site; or (b) the earlier instrumentation was reading a
different code path than I attributed it to. Both are live.

**NEXT STEP IS INSTRUMENTATION, NOT MORE READING.** This tick's reading has now produced a
conclusion that cannot be reconciled with a prior measurement, which is exactly the signal to stop
reading. Instrument the PORT at its is_polymorphic_type_assignable Generic arm and at its
find_or_generate exit: log what `$E` binds to and whether generation succeeds for
`append(&d)`. That is cheap (the port rebuilds every tick) and settles which of (a)/(b) holds
before any further change.

## #260: CONTRADICTION RESOLVED -- both the reading and the measurement were right (progress#255)

`check_expr.cpp:473` is:

    bool success = check_procedure_type(&nctx, final_proc_type, pt->node, &operands);
    if (!success) {          // <-- line 473, the site the earlier instrumentation flagged
        return false;
    }

So "find_or_generate FAILS at 473" (measured, earlier window) and "the Type_Generic arm binds and
returns true" (read, progress#254) are BOTH TRUE. The failure is inside check_procedure_type,
NOT at the polymorphic binding. Last tick's apparent contradiction was my own inference that
"generation succeeds at the Generic arm" implied "generation succeeds". It does not.

**The port's default_type is faithful** -- same seven untyped arms, NO Untyped_Nil arm, same
Generic recursion, same fall-through returning `t`. So that is not the divergence either.

**Revised mechanism, and it is simpler than the three-link story.** For
`append_elems :: proc(array: ^$T/[dynamic]$E, args: ..E)` called as `append(&d)`:
  param 0 `array: ^$T/[dynamic]$E` binds T and E from the real operand `^[dynamic]int`, so E := int
  param 1 `args: ..E` is therefore NO LONGER POLYMORPHIC by the time it is processed --
          `is_type_polymorphic_type` is false, determine_type_from_polymorphic is never called
  the untyped-nil dummy is then checked against a CONCRETE `..int`, and that is what fails,
          setting success = false and returning false at 473.
This also explains why every count-based attempt failed: the rejection depends on the dummy being
type-checked against an already-bound parameter, which no arity rule can express.

**NEXT: find the per-parameter operand check inside check_get_params that rejects untyped nil for
a concrete variadic parameter, and compare it with the port's.** That is now a narrow,
single-site question. Instrument the port there in the same build as any change.

No source edits were made this tick -- reading and reconciliation only. The marshalling change
from progress#253 remains in place (corpus-neutral, verified).

## #260: the accepting candidate is NAMED -- append_elems, score 601 (progress#256)

Instrumented the port's valid-candidate loop (temporary, reverted; vet rc=0 after). For
`append(&d)`:

    CAND append_elems score=601      <-- the port accepts this
    CAND copy_slice / copy_from_string ...  (unrelated, from base:runtime's own body)

So the port scores `append_elems :: proc(array: ^$T/[dynamic]$E, args: ..E)` as VALID with one
array argument and ZERO variadic values. The oracle admits no candidate at all. Single named
target now, instead of "the group path".

Critically, this build INCLUDED the progress#253 marshalling change, so the untyped-nil dummy IS
reaching polymorphic instantiation and instantiation still succeeds. That isolates the remaining
divergence to the port's check_procedure_type/check_get_params equivalent accepting an untyped-nil
operand for the `..E` parameter, where C++'s returns success=false (surfacing at
check_expr.cpp:473).

**Instrumentation bug worth recording, because it re-proved #260's own finding.** My first probe
indexed `procs[candidate.index]` and crashed with "Index 4 is out of range 0..<4".
`candidate.index` indexes `proc_entities`, NOT `procs` -- exactly the defect #260 fixed at
check_expr.cpp:7992. Writing the instrumentation reproduced the original bug, which is decent
independent confirmation that the two arrays really do diverge in length here.

**C++ candidates for the rejecting check, from progress#255's enumeration of `success = false`
inside check_get_params:** 1928, 1933, 2076, 2083, 2090, 2103, 2152, 2188, 2210, 2225. The
promising one is 2225, `if (is_type_untyped(default_type(type)))` -> "Cannot determine type from
the parameter". NOT yet confirmed to be the firing site -- next step is to instrument the PORT's
corresponding checks and see which one C++ has that the port lacks or evaluates differently.

## #260: THE MISSING CHECK IS NAMED -- port lacks BOTH "Ambiguous polymorphic variadic" sites (progress#257)

    C++  check_expr.cpp:6925  (in the `ordered_operands.count == 0 && param_count_excluding_defaults == 0` branch)
    C++  check_expr.cpp:6988  (in `if (variadic) { ... if (is_type_polymorphic(elem)) ... }`, UNCONDITIONAL
                               on the variadic operand count)
    PORT: grep for the message returns NOTHING. Neither site exists.

6988 is the important one: it runs whenever the variadic parameter's ELEMENT type is still
polymorphic, regardless of how many variadic operands there are, and sets
`err = CallArgumentError_AmbiguousPolymorphicVariadic`.

**Why the message never appears in the oracle's output, yet still decides the outcome.** In
proc-group scoring `show_error` is FALSE, so the error() call is skipped -- but `err` is still
assigned, which makes the candidate INVALID. The user-visible result is the group-level
"No procedures or ambiguous call for procedure group 'append'". So the port cannot be found to be
missing this by diffing messages: the message is invisible in both compilers on this input. It was
findable only by asking which CHECK is absent.

**This also explains the measurement from progress#256** (port accepts `append_elems` score=601)
without requiring generation to fail: 6988 invalidates the candidate independently.

**Two eliminated en route, both recorded so they are not re-tried:**
  - C++ 2225 `is_type_untyped(default_type(type))` -> the port HAS it, at check_type.odin:4833
    and :4953. It tests the PARAMETER type (int once E is bound), not the operand, so it cannot
    fire here in either compiler. My progress#256 "promising" label was wrong -- correctly flagged
    unconfirmed at the time.
  - The whole "generation must fail" line of reasoning is not needed for the fix.

**NEXT: port check_expr.cpp:6979-6991.** Implement in check_call_arguments_internal, after the
per-parameter scoring loop: if the proc is variadic, take the variadic parameter's slice element
type and, if `is_type_polymorphic(elem)`, set the ambiguous-variadic error (message gated on
show_error, exactly as C++ does). Verify with BOTH probes plus sweep AND parity, and watch
core/debug/trace, which attempts 2 and 3 regressed.

## #260 ROOT CAUSE MEASURED IN THE ORACLE -- user suggested instrumenting C++, which broke a 5-tick stall (progress#258)

Backed up ./odin + src/check_expr.cpp + src/check_type.cpp with sha256, added ODIN_DBG-gated
fprintf logs, rebuilt twice (~10 min each), measured, then restored. **Both hashes verified
identical afterwards; git status src/ clean.**

### Measurement 1 -- the two "contradictory" explanations are ONE CAUSAL CHAIN

    DBG gen FAIL entity=append_elems
    DBG variadic entity=append_elems elem=$E poly=1 vari_ops=0
    DBG variadic REJECT entity=append_elems

Generation fails FIRST; because it failed, pt stays generic, so elem is still `$E`, so
is_type_polymorphic(elem) is true, so the ambiguous-variadic guard fires. The earlier window's
measurement (gen fails at 473) and progress#257's finding (the guard rejects) are the same story
in sequence -- neither was wrong.

### THIS KILLED THE FIX I WAS ABOUT TO MAKE

progress#257 concluded "port the ambiguous-variadic guard". That would have been INERT: the port's
generation SUCCEEDS and binds E := int, so elem would be `int`, poly=0, and the guard would never
fire. A fourth inert change, avoided only because the oracle was instrumented.

### Measurement 2 -- exactly which check fails

Instrumented all 10 `success = false` sites in check_get_params. For append_elems, exactly one
fires: **check_type.cpp:2152**

    type = determine_type_from_polymorphic(ctx, type, op);
    if (type == t_invalid) { success = false; }      // 2152

So `determine_type_from_polymorphic` returns **t_invalid**.

**This REFUTES my progress#254 reading**, which concluded the Type_Generic arm binds
default_type(source) and returns true. It does not, for this input. Reading the code produced the
wrong answer; the binary produced the right one.

### Where this leaves the fix

The port's determine_type_from_polymorphic (or its is_polymorphic_type_assignable) must return
INVALID for (poly = `$E`, operand = untyped nil) and currently does not. That is a single
predicate on a single input pair -- the narrowest the target has ever been, and it is now
port-side work needing no further C++ rebuilds.

### Method note

Five ticks of reading produced two mutually contradictory conclusions and one nearly-shipped inert
change. Two instrumented oracle runs settled it and additionally invalidated the planned fix.
**When the question is "what does the reference actually do", rebuild the reference with logs.**
The ~10 min build is cheap against the cost of a wrong fix plus the ticks spent inferring.
Backup/restore discipline (hashes recorded and re-verified) makes it safe to repeat.

## #260: PORT-SIDE DEFECT MEASURED -- is_type_polymorphic_type false for a `[]$E` parameter (progress#259)

Instrumented the port's check_get_params (temporary, reverted; vet rc=0 after). For `append(&d)`:

    DBGP param poly=true  ptype=^$T/#soa[dynamic]$E optype=^[dynamic]int  -> invalid type   (soa)
    DBGP param poly=true  ptype=^$T/[dynamic]$E     optype=^[dynamic]int  -> ^$T/[dynamic]$E
    DBGP param poly=false ptype=[]$E                optype=untyped nil    <-- THE DEFECT
    DBGP param poly=false ptype=Source_Code_Location optype=<nil>

For `args: ..E` the port's `is_type_polymorphic_type` is **false** although the parameter type is
`[]$E`. So the gate at check_type.odin:4903 never opens, determine_type_from_polymorphic is never
called, generation succeeds, and the candidate stays valid at score 601.

C++ (check_type.cpp:1966-1968) sets `is_type_polymorphic_type = is_type_polymorphic(type)` with
type = `[]$E` -> TRUE -> determine_type_from_polymorphic -> t_invalid -> success=false at 2152 ->
generation fails at check_expr.cpp:473 -> pt stays generic -> ambiguous-variadic guard at 6988
rejects. The whole measured chain now closes end to end.

**The machinery is not missing -- it works when the gate is true.** The soa candidate on the line
above takes exactly this path and correctly yields "invalid type". Only the variadic parameter's
gate is wrong. That rules out "port determine_type_from_polymorphic is broken" and narrows it to
how the flag is computed for a VARIADIC parameter specifically.

**Not yet established, and must not be assumed:** WHERE the flag goes wrong. The port's flag site
(check_type.odin:4574-4576) reads `if is_type_polymorphic(param_type) { ... = true }`, which is
C++'s rule, and the port's is_type_polymorphic HAS a recursing `.Slice` arm (check_type.odin:1863)
and demonstrably works (`$P/^$Field_Type poly=true` at the same site). So either the variadic
param's type at FLAG time is not yet `[]$E` (the slice wrap happening later), or variadic params
reach a different branch that never runs the flag check. A DBGF log added at the flag site showed
no `[]$E` line at all among flag-site types, which favours the first explanation but is not
conclusive -- the filter that would have confirmed it was mangled by shell escaping.

**NEXT: log the variadic parameter's type AT the flag site and at the point the slice wrap
happens.** One more port build (~1 min). Do not change code until that is pinned -- this thread
has already produced four inert or reverted changes from acting on inference.

## #260 progress#260: NO PROGRESS -- reverted to reading after committing to instrument

This tick was spent grepping C++ for where `..E` becomes `[]$E` and found nothing conclusive:
  - check_type.cpp:3562/3565 alloc_type_slice is the ARRAY-TYPE path (`[]T`), not variadic
  - check_type.cpp:2248 and 2333 are #no_capture / EntityFlag_Ellipsis, not a type wrap
  - check_type.cpp:2378 asserts only
  - the PORT has no alloc_type_slice in check_type.odin at all
Best remaining reading: `..E` parses to an Ellipsis type node and check_type on it yields the
slice, so `type` is already `[]$E` when the flag is computed. But that predicts flag=TRUE in the
port too, which CONTRADICTS the measurement (flag=false for ptype=[]$E). Reading has now
contradicted measurement twice in this thread.

**Process failure, recorded deliberately.** progress#259 ended with "log the variadic parameter's
type AT the flag site -- one port build, ~1 min. Do not change code until that is pinned." I then
spent the whole tick reading instead. The cost of a wrong turn here is high precisely because four
changes have already been inert or reverted, and reading is what produced each of them.

**NEXT TICK, FIRST ACTION, NO READING FIRST:** add to check_type.odin immediately after the flag
assignment (~4574-4576):

    fmt.eprintf("DBGV variadic=%v ptype=%s poly=%v flag=%v\n",
                is_field_variadic, type_to_string(param_type),
                is_type_polymorphic(param_type), is_type_polymorphic_type)

build, run on $S/an1, grep DBGV. That prints the variadic flag, the type, the predicate and the
resulting gate together at the one point where they must agree. If the line for the variadic
parameter shows poly=true but flag=false, the assignment is being skipped or overwritten; if it
shows poly=false with ptype=[]$E, the predicate is wrong on that exact value; if no DBGV line
appears for the variadic parameter at all, that branch never reaches the flag site -- which is the
third possibility and the one no amount of reading has been able to rule out.

## #260 LAST ITEM FIXED -- variadic parameters never reached the polymorphic-flag site (progress#261)

**The DBGV measurement, first action of the tick as committed:** 864 flag-site hits, **ZERO with
variadic=true**. The variadic parameter never reached the flag site at all -- the third of the
three predicted outcomes, and the one no amount of reading had been able to rule out.

**Root cause, structural.** The port's parameter-type handling is a three-way if/else chain:
  1. `if ellipsis`   -> `param_type = make_slice_type(inner_type)`  -- and NO flag computation
  2. `else if typeid`-> type parameter
  3. `else` (normal) -> check_type + `if is_type_polymorphic(param_type) { flag = true }`
C++ has no separate variadic branch: for `args: ..E` the type_expr IS the Ellipsis node, so
check_type returns the slice and control flows through C++'s single `else` (check_type.cpp:1957-
1968) where the flag is set. **The port split the ellipsis into its own branch and the flag
computation did not come with it.**

**Fix:** compute the flag in the variadic branch too, citing check_type.cpp:1966-1968, with the
measured chain recorded at the site.

**Verified:**
  append_noval   FULL-MATCH  (was FULL-DIFFER)
  builtin_arity  FULL-MATCH  (was FULL-DIFFER)
  corpus         61 FULL-MATCH, **0 FULL-DIFFER** (was 59/2)
  canary core/debug/trace  oracle=0 port=0  (attempt 2 gave 0->2, attempt 3 gave 0->48)
  vet rc=0.  parity.sh + sweep t502 running.

**Why five attempts failed and the sixth worked.** Attempts 1-3 were count rules
(max(args,param_count); exact param_count; empty variadic slot) -- all reverted, because the
rejection is not an arity rule. Attempt 4 (progress#253, the two-array marshalling) was correct in
shape but INERT. Attempt 5 would have been the ambiguous-variadic guard -- also inert, and only
the instrumented ORACLE revealed that in advance. The actual defect was one missing
`is_type_polymorphic` call in a branch that reading never implicated, found by instrumenting the
PORT after the ORACLE had narrowed the target to a single line.

**The rule this thread earned:** when reading and measurement disagree, measurement wins, and the
right response to a stall is to instrument the thing you cannot see -- including the reference
compiler. Reading produced two contradictory conclusions and would have produced a fifth wasted
change; three instrumented builds produced the answer.

## MILESTONE: probe corpus AND package corpus simultaneously at full parity (progress#262)

    probes    : 61 FULL-MATCH, 0 FULL-DIFFER
    packages  : parity.sh 225/225, count_mismatches=0, text_mismatches=0
    sweep     : 0 error-count differences, stable totals 64 = 64,
                all 8 text differences are crash markers (#141 intermittent set)
    vet rc=0

This is the first time both instruments are simultaneously clean. #260's last item -- open across
six attempts -- is closed, and with it the last known FULL-DIFFER probe.

### The six attempts, kept as the record of what this cost

  1. `max(args, param_count)`      REVERTED -- over-rejected real code (core/debug/trace 0->2,
                                   core/rexcode/ir/wasm 0->1); caught only by the sweep
  2. exact param_count             REVERTED
  3. empty variadic slot           REVERTED -- core/debug/trace 0->48, caught in seconds by the
                                   varsurplus probe added after attempt 1
  4. two-array marshalling         KEPT, corpus-neutral, but INERT on the target
  5. ambiguous-variadic guard      NOT MADE -- would have been inert; the instrumented ORACLE
                                   showed the port's generation succeeds, so `elem` would be
                                   `int` and the guard could never fire
  6. the flag in the variadic br.  FIXED

Attempts 1-3 all encoded the rejection as an ARITY rule. It never was one. Attempt 4 was
structurally right and did nothing. Attempt 5 was averted only by measurement.

### What actually found it

  - ORACLE instrumentation (2 builds, ~10 min each, backed up and hash-verified restored):
    proved gen-fail and the guard are ONE causal chain, then pinned the failing check to
    check_type.cpp:2152.
  - PORT instrumentation (3 builds, ~1 min each): showed the accepting candidate
    (append_elems score=601), then the false flag on `[]$E`, then -- decisively -- 864 flag-site
    hits with ZERO variadic=true.

Reading alone produced two conclusions that contradicted measurements, and would have produced a
fifth wasted change.

### Rules earned

  - When reading and measurement disagree, measurement wins. This happened twice here.
  - A stall is a signal to instrument the thing you cannot see -- INCLUDING the reference
    compiler. Cost of a C++ rebuild (~10 min, safe with backup + hash verification) is trivial
    against a wrong fix plus the ticks spent inferring one.
  - "Necessary but not sufficient" is a real and reportable outcome. Attempt 4 stays in the tree,
    labelled inert and corpus-neutral, because it is a faithful transcription -- but it was never
    credited with fixing anything.

## #149: `'%s' %s` candidate DISPOSITIONED as a FALSE PAIR (progress#263)

C++ check_expr.cpp:9020-9038 composes one message from an expression string plus one of three
err_str values ("used as a value" / "is not an expression but a type, in this context it is
ambiguous" / "must be called"), emitted as `error(e, "'%s' %s", str, err_str)`.

The port has ALL THREE err_str values (check_expr.odin:4376, 4380, 4383), the same `if err_str
!= ""` guard, and the identical call `error(node, "'%s' %s", expr_str, err_str)` at 4389. Faithful.

The detector's port-side hit was `error_line("'%s'", var_str)` at check_expr.odin:4246/4281 -- a
CONTINUATION line listing a variable in an unrelated diagnostic. msgpair.py matches on format-
string shape, so a bare `'%s'` anywhere in the same file pairs against C++'s `'%s' %s`. This is
the second false pair of exactly this kind (the simd entry persists for the same reason: the file
still contains ~34 correctly-bare sites).

**#149 status: 7 detector candidates, all dispositioned except ONE.**
  FIXED (2)      : simd extract_lsbs/msbs; check_builtin.odin integer-type message
  FAITHFUL (4)   : Array count; Extra initial expression; bit_set (id-gated); decl_helpers
                   Expected-a-type (C++ counterparts at checker.cpp:3808/4161 are BARE)
  FALSE PAIR (1) : `'%s' %s`  <- this tick
  OPEN (1)       : check_proc_group.odin:256 "Expected a type for the argument" -- and it is NOT
                   a message-truncation issue at all. Both compilers carry both variants; the
                   port's site reports at `call_node` where C++ reports at `o->expr`
                   (check_expr.cpp:6958). A POSITION divergence, still unreproduced because the
                   site sits behind `show_error`, false during group scoring.

So the "port stops at the category" pattern that named #149 is, on the evidence, essentially
closed: 2 real instances found and fixed, 4 faithful, 1 false pair. The original "45 sites"
figure was never supported and the residual is a different defect class.

## #264 DONE: partial-polymorphic-procedure error ported, repro found first (progress#264)

The task said "port once a repro exists -- do NOT write blind". A repro was found on the first
attempt, because this thread's #260 work made the code path familiar: the error fires when the
operand is a PROCEDURE VALUE whose entity type is still polymorphic.

    f :: proc(x: $T) -> T { return x }     // stays polymorphic
    h :: proc(cb: $F) { }                  // polymorphic value parameter
    main :: proc() { h(f) }

    oracle: m.odin(11:4) Error: Cannot determine complete type of partial polymorphic procedure
    port  : errors=0                        <- under-rejection

Ported at the port's determine_type_from_polymorphic call site, citing check_type.cpp:2153-2161.

**The dead sibling was VERIFIED dead before writing, not trusted.** C++'s
`is_type_polymorphic_type = false` at 2155 is never read again anywhere through line 2340 --
confirmed by grep this tick, not carried over from the earlier note. Deliberately NOT ported, with
the reason recorded at the site so a later citation audit does not "restore" it.

Verified: probe partialpoly validated BOTH directions (FULL-DIFFER on t502, FULL-MATCH on t503);
corpus 62 FULL-MATCH / 0 FULL-DIFFER; vet rc=0. parity + sweep t503 running.

**Why this one was easy after #260 was hard.** #264 had sat open for want of a repro. The five
ticks spent instrumenting determine_type_from_polymorphic for #260 mapped exactly the branch #264
needed -- the ExactValue_Procedure arm two lines below the one that was failing. Deep work on one
defect made an adjacent one nearly free.

## #264 VERIFIED (progress#265)

parity.sh 225/225, count_mismatches=0, text_mismatches=0.
sweep t502 -> t503: 0 error-count differences, stable totals 64 = 64, all 3 text differences are
crash markers. STABLE=221, unstable=4 -- the highest stable count recorded (was 216 at t502,
193-196 earlier in the session).

A new REJECTION is the riskiest kind of change to add -- it can only over-reject -- so the clean
sweep matters more here than for the message-only fixes. Nothing regressed.

Running totals: probes 62 FULL-MATCH / 0 FULL-DIFFER; packages 225/225 on both count and text.

## #145 / #138 verified; and a STALE CROSS-REFERENCE found (progress#266)

**#138 VERIFIED FIXED.** `@(disabled)` is stored, not merely validated:
check_decl_helpers.odin:1072 `ac.disabled_proc = b`, with a comment recording that it previously
"stayed false forever and `.Disabled` was never set on any" procedure.

**#145 is 2 of 3, and the third is a genuine gap, not a fixed item.**
  check_deferred_procedures                    called  check_files.odin:234
  check_safety_all_procedures_for_unchecked    called  check_files.odin:306
  generate_minimum_dependency_set              **ABSENT from the port entirely**

C++ has it at checker.cpp:3110 (plus _internal at 2953, invoked 3207). The port has NO
implementation -- only three comments referring to it (check_files.odin:254, 511;
check_decl.odin:1140) and one reader, `entity.min_dep_count > 0` at check_proc.odin:2318, which
can therefore never be true.

**STALE CROSS-REFERENCE.** check_files.odin:254-257 says the pass is missing "(task #42)" and that
`check_unchecked_bodies` "stops being a no-op the moment #42 lands". But #42 was CLOSED with a
different conclusion entirely -- "bis was the error cap all along, fixed by #230/progress#216 --
NOT a dependency set". So the comment now points at a task that will never deliver the pass, and a
future reader would conclude the gap is already tracked when it is not.

This is the same failure mode as #266's fabricated citations, in a milder form: a reference that
was true when written and silently became false. Worth a periodic sweep of task-number references
in comments against the task list.

**Filed as a real remaining gap** rather than folded into #145, because it is a whole missing
pass with a live dead reader, not an uncalled-but-present phase.

## #272 SCOPED OUT (with evidence) and the stale reference corrected (progress#267)

**Every reader of `min_dep_count` in C++, enumerated:**
    llvm_backend.cpp x2, llvm_backend_proc.cpp, llvm_backend_stmt.cpp x2   -> CODEGEN
    main.cpp:3408                                                          -> driver
    checker.cpp:6650  check_unchecked_bodies                               -> RACE BACKSTOP
    checker.cpp:7509/7513  add_type_info_for_type_definitions              -> RTTI type-info table
  (writers: checker.cpp:2786, 2844)

**NONE emits a diagnostic.** So the missing pass cannot affect diagnostic parity, and the corpus
agrees: 225/225 on counts and text with the loop permanently empty.

check_unchecked_bodies is not even a semantic phase in C++'s own view --

    // NOTE(2021-02-26, bill): Sanity checker
    // This is a partial hack to make sure all procedure bodies have been checked
    // even ones which should not exist, due to the multithreaded nature of the parser
    // HACK TODO(2021-02-26, bill): Actually fix this race condition

**Decision: OUT OF SCOPE for this port's objective (semantic analysis parity), recorded as a
deliberate scope call with the enumeration behind it rather than silently dropped.** The remaining
in-principle exposure is the RTTI table, which is a runtime-data concern; if type-info completeness
ever comes into scope, this is the pass that gates it.

**Stale reference corrected at check_files.odin:254.** The old comment blamed task #42 and promised
the loop "stops being a no-op the moment #42 lands" -- but #42 closed with the OPPOSITE conclusion
("the error cap all along -- NOT a dependency set"). The new comment carries the full reader
enumeration, the scope decision, and an explicit note that the previous attribution was wrong.

**Class worth watching: TASK-NUMBER REFERENCES IN COMMENTS GO STALE SILENTLY.** A citation to C++
line numbers drifts visibly (#134's citefn catches it). A citation to a task number is true when
written and can be falsified later by that task closing with a different conclusion -- with nothing
to detect it. This is the second reference-rot class found in this session, after #266's fabricated
C++ citations.

## REFERENCE-ROT SWEEP: 6 stale task citations found and fixed (progress#268)

Swept every `task #N` citation in the checker (13 distinct numbers, ~17 sites).

**FIXED -- #42, four sites total.** progress#267 corrected ONE; three more were still promising a
pass that will never arrive:
    check_files.odin:527  "the dependency-set pass the port does not have yet (LEDGER task #42)"
    check_files.odin:546  "add_to_set awaits task #42"
    check_decl.odin:1141  "the pass in #42 does not exist here"
All now cite #272 with its scope decision. Note I fixed one site last tick and assumed that was
all of them -- it was not. **Fixing one instance of a rotted reference is not fixing the class;
grep for the number.**

**FIXED -- #5, two sites.** Both said "open task #5"; #5 is CLOSED. Reworded to say the task
closed and the deviation was left deliberately, so a reader does not wait for a fix that is not
coming.

**FLAGGED, needs an experiment not an edit -- #228, one site.** check_builtin.odin:74 says the
12 added names are "invisible today only because the port's check_expr does not reject a type
(task #228) -- simd_indices and type_is_superset_of are two of the seven intrinsics that light up
the moment it does." **#228 has since CLOSED as "prologue + strict check_expr".** So either the
prediction has already come true and nobody looked, or check_expr still does not reject types and
the comment's premise survives under a closed task. Filed as #273 -- this one is a testable
claim, not a wording fix.

**Verified benign (8):** #50, #64, #104, #181, #231 are descriptive references to completed work;
#166, #174, #187, #189 correctly describe still-open UPSTREAM tasks.

**New instrument `.claude/tools/taskrefs.sh`** lists every citation with file:line. It deliberately
does NOT try to judge correctness: the failure mode is semantic (comment asserts X, task concluded
not-X), so it needs a human read against the task list. Cheap to run, and it is the only thing
that would have caught the three surviving #42 sites.

## #273 ANSWERED, and it found a REAL under-rejection in len/cap (progress#269)

The comment at check_builtin.odin:74 claimed twelve intrinsics were "invisible today only because
the port's check_expr does not reject a type (task #228)". Tested it directly:

    type_is_superset_of(Foo, int)  oracle and port BOTH reject, identical text   -> premise wrong
                                                                                    for that one
    len(Foo)   oracle: "'len' is not supported for 'Foo'"   port: SILENT   <- REAL UNDER-REJECTION
    cap(Foo)   oracle: "'cap' is not supported for 'Foo'"   port: SILENT   <- REAL UNDER-REJECTION
    abs(Foo)   both emit the same 2 diagnostics                            -> faithful
    len(Arr)   legal in both ([4]int, compile-time constant)               -> faithful

**Root cause is STRUCTURAL, not a missing guard.** C++ (check_builtin.cpp:~2995-3030):

    ...compute `mode` through an if/else-if chain over op_type...
    if (operand->mode == Addressing_Type && mode != Addressing_Constant) {
        mode = Addressing_Invalid;              // a TYPE is only legal if the result is constant
    }
    if (mode == Addressing_Invalid) {           // <- tested AFTER the whole chain
        error("'%s' is not supported for '%s'");
    }

The port puts that error inside the chain's FINAL `else` (check_builtin.odin:814) -- so it only
fires when no arm matched the type at all. `len(Foo)` matches the `is_type_struct` arm at 792,
`soa_kind` is neither Fixed nor Slice, `mode` stays `.Invalid`, and nothing ever tests it. The
port also lacks the Type guard entirely (no `.Type` reference in 770-816).

Two edits are needed, and the second is the important one:
  1. add the `operand.mode == .Type && mode != .Constant -> mode = .Invalid` guard
  2. move the error OUT of the final `else` to a post-chain `if mode == .Invalid`

**Deliberately NOT implemented this tick.** Edit 2 is a control-flow restructure of a builtin every
package uses; this session has four reverted/inert changes from doing restructures at the end of a
tick. Next tick with full budget, then probe + sweep + parity.

**Meta.** This defect was reached from a REFERENCE-ROT SWEEP -- a stale `task #228` citation in a
comment. The rot check was cheap and turned up a genuine under-rejection two steps away. Fixing
comments is not busywork when the comments encode claims about behaviour.

## #273 FIXED: len/cap silent bail restored to C++'s single mode==Invalid diagnostic (progress#270)

**My progress#269 diagnosis was WRONG in one detail and I корrected it before writing code.** I had
said the port "lacks the Type guard entirely (no `.Type` reference in 770-816)". It does not -- the
guard is at 827-829, just past the range I had grepped. Looking only at the window I had already
chosen nearly produced a change based on a false premise.

**Actual defect:** the port had BOTH the Type guard and the `if mode == .Invalid` test, but that
test was a SILENT `return false`. The diagnostic lived in the chain's final `else`, which fires
only when NO arm matched. So a type that matched an arm and still left `mode` Invalid was rejected
with no message at all:
    len(Foo) / cap(Foo) on a plain struct -> is_type_struct arm matches, soa_kind switch sets
    nothing for a non-SOA struct, mode stays .Invalid -> silent accept.
Same class as #232/#252: an invented bail that drops a diagnostic.

**Fix (C++ check_builtin.cpp:3018-3029):** delete the erroring `else`, let an unmatched type leave
`mode` at its initial `.Invalid` (declared line 687), and emit the diagnostic in the single
post-guard `if mode == .Invalid` branch -- C++'s exact shape, and it removes the duplication.

**Verified.** Probe `lentype` covers all five cases and validates BOTH directions:
    len(Foo), cap(Foo)                 rejected (were silent)
    len(bit_set[0..<8])                "did you mean 'card'?" -- a THIRD message also missing
    len([4]int)                        still legal (constant-result type operand)
    len(slice value)                   unaffected
  pre-fix st_t503 FULL-DIFFER, post-fix st_t504 FULL-MATCH; corpus 63 FULL-MATCH / 0 FULL-DIFFER;
  vet rc=0. parity + sweep t504 running.

**Provenance worth noting:** stale `task #228` citation -> reference-rot sweep -> tested the
comment's claim -> found this. Three steps from a comment audit to a real under-rejection in a
builtin every package uses.

## #273 VERIFIED (progress#271)

parity.sh 225/225, count_mismatches=0, text_mismatches=0.
sweep t503 -> t504: 0 error-count differences, stable totals 64 = 64, all 4 diagnostic-text
differences are crash markers. STABLE=218.

`len`/`cap` are called in nearly every package, so a new rejection there was the highest
over-rejection risk of the session. Nothing moved.

**Session state:** probes 63 FULL-MATCH / 0 FULL-DIFFER; packages 225/225 on both count and text.

## The reference-rot chain, end to end -- worth keeping as a worked example

    #272 scope work        -> noticed check_files.odin:254 cited task #42
    #42 had closed with the OPPOSITE conclusion       -> corrected that one comment
    progress#268 swept ALL task refs                  -> found THREE more #42 sites I had missed,
                                                         plus two "open task #5" (closed), plus a
                                                         BEHAVIOURAL claim citing #228
    tested the #228 claim                             -> type_is_superset_of faithful, but
                                                         len(Foo)/cap(Foo) SILENTLY ACCEPTED
    fixed                                             -> 3 diagnostics recovered, incl. the
                                                         bit_set 'card' suggestion

Four comment corrections and one real under-rejection in a universally-used builtin, all from
auditing citations. Two lessons already recorded and both earned here:
  - fixing one instance of a rotted reference is not fixing the class; grep the number
  - comments that encode CLAIMS ABOUT BEHAVIOUR are testable, and worth testing when their
    supporting task closes

## #133 VERIFIED FIXED, plus a dead-but-correct wrapper layer (progress#272)

**#133's substantive claim verified.** The three package predicates are no longer always-false:
`is_in_runtime_package` delegates to `is_package_runtime`, `is_in_builtin_package` to
`is_package_builtin`, and `is_in_init_package` tests
`pkg.fullpath == info.init_fullpath || pkg.kind == .Init` -- which is exactly the condition
C++ uses at checker.cpp:267. Content is correct and the citation is real.

**But all four are DEAD:** `is_in_runtime_package`, `is_in_init_package`, `is_in_builtin_package`,
`is_package_extra` have ZERO callers. Their delegates are live (`is_package_runtime` 2 callers,
`is_package_builtin` 3, `is_package_init` 3), so it is only the file-taking wrapper layer that is
unused. C++ has no functions by these names at all; it tests `pkg->kind == Package_Runtime` inline
at 21 sites, and the port likewise tests inline at 20.

**Deliberately NOT deleted, and the distinction from #266 matters.** #266's block was deleted
because it was INVENTED: fabricated citations pointing at unrelated C++ code, no upstream
counterpart, wrong content. These four are the opposite -- correct content, genuine citations,
merely unused. "Dead" alone is not the deletion criterion; "dead AND invented" was. Recording them
as redundant rather than removing correct, cited code on a cosmetic basis.

Also worth noting against my own progress#266 heuristic: that entry said contiguous runs of dead
procs indicate an invented block while "scattered singletons are usually API". These four are
scattered singletons and are NOT API -- they are internal helpers nobody wired up. The heuristic
is for FINDING candidates, not for classifying them; classification still needs the citation check.

## #176 ANSWERED, and the blind spot was hiding a WHOLE DISABLED SUBSYSTEM (progress#273)

The task said "no vet-gated diagnostic has ever been compared against the oracle". Building that
comparison took one harness and found a defect on the FIRST positive control.

**The instrument.** triage_vet (scratchpad) sets `checker.build_context.vet_flags` before calling
check_package_from_path. It uses exactly C++'s VetFlag_All (build_settings.cpp:323) --
`{Unused_Variables, Unused_Imports, Shadowing, Using_Stmt, Deprecated, Cast}` -- NOT every
Vet_Flag_Bit, because a bare `-vet` on the oracle does not enable Style/Semicolon/Tabs/
Unused_Procedures/Explicit_Allocators. Comparing against the wrong flag set would have manufactured
divergences that are not real.

**ROOT CAUSE: check_vet_flags_from_node was a stub returning `{}`.** check_proc.odin:1066-1070:

    check_vet_flags_from_node :: proc(node: ^ast.Node) -> Vet_Flag {
        // In Odin AST, nodes don't have a file() method like C++
        // We would need to track this separately via Checker_Info
        return {} // Empty bit_set = no vet flags
    }

Its sole caller is the proc-body vet gate (`check_scope_usage(ctx.checker, ctx.scope,
check_vet_flags(body))`, mirroring check_decl.cpp:2291), and that argument is the ONLY vet gate for
the whole body. So the stub did not degrade precision -- it disabled the entire proc-body vet
surface tree-wide: every unused variable, unused procedure, shadowed declaration and using-shadow
inside any procedure body, in every package, silently unreported.

**The stub's premise was false.** get_file_from_node (file_helpers.odin:44) already resolves a
node's file through node.pos.file, and its comment already explains why that is the correct
identity and node.file_id is not. The capability the stub said was missing had been built.

Fix: `check_vet_flags_from_node(info, node)` returns `ast_file_vet_flags(get_file_from_node(info,
node))`. Resolving to nil needs no guard -- ast_file_vet_flags(nil) falls to in_vet_packages(nil),
which returns true and yields build_context.vet_flags, exactly as C++ does for a null file().

**Measured.** Instrumenting check_scope_usage showed vet=Vet_Flag{} on ALL 1967 calls before the
fix -- "always", not "sometimes", so no rate estimation was needed. After: probe vetmap is a FULL
MATCH with the oracle on all three diagnostics at identical positions (2x unused local, 1x
shadowing). Before the fix the port emitted ZERO of them.

**Why swdiff and parity.sh both missed this for the entire project.** Neither ever passed -vet.
parity.sh is reference-anchored but only over the default flag set; swdiff is history-anchored and
the port has ALWAYS been silent here. This is the sharpest instance yet of the recorded rule that a
differential test against your own past output cannot find a defect you have always had -- and it
extends it: a reference-anchored test cannot find a defect in a MODE you never run the reference in.

### Two further findings from the same control, kept separate

1. **#179 CONFIRMED with a repro** (was pending with none): unused-import reports at the `import`
   keyword, oracle at the import path -- `vetctl/main.odin(3:1)` vs `(3:8)`.
2. **Missing SwitchValue branch** in the >256KiB stack-overflow warning. C++ checker.cpp:804-806
   has `else if (e->flags & EntityFlag_SwitchValue) { is_ref = !(e->flags & EntityFlag_Value); }`;
   the port handles only For_Value. Filed rather than fixed -- not yet reproduced.

**#177's premise does NOT reproduce.** Its claim (struct-field scopes lack .Type, so vet reports
every field as an unused variable, 68,119 spurious) shows nothing on a struct probe under vet: zero
field diagnostics. Consistent with #178, which already found that task's sibling premise wrong.

### #176 verification (both instruments, per the standing rule)

  odin check . -vet -strict-style -no-entry-point   rc=0
  parity.sh   225/225   count_mismatches=0  text_mismatches=0
  swdiff sw_t504 -> sw_176:  error-count differences: 0   stable totals 62=62
                             keys=225 both=225 capped=0 unstable=9 STABLE=216

swdiff reported 7 "diagnostic-text differences", and every one of them is a crash or timeout line
("double free or corruption (!prev)", "timeout: the monitored command dumped core") migrating
between packages -- the known intermittent #141 port-only failure, appearing in BOTH directions
(3 packages lost it, 4 gained it). None is a diagnostic change. The decisive signals are the two
that flakiness cannot fake: error-count differences 0, and stable totals identical at 62.

Worth noting for future ticks: these crash lines leak into swdiff's TEXT diff even though the
affected packages are counted in the unstable partition. The partition suppresses them from the
count comparison but not from the text comparison, so a text-diff of exactly this shape is noise,
not signal. Do not chase it.

## #179 DONE, and it was 88x bigger than its ticket (progress#274)

The first vet-mode parity run (parity_vet.sh, 225 packages) came back 7 count / 88 text mismatches.
ALL 88 text mismatches were one divergence: core/container/queue/mp_queue.odin(12:8) vs (12:1), the
unused-import column. core/container/queue is transitively imported by 88 packages, so a single
wrong token position WAS the entire vet-mode text-divergence surface.

**Root cause.** C++ parser.cpp:5151-5159 builds the import-name token:

    Token import_name = {};
    switch (f->curr_token.kind) {
    case Token_Ident: import_name = advance_token(f); break;   // alias
    default:          import_name.pos = f->curr_token.pos;     // NO alias
    }

At the default arm `import` is consumed and the path is not, so curr_token IS the path string.
checker.cpp:5658 passes that token to alloc_entity_import_name and checker.cpp:842 reports at
e->token. The port synthesised its unnamed-import token from import_decl.pos -- the `import`
KEYWORD. Fixed to import_decl.relpath.pos, the exact equivalent of C++'s curr_token here.

**After: vet text 88 -> 0, count 7 -> 3. Default parity 225/225, 0/0 (no regression).**

### MEASUREMENT DEFECT found in my own instrument -- parity.sh treats a crash as "port=0"

Of the original 7 count mismatches, most were NOT defects. Run individually, core/crypto/noise,
core/crypto/rsa and core/text/i18n each emit exactly the oracle's 1 diagnostic; they were recorded
port=0 because those runs hit the known intermittent #141 crash and produced no output.
core/rexcode/isa/riscv/tablegen/generated segfaults outright (rc=139).

parity.sh and parity_vet.sh capture stdout+stderr and count lines, but NEVER check the exit status.
A crashed port run therefore reports as a legitimate count mismatch, and a crashed ORACLE run would
equally manufacture one in the other direction. swdiff.py has a crash/timeout partition for exactly
this reason; parity.sh was built without one (progress#269) and has been reporting "225/225 clean"
on luck. This must be fixed before any future count mismatch is trusted -- and the "7 -> 3" delta
above is partly noise for this reason, not wholly credit to the #179 fix.

### The one REAL residual: core/encoding/cbor, oracle=1 port=5

The port emits 4 spurious "Declaration of 'a'/'b' shadows declaration at line N" on marshal.odin
415/449. Source is the idiomatic mutable-parameter shadow inside a sort comparator:

    proc(a, b: Encoded_Entry_Fast(^[]byte)) -> slice.Ordering {
        a, b := a, b

C++ suppresses this via check_vet_shadowing_assignment (checker.cpp:625-646): if the initialiser is
an Ident whose RESOLVED ENTITY is the shadowed entity, the shadow is intentional and ignored
(upstream issue #637). Both the port's check_vet_shadowing and check_vet_shadowing_assignment read
FAITHFUL -- same guards, same order, same `entity == shadowed` test -- and the single
Variable.init_expr write site matches too (check_decl.cpp:44 <-> check_decl.odin:70).

So the suspicion is the ident's resolved entity, not the rule. Counted write sites:

    C++  Ident.entity =   5 sites (checker.cpp:2022, checker.cpp:2144, check_stmt.cpp:2185,
                                   check_decl.cpp:190, check_builtin.cpp:2453)
    port ident.entity =   2 sites (entity_helpers.odin:247, check_decl.odin:438)

NEXT ACTION: map the 5 C++ sites onto the port's 2 and identify which are missing. Do NOT assume
the count difference is itself the defect -- one Odin helper may cover several C++ sites. Instrument
check_vet_shadowing_assignment on the cbor repro to confirm whether it receives a nil init_expr or a
non-nil ident with a null entity; those point at different fixes.

## The cbor shadow divergence is a DUPLICATE-VET race, not a missing rule (progress#275)

Last tick's next-action was "map the 5 C++ Ident.entity write sites onto the port's 2". That framing
was WRONG, and instrumenting first is what showed it. The entity-count difference is a red herring.

**Minimisation.** Two candidate shapes did NOT reproduce -- plain `a, b := a, b` in a normal proc,
and the same inside a proc literal passed as an argument. Both compilers stay silent. The shape that
DOES reproduce needs a POLYMORPHIC INSTANTIATED parameter type:

    Entry :: struct($T: typeid) { pre_key: [16]u8, val: T }
    slice.sort_by_cmp(items, proc(a, b: Entry(^[]byte)) -> slice.Ordering {
        a, b := a, b

That is exactly cbor/marshal.odin's `Encoded_Entry_Fast(^[]byte)`.

**Instrumented result -- both prior hypotheses are false.** init_expr is never nil (0 NIL-INIT over
37 hits) and the initialiser ident's entity IS populated. check_vet_shadowing_assignment works. What
the trace shows is the SAME entity evaluated TWICE against DIFFERENT shadowed candidates:

    name=a  entity=0x...8AB8  shadowed=0x...8AB8   same=true    <- suppressed, correct
    name=a  entity=0x...8AB8  shadowed=0x...18E48  same=false   <- REPORTED, spurious

The initialiser ident resolves to the parameter of one instantiation of the proc literal, while
scope_lookup(parent, name) returns the same-named parameter belonging to ANOTHER copy. C++'s
`init->Ident.entity == shadowed` test is pointer identity by design, so two structurally identical
copies compare unequal and the intentional-redeclaration suppression is defeated.

**It is INTERMITTENT: 18/24 runs (75%) emit the two spurious errors, 6/24 emit none.** Measured with
n=24, above the recorded n>=20 threshold for separating always/never; 75% is far from both. A second
instrumented run produced zero same=false lines, which is what prompted measuring the rate rather
than trusting the single trace -- had I read one trace and fixed, I would have "fixed" a race.

**Consequences for earlier claims.** The parityvet_1/parityvet_2 row "core/encoding/cbor oracle=1
port=5" is a sample of a FLAKY behaviour, not a stable count. It is a real divergence, but its
magnitude varies run to run, so it cannot be used as a before/after metric. Combined with #275
(parity treats crashes as port=0), NO parity COUNT row should be trusted until it is re-run
individually AND repeated.

**Next action (revised).** Find why one proc-literal body is vetted against two sets of parameter
entities. Likely candidates, in order: (a) polymorphic instantiation clones the proc literal's AST
(#125) and BOTH the original and the clone reach check_scope_usage; (b) the body is enqueued for
body-checking more than once. Determine whether C++ vets the generic copy at all. Do NOT change
check_vet_shadowing -- it is faithful and is not the defect.

## #275 FIXED: parity.sh/parity_vet.sh now partition crashes instead of scoring them (progress#276)

Both scripts piped each compiler straight into grep and compared line counts, never examining exit
status. A port run killed by the intermittent #141 crash emits nothing, so it scored as a genuine
"oracle=N port=0" count mismatch. Three of the first vet run's seven count mismatches were exactly
this -- crypto/noise, crypto/rsa and text/i18n each matched the oracle perfectly when re-run alone.

**The classification rule is SIGNAL-BASED, and getting this wrong would have been worse than the
bug.** `odin check` exits 1 whenever it reports ANY diagnostic -- measured directly: a package with
a single type error gives rc=1, a clean package gives rc=0. So the obvious `rc != 0 means crashed`
test would have excluded every package that has errors, i.e. precisely the packages the instrument
exists to compare, and reported a beautifully clean "0 mismatches" over an empty comparison set.
Only two statuses mean "no trustworthy output":

    rc == 124  -> timeout killed it
    rc >= 128  -> killed by a signal (139 SIGSEGV, 134 SIGABRT, ...)

Everything else, including 1, is a completed run. Excluded packages are PRINTED, and the summary
line now carries compared= and excluded= alongside the mismatch counts, so an exclusion reads as
unmeasured rather than clean (the #268 lesson: capped/excluded packages are not passing packages).

**Proven with deterministic controls, not by observation.** The natural candidate --
core/rexcode/isa/riscv/tablegen/generated, which segfaulted last tick -- did NOT crash on the
control run, because that crash is intermittent. An intermittent failure cannot serve as a positive
control. Instead a fake PORT binary that always `kill -SEGV $$`, and one that always hangs:

    control A (always SIGSEGV):  EXCLUDED ... port=SIG11    excluded=1 count_mismatches=0
    control B (always hangs):    EXCLUDED ... port=TIMEOUT  excluded=1 count_mismatches=0
    negative control:            4 real packages, excluded=0, cbor still COUNT -- rc=1 not misread

Generalised rule worth keeping: **when a bug is intermittent, it cannot validate the fix for the
instrument that measures it -- synthesise a deterministic failure instead.**

### #275 verified at full corpus -- and it corrects a claim I repeated for several ticks

    default : packages=225 compared=219 excluded=6 count_mismatches=0 text_mismatches=0
    vet     : packages=225 compared=217 excluded=8 count_mismatches=1 text_mismatches=0

I have been reporting "parity 225/225 clean" since #269. That was WRONG in a specific way: 6-8
packages per run never completed, and the old script scored them anyway. Where both sides happened
to produce nothing they registered as an accidental MATCH, which is how a crash could be laundered
into evidence of parity. The correct statement is "219 of 225 compared, 0 mismatches; 6 unmeasured".
Same #268 lesson as capped packages: excluded is not clean, and a tool that cannot say "I did not
measure this" will eventually say "this passed" instead.

**The crash surface is wider than #141's description.** Exclusions this run were SIG6 (SIGABRT, an
assertion failure), SIG11 (SIGSEGV) and SIG4 (SIGILL) -- not just the "double free or corruption"
that #141/#25 records. Roughly 3% of packages per run, and the SET varies run to run (default and
vet runs excluded overlapping but different packages), confirming it is nondeterministic rather than
input-specific. #141 should be widened to cover SIGABRT/SIGILL, not only the double-free signature.

**Remaining real divergences after this tick:**
  default mode : NONE across 219 compared packages
  vet mode     : ONE -- core/encoding/cbor, which is #276 (the polymorphic duplicate-vet race)

So the entire measured divergence surface, in both modes, is now a single known defect plus the
crash exclusions.

### #276 trigger isolated by ablation -- the polymorphic CALLEE is the whole story

Four variants, each repeated 10-12x because the defect is intermittent and a single run proves
nothing here:

    A  poly-typed literal bound to a variable, no call     0/12
    B  literal passed to a NON-polymorphic proc            0/10
    C  literal passed to a POLYMORPHIC proc, poly struct   6/10
    D  literal passed to a POLYMORPHIC proc, PLAIN struct  4/10

So the minimal trigger is: **a proc literal passed as an argument to a POLYMORPHIC procedure, whose
body uses the intentional self-shadow idiom `x := x`.** Neither the polymorphic struct
(D reproduces without it) nor the literal alone (A) nor the call alone (B) is sufficient.

This matters for scope: it is not a cbor curiosity. `slice.sort_by`, `slice.sort_by_cmp`,
`slice.map` and friends are all polymorphic and are routinely called with exactly this literal
shape, and `a, b := a, b` is the idiomatic way to get mutable parameters. cbor is simply the only
corpus package that currently combines them.

Mechanism, consistent with the earlier trace: instantiating the polymorphic callee causes the
literal argument to be checked more than once, producing two sets of parameter entities for a/b.
The initialiser ident resolves to one set while scope_lookup(parent) returns the other, and C++'s
deliberate pointer-identity test (init->Ident.entity == shadowed) then fails to suppress.

Note the proc_body_checked guard is NOT the gap -- it is present and mirrors C++ (check_proc.odin
175/187/723 <-> checker.cpp 6466/6473/6604). It guards NAMED procedure entities; an anonymous
literal argument has no such entity to gate on.

NEXT: find where the literal argument is checked twice during polymorphic instantiation. #81's
"pre-pass type probe discards diagnostics" is the prime suspect -- if the probe pass creates
parameter entities and only the DIAGNOSTICS are discarded, the stale entities survive into the vet
pass. Verify whether C++ probes the same way and what it does with the entities.

### #276 mechanism CONFIRMED, and the defect is DETERMINISTIC even though the symptom is not

Instrumenting the port's Proc_Lit arm (check_expr.odin:7680) to print the node pointer:

    run 1:  2x proclit node=0x...D38  main.odin:6:14   shadow errors: 2
    run 2:  2x proclit node=0x...D38  main.odin:6:14   shadow errors: 2
    run 3:  2x proclit node=0x...D38  main.odin:6:14   shadow errors: 0

**The SAME Proc_Lit node enters the arm exactly TWICE on every run.** The arm ends in
check_procedure_later_from_params, so the body is QUEUED TWICE, producing two independent sets of
parameter entities for a/b. Whether the spurious shadow surfaces afterwards is order-dependent --
run 3 double-checked and still reported nothing.

**This splits the phenomenon cleanly, and it changes how a fix must be verified:**
  - the DEFECT (proclit checked twice) is 100% deterministic, 3/3 runs
  - the SYMPTOM (spurious shadow diagnostic) is intermittent, ~50-75%

So the fix should be verified on the ENTRY COUNT (deterministic, n=3 suffices) rather than on the
diagnostic (flaky, needs n>=24). The previously-recorded "verify with n>=24" advice was right for
the symptom but unnecessarily weak now that a deterministic detector exists. Keep the n>=24 run as a
secondary confirmation, but the count is the primary signal.

**C++ has only ONE checking arm for ProcLit**, and it also calls check_procedure_later
unconditionally (check_expr.cpp:12349-12389; the second `case_ast_node(pl, ProcLit)` at 12917 is
write_expr_to_string, i.e. printing, not checking). Since C++ does not double-queue, the divergence
is that the port CHECKS THE ARGUMENT EXPRESSION an extra time on the polymorphic-call path, not that
its ProcLit arm is wrong. The arm is faithful; its caller runs twice.

Also note: the port's comment on that arm cites "check_expr.cpp:11630-11672", which is now the
type-assertion code -- the real arm is 12349-12389. Another instance of reference rot; the citation
should be corrected when this is fixed.

NEXT: the repro calls a SINGLE polymorphic proc, not a proc group, so the group scoring loop
(check_proc_group.odin:1756, which probes with .No_Errors) is not the path. Find the single-proc
polymorphic instantiation path in check_expr.odin and determine where it re-checks arguments;
compare against C++, which reuses the operands from its one pass.

## #276 ROOT CAUSE: the port has a bespoke polymorphic pre-pass C++ does not have (progress#277)

**C++ checks each argument exactly ONCE** (check_expr.cpp:8055-8113, the single-procedure path):

    check_unpack_arguments(c, lhs, lhs_count, &positional_operands, positional_args, ...);   // once
    ... named args via check_expr_with_type_hint, once each ...
    check_call_arguments_single(c, call, operand, nullptr, proc_type,
                                positional_operands, named_operands, ShowErrors, &data, false);

Polymorphic instantiation happens INSIDE check_call_arguments_single, consuming those
already-checked operands. There is no separate inference pass and no re-check.

**The port checks each argument TWICE** (check_expr.odin:10031+, check_call_arguments_basic):

    if pt.is_polymorphic {
        ... builds its own poly_operands by calling check_expr_or_type on every argument ...  // check 1
        ... find_or_generate_polymorphic_procedure_from_parameters(...) ...
    }
    // Continue with normal argument checking using the specialized type                       // check 2

The `poly_operands` pre-pass is a port invention: an extra traversal whose only purpose is to feed
type inference, after which control falls through to the ordinary argument checking that traverses
the same expressions again. For most argument kinds a second check is merely wasteful; for a proc
LITERAL it is a correctness bug, because that arm ends in check_procedure_later_from_params and so
QUEUES THE BODY A SECOND TIME -- yielding two parameter-entity sets and the spurious self-shadow.

This is the "restructured reimplementation" class CLAUDE.md forbids, not a missing line. The fix is
structural: the polymorphic path must consume the operands from the single normal unpack rather than
pre-checking arguments itself, matching C++'s one-unpack-then-instantiate-inside shape.

Deliberately NOT attempted at the end of a long tick -- this touches the main call path that every
package exercises, and both parity instruments plus the sweep must re-run behind it.

### Two citation-rot findings in the same block, recorded not silently patched

1. check_expr.odin:7683 (Proc_Lit arm) cites "check_expr.cpp:11630-11672". That range is now the
   type-assertion code; the real ProcLit arm is 12349-12389.
2. check_expr.odin:~10175 cites "LEDGER task 278/279". Verified by grep: NO such tasks exist -- the
   task list ends at #276 and the LEDGER has no #278/#279. A forward reference to numbers that were
   never allocated. Same class as the #42 rot (progress#272): fixing one instance is not fixing the
   class, so both are recorded here and should be corrected when #276's fix lands.

### #276 EDIT PLAN (boundaries computed; next tick executes mechanically)

Design is settled and the exact line boundaries are measured, so the next tick edits rather than
re-derives. check_call_arguments_basic spans check_expr.odin:10028-10744 (716 lines).

    poly block  : 10042..10214  (173 lines)  `if pt.is_polymorphic { ... }`
    named loop  : 10325..10357  `for fv in named_args { ... }`
    INSERT AFTER: 10357

**Move the poly block from 10042 to after 10357, and stop it re-checking arguments.**

C++ ordering, confirmed from three separate sites, all agree the block belongs LATE:
  - check_expr.cpp:8055-8113  unpack args ONCE, then check_call_arguments_single
  - check_expr.cpp:6835-6844  missing-parameter loop runs BEFORE instantiation
  - check_expr.cpp:6931       `if (pt->is_polymorphic && !pt->is_poly_specialized && err == None)`
The port's placement at the very TOP of the function is the structural error: it forces a bespoke
argument pre-pass to exist at all, because at that point nothing has been unpacked yet.

Rewrite inside the moved block:
  - DELETE the two pre-pass loops (10088-10099) that call check_expr_or_type per argument.
  - BUILD poly_operands from what already exists at the insertion point:
      * ordered_operands[i]      for parameters filled by a named argument (visited[i])
      * positional_operands[...] consumed in order for the rest
    poly_visited collapses into the existing `visited` plus positional consumption.
  - KEEP verbatim: the poly_missing_required gate, find_or_generate_..., the gen_entity update,
    and the where-clause committed pass. Those are already faithful.

After instantiation, RECOMPUTE the pt-derived locals that were computed from the GENERIC pt at
10217-10250 and are stale once pt becomes specialized:
    variadic_index, variadic_elem_type, is_variadic_any, param_types
`param_count`, `visited` and `ordered_operands` keep their sizes -- specialization changes parameter
TYPES, not the parameter count -- so no reallocation is needed. Unpacking with the GENERIC signature
as `lhs` is correct and is what C++ does (populate_proc_parameter_list on the pre-instantiation
proc_type).

Also correct while in here (verified rotted this tick):
  - 10270-10272 comment claims "This is the only place the positional arguments get checked;
    everything below consumes positional_operands rather than the raw argument nodes." FALSE today
    for polymorphic calls -- the pre-pass checked them first. It becomes TRUE once this lands.
  - 7683 cites check_expr.cpp:11630-11672 -> real ProcLit arm is 12349-12389
  - ~10175 cites "LEDGER task 278/279" -> no such tasks exist

VERIFY IN THIS ORDER (primary signal is deterministic, so failure is cheap to detect):
  1. build; Proc_Lit entry count on scratchpad/shadowvar must go 2 -> 1 (n=3, deterministic)
  2. odin check . -vet -strict-style -no-entry-point   rc=0
  3. shadowvar variant D: 0 shadow errors over n>=24 (flaky symptom, secondary)
  4. probe corpus; then parity.sh AND parity_vet.sh over allpkgs; then sweep_det + swdiff
  5. REVERT from scratchpad/ce_276fix.bak if any of 1-4 regress -- this is the main call path that
     every package exercises, so a partial fix is worse than none.

## #276 FIXED: the invented polymorphic pre-pass is gone (progress#278)

Moved the 173-line `if pt.is_polymorphic` block from the TOP of check_call_arguments_basic to after
the named-argument loop, deleted its two bespoke `check_expr_or_type` pre-pass loops, and sourced
poly_operands from the operands the ordinary unpack already produced. This is C++'s shape: one
unpack, then instantiation INSIDE the committed pass (check_expr.cpp:8055-8113).

Four locals derived from the GENERIC pt are recomputed after specialization (variadic_index,
variadic_elem_type, is_variadic_any, param_types). Sizes are untouched -- specialization changes
parameter TYPES, not the parameter count -- so param_count, visited and ordered_operands stay valid.

### Results

    Proc_Lit entry count (DETERMINISTIC)   2 -> 1   (3/3 runs)
    shadowvar variant D                    4/10 -> 0/24
    core/encoding/cbor under vet           oracle=1 port=5 -> oracle=1 port=1
    odin check . -vet -strict-style        rc=0
    parity.sh      224 compared, 1 excluded, 0 count, 0 text
    parity_vet.sh  224 compared, 1 excluded, 0 count, 0 text
    swdiff sw_176 -> sw_276                error-count differences: 0
                                           unstable 5 -> 1, STABLE 216 -> 220

**The vet-mode divergence surface is now EMPTY.** cbor was the last one (progress#274 recorded it as
the sole real residual); both modes are now 0 count / 0 text over 224 compared packages.

Unexpected bonus, worth noting because it was not the goal: the sweep's UNSTABLE count fell 5 -> 1
and STABLE rose 216 -> 220. Removing a redundant traversal of every polymorphic call's arguments
plausibly reduced exposure to the #141 race, but this is ONE observation of a nondeterministic
quantity and must not be quoted as "the fix reduced crashes" without repeated runs. Recorded as a
hypothesis, not a result.

### The probe corpus FULL-DIFFER=2 is NOT a regression -- checked, did not assume

cmpfull.py reported FULL-DIFFER=2 where the corpus had been 0. Both differ identically:

    oracle: main.odin(1:1) Error: Undefined entry point procedure 'main'
    port  : <missing>

Control: running the PRE-#276 binary (st_179) over the same probe set gives the SAME FULL-DIFFER=2.
So the cause is the two vet probes added this session (vet_unused, vet_import) -- neither declares
`main`, and cmpfull.py invokes the oracle in a mode that demands an entry point, while the port
harness does not. A tooling artifact of MY OWN probe additions, not a checker divergence.

This is why the pre-change control matters: "the corpus was 0 DIFFER before my edit" was true but
misleading, because the corpus had also GAINED two probes since that measurement. Comparing against
the remembered number rather than a re-run of the old binary would have manufactured a regression.

### Probe corpus restored to clean, and the two vet probes are now oracle-comparable

Appended `main :: proc() {}` to vet_unused and vet_import -- at the END of each file, so the
diagnostic line numbers the probes assert on (3:8, 6:2, 11:2, 15:2) are unchanged. Both now match
the oracle exactly under -vet (3 and 2 diagnostics respectively, byte-identical after sort).

    probe corpus: 65 FULL-MATCH / 0 FULL-DIFFER   (was 63/0 before the two vet probes existed)

Lesson for future probe authorship: cmpfull.py does NOT pass -no-entry-point to the oracle, so every
probe package must declare `main` or the oracle emits "Undefined entry point procedure 'main'" that
the port harness never produces. All 63 pre-existing probes already did; mine did not, and that is
what manufactured the phantom FULL-DIFFER=2.

## #274 DONE: the SwitchValue arm of the stack-overflow warning (progress#279)

Filed unreproduced last tick, so the first step was establishing the direction rather than assuming
it. Probe swval (now in the corpus) declares a 512KiB variant and switches on it BOTH ways:

    ORACLE: 1 warning  -- line 17 only (the by-VALUE switch)
    PORT:   2 warnings -- line 9 (by-REFERENCE, spurious) + line 17

So the port OVER-warns. C++ checker.cpp:800-808 derives is_ref from two flags:

    if ((e->flags & EntityFlag_ForValue) != 0) {
        is_ref = type_deref(e->Variable.for_loop_parent_type) != NULL;
    } else if ((e->flags & EntityFlag_SwitchValue) != 0) {
        is_ref = !(e->flags & EntityFlag_Value);
    }

Only the ForValue arm was ported. Added the else-if. The flags it reads were already correct:
check_stmt.odin:2508 adds .Switch_Value unconditionally and .Value only when the binding is not
addressed, mirroring check_stmt.cpp:1603 -- so this really was one missing branch, not a layer.

**The probe deliberately covers BOTH directions.** After the fix the by-VALUE warning at line 17
still fires; that is what distinguishes a correct fix from `is_ref = true`, which would also have
made a one-sided probe pass. A probe that only tests the case you expect to change cannot tell a fix
from an over-suppression.

### Verification -- the cleanest full-corpus result so far

    odin check . -vet -strict-style   rc=0
    probe corpus                      66 FULL-MATCH / 0 FULL-DIFFER
    parity.sh                         224 compared, 1 excluded, 0 count, 0 text
    parity_vet.sh                     224 compared, 1 excluded, 0 count, 0 text
    swdiff sw_276 -> sw_274           error-count differences: 0
                                      diagnostic-text differences: 0
                                      unstable 1, STABLE 224, stable totals 64=64

STABLE has climbed 216 -> 220 -> 224 across the last three fixes and diagnostic-text differences are
now 0 (they were 4-7 crash lines before). Both parity modes are 0/0.

## NEW, and it was hiding inside the exclusion list: Foundation crashes DETERMINISTICALLY

core/sys/darwin/Foundation has been the single EXCLUDED package in the last three parity runs. I had
been mentally filing it under #141 (intermittent, ~3%/run, set varies). Measured directly:

    8 runs, 8 crashes, rc=132 (128+4 = SIGILL) -- 100%, not intermittent

That is a DIFFERENT defect from #141. #141's signature is a varying set of packages at ~3% per run;
this is one specific package, every time, with a consistent signal. It was invisible as a distinct
problem precisely because #275's new exclusion partition lumps it in with the flaky crashes -- the
partition correctly stops it corrupting parity counts, but "excluded" is not "diagnosed".

Filed separately. Note the connection to #21 (objc_class_implementations teardown asserts on
darwin): Foundation is the objc-heavy package, so these may share a root cause.

## #277 PARTIAL: crash fixed, but it was masking an over-rejection (progress#280)

**Root cause of the SIGILL.** check_objc_methods asserts `t.kind == .Named` on ac.objc_type
(check_decl_helpers.odin:2005), on the stated grounds that it was "already checked at attribute
resolution stage". C++ carries the IDENTICAL GB_ASSERT and comment (check_decl.cpp:1061), so the
assert is faithful -- the divergence was upstream. C++ checker.cpp:3806-3820 assigns ac->objc_type
ONLY when has_type_got_objc_class_attribute passes:

    Type *objc_type = check_type(c, value);
    if (objc_type != nullptr) {
        if (!has_type_got_objc_class_attribute(objc_type)) { error(...); }
        else { ac->objc_type = objc_type; }
    }

The port assigned it unconditionally -- no nil check, no @(objc_class) guard, no diagnostic. That is
an under-rejection in its own right AND it broke the assert's precondition. Fixed by porting C++'s
guard verbatim. Foundation: 8/8 crashes -> 0/8.

**I re-made a mistake this LEDGER already records.** My first version wrote
`type_str := type_to_string(type_val); defer delete(type_str)`, and Foundation immediately aborted
with "free(): invalid pointer". #142 records exactly this: type_to_string's result is not owned by
the caller. Every other call site in the checker leaves it alone; I did not check before writing.
The comment at the site now states this so the next author does not repeat it a third time.

**NOT DONE, and the crash was hiding it.** Foundation now checks without crashing but reports 24
errors where the oracle reports 0:

    2  Illegal declaration cycle of `Array` / `String`
    12 'objc_type' expected a named type with @(obj_class=<string>), got type invalid type
    (rest are cascades)

The objc_type messages are CASCADES -- they say "got type invalid type", i.e. check_type already
failed. The real defect is the declaration-cycle over-rejection on Array/String, which C++ does not
report.

**What I CANNOT yet claim:** whether that cycle error is pre-existing or newly introduced. The
pre-fix binary printed ZERO diagnostics, but that is not evidence -- diagnostics are collected and
flushed by print_package_diagnostics at the end, and the abort pre-empted the flush. So "0 cycle
errors before" is an artifact of the crash, not a measurement. Reasoning says my guard cannot affect
type resolution of Array (it only gates an attribute assignment), but that is an argument, not a
measurement, and this LEDGER has several entries where the argument lost. Left explicitly open.

Foundation therefore moves from "excluded, crashing" to "compared, over-rejecting" -- real progress,
since an over-rejection is measurable and a crash is not, but #277 stays OPEN.

### #277's residual is PRE-EXISTING and objc-independent -- settled by measurement

Last entry left open whether the Array/String declaration cycle was pre-existing or introduced by my
guard, because the crashing binary printed zero diagnostics and so "0 before" was an artifact, not a
measurement. Reduced repro (probe polycyc), with NO objc attributes anywhere:

    Object  :: struct { isa: rawptr }
    Copying :: struct($T: typeid) { using _: Object }   // T is NEVER used in the body
    Array   :: struct { using _: Copying(Array) }

    ORACLE                : silent
    PORT pre-#277 (st_274): Illegal declaration cycle of `Array`
    PORT post-#277        : Illegal declaration cycle of `Array`   (identical)

Both port binaries produce it and the oracle produces neither. PRE-EXISTING, and nothing to do with
the objc_type guard. My reasoning last tick ("the guard only gates an attribute assignment, it
cannot affect Array's type resolution") turned out correct -- but it was an argument, and this
LEDGER has entries where the argument lost, so it needed the reduced repro to become a fact.

**The defect:** `Copying`'s polymorphic parameter T is never referenced in its body, so `Copying(X)`
does not embed X for any X, and `Array` is not self-referential. The port's declaration-cycle
detection nonetheless treats the polymorphic ARGUMENT as a dependency edge. C++ follows actual field
types and sees no cycle. Filed as #278.

**Probe corpus note:** polycyc is added as a KNOWN-FAILING probe, so the corpus is now
66 FULL-MATCH / 1 FULL-DIFFER rather than 67/0. That is deliberate -- a real open defect with a
minimal repro belongs in the corpus where it cannot be forgotten, and the DIFFER count is the honest
representation of it. Do NOT "restore 0 DIFFER" by removing the probe; it clears when #278 is fixed.

### #278 narrowed: type_path holds `Array` TWICE, and every structural comparison point MATCHES

Instrumented check_cycle to dump the path when it fires:

    [CYCDBG] cycle curr=Array path=[Array Array]

So `Array` is on the type path twice while `Copying(Array)`'s argument is resolved, and check_cycle
correctly reports a repeat. The question is why C++ does not.

**First instrumentation went to the WRONG site, and the measurement said so immediately.** I
instrumented check_entity_decl (check_decl.odin:598), which is one of two places emitting this
message. It produced zero CYCLE-ERR lines and showed `Array` entered exactly ONCE -- so the
diagnostic comes from the other site, entity_helpers.odin:1399 (C++ check_expr.cpp:1811). Reading
would have picked one of the two sites and had a 50% chance of being wrong for the rest of the tick.

**Everything structural compared EQUAL:**

    check_cycle body            entity_helpers.odin:1383  <-> check_expr.cpp:1803   identical logic
    check_type_path_push sites  2 in port                 <-> 2 in C++
      site A                    check_decl_helpers:1844   <-> check_decl.cpp:471    identical context
      site B                    check_decl.odin:653       <-> check_decl.cpp:2042   identical, incl.
                                                              the track_cycle_path kind switch
    check_cycle call sites      2 in port                 <-> 2 in C++
      guard                     check_expr.odin:495       <-> check_expr.cpp:1960   same kind switch

Both compilers therefore push Array at BOTH sites, so C++'s path should also read [Array Array] --
yet C++ reports nothing. My model is incomplete: something stops C++ reaching check_cycle for the
polymorphic ARGUMENT `Array`, or Array is already Resolved there. Candidates, untested:
  (a) C++ resolves a polymorphic type argument through a path that never calls check_ident's
      check_cycle (poly instantiation handles the argument directly);
  (b) C++'s Array is Resolved by that point because struct field resolution is deferred differently.

**NEXT: instrument the C++ side.** This is exactly the case the user's standing hint covers ("when
you're spinning, you could add some logs to the cpp paths; so long as it isnt committed"). Print in
C++ check_cycle: curr name, state, and the full type_path, on the polycyc input. If C++'s path is
NOT [Array Array] the divergence is in the push/pop pairing; if it IS but check_cycle is never
reached, the divergence is in the argument-resolution path. Those point at different fixes, and
guessing between them is what this tick has already shown to be unreliable.
Remember: back up ./odin first and restore src/ pristine afterwards.

## #278 ROOT CAUSE, found by instrumenting the ORACLE (progress#281)

Four structural comparison points all matched (check_cycle body, both push sites, both call sites,
both guards), so reading had run out. Instrumented C++'s check_cycle and check_type_path_push behind
`getenv("ODIN_CYCDBG")` and ran the polycyc probe. C++ trace, filtered to the probe's entities:

    [CPP-PUSH] name=Object  state=1
    [CPP-PUSH] name=Copying state=1
    [CPP-PUSH] name=Array   state=1
    [CPP-CYC]  curr=Copying state=2 path=[Array Array ]
    [CPP-CYC]  curr=Array   state=1 path=[]          <-- THE DIVERGENCE
    [CPP-CYC]  curr=Object  state=2 path=[Array Array ]

C++'s path is ALSO [Array Array] for Copying and Object -- identical to the port. The difference is
the single line where curr=Array: C++ resolves the polymorphic ARGUMENT with an EMPTY type_path,
while the port resolves it with [Array Array] and therefore reports a cycle.

**The site, with C++'s own comment stating the intent** (check_expr.cpp:8166-8173):

    // NOTE(bill, 2019-10-26): Allow a cycle in the parameters but not in the fields themselves
    auto prev_type_path = c->type_path;
    c->type_path = new_checker_type_path();
    defer ({
        destroy_checker_type_path(c->type_path);
        c->type_path = prev_type_path;
    });

C++ swaps in a FRESH type path around the polymorphic record's argument checking, deliberately, so
that a cycle THROUGH THE PARAMETERS is legal while a cycle through the FIELDS is still caught. The
port never ported the swap, so the enclosing path leaks into argument checking and
`Array :: struct { using _: Copying(Array) }` is rejected.

This also explains why every structural comparison matched: the missing code is not in the cycle
machinery at all, it is a context save/restore AROUND the caller. Comparing the two implementations
of check_cycle forever would never have found it -- the defect is in what the caller does to the
shared context before calling in.

**The user's standing hint is what unblocked this.** "when you're spinning, you could add some logs
to the cpp paths; so long as it isnt committed may help diagnose" -- this is the second time that
advice has broken a stall (first: #260's variadic flag site). Instrumenting the reference is the
move when N structural comparisons all come back equal.

Oracle discipline: ./odin backed up (md5 1e53368a40545f2d0be4a5012fee27f6), src/check_expr.cpp and
src/checker.cpp restored from pristine copies, oracle rebuilding to verify byte-identical before any
parity run is trusted again. Instrumentation was env-gated so the instrumented binary behaved
identically when ODIN_CYCDBG was unset.

### Oracle restore verified BEHAVIOURALLY, not by md5 -- and the first check was a false alarm

After restoring src/ pristine and rebuilding, the oracle's md5 did NOT match the pre-instrumentation
backup (41e9db34... vs 1e53368a...). src/ showed an empty diff vs HEAD and zero instrumentation
strings, so the binary difference is build non-reproducibility (-march=native, timestamps, embedded
GIT_SHA), not surviving instrumentation. **The build is not byte-reproducible; do not use md5 as the
restore criterion in future -- use behaviour.**

First behavioural comparison reported 7/7 DIFF, which looked catastrophic. It was an artefact of the
METHOD: the saved pristine binary lives in the scratchpad, and a copied odin cannot find its library
collections, so every invocation of it failed with

    Internal Compiler Error: Cannot find the library collection 'base'. Is the ODIN_ROOT set up correctly?

I was comparing working output against a binary that could not run. Re-running with
ODIN_ROOT=/home/kalsprite/dev/odin exported gives 0/7 differences across cbor, container/queue,
crypto/rsa, text/regex, polycyc, swval and vet_import. The oracle is sound.

Two process notes worth keeping:
  - An aggregate "7/7 DIFF" is not a finding until one actual diff has been read. Reading the first
    one took a single command and turned a scare into a method bug.
  - A COPIED odin binary needs ODIN_ROOT exported to work at all. Any future oracle A/B against a
    scratchpad copy must set it, or the comparison is vacuous in the most misleading direction:
    it makes the restored compiler look broken.

## #278 type_path swap LANDED; my objc_is_class_method fix HUNG and was reverted (progress#282)

**Landed:** the fresh-type_path swap around polymorphic-record argument checking
(check_expr.odin, before operand_list is built), mirroring check_expr.cpp:8166-8173.

    probe polycyc:  port 1 error -> 0 errors, oracle 0.  FULL-MATCH.
    Foundation:     "Illegal declaration cycle" 2 -> 0, and the objc_type cascades with them.

**Reverted:** while fixing the next-layer divergence exposed by that, I made it worse. Foundation's
remaining 36 errors are all `'objc_is_class_method' expects no parameter`. The port treats that
attribute as valueless and errors on any value; C++ (checker.cpp:3798-3805) REQUIRES a boolean and
assigns it. The port is inverted twice over -- it rejects `=true` AND would set the flag true for
`=false`. I ported C++'s handler.

Result: **Foundation stopped terminating.** rc=124 at a 30s cap, where it had produced 36 errors in
seconds. Accepting the attribute evidently lets objc method processing proceed into a
non-terminating path. core/container/queue and polycyc were unaffected, so it is specific to that
route. A HANG IS WORSE THAN AN OVER-REJECTION -- errors are measurable, a hang removes the package
from measurement entirely and stalls every sweep. Reverted check_decl_helpers.odin to its #277
state; the objc_type guard from #277 is kept, only the objc_is_class_method change is gone.

**A near-miss worth recording.** My first attempt used `Exact_Value_Bool`, which does not exist --
the union uses plain `bool`. The build failed, and because I had chained
`./odin build ... | head` with the port invocations in the SAME command, the subsequent runs
reported "PORT: 0" for both Foundation and polycyc. Zero errors from a binary that was never
produced. It looked exactly like success. The tell was that `BUILD-OK` never printed. Fixed by
testing the build's exit status explicitly and asserting the binary exists before using it -- worth
keeping as a habit, since "0 errors" is the most dangerous possible false positive here.

**State: Foundation 21 -> 36 errors, one clean class instead of a mixed cascade.** The count is
worse; the structure is better (root cause removed, one pre-existing over-rejection fully exposed).
NOT claiming this as an improvement in the parity metric -- it is a regression there, and #278 stays
open until the objc_is_class_method route is fixed WITHOUT hanging.

### type_path swap VERIFIED SAFE across the corpus

    probe corpus   67 FULL-MATCH / 0 FULL-DIFFER   (polycyc cleared; was 66/1)
    parity.sh      224 compared, 1 excluded, count_mismatches=1 (Foundation), text=0
    parity_vet.sh  223 compared, 2 excluded, count_mismatches=1 (Foundation), text=0
    odin check . -vet -strict-style  rc=0

No regression anywhere. The swap is kept. The known-failing probe added in progress#280 is now a
passing probe, which is the intended way for that entry to clear -- by fixing the defect, not by
deleting the probe.

Foundation is the sole remaining divergence in BOTH modes, at oracle=0 port=36, all one class
(`'objc_is_class_method' expects no parameter`). Recorded again for honesty: that count is UP from
21, because removing the cycle root let checking reach a pre-existing over-rejection that the
cascade had been hiding. Structure improved, metric regressed.

### #278 part 2: the hang localized to a branch the OLD BUG had kept permanently dead (progress#283)

Two hypotheses tested and killed by measurement, in order:

1. **"The minimal objc shape hangs."** Built a minimal probe (objc_class + objc_type + objc_name +
   objc_is_class_method=true + objc_send). rc=0. Does NOT hang. So the shape alone is not enough.

2. **"check_objc_methods loops."** Instrumented it with an atomic call counter printing the first
   40 hits and every 5000th. Result: exactly 40 enters, no growth, then silence while the process
   spun. check_objc_methods is NOT the loop. This was my stated next-step hypothesis last tick and
   it was wrong; the counter said so in one run.

**Bisect result, and how it misled me.** 44 of Foundation's 45 files pass; adding objc.odin hangs.
But objc.odin contains NO objc_* attributes -- it defines the dispatch helpers (msgSend etc.) the
other 44 files call. Without it those calls are unresolved, checking bails early, and the loop is
never reached. So "objc.odin is the trigger" is FALSE; the real condition is "the package resolves
completely". A bisect over files finds the last file needed to make the program valid, not the file
containing the defect -- worth remembering before trusting a file-level bisect again.

**Where it actually is.** ac.objc_is_class_method is read at check_decl_helpers.odin:2060, 2078,
2085, 2135 and 2167. The 2167 site is:

        md := tn_type_name.objc_metadata
        sync.mutex_lock(&md.mutex)
        defer sync.mutex_unlock(&md.mutex)
        if !ac.objc_is_class_method {
            ... scan md.value_entries, append ...
        } else {
            ... scan md.type_entries, append ...
        }

The old code set ac.objc_is_class_method = true UNCONDITIONALLY, so `!ac.objc_is_class_method` was
never true and the INSTANCE-METHOD arm was permanently dead. Correcting the flag activates dead
code, under a mutex, and the process stops terminating -- a hang, not a spin, which fits a
non-recursive mutex being re-entered on one thread rather than an infinite loop.

**This is the #266 pattern again**: a defect that made a branch unreachable, hiding a second defect
inside it. Fixing the first exposes the second, and the second is worse. The attribute fix stays OUT
until the lock discipline in that block is understood.

Source restored to the #277 state (objc_type guard kept, attribute fix removed, no instrumentation);
Foundation rc=0, back to its 36 over-rejections.

### #278 part 2: third hypothesis dead -- the lock structure is FAITHFUL

Predicted last tick: "if C++ holds no lock there, or a different one, the port's mutex is the
invention". Wrong. Side by side:

    C++ check_decl.cpp:1183-1191          port check_decl_helpers.odin:2151-2159
    mutex_lock(&global_..._mutex)         sync.mutex_lock(&global_type_name_objc_metadata_mutex)
    defer unlock                          defer sync.mutex_unlock(...)
    if (!tn->TypeName.objc_metadata)      if tn_type_name.objc_metadata == nil
        ... = create_..._metadata()           ... = create_type_name_objc_metadata(...)
    md = tn->TypeName.objc_metadata       md := tn_type_name.objc_metadata
    mutex_lock(md->mutex)                 sync.mutex_lock(&md.mutex)
    defer unlock                          defer sync.mutex_unlock(&md.mutex)

Same two locks, same order, same lazy creation, same deferred release. The port even has the global
mutex declared with a citation (objc_helpers.odin:11-13 <- entity.cpp:141). Nothing invented here.

**Hypotheses killed on #278 part 2 so far, all by measurement:**
  1. minimal objc shape hangs                     -> NO, rc=0
  2. check_objc_methods loops                     -> NO, exactly 40 enters, no growth
  3. port's objc_metadata locking diverges        -> NO, structurally identical to C++
  4. objc.odin is the trigger file                -> NO, it has no objc attributes; it merely
                                                     completes resolution so the path is reached

Four wrong guesses. The pattern in all four: I proposed a mechanism from reading and it did not
survive contact with a measurement. The remaining honest step is to stop proposing mechanisms and
instrument the lock itself -- print enter/exit around both acquisitions with thread and entity, and
see which acquisition never returns. That names the deadlock instead of guessing at it.

DEPRIORITISATION NOTE: the tree is in a good state without this (Foundation terminates, 36 known
over-rejections, both parity modes otherwise clean, corpus 67/0). #278 part 2 has now consumed
several ticks. Give it ONE more tick with lock instrumentation; if that does not name the site,
park it and return to the backlog rather than continuing to spend on a single package.

### #278 part 2 PARKED at the budgeted stop -- 5 hypotheses dead, hang located OUTSIDE the suspect

Final budgeted attempt: instrumented BOTH lock acquisitions (want/got, per entity) and re-applied
the attribute fix to reproduce. Result:

    703 want-global   703 got-global   703 want-md   703 got-md      <- perfectly balanced
    703 got-md events, 703 DISTINCT entity names                     <- zero repeats
    trace still advancing through new names when killed at 20s

**Not a deadlock and not a re-registration loop.** Every lock taken is released, and every objc
method registers exactly once (703 is a plausible count for Foundation). The block I had localized
to last tick -- the objc_metadata mutex region at check_decl_helpers.odin:2151-2199 -- runs to
completion and is INNOCENT. The non-termination is downstream of it.

**Hypotheses killed on this one defect, all by measurement:**
  1. minimal objc shape hangs                  -> NO (rc=0)
  2. check_objc_methods loops                  -> NO (40 enters, no growth)
  3. objc_metadata locking diverges from C++   -> NO (structurally identical, both locks, same order)
  4. objc.odin is the trigger file             -> NO (no objc attributes; only completes resolution)
  5. deadlock / repeated registration in 2167  -> NO (703/703 balanced, 703 distinct, still advancing)

Five wrong mechanisms. Every one came from reading and died to a measurement, which is the same
lesson as progress#281 but at a higher price: I kept proposing where the bug "must" be instead of
first asking the process where it actually was. For a HANG specifically, the cheap first move is a
sampling profile or a coarse phase trace ("which checker phase am I in?"), NOT a targeted probe on
the function I suspect -- a targeted probe can only ever confirm or deny one guess, while a phase
trace localises in one run regardless of which guess was right.

PARKED per the stop condition recorded last tick. Tree restored to the #277 state: Foundation
terminates (rc=0) with its 36 known over-rejections, vet rc=0, corpus 67/0, both parity modes clean
apart from that one package. The attribute fix stays OUT.

Cost check: #278 part 2 consumed roughly four ticks for zero net change. That is the signal the
stop condition existed to catch, and it fired correctly. Next work goes to the backlog.

## #177 CLOSED as PREMISE-WRONG, with evidence from three directions (progress#284)

Claim: "Struct-field scopes lack the .Type flag, so vet reports every field as an unused variable
(68,119 spurious diagnostics)."

1. **Direct probe** (now .claude/probes/fieldvet): a struct with 7 fields incl. multi-name
   declarations, a `using` embed, a self-pointer, a map, plus a union and an enum over them.
   ORACLE -vet: 0 diagnostics. PORT under vet: 0 diagnostics. No field is reported.

2. **Corpus scale**: parity_vet.sh over 223 compared packages reports 0 TEXT mismatches. A defect
   producing 68,119 spurious unused-variable diagnostics could not hide there -- it would dominate
   every struct-bearing package.

3. **Source**: the port sets `.Type` on struct scopes at FOUR sites --
   check_type.odin:489, 870, 934, 3297 (`scope.flags += {.Type}`). The flag the task says is
   missing is set.

So the premise is false in measurement AND in code. Consistent with #178, which had already found
this task's sibling premise wrong ("the cause was a missing force_use on intrinsics imports, not vet
scoping"). Two tasks in the same family both rested on the same mistaken reading of the vet scoping
layer.

Why it survived so long: until #176 there was NO way to run the port in vet mode against the oracle,
so a claim about vet behaviour could be neither confirmed nor refuted. It sat pending for want of an
instrument, not for want of attention. That is the same shape as #176 itself -- the blind spot
protected the claim.

fieldvet added to the corpus as a PASSING probe (68 total) so the closure is regression-guarded
rather than a one-off observation.

## #210 REFINED: premise half wrong, half right, and the right half is not yet observable

Claim: "parser collects File_Tag tokens but never interprets #+vet, so file_allow_newline's per-file
term is dead."

**The CHECKER does interpret #+vet.** Probe: a file whose first line is `#+vet unused`, containing
an unused local, checked with NO global -vet.

    ORACLE: main.odin(7:2) Error: 'tagged_unused' declared but not used
    PORT  : main.odin(7:2) Error: 'tagged_unused' declared but not used     IDENTICAL

check_files.odin:434 reads the tag via get_vet_flag_from_name and sets file.vet_flags /
vet_flags_set. So "never interprets #+vet" is false as stated. (This is also a second-order
confirmation of #176: the per-FILE vet path reaches the proc body, not just the global one.)

**The PARSER does not.** parser.odin:514-516 says so in its own comment -- "the port's parser never
sets them, so file.vet_flags_set is always false here and the fallback always wins". file_vet_flags
therefore always returns p.vet_flags, and file_allow_newline's per-file term is dead AT PARSE TIME.
The function itself is faithful:

    port: is_strict := p.strict_style || .Style in file_vet_flags(p)
    C++ : bool is_strict = build_context.strict_style || ast_file_vet_style(f);

**Not yet observable.** Tried a `#+vet style` file with a brace on the following line, expecting the
oracle to reject at parse time and the port to accept. BOTH were silent, so that construct does not
exercise the difference and the test proves nothing either way. I do not have an input that
distinguishes the two compilers on this term.

Status: a real code-level gap (the parser never populates per-file vet flags) with NO demonstrated
behavioural consequence. That is the "necessary but not sufficient / inert" outcome this LEDGER
already treats as a legitimate result -- recording it as such rather than fixing an invisible
difference or claiming it is harmless. Whoever picks this up needs to find a construct where
-vet-style changes PARSE behaviour, and confirm the oracle actually diverges there, BEFORE touching
the parser.

## #149 residual dispositioned: TWO divergences at that site, both currently unobservable (progress#285)

The task recorded one residual (position). There are actually TWO, and I found the second only by
reading the surrounding control flow rather than the error line alone.

    C++ check_expr.cpp:6955-6968          port check_proc_group.odin:253-258
    if (o->mode != Addressing_Type) {     if operand.mode != .Type {
        if (show_error)                       if show_error
            error(o->expr, "Expected           error_node(call_node, "Expected a type
                  a type for the argument")          for the argument")
        err = CallArgumentError_WrongTypes;   return -1, true          <-- BAILS
    }                                     }
    if (are_types_identical(...)) {       if are_types_identical(...) { ... }
        score += assign_score_function(1);
    } else {
        score += MAXIMUM_TYPE_DISTANCE;
    }
    continue;                             <-- scores, then next parameter

  1. POSITION: C++ reports at `o->expr` (the offending ARGUMENT), the port at `call_node` (the whole
     CALL). Real, and the port is less precise.
  2. CONTROL FLOW (new, not in the task): C++ records err and CONTINUES scoring the parameter; the
     port returns -1 immediately.

**Both are currently unobservable, and I could not make either fire.**
  - The message did not appear from EITHER compiler on two repros: a direct call to
    `proc($T: typeid, x: int)` with a value argument (both emit "Expected a type to assign to the
    type parameter" from a different site), and a proc GROUP where a type-name candidate is offered
    a value (both emit only "No procedures or ambiguous call for procedure group 'g' ...").
  - The control-flow difference is masked because C++ returns `err` at the end of the function, so a
    candidate that hit this branch is rejected regardless of the score it accumulated. Port rejects
    via -1, C++ rejects via err. Same outcome, different route.

So the site is show_error-gated and, in group scoring, show_error is false -- exactly as the original
triage suspected. Recording as INERT rather than fixing: changing `call_node` to `operand.expr` is a
one-word edit, but with no input that reaches the line I could not tell a fix from a no-op, and this
run has already shown (progress#282) what shipping an unverifiable "correct in isolation" change
costs.

WHAT WOULD MOVE IT: find an input where show_error is TRUE at a type-name parameter mismatch. That
means the committed single-candidate pass, not group scoring. If such an input exists, fix BOTH the
position and the early return together -- they are one arm of one branch.

## #188 CLOSED: the "~83 near-misses" are gone; msgpair's 7 survivors are all false positives (progress#286)

The task cited ~83 near-miss messages in classes A/C/D/E, found by a tool called "textscan".
textscan does not exist in .claude/tools and is not described anywhere in this LEDGER -- it was a
scratch instrument, and like #165's fv1/lx/pe its output died with the scratch directory. Same
lesson as progress#274: an instrument that is not in .claude/tools is not an instrument, it is a
memory.

Reconstructed with the surviving equivalent, msgpair.py, which is stricter (it requires an EXACT
match after stripping a trailing operand clause). It reports 7 candidates, and its own header warns
that a hit is not a defect because both compilers keep bare and operand-bearing variants at
different call sites. Checked all 7 against their call paths:

    'X' expected a simd vector type            C++ ~38 bare + 4 with ", got"; port ~38 bare + 4 with
                                               ", got". Site-for-site correspondence.
    Expected a type for 'X'                    C++ 37 bare + 1 ", got"; port many bare + 2 ", got".
                                               Both variants present in both.
    Expected a bit_set type for 'X'            C++ bare at operand->expr + ", got" at ce->args[0];
                                               port has BOTH.
    Expected a type for the argument 'X'       C++ bare at 6958 + ", got" at 8378; port bare at
                                               check_proc_group:256 + ", got" at check_expr:9612.
                                               (Same site dispositioned in progress#285.)
    Extra initial expression 'X'               C++ 4692 with '%s' + 4695 bare; port 635 + 638. Pair
                                               for pair.
    Array count must be a constant integer     C++ 2829 ", got" + 2871 bare; port 6547 + 6615. Pair
                                               for pair.
    '%s' %s  vs  '%s'                          Spurious: stripping the operand from a generic
                                               "'%s' %s" yields "'%s'", which collides with a
                                               CONTINUATION line (check_import_export:493) that
                                               prints a quoted package name. Not a message pair.

ALL SEVEN are false positives. Every one is the exact shape msgpair's header predicts, which is a
point in the tool's favour: it narrowed 4,000+ format strings to 7 and flagged its own failure mode
accurately.

Corroborating evidence that the message surface is sound: parity_vet.sh reports 0 TEXT mismatches
over 223 compared packages, and parity.sh 0 over 224. A systematic message-shape divergence would
surface there.

CLOSED. If the original 83 were real, they were fixed across #196/#203/#205/#226/#238/#258/#259 and
the rest of the message work; if they were textscan artefacts, they were never real. I cannot
distinguish those two without textscan's output, and say so rather than claiming credit.

## #165 partially RECONSTRUCTED, and I nearly discarded the tool that did it (progress#287)

#165's evidence (fv1/lx/pe) is lost like #188's textscan. But its DESCRIPTIONS survive, and one of
the three -- "an invented message family" -- is statically reconstructable: an invented message is
port text with no C++ counterpart, which needs no repro to detect.

Built .claude/tools/invented.py for it. First run: 538 candidates, which is implausible, plus
obvious extraction artefacts ("base:runtime", a bare "Internal Compiler Error: ").

**I then calibrated it badly and almost threw it away.** I sampled 4 candidates with a SUBSTRING
grep, found C++ hits for 3, and concluded a ~75% false-positive rate. That was wrong: the tool
compares NORMALISED FULL STRINGS, my grep compared substrings, so my check was strictly weaker than
the thing it was checking. Re-running with full-string extraction:

    port "Duplicate parameter '%s'"                     C++ has ONLY "... in procedure call"
                                                        and "... in polymorphic type"   -> bare is EXTRA
    port "Invalid negative array count"                 C++ has ONLY "..., %.*s"        -> bare is EXTRA
    port "Array count too large"                        C++ has ONLY "..., %.*s"        -> bare is EXTRA
    port "matrix row count must be an integer"          NO C++ counterpart at all
    port "matrix row count must be a constant integer
          or polymorphic type parameter"                NO C++ counterpart at all

The last pair is an INVENTED MESSAGE FAMILY -- matching #165's description. The first three are a
different, subtler class: the port carries an EXTRA bare variant alongside the faithful ones, so
some call site emits a message C++ never produces in that form.

**The lesson is about the calibration, not the tool.** A check must be at least as strict as what it
is checking. Grepping a substring to validate a full-string matcher can only produce false
reassurance, and it very nearly cost a working instrument -- the opposite failure to progress#286,
where a tool's hits were all false and I was right to reject them. Both times the answer came from
comparing the ACTUAL STRINGS, not from a proxy.

invented.py kept, with its 538 count understood as unfiltered: the artefacts (short strings,
continuation fragments, non-message literals) still need filtering before the number means anything.
Do NOT quote 538 as a defect count.

NEXT: audit the matrix row/column count messages. #258 already collapsed eleven invented matrix
diagnostics into C++'s single matrix_error; these two may be survivors of that sweep or a distinct
site. Compare against check_type.cpp's matrix path, and confirm with a repro before touching them.

## #312 DONE: `struct #simple` field validation was entirely missing (progress#288)

The parser accepted `#simple` on a struct and set the AST flag; nothing ever read it. C++
(check_type.cpp) walks the fields after `check_struct_fields` and rejects any field whose type is
not at least "nearly simple compare". The port had `is_type_nearly_simple_compare` (types.odin:2039
-- my first grep said it was missing, which was wrong; the grep was truncated by `head -5`) but no
caller.

Three edits: `is_simple: bool` added to `ast.Type_Struct`; the validation loop added after
`check_struct_fields`; and the `.Struct` arm of the predicate given C++'s `if struc.is_simple`
early-out. Four probes byte-identical, including `n7_simp4` (a `#simple` struct nested inside
another), which is what actually exercises the early-out rather than merely asserting it exists.

At the validation site, `type_to_string`'s result is NOT deleted. That is the exact mistake #142 was
retracted for -- the helper can hand back a string literal, and freeing it aborts. The comment at the
site records this so the "leak" is not re-fixed.

Corpus 97 -> 101 FULL-MATCH / 0 DIFFER. Plain parity 225/225, 0 count and 0 text mismatches.

## #313 The vet sweep's ONE text mismatch is the ORACLE being nondeterministic, not the port

This was the first non-zero mismatch in the session, and it arrived on the same sweep as #312, which
is exactly the shape that invites a false attribution. It was not #312.

    TEXT core/rexcode/isa/mos65816/tools   (2 diagnostics, same count, different text)
      < .../dump_verify_input.odin(84:1)      Error: Redeclaration of 'main' in this scope   [oracle]
      > .../gen_mnemonic_builders.odin(185:1) Error: Redeclaration of 'main' in this scope   [port]

The package has two files, each declaring `main` at package scope. Which one is "the redeclaration"
depends purely on which is reached first.

Discrimination, in the order that settles it:

  * pre-#312 (`vt_311b`) and post-#312 (`vt_312b`) hash IDENTICALLY on this package, 20/20 each.
    #312 cannot be the cause -- that is decided before any theory about what `#simple` might have
    perturbed.
  * Oracle in isolation: 20/20 on `gen_mnemonic_builders.odin(185:1)`.
  * The port's sweep answer WAS that consensus. The side that moved was the oracle.
  * Reproduced under load (6 spinners, 60 oracle runs): **1/60 flipped** to `dump_verify_input`.

Same class as #197 and #201: C++'s own file/hash ordering decides the output, and a full sweep
supplies the contention that surfaces it. Not excludable and not worth excluding at ~1.7% under
artificial load; recorded here and in parity_vet.sh so the next occurrence is recognised rather than
re-investigated.

**The rule this confirms** (previously stated for timeouts in #301, now shown to hold for CONTENT
too): discriminate a new mismatch against the previous binary BEFORE theorising about the change
that happens to share its sweep. My three ranked suspects for #312 causing this -- predicate
early-out, validation loop firing on a core struct, positional read of the new AST field -- were all
plausible and all irrelevant. Two md5 runs killed the question faster than any of them could have
been investigated.

## #314 DONE: check_shift was a REIMPLEMENTATION -- six divergences, found via one simd Suggestion

The #7 worklist offered four simd Suggestion lines as "absent from the port". Three were real. The
fourth, the shift one, turned out to be the visible edge of a rewritten function.

Probing `v << s` on a `#simd[4]i32` with a signed amount:

    oracle: Shift amount 's' must be an unsigned integer
              Suggestion: Use 'simd.shl' or 'simd.shl_masked'
    port:   Shift operand must be an integer type, got '#simd[4]i32'

Not a missing Suggestion -- a different diagnostic about a different operand. check_expr.cpp:3421-3533
was reimplemented rather than ported, and diverged six ways:

  1. ORDER. C++ validates the shift AMOUNT first and returns; only then the shifted operand. The
     port tested the operand first, so the simd case never reached the amount check at all.
  2. Both messages reworded, and printing the TYPE where C++ prints the EXPRESSION.
  3. "Shift amount must be an integer type, got '%s'" is INVENTED -- C++ has no such message; an
     untyped amount goes through convert_to_typed, not a type test.
  4. MAX_BIG_INT_SHIFT was 128. C++ (big_int.cpp:46) defines it as **1024**. Untyped shifts of
     129..1024 were rejected outright -- a real over-rejection, and the one that led to #315.
  5. The bound was compared against a truncated i64, so a shift amount overflowing i64 could wrap
     into the accepted range. Now compared as a BigInt, as C++ does.
  6. Error paths returned without setting `x.mode = .Invalid`, so an invalid shift left a usable
     operand and cascaded.

The other two Suggestions (ternary -> simd.select, index -> simd.extract/replace) were plain
additions at check_expr.cpp:9837 and 11918, both needing an ERROR_BLOCK the port did not have.

**Nine probes, all byte-identical.** Three positive (n7_sshl/stern/sidx) and -- the part that
matters -- three NEGATIVE controls (n7_shctl/tectl/ixctl) running the same three shapes on
non-simd types, so the Suggestion is proven gated rather than unconditional. Plus n7_sh2000
(above the bound), n7_shneg, n7_shhint.

**The lesson: a "missing Suggestion line" is a cheap probe with a wide blast radius.** The
worklist entry was one string. Probing it surfaced an over-rejection, an invented message, a
truncation bug and a cascade bug that no amount of reading the Suggestion would have found.

## #315 OPEN: an untyped integer constant is not range-checked against its DEFAULT type

Fixing #314's MAX_BIG_INT_SHIFT bound let `1 << 200` through, as C++ does -- and revealed that the
port then says nothing at all, where C++ reports at the use site:

    Error: Cannot convert numeric value '1267650600228229401496703205376' from 'X' to 'int'
           from 'untyped integer'
      The maximum value that can be represented by 'int' is '9223372036854775807'

**This is NOT #314's doing, and the probe that proves it contains no shift.** `n7_biglit` is a bare
2^200 literal bound to a constant and then used:

    X :: 1606938044258990275541962092341162602522202993782792835301376
    _ = X

st_312 (pre-#314) and st_314b (post) both emit nothing, identically. So the gap is in converting an
untyped constant to its default type at a use site, not in check_shift. Had I not built the
no-shift variant I would have filed this against my own change.

Three probes kept as EXCLUDED corpus members with this reason recorded: n7_sh200, n7_sh100
(under the old 128 bound, which is what discriminated it), n7_biglit.

### #314 VERIFIED: corpus 101 -> 110 FULL-MATCH / 0 DIFFER, both parities 225/225 clean

    CORPUS-DONE       members=110 missing=0 excluded=15   FULL-MATCH=110
    PARITY-VET-DONE   packages=225 compared=225 excluded=0 count_mismatches=0 text_mismatches=0
    PARITY-DONE       packages=225 compared=225 excluded=0 count_mismatches=0 text_mismatches=0

Note the vet sweep came back with text_mismatches=0 this time, where the #312 sweep saw the
mos65816 oracle flip. That is exactly the ~1-in-60 rate #313 measured -- one clean sweep is not
evidence the flip is gone, and a future sweep hitting it again is expected, not a regression.

## #316 DONE: label-as-expression, and the directive-call inlining/tailing diagnostics

Three more from the #7 worklist. One entry on that list was a FALSE POSITIVE and one was a
mis-attribution, which is the usual ratio:

  * **"Cannot cyclicly import packages"** is COMMENTED OUT in C++ (parser.cpp:5182). The port is
    correct to lack it. Same class as #171.
  * **"Inlining operators are not allowed on built-in procedures"** (check_builtin.cpp:2780) is
    ALREADY ported at check_builtin.odin:31. The worklist string was the neighbouring
    **"Inlining DIRECTIVES ..."** (check_expr.cpp:8754), a genuinely different site. My first probe
    hit the ported one and looked like a false positive; it was the wrong probe.

Two real gaps fixed:

**Label used as an expression.** A label is an entity in scope, so check_ident resolves `loop`
happily and the port then used it as a value with NO diagnostic at all -- a silent under-rejection.
C++ check_expr.cpp:12297 reads the ENTITY's token for the name, not the ident node.

**Directive-call inlining/tailing.** C++ recognises the directive NAME, emits these, and only then
dispatches to the handler; the unknown-name branch returns first. The gate is name recognition, not
handler success -- established by probe, not by reading:

    recognised name whose handler FAILS  ->  the inlining error fires     n7_inldir2
    unrecognised name with #force_inline ->  only "Unknown directive"     n7_inldir3

The name list now lives in ONE predicate, `directive_call_name_is_known`, because two call sites
depend on it and the second copy was already written out separately.

**A probe hygiene failure worth recording.** My first `n7_label` run reported a package-name syntax
error that had nothing to do with the probe: the directory held a STALE `a.odin` from an earlier
probe this session. I nearly read that as "the label case does not reach the checker". This is
corpus.sh's founding lesson (a corpus must be a curated list, not whatever is on disk) reappearing
one level down, at the individual probe. Delete-then-write, or probe in a fresh directory.

Verified: 5 of 8 probes byte-identical, all four carrying a NEW diagnostic among them. The three
residuals are #317 and are pre-existing.

## #317 OPEN: two diagnostics caret one column in C++ and the whole node in the port

    oracle:  Failed to `#load` file: ...        port:  same text
               a := #load("missing.bin")                a := #load("missing.bin")
                    ^                                        ^~~~^

Affects "Failed to `#load` file" and "Unknown directive: #x". C++ marks a single column; the port
underlines the node's full extent.

**Proven pre-existing, not #316**: n7_inlctl is a plain `#load` of a missing file with NO inlining
and nothing #316 touches, and st_314b and st_316 produce byte-identical output on it. n7_inldir3 is
likewise identical across the two binaries.

Related to but not the same as #302/#311, which fixed the caret RANGE for error_node/warning_node.
Here the range is being computed at all where C++ computes none, so the likely cause is the node
passed to the reporter rather than the padding loop. Three probes kept as EXCLUDED corpus members.

## #316 VERIFIED, and #318: the parity scripts now separate ATTRIB from TEXT

#316's sweep: corpus **110 -> 115 FULL-MATCH / 0 DIFFER**, 18 excluded. Both parities reported
exactly one text mismatch, and both were #313's shape:

    vet   core/rexcode/isa/mos65816/tools   Redeclaration of 'main', different file
    plain core/rexcode/isa/mips/tools       Redeclaration of 'main', different file

Discriminated before believing either. In isolation, 15 runs each of the oracle, st_314b (pre-#316)
and st_316 (post) agree on BOTH packages -- one hash, 15/15, all three. #316 provably did not touch
them.

**#313's characterisation was wrong in two ways and is corrected here.**

  * Not one package -- **ten**. Every `core/rexcode/isa/*/tools` directory has 2-4 files declaring
    `main`: arm32, arm64, mips, mos6502, mos65816, ppc, ppc_vle, riscv, rsp, x86. 4.4% of the sweep.
  * Not "~1 run in 60". That was measured under six artificial CPU spinners, and a real sweep is
    heavier and longer. The very next plain+vet pair produced TWO events. Expect roughly one per
    full sweep.

So this is not a curiosity, it is a recurring instrument false positive that I would otherwise
re-discriminate every single sweep.

**#318: parity.sh and parity_vet.sh now classify ATTRIB separately from TEXT.** Strip the
`file(line:col)` prefix and compare the message texts as a multiset: if those agree and only the
blamed site differs, it is an attribution difference.

**The danger in this change, recorded at both call sites: an ATTRIB is NOT automatically benign.**
**#179 was exactly an attribution bug and it was a REAL DEFECT** -- the port anchored an unnamed
import at the `import` keyword instead of the path, and that was 88/88 of the vet-mode divergences
at the time. If ATTRIB becomes a category I skim past, #179 recurs invisibly. The split exists to
make the two classes distinguishable at a glance, NOT to make either skippable; both still demand
the #301/#313 discrimination. The summary line prints `attrib_mismatches=N` so a nonzero count is
never hidden, and the diff is still printed in full.

### #318 VALIDATED with a control pair -- and the first control was a silent no-op

The revalidation sweep came back completely clean:

    PARITY-VET-DONE  225/225  count=0 text=0 attrib=0
    PARITY-DONE      225/225  count=0 text=0 attrib=0

Good for #316, but it means **the new ATTRIB branch never executed**. Shipping a classification
branch that has never run once is the "check that never fires" defect this ledger keeps recording
(#122, #135, #212, #213). So it was exercised deliberately, with a fake port -- a shell script that
runs the oracle and rewrites its output -- against a one-package list:

    fake port rewrites the FILE, keeps the text   ->  ATTRIB 1, text 0     (positive control)
    fake port rewrites the TEXT, keeps the file   ->  TEXT   1, attrib 0   (negative control)

Both hold in parity.sh AND parity_vet.sh; the two scripts carry separate copies of the branch, so
both were tested rather than one being assumed from the other.

**The near-miss: my first positive control was a no-op and reported `attrib=0 text=0`.** I had
written the sed to rewrite `dump_verify_input.odin(24:1)`, but the oracle emitted
`gen_mnemonic_builders.odin` and `verify_against_llvm.odin` that run -- so the substitution matched
nothing, the two sides agreed, and the script correctly reported a clean package.

That output is IDENTICAL to what a passing control looks like. A control that fails to perturb
anything is indistinguishable from a control that passes, and I would have recorded "validated" on
the strength of it. **A control must be shown to actually change the input** -- check what the
oracle really emits first, then perturb that. Cost this time: one wasted run. In a case where the
branch was broken, it would have been a false "validated" in the ledger.

## #319 DONE: inline-asm directive validation -- a missing default arm and five wrong anchors

From the #7 worklist ("Invalid directive on inline asm expression"). parser.odin's asm-directive
loop had C++'s five arms but two divergences from parser.cpp:3115-3147:

  * **No `case:` default.** `asm(...) -> i32 #bogus { ... }` was accepted in SILENCE. Real
    under-rejection. Probe n7_asmbad: oracle 1 diagnostic, port 0.
  * **All five existing messages anchored at `tok.pos`, the `asm` keyword**, where C++ reports at
    the directive's own identifier token. On
    `asm(i32,i32) -> i32 #side_effects #side_effects {...}` the port pointed at column 7 and the
    oracle at column 43. Same shape as **#179**, where a wrong anchor was 88/88 of the vet-mode
    divergences -- and exactly the class #318's new ATTRIB category is meant to surface.

Both probes now byte-identical.

## #320 OPEN: the inline-asm type is never built, so a ported check is dead

Found by the OVER-REACH GUARD, not by the fix. n7_asmok is a *valid* asm expression, added only to
prove #319 had not started rejecting good code. It differs:

    oracle: Error: Invalid use of inline asm in variable declaration
    port:   (silent)

The port is not missing this check. It HAS it, at check_decl.odin:118-122, structurally identical to
check_decl.cpp:86-89, and `is_type_asm_proc` (types.odin:3449) is a faithful port of types.cpp:1743.

The gate is DEAD because nothing ever satisfies it: check_expr.odin:8030's `Inline_Asm_Expr` arm is
a reduction of check_expr.cpp:11720+ that validates the asm and constraint strings but never builds
a `Type_Proc` carrying `calling_convention == .Inline_Asm`. So `is_type_asm_proc` is always false.

Same family as #20/#135/#212: a check that is present, correct, and never reached. Note the earlier
two asm probes could not have caught it -- they carry SYNTAX errors, so checking never runs. Only a
probe with valid syntax could reach the checker, which is precisely what an over-reach guard is.

n7_asmok kept as an EXCLUDED corpus member with this reason.

### #319 VERIFIED, and #320 DONE: the inline-asm arm was five divergences, not one

#319: corpus 115 -> 117 FULL-MATCH, plain parity 225/225 clean, vet parity 225/225 clean.

#320 turned out to be a rewrite of the whole `Inline_Asm_Expr` arm rather than a single missing
type assignment. Measured against check_expr.cpp's `case_ast_node(ia, InlineAsmExpr, node)`:

  1. **The type.** The port set the operand to the RETURN type (or No_Value); C++ builds a
     PROCEDURE type -- proc scope, params tuple, results tuple, `alloc_type_proc(..., .Inline_Asm)`
     -- and always yields a Value. This one difference is what made `is_type_asm_proc` permanently
     false and `check_decl.odin:118`'s diagnostic dead.
  2. **Parameter types were never checked at all.** `asm(Undefined_Type) -> i32 {...}` was silent.
     Probe n7_asmpt.
  3. No proc-body guard ("Inline asm expressions are only allowed within a procedure body").
  4. Both string messages reworded: "Inline assembly string must be a constant string" for C++'s
     "Expected a constant string for the inline asm main parameter".
  5. ORDER: C++ checks the parameter and return TYPES first, then the two strings. The port checked
     the strings first, so a probe faulting in both would report them reversed.

Six probes byte-identical. Corpus 117 -> 121; n7_asmok promoted out of EXCLUDED.

**What this pair is really about.** #319 was the worklist entry. #320 was found by the OVER-REACH
GUARD I added to #319 -- a valid asm expression, written only to prove the fix had not started
rejecting good code. The two syntax-error probes could never have found it: they stop at the parser
and never reach the checker. The guard was the only probe in the set with valid syntax, and it was
the one that mattered.

That is the second time this session an over-reach guard has paid for itself (the first: #314's
n7_shctl/tectl/ixctl proving the simd Suggestions were gated). A guard is not ceremony -- it is
often the only probe exercising the SUCCESS path, and the success path is where dead checks hide.

### #320 VERIFIED: corpus 117 -> 121, both parities 225/225 clean (0/0/0)

## #321 OPEN: `#must_tail` does not parse at all -- an over-rejection under the missing diagnostic

The #7 worklist offered two entries that are one site: C++ check_expr.cpp:8937-8947 emits
"Use of '#must_tail' of a procedure must have the same type as the procedure it was called within"
plus the continuation "\tCall type: %s, parent type: %s".

Probing found something larger. The port does not PARSE the directive:

    n7_mtail2  return #must_tail callee(1)   -- types differ, C++ reports the mismatch
               port: Syntax Error: Expected ';', got identifier
    n7_mtail3  return #must_tail callee()    -- types MATCH, C++ accepts SILENTLY
               port: Syntax Error: Expected ';', got identifier

n7_mtail3 is the important one: it is valid code, the oracle emits nothing, and the port rejects it.
So this is an OVER-rejection first and a missing diagnostic second. The stacked form
`#force_no_inline #must_tail f()` fails too, with a different message.

Note the port DOES have "'#must_call' can only be applied to a procedure call, not the procedure
literal" in parser.odin -- so part of this family is present. Whether that one is reachable is
unknown and must be probed, not assumed; #320 has just shown what an unreachable-but-present check
looks like.

Filed rather than fixed: it needs the C++ call-prefix directive parsing read properly, not a
guess, and this tick's budget went on #320.

### mkprobe.sh added -- the stale-probe trap caught me a SECOND time

#316 recorded that a reused probe directory can hold a stale .odin from an earlier probe, that
`odin build` then compiles both, and that the resulting diagnostic looks like a genuine finding. I
wrote "delete-then-write, or probe in a fresh directory" into the ledger.

One hour later, n7_mtail hit exactly the same trap, for exactly the same reason.

A lesson recorded but not operationalised is a lesson not learned. `.claude/tools/mkprobe.sh` now
does the clearing, and PRINTS what it discarded -- a silent wipe would hide the very collision it
guards against. Use it instead of `mkdir -p` for every new probe.

## #321 DONE (both halves): `#must_tail` -- a parser omission on top of a missing diagnostic

The worklist offered two strings from one C++ site (check_expr.cpp:8937-8947). Probing found the
checker was the SECOND problem.

**Part 1, the parser.** C++ lists all three directive names at BOTH dispatch sites; the port's
STATEMENT-level site (parser.odin ~1880) had all three, and its OPERAND-level site (~3385) had only
force_inline/force_no_inline. So `return #must_tail f()` -- directive in expression position --
fell through to ast_basic_directive and died with "Expected ';', got identifier".

That made it an OVER-REJECTION, not a missing diagnostic: probe n7_mtail3 is valid code with
matching types, the oracle emits NOTHING, and the port emitted a syntax error. Having one of the
two dispatch sites correct is exactly what made this look like a checker gap from the outside.

Three further divergences in parse_inlining_or_tailing_operand, all fixed:

  * **The assignments were unconditional.** C++ guards each with `if (pi != none)` / `if (pt !=
    none)`; the port wrote `e.inlining = pi; e.tailing = pt` on every path. In the stacked form
    `#force_no_inline #must_tail f()` the inner directive sets tailing, then the OUTER one -- pt
    None -- wrote it straight back to None. A directive silently erasing its neighbour.
  * The kind check now happens first and bails, as C++ does, naming the node kind it got.
  * Three messages reworded to C++'s, INCLUDING C++'s naming slip: the must-tail-on-a-literal
    message says **'#must_call'**. The port had "corrected" it to '#must_tail'. Parity means
    reproducing the slip -- same reasoning as #131.

**Part 2, the checker.** C++'s tailing switch requires the callee's type to be IDENTICAL to the
enclosing procedure's, and prints both on a continuation line. Added at the call-check site. It
could not have been written first: until part 1 landed, no Call_Expr ever carried a tailing flag
for it to read.

All three probes byte-identical, including the stacked form and the "Call type: ..., parent type:
..." line.

## #322 OPEN: parser diagnostics that C++ anchors to a NODE lose their caret span

Found by #321's over-reach guards. n7_mtailpl/n7_mtailbad/n7_mtailboth all produce the CORRECT
message at the CORRECT position -- and differ only in caret width:

    oracle:  f := #must_tail proc() {}          port:  f := #must_tail proc() {}
                             ^~~~~~~~^                                 ^

STRUCTURAL, not local. C++'s `syntax_error` is overloaded on `Ast*`, and a node carries a range;
the port's parser has exactly ONE error proc, `error(p, pos, ...)`, taking a bare Pos, used at all
174 call sites. Any diagnostic C++ anchors to a node therefore renders one column wide.

Blast radius measured rather than guessed -- C++ syntax_error first arguments:

    token 48   tag 18   pos 16   token_for_pos 14   type 12   tag_token 10
    name 6     ident 6  stmt 5   node 5             expr 5    tok 4

so roughly **27 sites** (type/stmt/node/expr) are affected. The rest pass tokens and already match,
which is why the corpus sits at 121 FULL-MATCH despite this.

Not fixed here: it needs the parser's `Error_Handler` signature to carry an end position, which
means touching the handler wiring in package_resolver as well. That is a deliberate change, not a
tick-sized one. Related to #302/#311 (which fixed the caret RANGE for the checker's error_node and
warning_node) and to #317, but distinct from both: this is the parser, and here no range exists at
all rather than the wrong one being computed.

### #321 VERIFIED: corpus 121 -> 124 FULL-MATCH, plain and vet parity both 225/225 clean (0/0/0)

## #322 part 1 DONE: the parser now has a span-carrying error channel

Infrastructure, plus the four sites #321 exposed. The remaining ~23 node-anchored sites are
mechanical follow-on.

  * `Error_Range_Handler :: #type proc(pos, end: tokenizer.Pos, fmt: string, args: ..any)` and an
    `err_range` field on Parser.
  * `error_node(p, node, ...)`, which reports across `node.pos .. node.end`.
  * `package_resolver` wires `err_range = syntax_error_va`.

**Why a separate handler and not a wider Error_Handler.** `Error_Handler` is declared in the
TOKENIZER package and shared with the tokenizer's own diagnostics; widening it would churn three
packages to serve the parser. This is the same shape as the err_line / err_block pair added in
#307, and the checker end already existed -- `syntax_error_va(pos, end, ...)` has taken a range
since #302. The parser simply had no way to reach it.

`error_node` FALLS BACK to the position-only handler when `err_range` is unset. A host that has not
wired the new channel still gets the diagnostic, with the old narrow caret. Silently dropping it
would be much worse than a narrow caret, and this function is easy to call from a context that has
not been wired.

Four sites converted, and all six #321/#322 probes are byte-identical -- including the three that
were EXCLUDED one tick earlier for caret width alone. That is the channel proven end-to-end rather
than asserted.

NEXT: the other ~23 sites, found by scanning src/parser.cpp for `syntax_error(` whose first
argument is type/stmt/node/expr and matching them to the port's `error(p, X.pos, ...)`. Each needs
a probe; do not convert blind, since some of those C++ nodes may be positions in the port already.

## #322 part 2: 11 more sites converted, and one exposed a PRE-EXISTING anchor defect (#323)

Mapped every node-anchored C++ parser diagnostic to its port counterpart. Of the 23 outstanding:

  * **11 already anchored to the SAME node C++ does**, so the only change was gaining the span.
    Converted.
  * **3 anchor to a DIFFERENT node** and are NOT mechanical -- the port uses `name.pos` where C++
    passes `expr`, `ident.pos` where C++ passes `type`, and `tt.pos` where C++ passes `type`. One
    of those also drops C++'s ", got %s" suffix. Left for probing; converting them blind would
    change the reported position, not just the caret.
  * **2 are ABSENT from the port entirely** -- "Only declarations are allowed at file scope"
    (parser.cpp:6304) and "Invalid import path" (6310, 6342). Separate missing-diagnostic gaps,
    not caret work.

Three probes byte-identical. The fourth, c22_vararg2, is #323.

## #323 OPEN: "Extra variadic parameter after ellipsis" anchors at the wrong column

    oracle           m.odin(2:24)   f :: proc(a: ..int, b: ..int) {}
                                                           ^~~~^
    port             m.odin(2:26)                             ^~^

**Pre-existing, and the discrimination is the point.** Three-way:

    st_322  (before part 2)   2:26   ^      <- wrong column, no span
    st_322b (after  part 2)   2:26   ^~^    <- wrong column, span added
    oracle                    2:24   ^~~~^

So #322 part 2 did exactly what it should -- it added the span -- and the WRONG ANCHOR was already
there underneath, invisible while the caret was one column wide. A single-column caret hides an
off-by-two anchor; a span makes it obvious.

The port's `type` node for a variadic field evidently begins after the `..`, where C++'s begins at
the field. Needs the field-parsing path read against parser.cpp:4560-4570 -- not guessed.

Kept as an EXCLUDED corpus member with this reason.

### #322 part 2 VERIFIED: corpus 127 -> 130, both parities 225/225 clean (0/0/0)

## #323 DONE: the Ellipsis node carried the INNER TYPE's position, not the `..` token's

    port    e := ast.new(ast.Ellipsis, type.pos, type)
    C++     return ast_ellipsis(f, tok, type);      // parser.cpp:4182, node pos IS the token

One line. `b: ..int` anchored at `int` instead of `..`, two columns right, and `e.tok` keeps only
the token KIND -- so once the node was built the `..` position was gone. That constructor was the
only place it existed.

**This was invisible for the entire session until #322.** A one-column caret at the wrong column
looks almost exactly like a one-column caret at the right one; you have to be counting. Giving the
diagnostic a SPAN made the off-by-two obvious at a glance. The tooling improvement found the defect,
which is the second time this session that has happened (the first: #320, found by #319's
over-reach guard).

Three probes byte-identical, including c23_varok -- a VALID variadic procedure. That guard matters
more than usual here: the position change touches EVERY Ellipsis node in every parse, not just the
two sites that happen to report diagnostics.

### #323 VERIFIED: corpus 130 -> 133 FULL-MATCH, plain parity 225/225 clean

## #324 DONE: #322's last three sites -- and two of my three "needs care" calls were wrong

Last tick I set these aside as anchor-differing and refused to convert them blind. Reading each
against C++ showed I had judged two of them by VARIABLE NAME rather than by what the variable held:

  * **blank identifier** -- C++ `syntax_error(type, ...)` where two lines earlier
    `Ast *type = parse_ident(f)`. C++'s `type` IS the port's `ident`. Same node. Span only.
  * **compound literal** -- already anchored at `expr` with the ", got %s" tail, fixed earlier this
    session. Span only. My note that the port "uses name.pos" was reading the NIL branch, which
    correctly uses name.pos and correctly has no ", got" -- C++ has that as a separate earlier
    branch for exactly that reason.
  * **typeid specialization** -- GENUINELY different. C++ passes `type`; the port passed `tt`,
    which is `unparen_expr(type)`. For `(typeid/int)` those are different nodes. Fixed to `type`,
    and probe c24_tid is written parenthesised so the difference is actually exercised -- an
    unparenthesised probe would have passed either way and proved nothing.

So the caution was right once in three. That is still the correct trade: converting all three blind
would have silently moved a reported position, and the two false alarms cost only a read.

All three probes byte-identical. Every node-anchored parser diagnostic C++ has is now spanned in
the port, except the two that are ABSENT from the port entirely ("Only declarations are allowed at
file scope", "Invalid import path") -- those are missing diagnostics, filed separately, not caret
work.

### #324 VERIFIED: corpus 133 -> 136 FULL-MATCH, both parities 225/225 clean. #322 COMPLETE.

## #315 NARROWED to the blank-assignment path alone (not yet fixed)

Filed as "untyped integer constant not range-checked against its default type". Three probes show
that is too broad -- the check exists and works:

    c15_typed   x: int = <2^200>      oracle reports   port MATCHES
    c15_arg     f(X) with X = <2^200> oracle reports   port MATCHES
    c15_blank   _ = X                 oracle reports   port SILENT

So the gap is ONLY `_ = X`. That is a much smaller target than the original framing, and it means
convert_to_typed and the expressibility machinery are both fine.

Read so far, both faithful against C++:
  * check_stmt.odin:3273 blank branch -- `check_assignment(ctx, rhs, nil, "assignment to '_'
    identifier")`, matching check_stmt.cpp:433-440 including the nil type.
  * check_expr.odin:8155-8190 check_assignment nil-type branch -- computes `default_type` and
    calls convert_to_typed, matching check_expr.cpp:1151-1174.

Both look right, and `_ = X` still says nothing, so the divergence must be UPSTREAM: the statement
is not reaching check_assignment_variable at all. NEXT: instrument the Assign_Stmt path to confirm
whether the blank branch is entered, rather than reading further -- two faithful-looking readings
in a row is exactly when to start measuring instead.

## #315 ROOT CAUSE: an invented `continue` made the blank-assignment branch dead

Found by INSTRUMENTING, after two consecutive faithful-looking readings. check_stmt.odin's assign
loop had:

    if is_blank { continue }                                  // INVENTED
    check_assignment_variable(ctx, &lhs_operands[i], &rhs_operands[i], "assignment")

C++ check_stmt.cpp:2547 calls check_assignment_variable for EVERY pair and handles the blank
identifier INSIDE it (check_stmt.cpp:433-440), where it runs
`check_assignment(rhs, nullptr, "assignment to '_' identifier")`. Passing a NIL type is precisely
what triggers the default-type conversion and its range check.

So the port had blank handling in TWO places, and the outer one short-circuited the inner. The
inner branch -- which reads faithfully, and which I had just finished reading twice and calling
correct -- was DEAD.

**The instrumentation is what settled it, and the positive control is what made the instrumentation
trustworthy.** A print in the blank branch produced nothing on `_ = X`. That alone proves little:
it looks identical to a broken probe. Re-running on a plain `_ = y` ALSO produced nothing, and
`strings` on the binary confirmed the marker was compiled in. Only then was "the branch is never
entered" a finding rather than a guess. Same shape as #318's no-op control, one tick earlier.

Same family as #232 / #252 / #171: an invented bail that silently disables reachable C++ logic.
The fifth dead-code find this session (#20, #135, #212, #320, #315).

Seven probes byte-identical, including n7_biglit / n7_sh200 / n7_sh100 -- EXCLUDED as #315 repros
since #314 and now corpus members. c15_ctl (a plain valid `_ = y`) is the over-reach guard, and it
matters here more than usual: removing the skip makes check_assignment_variable run for EVERY blank
assignment in every package, so the parity sweeps are the real test, not the probes.

### #315 VERIFIED: corpus 136 -> 143 FULL-MATCH, plain AND vet parity 225/225 clean (0/0/0)

The widest blast radius of the session -- removing the invented `continue` makes
check_assignment_variable run for EVERY blank assignment in all 225 packages -- and nothing moved.

## #325 OPEN: two file-scope parser diagnostics, in the wrong place or missing

Probed, not assumed. Both from parser.cpp's file-scope declaration walk.

**c25_filescope** -- `x = 2` at file scope:

    oracle   Syntax Error: Expected ';', got =
             Syntax Error: You cannot use a simple statement in the file scope
    port     (silent)

A real under-rejection. Note the port DOES contain "Only declarations are allowed at file scope" --
but in **check_collect.odin, the CHECKER**, where C++ has it in the **PARSER** (parser.cpp:6304).
Wherever that copy lives it is not firing on this input, so it needs the #320 treatment: establish
by probe whether it is reachable at all before assuming the gap is only the second message.
C++'s "You cannot use a simple statement in the file scope" is absent outright.

**c25_abspath** -- `import "/absolute/path/pkg"`:

    oracle   Syntax Error: Invalid import path: '/absolute/path/pkg'      (PARSE stage)
    port     Error: Unable to find package: /absolute/path/pkg            (CHECK stage)

Wrong message AND wrong phase. Both "Invalid import path" and the helper
`is_import_path_absolute` are absent from the port; the absolute path simply falls through to
package resolution and fails there for an unrelated reason.

Not fixed this tick: the file-scope one needs the reachability question settled first, and the
import one needs C++'s is_import_path_absolute read (it is platform-sensitive -- a Windows drive
letter counts as absolute).

## #325 part 1 DONE: the file-scope simple-statement guard was COMMENTED OUT in the port

    port    // if p.curr_proc == nil {
            // 	error(p, p.curr_tok.pos, "simple statements are not allowed at the file scope");
            // 	return ast.new(ast.Bad_Stmt, start_tok.pos, end_pos(p.curr_tok));
            // }
    C++     if (f->curr_proc == nullptr) {                       // parser.cpp:3859, LIVE
                syntax_error(f->curr_token, "You cannot use a simple statement in the file scope");
                return ast_bad_stmt(f, f->curr_token, f->curr_token);
            }

`x = 2` at file scope was accepted in SILENCE -- errors=0, raw_diags=0 -- where C++ reports two
diagnostics. Restored with C++'s exact message; the commented-out version had also reworded it.

**This is the mirror image of #171**, where the port had LIVE a bail C++ has commented out. The
rule holds in both directions: the reference decides, not the comment. Commented-out code is not a
neutral state -- here it silently disabled a real rejection, and it read as deliberate.

Worth noting the port already had this exact shape LIVE in parse_for_stmt ("You cannot use a for
statement in the file scope"), so the pattern was never in doubt -- only this instance of it. That
is what made it invisible to a reading pass: the neighbouring code looks right.

Three probes byte-identical, including c25_ok exercising `=`, `+=` and `*=` inside a procedure --
the guard sits on EVERY assignment operator, so the over-reach risk was real.

Part 2 (import path) still open: "Invalid import path" and is_import_path_absolute are both absent,
and the port reaches a later checker error instead. C++'s helper is platform-sensitive.

### #325 part 1 VERIFIED: corpus 143 -> 146 FULL-MATCH, plain and vet parity 225/225 clean

Restoring a guard that sits on EVERY assignment operator changed nothing across 225 packages.

### #325 part 2 SCOPED (not implemented) -- and a correction to my own note

**Correction.** Two ticks ago I filed C++'s `is_import_path_absolute` as "platform-sensitive (a
Windows drive letter counts as absolute)". Reading it (parser.cpp:6057) shows that is wrong: BOTH
rules apply unconditionally on every platform.

    path[0] == '/'                                                  -> absolute
    len>2 && alpha(path[0]) && path[1]==':' && path[2] in "/\\"      -> absolute

Reading it first was right; the reason I gave for reading it was not. Worth recording because the
instinct ("this smells platform-conditional") produced a correct action from a wrong premise, and
that is exactly the kind of near-miss that stops being lucky.

**Bigger than filed.** Two things make this not a drop-in:

  * There are TWO C++ call sites, not one. parser.cpp:6181 validates the COLLECTION-STRIPPED path
    (`core:foo` -> `foo`) and is gated on is_import_decl_path; 6309 validates the whole original
    string in the file-scope walk. They need separate probes -- `import "/abs"` exercises one,
    `import "core:/abs"` the other.
  * The port has NO post-parse file-scope decl walk to host 6309. parse_import_decl (parser.odin:
    4976) does no path validation and appends to p.file.imports DURING the parse; C++ validates
    afterwards, iterating decls. Bolting the check into parse_import_decl would put it somewhere
    C++ does not have it, which is how #242 and #325-part-1 got their divergences in the first
    place.

So this wants the walk located or built deliberately, not a check dropped at the nearest
convenient site. Left open with the placement question stated.

## #317 DONE: two node-choice defects, not a caret-machinery one

RE-MEASURED FIRST. The finding was several ticks and many changes old, so before touching anything
I re-ran the three probes against the current binary. Still live -- otherwise this would have been
a fix for a stale report.

**Cause 1 -- the parser's Basic_Directive node ended at the NAME.**

    port    ast.new(ast.Basic_Directive, tok.pos, end_pos(name))     spans `#load`
    C++     ast_token(BasicDirective)     -> BasicDirective.token    the `#` alone
            ast_end_token(BasicDirective) -> BasicDirective.token    SAME token

Both C++ position functions return the same token, so begin == end and the caret is one column.
Eight constructions rewritten to end_pos(tok).

**Cause 2 -- my own #316 edit.** It anchored "Unknown directive" at `node`, the whole call; C++
check_expr.cpp:8747 anchors at `proc`, the directive. So `#unknown_thing(1)` was spanned entire.
A defect I introduced two ticks earlier and which #317's own probe caught.

All seven directive-family probes byte-identical. The three that were EXCLUDED as #317 repros
since #316 are now corpus members.

Note the shape: #322/#323 were about a MISSING span, #317 about a span that should not exist. Both
came out of the same question -- which node does C++ hand the reporter -- and neither was about the
caret rendering, which #302 had already made correct.

### #317 VERIFIED: corpus 146 -> 149 FULL-MATCH, plain and vet parity 225/225 clean

## #300 CLOSED: the premise no longer holds -- thread_pool_wait does not steal

Filed as "port's thread_pool_wait STEALS; C++'s does not -- a port-only addition that was masking
#299". Reading the current code, that is not the case. queue_drain.odin:616-640 drains its OWN
deque only, and the function body contains zero references to stealing.

Line for line against thread_pool.cpp:

    C++   while (tasks_left)                     port   for tasks_left != 0
          while (!thread_pool_queue_take(...))          for { take; if !Success break }
          rem = load; if rem == 0 return                same
          futex_wait(&tasks_left, rem)                  same

(C's take returns 0 on SUCCESS, hence the negation; the port's `if result != .Success do break` is
the same control flow.) The Chase-Lev steal machinery does exist in the port, but it is used by the
WORKER loop -- which is where C++ uses it too.

**What matters is HOW this closes.** The open note read: "hang-freedom rests on 0/120, not an
independent argument" -- i.e. an empirical result with no reasoning under it. It now rests on the
function being a faithful port, which is exactly the argument that was missing. The 0/120 becomes
corroboration rather than the whole case.

I cannot tell from the working tree whether #299's fix removed the steal or whether my original
reading was simply wrong; nothing is committed this session. Recording the ambiguity rather than
claiming a fix I cannot demonstrate. Either way the current state is correct.

Remaining open: #325 part 2 (needs the file-scope decl walk located or built), #301 (characterised,
low priority), and the upstream-only backlog.

### #325 part 2 REFRAMED: not two missing diagnostics -- ONE MISSING PHASE

Chased the placement question to its root. C++ hosts both diagnostics in
`parse_setup_file_decls` (parser.cpp:6286-6368, 82 lines), a post-parse walk over `f->decls`
called from parse_file (6930), with a sibling `parse_setup_file_when_stmt` (6267-6285) that
recurses into `when` bodies. The port has NO equivalent phase at all.

The three distinct diagnostics it emits, and where the port has them:

    Only declarations are allowed at file scope, got %s   -> in the CHECKER (check_collect.odin),
                                                             and not firing
    Invalid import path: '%s'          (two sites)        -> ABSENT
    No foreign paths found                                -> ABSENT

And the phase is not only diagnostics. It also does foreign-import path resolution, reserved
package-name rejection, `directive_count` accumulation for the ExprStmt-of-a-directive exemption,
and the when-body recursion.

**What the port did instead**: parse_file appends statements to p.file.decls in a loop and has
HOISTED exactly one check out of C++'s phase -- "Procedure literal evaluated but not used"
(C++ 5700/6918) -- into that loop, dropping everything else. That also explains why "Only
declarations are allowed at file scope" lives in check_collect.odin: it was put where it could go,
not where C++ has it.

So the work is: port parse_setup_file_decls + parse_setup_file_when_stmt as a phase, move the
hoisted check back into it, and retire the checker-side copy. Multi-tick, and a PARTIAL port here
would reproduce exactly the failure mode of #242 and of #325 part 1 -- a check placed somewhere
C++ does not have it. Left open, now with a definite shape rather than a symptom list.

**CORRECTION to the reframing above.** I wrote that the port's checker-side "Only declarations are
allowed at file scope" was "put where it could go, not where C++ has it." That is WRONG, and the
error mattered: it would have had me delete a faithful check.

C++ carries this message in TWO places, in two different forms:

  parser.cpp:6304   syntax_error(node, "Only declarations are allowed at file scope, got %.*s", ...)
  checker.cpp:5241  error(decl, "Only declarations are allowed at file scope")     [no suffix]

The checker one sits in the default arm of check_collect_entities' decl switch, gated on
ScopeFlag_File. The port's check_collect.odin:870-874 reproduces it exactly -- same gate, same
wording, same absence of the ", got %s" suffix. It is a faithful port and stays.

So the gap is narrower than I said: the port is missing the PARSER-stage diagnostic only, plus the
directive_count exemption and the when-recursion that feed it. Note the two C++ sites are not
redundant -- a parse-stage syntax error aborts before checking, so in practice the parser's fires
and the checker's is the path for decls that reach collection another way (e.g. via `when` bodies
the parser walked but checking re-visits).

Independent confirmation of the missing phase: ast.File.directive_count exists in the port
(ast.odin:164) and NOTHING writes or reads it. Its sole C++ writer is parse_setup_file_decls. That
is the #74/#104 declared-but-never-written signature, pointing at the same absent phase.

## #326 parse_setup_file_decls ported (the diagnostic half) -- the missing phase now exists

Implemented the phase whose absence #325 part 2 identified. parser.odin now has:

  is_ast_decl                  <- C++ parser.hpp:923 (the Ast__DeclBegin..Ast__DeclEnd range)
  parse_setup_file_when_stmt   <- C++ parser.cpp:6267-6285
  parse_setup_file_decls       <- C++ parser.cpp:6286-6368
  called from parse_file's tail <- C++ parser.cpp:6930, right after f->decls is complete

Three probes, all now BYTE-IDENTICAL to the oracle including position and the trailing space:

  c26_exprstmt  `f()` at file scope        3:1 "Only declarations are allowed at file scope, got expression statement"
  c26_when      `f()` inside `when true{}` 4:2 same message
  c26_dirstmt   `#assert(1 == 1)`          SILENT on both sides -- the directive exemption

c26_when is the one that earns the recursion. A file-scope `when` body is a Block_Stmt whose
statements never enter f->decls, so a flat loop cannot reach them; before this change the port was
silent there. That probe is why the phase had to be built as a phase rather than folded into the
parse loop.

Also closes the declared-but-never-written finding: p.file.directive_count now has its writer, the
same one C++ gives it.

SCOPE, STATED PLAINLY. This is the DIAGNOSTIC half. C++'s version also resolves import and
foreign-import paths (determine_path_from_string / try_add_import_path) and rewrites offending
decls to ast_bad_decl. This port resolves import paths in the CHECKER (package_resolver.odin), so
reproducing that half means relocating resolution across a stage boundary -- a separate change with
its own risk, deliberately not bundled here. Still outstanding, tracked: "Invalid import path"
(C++ 6309 and 6181) and "No foreign paths found" (6318). I am NOT claiming #325 part 2 closed.

Verification so far: corpus 149 members, 0 DIFFER. Full 225-package parity sweep RUNNING at the
time of writing -- not yet a result, and the phase adds a parser-stage diagnostic that fires
tree-wide, so that sweep is the one that matters. Binary $S/st_326, backup $S/parser.bak326.

**#326 verification (plain).** Full sweep on st_326:

    PARITY-DONE packages=225 compared=225 excluded=0 count_mismatches=0 text_mismatches=0 attrib_mismatches=0

Clean. That is the result that mattered -- the new phase emits a parser-stage diagnostic over every
file in every package, so an over-firing gate would have shown up here as text mismatches across
the tree, not as a handful. Corpus 149 members, 0 DIFFER. The three c26_* probes are now corpus
members, c26_dirstmt among them specifically as the over-reach guard: it fails the moment the
#directive exemption is dropped from the gate. Vet sweep running.

**#326 verification complete.** Vet sweep on vt_326:

    PARITY-VET-DONE packages=225 compared=225 excluded=0 count_mismatches=0 text_mismatches=0 attrib_mismatches=0

Both sweeps clean, corpus 149/0 DIFFER. #326 is verified.

**#325 part 2 RESCOPED -- it does NOT need resolution moved after all.** I had it that the two
"Invalid import path" sites needed determine_path_from_string, and so needed import resolution
relocated from the checker into the parser. Reading the C++ ORDER shows otherwise:

    String original_string = string_trim_whitespace(string_value_from_token(f, id->relpath));
    if (is_import_path_absolute(original_string)) {     <-- BEFORE any resolution
        syntax_error(node, "Invalid import path: '%.*s'", LIT(original_string));
        ...
    }
    bool ok = determine_path_from_string(...);          <-- resolution comes after

is_import_path_absolute (parser.cpp:6057) is a pure string predicate over the RAW token text:
leading '/', or alpha + ':' + ('/' or '\\'). No filesystem, no collection lookup, no platform
conditional (both rules always apply -- as recorded when I first mischaracterised it). The
foreign-import site (6327) has the same shape, and "No foreign paths found" (6318) is just a count
test. So all three remaining diagnostics are portable into the phase built in #326 without touching
where resolution lives; only determine_path_from_string / try_add_import_path stay in the checker.

## #327 import-path validation: four divergences found by probe, all in the #326 phase's territory

Probed BEFORE writing anything, which was right -- one of my two initial reads was wrong.

CONFIRMED DIVERGENCES (positions match where shown; oracle vs st_326):

  c27_absimp   import "/usr/lib/whatever"
                 oracle  2:1 Syntax Error: Invalid import path: '/usr/lib/whatever'
                 port    2:1 Error: Unable to find package: /usr/lib/whatever
  c27_winimp   import "C:/some/path"
                 oracle  2:1 Syntax Error: Invalid import path: 'C:/some/path'
                 port    2:1 Error: Unable to find package: C:/some/path
  c27_fgnabs   foreign import lib "/abs/libfoo.a"
                 oracle  2:1 Syntax Error: Invalid import path: '/abs/libfoo.a'
                 port    SILENT  -- straight under-rejection
  c27_fgnzero  foreign import lib {}
                 oracle  2:16 Syntax Error: foreign import without any paths
                 port    2:9  Syntax Error: foreign import without any paths

The first two are the same defect seen twice: the port has no parse-stage path check, so an absolute
path falls through to the checker and is reported as a missing package -- wrong message, wrong
stage, wrong severity. c27_winimp also settles the platform question empirically: the oracle
rejects a Windows drive path while running on Linux, so is_import_path_absolute is unconditional,
as parser.cpp:6057 reads.

CORRECTION, caught by probing. I had written that parser.odin:1695-1697's "foreign import without
any paths" was an INVENTED diagnostic, on the grounds that C++'s zero-path message in
parse_setup_file_decls is "No foreign paths found". Wrong -- C++ has BOTH: parser.cpp:5239 emits
this exact message at parse time, and 6318 emits the other one later. The port's copy is faithful
in text and only wrong in ANCHOR: C++ uses lib_name (parser.cpp:5239), the port uses
import_tok.pos, hence 2:16 vs 2:9. Had I "fixed" this by deletion on the strength of the reading, I
would have removed a correct check to cure a column offset.

IMPLEMENTATION NOTES for the fix:
  * is_import_path_absolute is a pure string predicate -- leading '/', or alpha ':' ('/' or '\\').
  * The port lacks Foreign_Import_Decl.multiple_filepaths (C++ sets it true only for the brace
    form, parser.cpp:5216). parser.odin:1678 already branches on Open_Brace, so the field is a
    one-line addition plus one assignment -- needed because C++ gates the foreign absolute-path
    check on `!multiple_filepaths && count == 1`.
  * The port has no string_value_from_token; it strips quotes by hand at several sites
    (check_import_export.odin:157, package_resolver.odin:41).
  * C++'s zero-path branch at 6318 does ast_bad_decl(f, ast_token(fl->filepaths[0]), ...) INSIDE
    the count==0 arm -- indexing element 0 of an empty slice. Possible upstream out-of-bounds; not
    chased, and likely unreachable because 5239 already errors at parse time.

**#327 IMPLEMENTED.** Six defects, not the three I scoped -- the last two only surfaced because the
first fix made the port report twice and I chased the extra line instead of accepting it.

  1. ast.Foreign_Import_Decl.multiple_filepaths added (ast.odin) and set at parser.odin:1678.
     C++ sets it only for the brace form; the absolute-path check is gated on it.
  2. is_import_path_absolute ported (C++ parser.cpp:6057), plus path_string_from_token.
  3. Import_Decl arm in parse_setup_file_decls -- "Invalid import path" (C++ 6305-6312).
  4. Foreign_Import_Decl arm -- "No foreign paths found" + the single-path absolute check
     (C++ 6315-6331).
  5. The zero-path arm now anchors at lib_name, not import_tok, AND returns a Bad_Decl as C++ does
     (parser.cpp:5239). The Bad_Decl is not cosmetic: parse_setup_file_decls only reaches its
     "No foreign paths found" branch for a real ForeignImportDecl, so returning the real node made
     the port emit BOTH messages where the reference emits one. This also settles the note from
     the previous entry -- C++ 6318 indexing filepaths[0] on an empty slice is unreachable
     precisely because this arm hands back a Bad_Decl.
  6. "You cannot use foreign import within a procedure. This must be done at the file scope"
     (C++ parser.cpp:5241) was ABSENT ENTIRELY -- a foreign import inside a procedure body was
     silently accepted. Probe c27_fgnproc.

All five probes byte-identical to the oracle, added as corpus members (149 -> 157 with the c26 set).
Sweeps running.

Method note worth keeping: the duplicate line in c27_fgnzero was the useful signal. Reading it as
"my new check is too eager" would have led to gating the phase's branch; the actual cause was the
PARSER handing back the wrong node kind, two functions away. Chasing the extra output found a
missing diagnostic (6) that no probe on my list was aimed at.

**#327 sweep results -- one clean, one NOT, and I am not calling it pre-existing.**

    PLAIN  packages=225 compared=224 excluded=1  count=0 text=0 attrib=0   [core/crypto/aes TIMEOUT]
    VET    packages=225 compared=225 excluded=0  count=0 text=0 attrib=1   [core/rexcode/isa/mos65816/tools]

The aes TIMEOUT is #301: it passes 3/3 on BOTH st_326 and st_327b in isolation, and #301 is
characterised as a timeout that only bites under full-sweep load. Dispositioned, no action.

The vet ATTRIB is NOT dispositioned. Its CONTENT is #313's exact signature -- same message, same
two files that #318's positive-control lesson already named:

    < .../dump_verify_input.odin(84:1)      Error: Redeclaration of 'main' in this scope
    > .../gen_mnemonic_builders.odin(185:1) Error: Redeclaration of 'main' in this scope

Two files in the package declare `main`; which one gets reported depends on processing order. That
touches nothing #327 changed -- no imports, no foreign imports, no file-scope gate.

BUT THE RATE MOVED, and the discrimination is not marginal:

    vt_326 (pre-#327):   0 / 46 runs
    vt_327 (post-#327):  ~4 / 18 runs

0/46 vs 4/18 is p ~ 0.008 by Fisher's exact. I sampled the old binary to 46 runs precisely because
0/16 vs 3/16 was NOT enough to conclude anything, and the extra 30 runs turned "suggestive" into
"significant". So the honest reading is:

  * #327's FUNCTIONAL correctness is verified -- 0 count and 0 text mismatches on both sweeps, all
    five probes byte-identical, corpus 157/0 DIFFER.
  * #327 did not introduce this defect, but it materially raised how often it fires.

The mechanism is plausible and worth stating as a hypothesis, not a finding: parse_setup_file_decls
adds per-file work at the tail of parse_file, files are parsed in parallel, and #313's outcome is
decided by which file's `main` is collected first. Anything that shifts thread completion order
shifts the rate.

THE REAL POINT: this upgrades #313 from "rare, characterised, low priority" to a live ordering
nondeterminism sensitive to unrelated changes -- meaning any future edit can flip it, and a clean
sweep is partly luck. C++ sorts a package's files; if the port's collection order is decided by
parse completion, that is a parity defect in its own right. The silver lining is that vt_327 is a
~20% repro where the old one was ~1-in-60, which finally makes #313 tractable.

**CORRECTION -- my "#327 raised #313's rate" conclusion was WRONG, and the p-value made it worse.**

Last entry I reported vt_326 0/46 vs vt_327 4/18, ran Fisher's exact, got p ~ 0.008, and concluded
#327 "materially raised how often it fires". Then I measured the thing I should have measured
first: what each compiler actually picks, run to run, on core/rexcode/isa/mos65816/tools.

    PORT vt_326 (pre-#327):   dump_verify_input= 0   gen_mnemonic_builders=25   over 25 runs
    PORT vt_327 (post-#327):  dump_verify_input= 0   gen_mnemonic_builders=25   over 25 runs
    ORACLE ./odin build:      dump_verify_input= 3   gen_mnemonic_builders=22   over 25 runs

The port is DETERMINISTIC here, and identical before and after #327. The ORACLE is the
nondeterministic party -- it picks the minority file ~12% of the time. parity_vet.sh re-runs the
oracle fresh on every invocation (line 77), so the oracle is resampled in BOTH arms of my
comparison. The mismatch fires precisely when the oracle happens to pick dump_verify_input.

So the 0/46 vs 4/18 split was the ORACLE's distribution drifting between measurement sessions --
plausibly load-dependent, since both compilers thread entity collection and the winner is decided
by which thread inserts `main` first. Attributing it to the port binary was unfounded: the p-value
was computed under the assumption that the port was the only variable, and that assumption is
exactly what the 25/25-vs-25/25 measurement refutes. A significance test on a mis-specified model
is not evidence, and dressing the claim in a p-value made it look better-supported than it was.

WHAT THIS ACTUALLY IS: the same class as #197 and #201 and the vt_nopkg2/vt_nopkg3 corpus
exclusions -- the reference compiler is nondeterministic on this input, so a fixed-expectation
comparator cannot score it. The port matches the oracle's 88% majority every time, which is the
best a deterministic implementation can do against a nondeterministic reference.

#313's 10 susceptible packages (all core/rexcode/isa/*/tools, 2-4 files each declaring `main`) are
therefore NOT a port defect and never were. #327 is clean on both sweeps once this is accounted
for. The remaining honest caveat is unchanged from #170: the port being deterministic here is not
proof it matches C++'s ordering everywhere -- only that on this input it lands on the majority.

## #328 three slice-checking divergences, found via newdiag + one found by reading

newdiag.sh reported 14 messages added to C++ since 2026-01-01 and absent from the port. Probed four;
three were real, one was my bad probe (n8_forsemi: both compilers give the same recovery, the
message needs a construct I did not build).

  1. FIXED_CAPACITY slice, addressability. C++ check_expr.cpp:12062 rejects slicing a
     fixed-capacity dynamic array that is not addressable; the port's arm CITED 12060-12070 in its
     comment and never wrote the guard, so `f()[:]` on a `[dynamic; N]T` return was accepted
     silently. Probe n8_fixcapslice.
  2. ENUMERATED_ARRAY slice. Three divergences at one site: message reworded, the whole
     `Suggestion: ... use 'slice.enumerated_array'` line missing, and it anchored at `node` where
     C++ anchors at o->expr. Probe n8_enumslice.
  3. #soa FIXED slice -- NOT from newdiag, found by reading the neighbouring arm. The condition
     tested `operand.mode != .Soa_Variable` where C++ tests `!is_type_pointer(o->type)`; those are
     different questions, so a POINTER to a fixed #soa array was rejected and a Soa_Variable rvalue
     accepted. The message ("Cannot slice non-addressable SOA array") was invented, and the arm
     fell through to the generic "Cannot slice" instead of bailing as C++ does.

Both probes byte-identical after the fix. This is the value of reading the whole switch rather than
only the arm the instrument pointed at -- 2 of the 3 came from the tool, the third from its
neighbour.

## #329 STRUCTURAL: Checker_Info.build_context is NEVER ASSIGNED -- 28 read sites are dead

Chasing why the `main` calling-convention check did not fire led somewhere much larger. The port
HAS the check (check_decl.odin:1392-1394, correct message, correct condition). It never runs.

    checker.odin:1146  // In C++, build_context is a global. We store it in Checker_Info for
    checker.odin:1147  // better encapsulation.
    checker.odin:1148  build_context: ^Build_Context

Nothing ever writes it. `grep "info.build_context = "` over the whole checker returns nothing, and
there is no struct-literal initialisation either. It is always nil. Meanwhile `build_context` also
exists as a plain global (build_settings.odin:478) which the rest of the checker reads directly --
so the "encapsulation" copy was introduced, threaded through 28 call sites, and never connected.

The 28 readers are all nil-guarded, so nothing crashes; they all silently take the nil branch:

    check_builtin.odin        12      check_decl.odin            6
    check_type.odin            3      entity_helpers.odin        2   (reads ODIN_ROOT)
    check_stmt.odin            2      check_decl_helpers.odin    2   (is-darwin predicate!)
    type_info.odin             1

Consequences confirmed or strongly implied:
  * The whole entry-point block (check_decl.odin:1384-1402) is dead: the 'proc()' type check, the
    custom-calling-convention check, "Redeclaration of the entry pointer procedure 'main'", and the
    ctx.info.entry_point assignment.
  * check_decl_helpers.odin:1258-1261 returns false unconditionally, so every darwin-only rule
    behind it is off.
  * no_rtti, no_thread_local, strict_target_features gates never fire.

This is the #74/#104 declared-but-never-written family again, and the largest instance yet.

NOT FIXED THIS TICK, deliberately. The fix is one line (point it at the global), but it switches on
28 read sites simultaneously -- the exact shape of change that needs corpus + both sweeps measured
before and after, not a drive-by at the end of a tick. Filed as its own item.

**#329 SCOPING, established before touching code.** The fix is not merely "assign the pointer".

Wiring `c.info.build_context = &build_context` uses the DEFAULT Build_Context, and on Linux that
has `no_entry_point == false` (build_settings.odin:991 sets it true only for Freestanding). But BOTH
sweeps run the reference with the flag ON:

    parity.sh:59       ./odin check "$p" -no-entry-point
    parity_vet.sh:96   ./odin check "$p" -vet -no-entry-point

and the triage harnesses set nothing at all -- `grep no_entry_point .claude/tools/triage_*/main.odin`
is empty. So a bare wiring would switch the port's entry-point checks ON while the oracle has them
OFF, and every package containing a `main` would start reporting diagnostics the reference does not.
core/rexcode/isa/*/tools alone would light up, since those declare `main` several times over.

That would look like a large regression and would in fact be a HARNESS mismatch, not a port defect
-- the same shape of self-inflicted false positive as #45 (triage harness bypassed the merge pass)
and #275 (crashes counted as passes). Worth stating plainly because the obvious one-line change is
the wrong one.

So #329 is two coupled edits:
  1. checker_lifecycle.odin:213, next to `c.info.checker = c` -- point info.build_context at the
     global the rest of the checker already reads.
  2. the triage harnesses -- set build_context.no_entry_point = true, so the port is measured under
     the same flag the sweeps give the oracle.

Blast radius, re-estimated after reading the defaults rather than counting call sites: of the 28
readers, the no_rtti / no_thread_local / strict_target_features gates all read flags that default
to FALSE, so they stay off and change nothing. is_darwin (check_decl_helpers.odin:1258) currently
returns false via the nil guard and would return `metrics.os == .Darwin`, which on this host is also
false -- no change here either, though it WOULD change on a darwin host, which is the real fix.
The substantive live change is the entry-point block, which is exactly what part 2 must keep aligned
with the oracle. "28 dead sites" was the honest count; "28 behavioural changes" would not have been.

**#328 VERIFIED.** Both sweeps on st_328 / vt_328:

    PLAIN  packages=225 compared=224 excluded=1  count=0 text=0 attrib=0  [arm32/tablegen TIMEOUT, #301]
    VET    packages=225 compared=225 excluded=0  count=0 text=0 attrib=0

Corpus 159, 0 DIFFER. Note the vet attrib is 0 this run where #327's was 1 -- same binary family,
same packages; that is the #313 oracle nondeterminism not firing this time, exactly as the corrected
model predicts (~12% per run). It is not evidence that anything was fixed between the two runs, and
would have been easy to read that way.

## #329 IMPLEMENTED: Checker_Info.build_context wired, plus the harness flag it forces

Two coupled edits, as the scoping note required:

  1. checker_lifecycle.odin, beside `c.info.checker = c` -- `c.info.build_context = &build_context`,
     pointing the never-assigned field at the global the rest of the checker already reads.
  2. .claude/tools/triage_st/main.odin and triage_vet/main.odin -- set
     `build_context.no_entry_point = true`, because both sweeps pass -no-entry-point to the oracle.

POSITIVE CONTROL, and it was necessary. With the flag set the port is silent on
`main :: proc "c" () {}`, which is ALSO what a still-dead block would produce -- the two are
indistinguishable from that observation alone. So I built a control harness with the flag line
removed (verified by grep that 0 lines still set it) and ran the same probe:

    control (entry-point checks ON):  m.odin(2:1) Error: Procedure 'main' cannot have a custom calling convention
    oracle  (no flag):                m.odin(2:1) Error: Procedure 'main' cannot have a custom calling convention

Byte-identical, and before #329 that block emitted nothing at ANY flag setting. That is what
establishes the wiring is live rather than merely suppressed.

Corpus 159, 0 DIFFER on st_329. Both sweeps running -- not claiming #329 verified until they land.
Backups: checker_lifecycle.bak329, triage_st_main.bak329, triage_vet_main.bak329.

**#329 SWEEPS CAUGHT A REAL REGRESSION -- mine -- and it led to a genuine missing check.**

    PLAIN  count_mismatches=1   COUNT core/sys/darwin/Foundation  oracle=0  port=36
    VET    count_mismatches=1   same package, same numbers

36 is the pre-#277 Foundation count, so this was #329 undoing settled work. Two of my own claims
were wrong and the sweep is what exposed them:

  * I wrote last tick that is_platform_darwin "currently returns false via the nil guard". It
    returns TRUE -- check_decl_helpers.odin's nil branch is commented "Allow objc intrinsics by
    default". So wiring build_context flipped it from permissive to `metrics.os == .Darwin`, i.e.
    false on Linux, and every objc intrinsic in Foundation started erroring.
  * I listed is_platform_darwin among the sites that "change nothing on this host". It was the one
    site that changed everything.

ROOT CAUSE, and it is a real port gap rather than just my error. C++ check_builtin.cpp:283-287:

    if (build_context.metrics.os != TargetOs_darwin) {
        // allow on doc generation (e.g. Metal stuff)
        if (build_context.command_kind != Command_doc && build_context.command_kind != Command_check) {
            error(call, "'%.*s' only works on darwin", LIT(builtin_name));
        }
    }

The diagnostic is SUPPRESSED under `odin check` and `odin doc`. The sweeps run `odin check`, which
is why the oracle reports 0 for Foundation on Linux. That command_kind exemption was never ported.
The permissive nil default had been standing in for it -- accidentally right under `odin check`,
and accidentally WRONG under `odin build`, where C++ would report and the port would stay silent.

FIXED: is_platform_darwin now mirrors C++ -- darwin, or command_kind containing .Check/.Doc.
The harnesses set `command_kind = {.Check}` to match the command the oracle is given.
Foundation: oracle=0 port=0. Corpus 159, 0 DIFFER. Sweeps re-running as #330.

The lesson is about the shape of the earlier reasoning, not just the fact. I predicted the blast
radius by reading flag DEFAULTS and calling three gates inert, but I never read the body of the one
predicate whose nil branch was non-trivial. Reading defaults is not reading behaviour. The sweep
did the job the estimate should have.

**#330 VERIFIED -- and it is the cleanest sweep pair of the session.**

    PLAIN  packages=225 compared=225 excluded=0 count=0 text=0 attrib=0
    VET    packages=225 compared=225 excluded=0 count=0 text=0 attrib=0

Zero exclusions on both (no #301 timeout this run) and zero attrib (no #313 oracle flip this run).
Corpus 159, 0 DIFFER. Foundation oracle=0 port=0. #329 + #330 are done: build_context is wired,
the entry-point block is live, and the command_kind exemption C++ has is now ported.

**MEASUREMENT CAVEAT that follows from this, and must not be forgotten.** The harnesses now set
`no_entry_point = true` and `command_kind = {.Check}` to mirror how the sweeps invoke the oracle
(`odin check ... -no-entry-point`). But corpus.sh drives the ORACLE side with `odin build`, which
has neither. So the two instruments now disagree about entry-point checking:

    parity.sh / parity_vet.sh   oracle `odin check -no-entry-point`   port no_entry_point=true    AGREE
    corpus.sh                   oracle `odin build`                   port no_entry_point=true    DISAGREE

Consequence: a corpus probe that trips an entry-point diagnostic would report a spurious DIFFER --
the oracle would emit it under `odin build` and the port would suppress it. This is why probe
c29_ctl (`main :: proc "c" ()`) is deliberately NOT a corpus member; it is the #329 control and
lives only in the ledger. The entry-point block is therefore verified by that control probe alone,
NOT by either sweep, and no sweep currently exercises it. Stated so a future tick does not read
"both sweeps clean" as covering entry-point behaviour.

## #331 two more #7 gaps fixed, and a control probe found a THIRD (unfixed)

Probed four more newdiag candidates. n9_typeval (`f(int)` where a value is wanted) MATCHED --
another false positive, consistent with the instrument's ~50% rate.

FIXED:
  1. simd reduce predicate -- NOT a wording drift, a real OVER-REJECTION. C++
     check_builtin.cpp:1410 accepts `is_type_boolean(elem) || is_type_integer(elem)`; the port
     tested boolean alone. `simd.reduce_any` on `#simd[4]i32` is legal to the reference (probe
     n9_simdint: oracle silent) and the port rejected it. The message wording ("boolean or an
     integer element") falls out of the same line. I only caught the over-rejection because I
     probed an INTEGER element after seeing the wording differ -- had I treated it as a message
     fix, the over-rejection would have survived.
  2. `#unroll for` over a slice -- the Suggestion line (C++ check_stmt.cpp:1059-1061) was missing.
     Note it is CONDITIONAL in C++: only for slice / dynamic array / fixed-capacity, not for every
     failure of that branch.

FOUND, NOT FIXED -- and it came from the over-reach control, not the worklist. Probe
n9_unrollctl, `#unroll for x in a` over a fixed `[3]int`:

    oracle: (silent -- legal)
    port:   Error: An '#unroll for' expression must be known at compile time

Discriminated against st_330, the pre-change binary: byte-identical there, so it is PRE-EXISTING
and not something #331 introduced.

A lead, stated as a lead rather than a diagnosis. C++ check_stmt.cpp:1063-1065 gates that error on
THREE conjuncts:

    operand.mode != Addressing_Constant && unroll_count <= 0 && inline_for_depth == 0

The port (check_stmt.odin) has only the first two -- `inline_for_depth` does not appear. That is a
real structural difference, but I have NOT shown it is the cause of this probe's divergence: at top
level the depth ought to be 0, which would make C++ error too, and the oracle does not. So either
the depth is not what I assume or the divergence is upstream of this branch. Needs instrumenting,
not guessing.

Backups: check_builtin_simd.bak331, check_stmt.bak331.

**#331 VERIFIED.** Both sweeps 225/225, 0 excluded, 0/0/0. Corpus 162, 0 DIFFER.

## #332 the #unroll over-rejection from #331's control -- and my "lead" was wrong about the mechanism

Instrumented rather than acted on the guess, which was the right call: the guess was wrong.

I had written that C++'s third conjunct `inline_for_depth == 0` "ought to be 0 at top level, which
would make C++ error too, and the oracle does not -- so either the depth is not what I assume or
the divergence is upstream". It was the first: THE NAME IS MISLEADING. inline_for_depth is not a
nesting depth at all, it is the ITERATION COUNT. C++ check_stmt.cpp sets it from the length of the
thing being iterated -- enum field count (990), string length (1000/1007), ARRAY COUNT (1016),
enumerated-array count (1024). For `[3]int` it is 3, so `== 0` is false and no error is due.

And the port already had ALL of it. check_stmt.odin's Array arm computes
`inline_for_depth = unroll_count > 0 ? unroll_count : tv.count` exactly as C++ does, and the
Enumerated_Array / Slice / Dynamic_Array arms are present too. The ONLY missing piece was the
conjunct in the guard: the port tested `mode != .Constant && unroll_count <= 0` and dropped
`&& compare_exact_values(.Cmp_Eq, inline_for_depth, exact_value_i64(0))`. One term, and a fixed
array was rejected as "not known at compile time".

Probes: n9_unrollctl (fixed [3]int, legal) now MATCH; n9_unroll (slice, error + Suggestion) still
MATCH, so the fix did not weaken the real rejection. Both are corpus members -- n9_unrollctl was
deliberately excluded while it failed and added the moment it passed. Corpus 163, 0 DIFFER.

Process note: the first build of this fix FAILED (`.CmpEq` is spelled `.Cmp_Eq`), and the probe
loop in the same command then ran against a STALE binary and printed DIFFER for n9_unroll. That
output looked exactly like a regression I had just caused. The tell was that the port column was
EMPTY rather than wrong -- a missing binary, not a changed one. Worth remembering: always confirm
the build succeeded before reading probe results from the same command.

**#332 plain sweep CLEAN**: 225/225, 0 excluded, 0/0/0. Corpus 163, 0 DIFFER. Vet still running.

## #333 two METHOD findings from the cyclic-import probe -- no port defect in either

Probed "Cannot cyclicly import packages" (a #7 candidate) with a genuine two-package cycle.

FINDING 1 -- the message is COMMENTED OUT in the reference:

    src/parser.cpp:5182   // syntax_error(import_name, "Cannot cyclicly import packages");

So C++ cannot emit it, and the port is right not to have it. This is a SYSTEMATIC false-positive
source in newdiag.sh: the extractor pulls diagnostic string literals without stripping comments, so
any message the reference has commented out is reported as "absent from the port" -- which is true
but meaningless. Same shape as #171, where the port had faithfully reproduced a bail that C++ has
commented out. Checked the other three unprobed candidates for the same defect: all three are LIVE,
so this is not the whole explanation for the tool's ~50% false-positive rate, but it is one strand.

FINDING 2 -- what the cycle actually produces is nondeterministic ON BOTH SIDES. The real messages
are "Cyclic importation of '%s'" plus an "'%s' refers to" continuation, and WHICH package gets
which is a coin flip:

    oracle, 5 runs:  a  b  b  a  b
    port,   5 runs:  b  a  b  a  b

My first single-run comparison showed oracle=b / port=a and looked exactly like an attribution
divergence. It is not; it is two independent coin flips, the #197 / #201 / #313 family again. One
run would have been enough to file a bogus defect -- five runs cost seconds and prevented it.

No code change. Both findings are about the instruments, not the port.

**#332 VERIFIED.**

    PLAIN  packages=225 compared=225 excluded=0 count=0 text=0 attrib=0
    VET    packages=225 compared=224 excluded=1 count=0 text=0 attrib=0   [core/odin/checker TIMEOUT]

The exclusion is #301: core/odin/checker passes 2/2 in isolation on vt_332 and 1/1 on vt_331, so it
is the load-dependent timeout, not the change. Note it landed on the port checking ITSELF -- the
largest package in the list -- which is where a load-sensitive timeout is most likely to bite.

Running tally of #301 sightings this session, all different packages, all clean in isolation:
core/crypto/aes, core/rexcode/isa/arm32/tablegen, core/odin/checker. That the victim moves each
time is itself evidence for "scheduling artefact" over "package-specific defect".

Corpus 163, 0 DIFFER. Binaries st_332 / vt_332.

**#333 newdiag.sh now drops commented-out C++ calls.** One-line filter (`grep -vE '^[[:space:]]*//'`)
before the literal extraction, with a comment recording why and what it does NOT catch (/* */
blocks, mid-line comments). Deliberately crude: it removes the case that actually bit, and the
header's "every entry needs a probe before it is believed" still stands.

Re-ran it. The worklist went 14 -> 9, and the composition is a useful check on both the tool and
the session's work:

    dropped by the comment filter   1   "Cannot cyclicly import packages"
    dropped because NOW FIXED       4   fixed-capacity slice addressability      (#328)
                                        enumerated-array Suggestion              (#328)
                                        simd boolean-or-integer predicate        (#331)
                                        #unroll count Suggestion                 (#331)

So the instrument tracks the repairs rather than merely listing forever, which is the property that
makes it worth keeping. added=70 present_in_port=60 absent_from_port=9.

Nine candidates remain, none yet probed:
    Cannot address value '%s' as it has not got a determined type yet
    '#c_vararg' parameter '%.*s' cannot be used directly
    Expected ';', followed by a condition expression and post statement, or 'x in y' style loop
    @(init) and @(fini) have been disabled with '-disable-init-fini'
    Invalid procedure type found during deferred procedure checking
    Procedure 'main' cannot have a custom calling convention beyond \   [the -bedrock variant]
    Suggestion: Add an explicit type to the declaration of '%.*s' ...
    Suggestion: Are you trying to pass a type to a value parameter?
    Suggestion: use c_va_start to convert C varargs to c_va_list

## #334 polymorphic type-to-value Suggestion FIXED; #c_vararg direct-use FILED, not half-done

Probed two more #7 candidates.

FIXED -- "Suggestion: Are you trying to pass a type to a value parameter?" (C++ check_type.cpp:
1647-1649). The port emitted "Cannot determine polymorphic type from parameter" and stopped. The
Suggestion is GATED on `operand.mode == Addressing_Type`, and that gate is load-bearing: a mistyped
VALUE must get the bare error. Probes: na_polytype (`f(int)` where `f :: proc(x: $T)`) now matches
including the Suggestion; na_polyval (`f(1, "s")`, a genuine value mismatch) is the over-reach
control and still matches WITHOUT a Suggestion.

FILED, DELIBERATELY NOT PARTIALLY FIXED -- the #c_vararg pair. Probe na_cvararg exposed two halves
of one divergence:

  * OVER-REJECTION. check_decl.odin:1430 rejects "A procedure with a '#c_vararg' field cannot have
    a body and must be foreign". C++ has that exact line COMMENTED OUT (check_decl.cpp:1587-1589),
    so the reference accepts the body. This is #171's shape for the third time: the port faithfully
    reproducing something C++ disabled.
  * MISSING CHECK. What C++ reports instead is at USE: "'#c_vararg' parameter '%s' cannot be used
    directly" plus "Suggestion: use c_va_start to convert C varargs to c_va_list"
    (check_expr.cpp:2004-2007). The port has neither.

Deleting the over-rejection ALONE would turn it into an under-rejection -- the port would go silent
exactly where the reference errors. So it is all-or-nothing, and the second half is a four-part
feature the port has none of:

    1. an entity flag equivalent to EntityFlag_CVarArg on the variadic parameter
    2. a Checker_Context field equivalent to allow_c_vararg_param  (checker.hpp:837)
    3. set/cleared around the c_va_start builtin                   (check_builtin.cpp:768/771)
    4. the check + Suggestion at the Entity_Variable arm           (check_expr.cpp:2004-2007)

`grep` for C_Vararg/CVarArg and allow_c_vararg in the port returns nothing for either. Filed whole
rather than trading one divergence for another.

**#334 VERIFIED.** Both sweeps 225/225, 0 excluded, 0/0/0. Corpus 165, 0 DIFFER.

## #335 the #c_vararg pair IMPLEMENTED -- and my scoping last tick was wrong in the port's favour

CORRECTION FIRST. Last tick I filed this as "a four-part feature the port has none of", having
grepped for `CVarArg` and `C_Vararg`. The port spells it **C_Var_Arg**. Piece 1 was fully present:
ast.Entity_Flag.C_Var_Arg exists, check_type.odin:5139-5140 SETS it on the variadic parameter, and
five sites read it. Three pieces were missing, not four, and the item was smaller than I said. A
grep that misses on spelling reads exactly like an absent feature -- the fix is to check the port's
own naming before concluding absence.

IMPLEMENTED, all of it:
  2. Checker_Context.allow_c_vararg_param            <- C++ checker.hpp:837
  3. set/cleared around c_va_start's 2nd argument    <- C++ check_builtin.cpp:768-771
  4. the direct-use check + Suggestion in check_ident's .Variable arm, BEFORE the t_invalid bail,
     matching C++'s order                            <- C++ check_expr.cpp:2004-2007
  and REMOVED the body/foreign over-rejection from check_decl.odin, which C++ has commented out
  (check_decl.cpp:1587-1589). Third instance of that family after #171 and #333.

    na_cvararg  `x := args`                          error + "use c_va_start ..." Suggestion, MATCH
    na_cvok     `intrinsics.c_va_start(&list, args)` SILENT on both sides, MATCH

THE CONTROL WAS VACUOUS AT FIRST AND I NEARLY BANKED IT. na_cvok's first version called
`c.va_start`, which does not exist -- both compilers failed identically with "'va_start' is not
declared by 'c'", the comparison said MATCH, and nothing about allow_c_vararg_param was tested. The
real name is intrinsics.c_va_start (core/c/libc/stdarg.odin:9 aliases it). Only after fixing the
probe does silence on both sides mean anything: without piece 2 the new check would fire there.
"Both sides agree" is not evidence when both sides are failing for an unrelated reason -- the same
trap as #318's silent positive control, in a new costume.

Corpus 167, 0 DIFFER, both probes members. Sweeps running.
Backups: checker.bak335, check_builtin.bak335, check_decl.bak335, check_expr.bak335.

**#335 VERIFIED.**

    PLAIN  packages=225 compared=225 excluded=0 count=0 text=0 attrib=0
    VET    packages=225 compared=225 excluded=0 count=0 text=0 attrib=0

Corpus 167, 0 DIFFER. Worth stating why this pair carries weight: the new check runs in
check_ident's .Variable arm, which EVERY identifier reference in every package passes through, and
it is positioned before the t_invalid bail. A wrong predicate there would not be subtle -- it would
reject identifiers tree-wide. 0 text mismatches over 225 packages is the evidence that the
.C_Var_Arg gate is narrow.

## #336 the address-of-undetermined-type branch was a SILENT BAIL

check_expr.odin:2402 in check_unary_expr read

    check_expr_base(ctx, o, ue.expr, operand_hint)
    if o.mode == .Invalid { return }

C++ check_expr.cpp:12496-12507 does NOT return silently there -- it reports "Cannot address value
'%s' as it has not got a determined type yet", then conditionally a Suggestion, then sets o->expr
and returns. Two of the six remaining #7 candidates were this ONE site (the error and its
Suggestion), not two separate gaps.

Ported the whole else-branch. The Suggestion is gated on the operand resolving to a Variable
entity, and BOTH directions of that gate are now covered by probes:

    nb_addr   `x := &x`            error only -- the entity is undeclared, not a Variable
    nb_addr2  `a := &b; b := &a`   error for 'b' (undeclared) AND error+Suggestion for 'a'

nb_addr2 is the better probe of the two: it exercises the gate BOTH ways in a single file, so an
unconditional Suggestion and a never-firing Suggestion each fail it. Both byte-identical to the
oracle.

SEPARATE FINDING, filed not fixed. Probe nb_forsemi (`for x := 0 x < 3 {`) was aimed at the
"Expected ';', followed by a condition expression and post statement" candidate and did not reach
it -- but it exposed a POSITION divergence in the same area. Both compilers emit the same three
messages; "Expected 'boolean expression', found a simple statement." lands at 5:2 in the reference
and 3:6 in the port. Same text, same count, different anchor, so a TEXT comparison catches it but
an ATTRIB-style one would not. Not chased this tick; the target message remains unprobed.

**#336 VERIFIED.** Both sweeps 225/225, 0 excluded, 0/0/0. Corpus 169, 0 DIFFER.

## #337 convert_stmt_to_expr anchored at the statement, C++ anchors at the current token

The divergence nb_forsemi turned up last tick, chased to one line:

    C++  parser.cpp:2120   syntax_error(f->curr_token, "Expected '%.*s', found a simple statement.", ...)
    port parser.odin:1281  error(p, stmt.pos,          "Expected '%s', found a simple statement.", kind)

stmt.pos is where the simple statement STARTED; f->curr_token is where the parser gave up. For
`for x := 0 x < 3 {` that is 3:6 versus the reference's 5:2 -- same text, same count, different
anchor. An ATTRIB-style comparison would have called this benign; the TEXT comparison is what
catches it.

Worth noting the two lines of that function disagreed with each other: the error used stmt.pos
while the Bad_Expr constructed immediately below already used p.curr_tok. One of them had to be
wrong, and C++ says which.

    nb_forsemi   `for x := 0 x < 3 {`   MATCH
    nb_ifsimple  `if x := 1 {`          MATCH -- same helper reached through a DIFFERENT caller,
                 so the fix is verified for the if-form as well as the for-form, not just the
                 one shape that exposed it.

**#337 VERIFIED.** Plain 225/225 0/0/0. Vet 224 compared 0/0/0, one exclusion: core/sys/darwin
TIMEOUT, clean 2/2 in isolation -- #301 again, and now the FOURTH distinct victim package
(aes, arm32/tablegen, odin/checker, sys/darwin). The victim moving every time remains the strongest
evidence that it is scheduling and not a package-specific defect.

## #338 deferred-procedure checking: one missing rejection and one assert-instead-of-diagnostic

Came from the last unprobed #7 candidate, "Invalid procedure type found during deferred procedure
checking". Reading check_deferred.odin against checker.cpp turned up two defects in one loop.

1. CHAINING WAS NOT REJECTED AT ALL. C++ checker.cpp:6893-6898 refuses a deferred procedure whose
   target itself has a deferred procedure. `grep` for the message in the port returned 0. Probe
   nc_defchain (a -> b -> c) : oracle errors, port SILENT. Real under-rejection, now fixed and
   placed where C++ has it -- between the self-reference and polymorphic checks.

2. ASSERT WHERE C++ DIAGNOSES. check_deferred.odin:150-151 was

       assert(is_type_proc(src.type))
       assert(is_type_proc(dst.type))

   against C++ checker.cpp:6911-6913, which emits "Invalid procedure type found during deferred
   procedure checking" and continues. An assert on a user-reachable condition aborts the whole
   checker where the reference reports and carries on -- the #21 / #283 family.

   STATED HONESTLY: I could NOT build a repro that reaches it. The attribute checker may reject a
   non-procedure target earlier, in which case this is unreachable today. So this is a LATENT
   abort, not a demonstrated one, and I am changing it because failing the way C++ fails is correct
   regardless of current reachability -- not because I have shown it fires.

    nc_defchain  a -> b -> c    MATCH (both reject)
    nc_defok     a -> b         MATCH (both accept) -- the over-reach control, since a chaining
                 check that is too eager would break every ordinary deferred procedure

**#301 characterisation SHARPENED (from #338's plain sweep).** Fifth distinct victim:
core/terminal/ansi, clean 2/2 in isolation. Full list so far:

    core/crypto/aes                  core/rexcode/isa/arm32/tablegen
    core/odin/checker (the largest)  core/sys/darwin
    core/terminal/ansi (small)

The victim has now included both the biggest package in the list and a small one, and every single
one passes in isolation. That rules out "big packages time out because they are big" -- which was
the natural first hypothesis and would have pointed at a real performance problem. It is the
scheduler, not the workload. Rate remains ~1 exclusion per 1-2 full sweeps, i.e. well under 1%.

**#338 VERIFIED.** Plain 224 compared 0/0/0 (one #301 exclusion), vet 225/225 0 excluded 0/0/0.
Corpus 173, 0 DIFFER. newdiag worklist 6 -> 3.

## #339 the last reachable #7 candidate: a missing diagnostic AND a truncated message

Probing `for i := 0; { }` and `for i := 0; do ...` showed the port producing ONE diagnostic where
the reference produces TWO, and the one it did produce was reworded.

  1. MISSING ENTIRELY. C++ parser.cpp:5022-5026 rejects `for init; ; {` -- an init with neither
     condition nor post statement -- and suggests the rewrite. `grep` in the port: 0 occurrences.
     Silently accepted. Anchored at `init`, not at the `for` keyword.
  2. TRUNCATED WORDING. C++ parser.cpp:4970 says "... and post statement, or 'x in y' style loop,
     got %s"; the port dropped ", or 'x in y' style loop" -- the clause that tells the reader what
     the alternative actually is.

THE BRACE TRAP, AGAIN. My first build produced

    'for init; ; %!(MISSING ARGUMENT)%!(MISSING CLOSE BRACE) without an explicit condition ...

because the message contains literal `{` and it goes through Odin's fmt. This is precisely what
#211 fixed in four other messages, and the parser already carries two `{{}}`-escaped strings
(parser.odin:927 and 3779) with a comment explaining why. I walked into it anyway. Doubling both
braces fixed it. The lesson is not "escape braces" -- it is that a diagnostic containing punctuation
that the FORMATTER interprets must be checked by running it, never by reading it: the source line
looks correct in both the broken and the fixed version.

    nd_forsemi2  `for i := 0; {`        both messages, MATCH
    nd_fordo     `for i := 0; do ...`   both messages, MATCH
    nd_forok     `for i := 0; i < 3; i += 1 {` and `for i := 0; i < 3; {`
                 the over-reach control: a normal three-clause for, and one with an EMPTY post but
                 a present condition, which must stay silent. Both do.

**#339 VERIFIED.** Plain 225/225 0/0/0; vet 225/225, one ATTRIB on core/rexcode/isa/mos65816/tools
which is #313's signature (same TEXT, oracle flipping between two files for "Redeclaration of
'main'"). Corpus 176, 0 DIFFER. That closes the last newdiag candidate reachable without flags.

## #340 the two flag-gated candidates -- and what making them measurable turned up

newdiag's last two entries needed `-disable-init-fini` and `-bedrock`, which the harness never set,
so no instrument could confirm OR refute them. Taught triage_st/triage_vet the flags (defaults
untouched: every sweep passes package paths only, and st_339 vs st_340 is byte-identical across
seven packages incl. base/runtime and Foundation). Both were real, and the second dragged in two more.

1. `-disable-init-fini` -- the flag did not exist in the port's Build_Context at all.
2. `-bedrock` main calling convention -- the port had ONLY C++'s `else` arm, so under -bedrock it
   applied the non-bedrock RULE (one permitted cc) rather than bedrock's (odin OR contextless),
   and recovered to default_calling_convention() where C++ recovers to Odin.
3. `#+build !bedrock` WAS NEVER HONOURED. `bedrock` fell through the tag parser's os/arch chain to
   the unknown-value case and was silently discarded, so the tag excluded nothing and the port
   checked base/runtime's i128 and map files under -bedrock -- 21 diagnostics the oracle never
   emits. Implemented as a per-group tri-state on Build_Kind (nil = group said nothing), mirroring
   C++'s `this_kind_correct = build_context.bedrock == !is_notted`. 21 errors -> 2.
4. `-bedrock` is a COMPOSITE. main.cpp:1669-1673 sets no_rtti, disable_non_constant_globals and
   disable_init_fini alongside it, and main.cpp:3974 then calls setup_bedrock_mode which sets
   ODIN_DEFAULT_TO_NIL_ALLOCATOR. That last one is load-bearing:
   default_temporary_allocator.odin:4 gates NO_DEFAULT_TEMP_ALLOCATOR on it, so without it the
   file's @(fini) stays live and the port reports it where the oracle does not. 2 errors -> 1.
   disable_non_constant_globals is deliberately NOT ported: its only reader is llvm_backend.cpp,
   i.e. the backend, so it is out of scope for a semantic-analysis port.

THE ORDERING TRAP, and how it was nearly mis-diagnosed. Under the flag the oracle emits ONLY the
disable message; the port emitted only "@(init) procedures must be declared as contextless". My
first two hypotheses were both wrong and both testable:
  - "C++ prefers one message"  -- refuted: the SIGNATURE error vanishes under the flag too, so a
    whole block is going missing, not one message losing a contest.
  - "C++ bails out of the phase once errors exist" -- refuted by probe nd_ifgate2, an unrelated
    decl-stage error at a DIFFERENT position, which leaves the validation fully visible.
The answer is the same-position merge (#219). C++ emits the disable error at declaration time and
the whole init/fini validation later, from generate_minimum_dependency_set_internal
(checker.cpp:3001-3045); both land on e.token and the first wins. The port had already relocated
that validation to declaration time (#286), so source order inside one function now decides it --
hence the check is placed BEFORE the chain rather than after it as C++ has it. The comment at the
site records this, because the "faithful" placement is the wrong one here.

Probes, all MATCH: nd_initfini / nd_ifsig (flagged), nd_initfini_ctl / nd_ifgate2 (unflagged
controls), nd_bedcc (-bedrock), nd_bedcc_ctl (same source, no flag -- proves the new arm is
selected by the flag and not always taken).

**#340 VERIFIED, and TASK #7 CLOSED.** Plain 225 packages / 225 compared / 0 excluded / 0-0-0.
Vet 225 / 225 / 0 excluded / 0-0-0. Corpus 176, 0 DIFFER. Fully clean on both instruments --
even the recurring #313 attrib did not surface this run, which is itself consistent with that
being ORACLE nondeterminism rather than a port defect.

TASK #7 ("language features added to C++ since Jan 2026") is now EMPTY. newdiag's worklist went
14 -> 3 -> 0 across this stretch. Every candidate is either ported or explicitly dispositioned:
  - ported: the parse-setup phase, foreign-import-in-procedure, the for-semicolon pair, the
    slice/simd/unroll arms, #c_vararg, deferred-procedure chaining, -disable-init-fini, the
    -bedrock main calling convention, and `#+build !bedrock`
  - dispositioned, NOT ported, with the reason recorded: disable_non_constant_globals (backend
    only -- llvm_backend.cpp is its sole reader)
The two flag-gated entries that had been sitting as "unreachable by the current instruments" were
not unreachable, only unmeasured; extending the harness cost little and turned up two further
defects (the build-tag term and the composite-flag modelling) that no amount of reading would
have surfaced. Worth remembering the next time something is filed as out of reach.

Remaining open, unchanged: #301 (~0.1% scheduling artefact, characterised), the upstream-only
backlog (#119 #156 #159 #161 #166 #169 #174 #187 #189 #195 #206 #225 #263), and #14/#15 threading.

## #341 tasks #14 and #15: one already done, one that was the opposite of what it looked like

#14 (tokenizer double-checked locking) needed NO work: the re-test is already at
core/odin/tokenizer/tokenizer.odin:130, and `git diff master...HEAD` confirms it is OUR change, so
it is a genuine upstream candidate for the PR rather than something still to write.

#15 was filed as "narrow the mutex", with the implied worry being deadlock: init_core_type_info
holds a GLOBAL mutex across check_single_global_entity (a full checker operation) and is reached
from the type_info_of/typeid_of builtins during PARALLEL body checking. If anything under that lock
reached back to those builtins it would self-deadlock on a non-reentrant mutex.

INSTRUMENTED RATHER THAN ASSUMED. A per-thread owner check across all 225 packages: 0 re-entrant
entries. That zero is only worth anything because the detector was first shown to fire -- inverting
its condition to `!= me` produced 70 hits on core/fmt and 8 on core/crypto. Without that control the
result would have been the #318/#335 vacuous-positive trap all over again.

So the deadlock is not real, but the SAME instrument found what is: 70 calls for core/fmt alone,
all but one hitting the early return, every one taking the global lock. That is pure serialisation
of every worker on a hot path, and it is what #15 was really about.

Fix: the tokenizer's own idiom (#14 -- pleasing symmetry), a lock-free fast path over an atomic
flag. Measured after: core/fmt 70 calls -> 1 lock; core/crypto adds 8 calls and exactly 1 more lock.

THE SUBTLE PART, recorded because the obvious version is wrong: the flag must be set at the END of
initialisation, not beside the first `t_type_info = ...` write. About forty more t_type_info_*
globals are written after that line, so a flag set there would admit readers mid-initialisation --
precisely the race the mutex exists to stop. Partial-init paths never set it and keep taking the
lock, i.e. exactly today's behaviour. reset_runtime_type_globals clears it FIRST and under the
mutex, or the flag would outlive a checker teardown and the next checker would read freed memory.
That reset path is not theoretical: the locked-count going 1 -> 2 across two packages in one
process is direct evidence it fires and re-initialises.

Verified: byte-identical to st_340 on 8 packages; 5 repeats of a 4-package single-process run all
identical (that run exercises destroy_checker -> reset between every package).

TWO PRE-EXISTING LINT FAILURES found by finally running CLAUDE.md's OWN check command
(`odin check . -vet -strict-style -no-entry-point`) rather than only harness builds and sweeps:
  - parser.odin:428 -- three `ok` bindings shadowing in one if/else-if chain, from my #326 work.
    Renamed to id_ok / fl_ok / ws_ok, matching the `bl_ok` already used two lines above.
  - core/container/queue/mp_queue.odin:12 -- "'sync' declared but not used". The diagnostic is
    CORRECT, not a compiler bug: every declaration in that file is polymorphic, and polymorphic
    bodies/field types resolve only on instantiation, which nothing in the package does. `_ :: sync`.
The lesson is the process one: sweeps and harness builds do not run -vet -strict-style, so lint
regressions in my own new code sat unnoticed. Run the documented command, not a proxy for it.

**#341 PART 2: THE OPTIMISATION WAS REVERTED. Evidence went against me, so it goes out.**

The fast path passed everything I would normally accept: byte-identical output on 8 packages,
plain sweep 225/225 0-0-0, vet 224 compared 0-0-0, corpus 176/0 DIFFER, and a directly measured
70 calls -> 1 lock. I added flake.sh to the run only because #341 touches locking, and that is the
instrument that caught it.

    st_340 (pre-change)   0 unstable events over 4 flake runs  (2700 package-runs)
    st_341 (post-change)  3 unstable events over 4 flake runs  (2700 package-runs)

Every event on the changed side. p ~= 0.25 for a 3-0 split under equal rates, so this is NOT
significant and I am not claiming it is. Two things made me revert anyway:

  1. DIRECTION IS CONSISTENT across four independent runs, on the arm carrying a locking change.
  2. THE BASELINE REFUTES THE COMFORTABLE EXPLANATION. "It is just #301" predicts ~2.7 events in
     2700 package-runs at the documented ~0.1%. The baseline showed ZERO. So #301's rate estimate
     is stale/wrong, or st_340 does not exhibit it -- and either way the reassuring story does not
     survive contact with its own baseline. Attributing the timeouts to #301 by pattern-match
     would have been the #313 error again: a conclusion the data does not carry.

Asymmetry decided it. #15 was a pure CONTENTION win with no correctness benefit. Keeping it risks
intermittent hangs in a compiler; dropping it costs a lock acquisition nothing depended on. When
one arm of that trade is "possible hang", weak evidence is enough to fold.

THE FINDING IS WORTH MORE THAN THE OPTIMISATION. If removing an unconditional global mutex makes
the checker hang intermittently, that mutex was masking a LATENT RACE that is present today and
merely improbable. That is a real defect hiding behind incidental synchronisation, and it is now
filed. The reverted patch is a ready-made reproducer: re-apply it to raise the hazard's
probability while hunting the race.

Kept from #341 (independent of the revert, both verified): the parser.odin shadowed-`ok` fix and
mp_queue.odin's `_ :: sync`. Both are lint failures against CLAUDE.md's own check command that
sweeps and harness builds never ran.

#14 CLOSED: nothing to implement, fix already present and ours, flagged as an upstream candidate.
#15 CLOSED AS "WILL NOT DO, WITH EVIDENCE" rather than done -- see the new race task.

## #313 first finding: the RTTI readiness gate is published ~43 lines too early

Chased by inspection rather than by hunting a 0.1% event, using #341's hypothesis to aim: the
reverted mutex serialised every worker entering type_info_of/typeid_of, so look at what that path
touches next. It is a PUBLICATION-ORDER defect, and it is in the committed code today.

    type_info.odin:62    t_type_info       = ...   <-- the readiness gate becomes non-nil HERE
    type_info.odin:63    t_type_info_ptr   = ...
    ...  several early-return branches, a struct check, a field-count check, a union check ...
    type_info.odin:105   t_type_info_float = ...   <-- ~43 lines and 4 bail-outs later

Meanwhile add_type_info_type (type_info.odin:198) gates on `t_type_info == nil` with NO lock at
all, and it is called from parallel body-checking workers. So a worker can observe the gate as
"ready" while forty-odd t_type_info_* globals are still nil, then call
add_type_info_type_internal, which reads t_type_info_ptr / t_type_info_float.

WHY THIS HANGS RATHER THAN CRASHES: add_type_info_type_internal opens with `if t == nil ... return`.
A nil late-global is therefore a SILENT SKIP of an RTTI dependency, not a segfault. A dependency
that is never registered is a type that is never completed -- and #278 already established that an
uncompleted type leaves any waiter blocked forever. That is the shape of the observed symptom: a
timeout while the process is ACTIVELY RUNNING, not a crash and not a spin.

The window exists WITHOUT #341. All #341 did was stop workers queueing on the mutex, so more of
them run concurrently and the window is entered more often. That is consistent with 0 events on the
baseline and 3 on the changed binary, without #341 having introduced anything.

CANDIDATE FIXES, none applied yet, because each still leaves a silent skip during the window and I
will not land a concurrency change on a hypothesis with no reproducer:
  (a) gate on a completion flag published at the end (the #341 flag, repurposed from lock-elision
      to readiness) -- window becomes "skip" instead of "partial read";
  (b) have add_type_info_type take the mutex -- correct, but reinstates exactly the contention #15
      wanted gone;
  (c) publish t_type_info last so the gate means what it claims.
All three convert a partial-state read into a skipped registration. If a skip is itself what
strands the waiter, then the real answer is that readers must WAIT for initialisation rather than
skip it, and (a)-(c) only move the bug. Settling that needs a reproducer, which is the next step.

**#313 RETRACTION: the publication-order mechanism I proposed above is REFUTED.**

I widened the window deliberately -- a 20M-iteration cpu_relax spin inserted between the
`t_type_info` write and the rest, on COMMITTED locking, precisely because add_type_info_type never
takes that mutex and so should have been able to observe the partial state regardless of #341.

    core/fmt              6 runs, 0 hangs
    core/math/linalg/glsl 6 runs, 0 hangs

Vacuity control, because "no hangs" from an instrument that never ran proves nothing: st_win takes
649ms against st_342's 417ms on core/fmt. The spin executed and the window really was ~230ms wide,
which is enormous next to a 400ms run. Twelve runs, zero hangs.

So the partial-state window is NOT reachable. The most likely reason is that the single real
initialisation (LOCKSTAT measured exactly ONE locking call per package) happens during a
SEQUENTIAL phase, before parallel body checking starts -- so no reader is ever concurrent with it,
and all ~70 subsequent calls are post-init early returns. Supporting detail: widening the window
added very nearly the full spin cost to wall-clock (+232ms of a ~230ms spin). Had workers been
running concurrently, the overlap would have hidden much of it.

WHAT THIS COSTS ME: the mechanism section in the entry above is wrong and stands corrected here.
The reasoning was plausible and the code smell is real -- a gate published ~43 lines before the
data it gates is genuinely poor -- but "ugly and latent" is not "reachable", and I presented the
hang explanation with more confidence than the evidence carried. Inspection produced a story;
the experiment killed it. That is the correct order, but I should have run the experiment before
writing the mechanism up as a finding.

WHAT REMAINS OPEN: the 3-vs-0 timeout observation across the #341 boundary is still unexplained.
It is not this. The revert stands regardless -- it was made on the measurement, not on the
mechanism, and the measurement is untouched by this retraction.

## #342 the branch's stray `tmp/` was hiding a live UPSTREAM CRASH

A consolidated pass over every package the branch touches (not just the ones I had been checking)
turned up core/odin/checker/tmp/file.odin -- package `repro`, unreferenced by anything, added in
the initial commit. Debris of the #8 kind. Before deleting it I ran it, because it carried a
`// PANIC` comment, and it still panics the REFERENCE compiler today:

    src/types.cpp(1985): Panic: Invalid complex type
    This is a compiler error. Please report this.

3/3 reproducible. The port checks the same source cleanly, 0 errors -- and the port is RIGHT:
`complex(r, i)` is complex128, `Value` is a union containing complex128, so returning it is an
ordinary conversion to a union variant.

MINIMISED: `complex(1.0, 2.0)` on its own is fine. The union return type is essential. The trigger
is a `complex()` call whose EXPECTED type is a union containing a complex variant.

SITE: base_complex_elem_type (src/types.cpp:1971-1987). It switches on the basic kinds and
GB_PANICs on anything else -- so it is being handed the UNION rather than the complex variant.
Something upstream of it resolves the expected type to the union and passes it in without first
selecting the variant.

Filed as an upstream item alongside #161 / #225 / #285. The stray tmp/ directory is now removed:
its only value was this repro, which is recorded here and in the task, and a stray `repro` package
under core/odin/checker would be noise in a PR to the Odin repo.

METHOD NOTE. I nearly deleted this as debris on sight. Running it first cost one command and turned
a cleanup into a compiler-crash report. "Look at the target before deleting" is worth more than it
sounds -- looking meant EXECUTING it, not reading it.

## #343 the consolidated branch check found six test files that DO NOT COMPILE

Enumerated every package the branch touches (`git diff master...HEAD --name-only`) rather than the
handful I had been spot-checking, then ran CLAUDE.md's own command against each. The checker,
parser, ast, tokenizer, container/queue and tests/core/simd were all clean. The SPEC TEST packages
were not: six branch-added files call

    helpers.check_source_capture_errors(`package test ...`)

but the helper is `check_source_capture_errors(t: ^testing.T, src: string, ...)` -- the leading
`t` is missing, so 21 call sites fail with "Parameter 'src' of type 'string' is missing". These are
real tests (2 and 6 @(test) procs in the two I inspected), not scratch, so they were fixed rather
than deleted: `t` inserted at exactly the sites whose first argument is a raw string literal, which
leaves the 4 already-correct sites untouched.

    spec_advanced/test_debug.odin              9
    spec_indexing/test_debug.odin              4
    spec_directives/test_debug.odin            3
    spec_runtime/test_debug.odin               2
    spec_errors/test_errors_procedures.odin    2
    spec_errors/test_errors_redeclaration.odin 1

All 10 spec packages plus the parent tests package now check clean.

MY OWN MEASUREMENT ERROR, noted so the numbers above are not misread: my first glob was `spec_*`,
which matched four `.bin` BUILD ARTIFACTS sitting in that directory and reported them as failures.
They are UNTRACKED, so they were never a branch problem -- `git ls-files` returns nothing for them.
Re-globbing as `spec_*/` fixed it. The lesson is the small one: a glob over a source tree will
happily match build output, and "FAIL" from an instrument is not automatically a fact about the code.

WHY THIS SAT UNNOTICED. Everything I have verified for weeks -- corpus, both parity sweeps, flake,
doccmp -- drives the CHECKER over other packages. None of it compiles the branch's own test suite.
Six non-compiling test files would have been the first thing a reviewer hit.

## #344 the spec suite RUNS for the first time: 432 tests, 25 failures, ZERO of them port defects

Yesterday's pass got the suite COMPILING (#343). Compiling is not passing, so this tick ran it.
432 tests, 25 failures across 7 of 10 packages. Every failure investigated is test-side.

CLASS 1 -- BAD EXPECTATIONS (23, enumerated automatically). Built .claude/tools/specvalid.py: it
extracts every `check_should_pass(t, `SRC`, "ID")` and runs the ORACLE on SRC. A should-pass
assertion is only meaningful if the REFERENCE compiler accepts the source; where it does not, the
test asserts semantics Odin does not have and the port is RIGHT to reject.

    286 should_pass cases, 263 the oracle accepts, 23 BAD EXPECTATIONS

Spot-checked the first by hand before trusting the tool: `T :: type_of(p)` with p a runtime local
gives BYTE-IDENTICAL 4-error output from port and oracle. Others include `cap` of a slice,
`raw_data` of a fixed array, and statements after `return` -- all rejected by the reference
compiler. These tests were written against a spec DOCUMENT and never executed, so nothing could
catch expectations the language does not actually have.

CLASS 2 -- TEST HARNESS GAPS (the residual). Verified two directly:
  - RT-TYPE-004 type_info_of fails with `assert(t_type_info_ptr != nil)`. The assert is FAITHFUL --
    C++ has GB_ASSERT(t_type_info_ptr != nullptr) at check_builtin.cpp:3357, the same site. And the
    same source standalone is clean on BOTH compilers.
  - DIR-HASH-005 `#location()` is accepted by BOTH compilers standalone, yet fails under the harness.
  The cause is check_source_internal (test_helpers.odin) building a checker WITHOUT the runtime
  preload / RTTI init that check_package_from_path performs. Any test needing a runtime type fails,
  and the faithful assert is simply the loudest symptom.

WHAT I DID NOT VERIFY: 23 bad expectations are machine-confirmed and 2 harness gaps hand-confirmed.
The remaining handful I have classified BY PATTERN, not individually. Stated so it is not misread
as a complete audit.

NO PORT DEFECT was found by any of the 25. That is a real result for the checker, and it is only
believable because the classification ran the ORACLE rather than trusting the tests.

WHY THIS MATTERS BEYOND THE COUNT: a green suite here would have been worthless, because 23 of its
assertions encode non-Odin semantics. Had the suite ever been run and "fixed" by changing the
CHECKER to satisfy them, the port would have been bent away from the reference compiler by its own
tests. Running the tests against the oracle first is what prevents that.

FOLLOW-UP FILED: fix the 23 expectations and give the harness a real init.

## #345 fixing the spec expectations -- and my own extractor had a bug that faked one

Started clearing #344's list. 23 -> 15 this tick, and the count itself moved for a reason worth
recording.

MY INSTRUMENT WAS WRONG. specvalid.py matched the test id with `"(?P<id>[^"]*)"`. One id contains
ESCAPED QUOTES:

    "DIR-ATTR-007: @(private=\"file\") attribute"

`[^"]*` stops at the backslash-quote, so the match ended mid-literal and DESYNCHRONISED every later
match in that file. The knock-on was that DIR-ATTR-008 was reported as a bad expectation while the
"source" printed for it was actually DIR-ATTR-007's source plus the intervening Odin between the two
tests. DIR-ATTR-008 is FINE. I caught it only because I printed the extracted source before editing,
and it obviously spanned two tests.

Had I trusted the tool and "fixed" DIR-ATTR-008, I would have broken a working test to satisfy a
parser bug of my own making. The instrument that partitions bad tests from real defects has to be
held to the same standard as the thing it measures -- #344 says run the tests against the oracle,
and this says check the harness that runs them. Regex now matches escapes: `(?:[^"\\]|\\.)*`.
Corrected baseline: 287 should-pass cases, 18 bad expectations (not 23).

FIXED THIS TICK (7 of the original 23):
  incidental test bugs, feature was never in question -- variable declared and never used:
    IDX-ARR-004, RT-TYPE-002, SEM-CF-002, SEM-CF-003   (added `_ = x` / `_ = y`)
  wrong FORM of a real feature, rewritten to the valid form so coverage is preserved:
    DIR-ATTR-001  @(init)  proc()  -> proc "contextless" ()   (C++ enforces it, checker.cpp:3014)
    DIR-ATTR-002  @(fini)  proc()  -> proc "contextless" ()
    DIR-ATTR-011  @(disabled)      -> @(disabled=true)        ("Expected a boolean value")
  plus DIR-ATTR-008 withdrawn as MY false positive.

The rewrite-to-valid-form choice matters: converting these to check_should_fail would have recorded
the mistake rather than the feature. @(init) IS a real attribute and deserves a positive test -- it
just has to be spelled the way the language spells it.

REMAINING 15: the #-parameter directives (DIR-PARAM-003/005/006), the or_else/or_return family
(RT-OR-003/004/005, SEM-DEFER-011), bounds_check/no_bounds_check as attributes rather than
directives (RT-TYPE-007/008), RT-TYPE-013's syntax error, and the builtins group
(BUILTIN-CORE-006/016/017/027/030).

## #346 spec expectations 15 -> 8, and specvalid's SECOND blind spot

Six more rewritten, each verified against the ORACLE before being written into the tests rather
than after -- candidate source first, `odin check` it, only then edit. That caught a mistake in my
own first attempt: the obvious or_return rewrite still failed, because the reference compiler
requires NAMED returns once a procedure has more than one result ("allowing for early return").
Had I edited first and validated after, that would have looked like a checker defect.

    RT-OR-004 / RT-OR-005 / SEM-DEFER-011   `inner().? or_return` in a Maybe-returning proc.
        `.?` yields (int, bool) and a bool cannot be the error value of a Maybe. Rewritten to the
        idiomatic shape: explicit Error enum, named returns, `inner() or_return`.
    RT-OR-003   `first().? or_else second().? or_else 0` -- `first().?` is ALREADY unwrapped to
        int, so the second or_else gets an int. Rewritten to a single `or_else 0`.
    RT-TYPE-007 / RT-TYPE-008   bounds_check / no_bounds_check written as ATTRIBUTES. They are
        statement directives: `#bounds_check { ... }`.

SECOND BLIND SPOT IN MY OWN TOOL. RT-TYPE-013 was reported as a bad expectation. It is not. That
test builds its source by CONCATENATION so it can embed a backtick raw string:

    `... r := ` + "`raw\nstring`" + ` ...`

specvalid matches source between backticks, which cannot span that, so it captured a fragment and
faithfully reported the fragment's syntax error. The assembled source checks CLEAN, and RT-TYPE-013
never appeared in the suite's failure list either -- two independent signals I had ignored in
favour of my own tool's output.

Now DETECTED AND SKIPPED, with the skip printed and counted: `skipped_concatenated=2` (RT-TYPE-013
and OP-ARITH-010). An instrument that cannot read an input must SAY SO; silently mis-reading is
strictly worse than declining, because the mis-read looks like a finding. That is two false
positives from this one tool now (the escaped-quote id in #345, concatenation here) -- both caught
only because I printed the extracted source before acting on it. Keep doing that.

SUITE EFFECT, which is the measure that actually counts:
    spec_indexing    1 failure -> 0   (36 tests, all pass)
    spec_semantics   3 failures -> 0  (70 tests, all pass)
    spec_runtime     6 failures -> 1  (residual is the harness-init assert, not an expectation)
    spec_directives  7 failures -> 4  (2 harness-init, 2 still-bad expectations)

REMAINING 8 expectations: BUILTIN-CORE-006/016/017/027/030 and DIR-PARAM-003/005/006.
Plus the harness-init gap, which no expectation fix can touch -- that is the other half of #315.

## #347 the last 8 expectations -- and the suite found a parity defect the sweeps structurally could not

BAD_EXPECTATIONS is now 0 (285 should-pass cases, 2 honestly skipped as concatenated). Suite
failures 25 -> 8. Every rewrite was oracle-verified BEFORE being written into the tests.

The parameter directives were the instructive group. `proc(s: #by_ptr BigStruct)` and
`proc(b: #no_broadcast Vec4)` both failed, and my first guess -- moving the tag to the proc, i.e.
`proc(s: BigStruct) #by_ptr` -- was rejected too ("Unknown procedure type tag"). The answer came
from reading REAL USAGES rather than guessing further: base/runtime/core_builtin_soa.odin:382 has
`#no_broadcast arg: E` and base/intrinsics/intrinsics.odin:70 has `#const scale: uint`. The
directive precedes the parameter NAME, not its TYPE. Two wrong guesses, then the codebase answered
it in one grep.

    BUILTIN-CORE-006  cap of a slice        -> cap of a [dynamic]int
    BUILTIN-CORE-016  T :: type_of(x)       -> y: type_of(x) = 100      (type position, not a const decl)
    BUILTIN-CORE-017  same for a struct
    BUILTIN-CORE-027  raw_data(arr)         -> raw_data(&arr)
    BUILTIN-CORE-030  stmt after return     -> unreachable() on a fall-through path
    DIR-PARAM-003/005/006                   -> directive before the NAME

A REAL PARITY DEFECT, found by a test the sweeps can never reach. ADV-PG-009 asserts an empty
procedure group is rejected. Both compilers DO reject it -- but not with the same words:

    oracle: Expected a least 1 argument in a procedure group     (parser.cpp:2550)
    port:   expected at least 1 argument in procedure group

THREE divergences in one line: the capital E, a dropped "a" before "procedure group", and -- the
telling one -- the port had SILENTLY CORRECTED upstream's "a least" typo. Fixing the reference
compiler's prose is still a parity break; its text is the specification (#171, #185 again). Now
reproduced verbatim, typo included, and the probe MATCHes.

WHY parity.sh COULD NOT HAVE FOUND THIS: no package in the 225-package sweep contains an empty
procedure group, so that line is unreachable from the sweeps by construction. The spec suite
reaches constructs real code never uses. That is precisely the coverage a corpus of real packages
cannot provide, and it justifies the whole detour -- the suite has now paid for itself in a defect
class the existing instruments are blind to.

ADV-PG-009 itself is NOT a port defect: both compilers reject the source, and the test reports
"expected error but got none" because check_should_fail does not count SYNTAX errors -- a third
harness gap alongside the missing runtime init.

REMAINING 8 SUITE FAILURES, all test-side, none port defects:
  4  harness init   -- t_type_info_ptr x2, DIR-HASH-005/006 (#location, #caller_location)
  3  spec_errors    -- check_should_fail substring assertions that do not match the actual (correct)
                       message, e.g. expects 'Redeclaration', gets "'Red' is already declared in
                       this enumeration". specvalid only validates should-PASS cases, so this whole
                       class is outside what it can check -- a fourth thing to build or verify by hand.
  1  ADV-PG-009     -- the syntax-error-counting gap above.

## #348 #347's sweeps: my parser change was clean, but I had CONTAMINATED THE CORPUS

    plain   225/225, 0-0-0 except 1 ATTRIB -- #313's signature again (Redeclaration of 'main',
            same TEXT, oracle flipping between two files in core/rexcode/isa/ppc/tools)
    vet     225/225, 0-0-0
    corpus  176 members, 1 FULL-DIFFER + 1 PORT-CRASHED

I had said the empty-procedure-group construct was unreachable from the sweeps and re-ran anyway.
Good thing: the corpus came back DIFFER=2, and for a moment that looked like my change.

IT WAS NOT. It was me, one tick earlier. While investigating RT-TYPE-013 I needed a scratch
directory and wrote `$S/trunc/a.odin`. The scratchpad IS the corpus probe root (corpus.sh:18), and
`trunc` is a DECLARED CORPUS MEMBER (corpus.sh:30) -- the #281 float-division truncation probe. My
file landed alongside its main.odin as a second file declaring a different package, so the port
reported "Different package name, expected 'test', got 'trunc'" and the probe went FULL-DIFFER.

Recoverable, as it happens: the probe's real content is main.odin, my a.odin was purely additive,
and deleting it restored the probe byte-for-byte (verified: trunc MATCHes again). Nothing was lost.
But it was luck, not care -- probes are NOT tracked in git (`git ls-files | grep trunc` -> 0), so
had I written main.odin instead of a.odin the probe would simply be gone, and the corpus would have
silently lost a regression test with no way to reconstruct it.

RULE, adopted now: never mkdir directly in $S. Scratch goes in a namespaced subdirectory. The
probe corpus and my scratch space have been the same directory this whole session, and only the
name collision made that visible.

The PORT-CRASHED was p_pv2, rc=-9 (SIGKILL). Five runs in isolation: rc=0 every time. That is a
timeout under sweep load, the #301 family again -- the same artefact as the plain ATTRIB, in the
same run.

NET: the #347 parser message change caused nothing. Both anomalies were pre-existing artefacts or
self-inflicted, and both are now dispositioned rather than assumed.

## #349 the harness rewrite is REVERTED -- right diagnosis, wrong remedy

#315 part 2 said: route check_source_internal through check_package_from_path so the tests get a
real runtime init. I implemented it. It works, and it is too expensive to keep.

WHAT IT FIXED (the diagnosis was right):
    spec_builtins    1 failure -> 0    (t_type_info_ptr assert gone)
    spec_directives  2 failures -> 0   (#location / #caller_location now resolve)
Those four harness-init failures were exactly what a real runtime load was supposed to clear, and
it cleared them.

WHAT IT BROKE:
  1. SEGFAULTS in spec_errors and spec_indexing, plus `runtime assertion: data != nil` in
     spec_runtime. My bug: I allocated the temp directory path from context.temp_allocator, but
     every caller sets context.allocator = context.temp_allocator under a TEMP_GUARD and a whole
     package load happens in between -- so the path was dangling when the deferred cleanup ran.
     THE TELL WAS THE TEST COUNT, not the failures: spec_indexing reported 14 tests where it had
     reported 36. A falling count means the process is dying partway, which is a different and
     worse signal than a failing assertion. Fixed by building both paths in stack buffers.
  2. SPEED, and this is the one that kills it. With the crash fixed, spec_indexing did not finish
     in 2 MINUTES; it used to run 36 tests in 15ms. Each test now loads base:runtime from scratch,
     so the cost is per-test rather than per-process. 432 tests x a full package load is not a
     test suite anyone will run.

REVERTED. The suite is back to 36 tests in 14.6ms and the known 8 failures. A crash-prone,
minutes-long suite is worse than a fast one with 8 catalogued, understood failures -- and I would
be trading a measured baseline for an unmeasured one.

WHAT THE REAL FIX NEEDS: not a harness change at all, but checker-side support for loading
base:runtime ONCE and reusing it across many checks. The per-test cost is the package load, and no
amount of care in test_helpers.odin can amortise something the API only exposes per-call. That is
a checker API change, and it should be scoped as one rather than smuggled in as a test fix.

The four harness-init failures stay open, now with a measured reason rather than a guess.

**#349 POSTSCRIPT: the broken harness scored BETTER on the headline number.**

The pre-revert run finished after I had already reverted. Its summary line:

    TOTAL tests=399  failures=5

Five failures against a baseline of EIGHT. By the metric I would naturally quote, the crashing
harness was an improvement. It was not: 3 segfaults (spec_errors, spec_indexing, spec_semantics),
one runtime assertion, and 399 tests where there should be 432 -- 33 tests NEVER RAN, so they
could not fail. The missing tests were subtracted from the failure count.

spec_semantics 70 -> 64 was the third crash, which my partial read had not yet reached.

This is the sharpest version of a rule I keep relearning: a pass/fail count is only meaningful
against a known DENOMINATOR. "Failures went 8 -> 5" and "33 tests silently disappeared" were the
same event. Any suite summary I quote from here on gets its test COUNT quoted beside it.

## #350 the three spec_errors substring assertions: all three were spec-derived, none was a port defect

check_should_fail's substring assertions are a class specvalid.py cannot see -- it only validates
should-PASS cases. Verified by hand against the oracle instead. All three sources produce
BYTE-IDENTICAL messages from port and reference compiler:

    ERR-PROC-001  wanted "argument"      got  Parameter 'y' of type 'int' is missing in procedure call
    ERR-RD-014    wanted "Redeclaration" got  'Red' is already declared in this enumeration
    ERR-SC-018    wanted "not declared"  got  Undeclared name: runtime

Every one was written against the SPEC DOCUMENT's phrasing rather than the compiler's. ERR-RD-014
is the sharpest: duplicate enum fields have their OWN message and never go through the generic
redeclaration path, so "Redeclaration" was never going to appear. Substrings updated to fragments
of the real text, each with a comment recording that it is oracle-verified -- otherwise the next
reader "corrects" it back toward the spec prose and reintroduces the failure.

spec_errors: 39 tests, all pass. THE COUNT IS 39, unchanged -- stated explicitly per #349's
postscript, because a package that silently ran fewer tests would also show zero failures.

Suite 8 -> 5 failures: 4 harness-init (blocked on the checker API change, LEDGER #349) and
ADV-PG-009 (check_should_fail does not count syntax errors).

## #351 ADV-PG-009 closed: check_should_fail now counts SYNTAX rejections

check_expects_error (test_checker_errors.odin:34-37) returns has_errors=false on a parse failure,
with the comment "Parse error - not a type error". That contract is deliberate and ~20 callers rely
on it, so I did NOT change it. check_should_fail asks a broader question -- does the compiler reject
this source? -- and a syntax rejection is still a rejection. Added a file-private source_parses()
and short-circuited on it.

MY FIRST ATTEMPT DID NOT WORK, and the reason is the interesting part. I keyed on parse_file's
RETURN VALUE. It returns TRUE for `empty :: proc { }`: the parser reports
"Expected a least 1 argument in a procedure group" through the error handler -- which the harness
silences -- and then RECOVERS and produces a tree. A parser that recovers well is precisely a
parser whose return value cannot tell you whether it complained. The record of "did anything get
reported" is p.error_count (parser.odin:95, incremented at :142). Checking `ok && p.error_count == 0`
is what actually works.

Worth keeping: "did it parse" and "did the parser complain" are different questions, and for a
recovering parser only the second one is the rejection test.

SUITE NOW: 432 tests, 3 failing packages, 4 failing tests -- ALL of them the harness-init class
(t_type_info_ptr x2, DIR-HASH-005/006), which is blocked on the base:runtime reuse API (#349).
Count stated deliberately: 432, unchanged, so nothing was lost to earn the improvement.

Journey: 25 failures -> 8 (expectations, #345-#347) -> 5 (spec_errors substrings, #350) -> 4 (this).
Every one resolved was test-side. The port itself produced exactly one defect across the whole
exercise -- the #347 proc-group message, which no sweep could have reached.

## #352 branch verification after the test-only work: everything inert, as predicted

Everything since #347 touched TEST files only (expectations, substrings, check_should_fail). I
predicted the sweeps would be unaffected and ran them anyway -- this session has repeatedly rewarded
checking predictions over trusting them, and #348 is the case in point, where a "surely unreachable"
argument was correct about the parser change and wrong about my own contamination.

    corpus  176 members, 0 FULL-DIFFER, 0 PORT-CRASHED
    plain   225 packages, 224 compared, 0-0-0, 1 EXCLUDED
    vet     225 packages, 225 compared, 0 excluded, 0-0-0

The one exclusion is core/odin/checker, port=TIMEOUT: the #301 family again. 5 runs in isolation,
rc=0 every time. Not a defect, and notably it is the checker checking ITSELF -- the largest package
in the sweep, so the most likely to lose a race with the timeout under load.

BRANCH STATE, settled:
    sweeps      plain + vet clean (modulo #301/#313 artefacts, both characterised)
    corpus      176/176
    spec suite  432 tests, 4 failures, ALL the harness-init class blocked on #316
    port-side backlog   EMPTY
    remaining   #313 (parked, unexplained, may be noise), #301 (premise stale, needs re-measuring),
                #316 (session API, scoped and deliberately NOT started), 13 upstream-only reports

WHY #316 IS SCOPED BUT NOT STARTED. It changes allocator ownership of process-wide state shared
across 32 threads, in the exact area where #341 was reverted on a timeout signal and #313's
hypothesis says a latent race may be hiding. The payoff is four test failures in a suite whose
diagnostic value has already been extracted -- it found its one real port defect (#347) and the
rest were test bugs. Risk/benefit says this wants a human's judgement, not mine unattended.

## #353 RETRACTION: #301's premise is NOT stale. I compared two instruments as if they were one.

In #341 I wrote that #301's "~0.1% of package-runs time out" no longer holds, on the strength of
st_340 showing 0 events across 2700 package-runs. That was wrong, and the error was comparing
unlike measurements.

Tallying EXCLUSIONS (port=TIMEOUT) across ten saved parity runs on current-era binaries:

    parity      339:0  340:0  341:0  347:0  351:1
    parity_vet  339:0  340:0  341:1  347:0  351:0
    ---------------------------------------------
    2 exclusions / (10 runs x 225 packages) = 2/2250 = 0.089%

That is #301's ~0.1%, essentially on the nose.

WHY THE TWO NUMBERS DISAGREED. flake.sh runs the PORT ALONE. parity.sh runs the port AND the
reference compiler over the same package, roughly doubling machine load. Timeouts are load-dependent,
so ~0 under flake and ~0.1% under parity are both correct -- for their own conditions. I took a
flake-derived zero as refuting a parity-derived rate.

CONSEQUENCE FOR #341, and it CUTS IN FAVOUR OF THE REVERT. My 3-vs-0 observation was flake-vs-flake,
the same instrument on both arms. If flake baseline is genuinely ~0 (2700 runs, 0 events, now
corroborated by parity runs showing flake-load events are rare), then 3 events on the changed binary
is a cleaner anomaly than I credited at the time, not a muddier one. The revert stands, and its
evidence is slightly stronger than I described.

METHOD NOTE, the general form: a rate is a property of the MEASUREMENT CONDITIONS as much as of the
system. Two instruments that both "run the checker over packages" can differ by 2x in load and
report rates that differ by orders of magnitude. Before declaring one measurement refutes another,
check they were taken under the same load. I did not, and asserted a retraction on that basis.

## #354 the runtime session works, and it immediately paid for itself: spec suite 4 failures -> 0

WHAT WAS BUILT. `acquire_runtime_session` / `adopt_runtime_session` (core/odin/checker/runtime_session.odin).
One base:runtime load per process, owned by a checker that is never destroyed, borrowed by every
later checker through the only two things find_core_entity reads: `info.runtime_package` and its
`package_scopes` entry. `reset_runtime_type_globals` learns a `runtime_session_active` guard so a
per-check teardown does not nil globals the session owns. All of it opt-in: nothing changes unless
a caller acquires, so the parity sweeps and the corpus exercise unchanged code.

PROVEN, NOT ASSUMED. Probe `sess`: t_type_info false -> true on acquire, and still true after a
borrowing checker is created, adopted and DESTROYED. Control `ctl`: with no session, a real
`check_package_from_path` leaves t_type_info nil after teardown -- so the guard is what keeps them
alive, not something else.

THE COUNT, BOTH SIDES. 432 tests throughout, run as ten spec_* packages.
  baseline (session disabled in the same tree): 432 tests, 4 failed
  wired, first attempt:                          432 tests, 8 failed   <- WORSE
  wired, after the allocator fix:                432 tests, 3 failed
  wired, after the three real fixes:             432 tests, 0 failed

DEFECT 1, MINE, and the reason the first attempt was worse. Four new SEGFAULTS. gdb put them at
type_info.odin:148 reading a freed `^Type`, reached through the `.Any` arm of
add_type_info_type_internal, which registers t_type_info_ptr. `acquire_runtime_session` passed
`default_allocator` to `init_checker` and to the loader -- but alloc_type_pointer and its family
take no allocator and spend `context.allocator`, and a test caller runs under
`context.allocator = context.temp_allocator` with a TEMP_GUARD. So the session's own pointer types
were built in the FIRST test's temp arena and freed when that test returned. One line
(`context.allocator = alloc`) fixed it. Lesson: passing an allocator explicitly says nothing about
what the code you call spends.

DEFECT 2, THE PORT'S, and the whole point of doing this. With base:runtime actually loaded,
`#location()` and `#caller_location` were REJECTED on sources the oracle accepts clean. Both read
`ctx.info.cached_source_code_location` -- a PER-CHECKER field -- and errored when it was nil with
"'#location' requires core:runtime to be imported" / "'#caller_location' requires base:runtime to
be imported". C++ (check_builtin.cpp:2437, check_type.cpp:1746, check_expr.cpp:9737/9753/9759)
reads the GLOBAL t_source_code_location at every one of those sites and has no such error
anywhere -- grep "to be imported" in src/ returns nothing. Both the cached_ read and the error
were invented. They are not interchangeable: init_core_source_code_location guards on the GLOBAL
(matching C++, see the init_mem_allocator note), so the SECOND checker in a process finds the
global set, returns early, and leaves its own cached_ field nil -- and then rejects valid code.
Four read sites repointed at the global; two invented errors deleted.

DEFECT 3, THE TEST'S. ERR-SC-018 expected "Undeclared name" for `runtime.NonExistent`. Re-run
against the oracle on exactly that source: `'NonExistent' is not declared by 'runtime'`. The old
expectation -- and its comment claiming oracle verification -- was recorded when the harness never
loaded base:runtime, so `runtime` resolved to nothing and the port fell back to the generic error.
The port now matches the oracle byte for byte. A stale expectation with a confident comment is
still a stale expectation; the comment is not evidence, the re-run is.

METHOD NOTE. The first wired run crashed in three spec packages, and single-threading did not make
the crashes go away -- but running ONE test alone did. That is the signature of state accumulated
across tests, not of a race, and it is what pointed at allocator lifetime rather than concurrency.
Worth remembering: "still fails at -threads=1" and "fails only in company" together localise a bug
faster than either does alone.

ALSO RECORDED. The root `core/odin/checker/tests` package segfaults in its core-package
integration tests (test_check_ast_package / test_check_checker_package) BEFORE this change as well
-- verified by running the session-disabled tree. It is pre-existing and unrelated; the spec suite
is the ten spec_* packages and is unaffected.

VERIFICATION, all four gates, after the three fixes:
  spec suite   432 tests, 0 failed   (baseline in the same tree: 432 tests, 4 failed)
  parity plain PARITY-DONE packages=225 compared=225 excluded=0, 0/0/0
  parity vet   PARITY-VET-DONE packages=225 compared=225 excluded=0, 0/0/0
  corpus       CORPUS-DONE members=176 missing=0 excluded=12, no DIFFER
  flake        FLAKE-DONE packages=224 runs=3 unstable=0 absent=0
  odin check -vet -strict-style -no-entry-point clean on checker, tests, parser, ast.
flake is included deliberately: it is the screen that caught #341 when parity and corpus were both
clean, and this change moves ownership of process-wide state.

## #355 `#location(1)` was accepted: the argument arm called check_expr and threw the result away

FOUND BY #354, deferred from it deliberately so it could get its own probes.

C++ (check_builtin.cpp:2422-2435) does not type-check the `#location` argument -- it RESOLVES it.
Only two node kinds can name an entity, and each has its own helper:
    if (arg->kind == Ast_Ident)             e = check_ident(c, &o, arg, nullptr, nullptr, true);
    else if (arg->kind == Ast_SelectorExpr) e = check_selector(c, &o, arg, nullptr);
    if (e == nullptr) error(ce->args[0], "'#location' expected a valid entity name");
The port called `check_expr(ctx, &arg_op, arg)` and discarded `arg_op`, so ANY expression was
accepted -- and the diagnostic did not exist in the port at all. Both helpers were already present
with matching signatures; nothing new had to be written.

ORACLE-VERIFIED, four probes, port and oracle byte-identical including the column:
  loc_lit   `#location(1)`     a.odin(3:19) Error: '#location' expected a valid entity name
  loc_undef `#location(nope)`  a.odin(3:19) Error: Undeclared name: nope
  loc_ok    `#location(g)`     clean both sides
  loc005    `#location()`      clean both sides
Before the fix loc_lit was 0 diagnostics on the port against 1 on the oracle; the other three
already agreed, which is why no sweep had ever caught it -- the corpus contains no `#location`
with a non-entity argument.

VERIFICATION: spec 432 tests / 0 failed; parity plain 225/225 0/0/0; parity vet 225/225 0/0/0;
corpus 176 members, no DIFFER; odin check -vet -strict-style clean.

## #356 the root test suite's crash is the HOST's allocator, not a checker race -- and my first fix was wrong about which part

#317 recorded that `odin test core/odin/checker/tests` segfaults in its core-package integration
tests, pre-existing and unrelated to #354. This tick traced it.

gdb on a debug build put the first crash inside __map_get for the global source-file registry,
called from register_source_file (error.odin), under test_check_ast_package. That test does
`context.allocator = context.temp_allocator` behind a TEMP_GUARD, and register_source_file did
`make(map[string]^ast.File)` with no explicit allocator -- so a PROCESS-WIDE map was being built
inside one test's arena. Same defect family as #354's: an explicit allocator argument elsewhere in
the call says nothing about what `make` spends.

FIXED: the map and its keys are now owned by default_allocator (error.odin).

BUT THE CRASH DID NOT GO AWAY, and that is the part worth recording. Probe `regprobe` -- two
`check_package_from_path` calls, each behind its own TEMP_GUARD -- still dumped core, now in
destroy_checker_type_path freeing a dynamic array whose allocator procedure pointer was 0x1. So
the map was A corruption, not THE corruption. I would have shipped "fixed" on the strength of a
clean-looking rationale if I had not re-run the probe.

WHAT ACTUALLY DISCRIMINATES, by control: probe `regprobe2` is byte-for-byte `regprobe` with the
one line `context.allocator = context.temp_allocator` removed.
    regprobe   (temp allocator installed)  -> core dump, every run
    regprobe2  (caller's default allocator) -> "first ok=true / second ok=true / survived", clean
Two checks in one process are fine. Two checks under a temp allocator are not.

MECHANISM, as far as this tick establishes it: check_package_from_path fans out to a 32-thread
pool (queue_drain.odin:406, thread.create). core:thread documents that a worker with no
init_context "will get the same context as main() gets" and its OWN fresh temp allocator -- so the
workers allocate from main's heap allocator while the calling test allocates from its own arena,
and objects cross between them. A per-thread scratch arena cannot be the shared allocator of a
thread pool no matter who installs it, so this is not fixable by threading the caller's allocator
through to the workers.

THE REAL FIX IS A CONTRACT, and it is test-side: the checker's package entry points must not be
called with a scratch/temp allocator as context.allocator. The tests that do it must stop, and the
precondition should be stated on the entry points. That is surgery across many tests in the root
package and is NOT done here -- filed, not hidden. The ten spec_* packages do not use
check_package_from_path and are unaffected (432 tests, 0 failed, with and without this change).

VERIFICATION of the registry fix alone: spec 432 tests / 0 failed; parity and corpus re-run.

## #357 the root suite runs to completion for the first time: 146 tests, 5 failures, no crash

#356 established the contract; this applied it. The eight tests in test_checker_integration.odin
that drive the package loader/checker no longer install `context.allocator = context.temp_allocator`
(test_check_real_package, _parser_package, _ast_package, _checker_package, _core_fmt,
_core_strings, _all_core_packages, and test_runtime_package_is_seeded_by_loader -- the last one
because the LOADER registers ^ast.File pointers in a process-wide table). The TEMP_GUARDs stay:
only the allocator install was unsound.

    before: crashed in test_check_ast_package / test_check_checker_package, then HUNG
            (a 300s run finished 2 tests)
    after:  Finished 146 tests in 6m13s. 5 tests failed. No signal, no hang.

This is the first time the root suite's real numbers have ever been visible. Five failures:
  - test_check_parser_package     LIMIT REACHED, 37 errors on core/odin/parser
  - test_check_all_core_packages  14/86 packages have check errors
  - test_check_if_with_initializer / _nil_check / _ok_idiom

THE FIRST ONE IS NOT A PORT DIAGNOSTIC DEFECT, and the discriminating runs matter:
    test_check_parser_package ALONE                    -> passes, 1/1
    test_check_ast_package + test_check_parser_package -> parser LIMIT REACHED, 37 errors
    regprobe2 (ast then tokenizer, plain main)         -> both clean
All at -threads=1, so not a race. A package check contaminates a LATER package check in the same
process. Filed as its own item; the likely mechanism is the runtime type globals, every one of
which guards on "global already non-nil", so the second check adopts the first check's Type objects
while its own base:runtime load made different ones.

AND IT IS NOT #354'S SESSION. I suspected my own change first and tested it before saying so:
    test_error_type_mismatch_int_string (acquires the session) + test_check_parser_package
        -> BOTH PASS
The failing pair contains no helper-based test at all, so runtime_session_active is false and the
reset guard is not on that path. The contamination predates the session; it was simply unreachable
while the suite crashed before ever running a second package check.

VERIFICATION: spec suite still 432 tests / 0 failed. The edit is test-only, so the parity sweeps
and corpus are untouched by it (they run the triage binaries, not the test package).

## #358 CORRECTION: the "pre-existing" contamination in #357 was MINE, and the guard that caused it named one bad allocator instead of demanding a good one

#357 filed the second-package-check failure as pre-existing. That was wrong, and the correction
matters more than the fix.

WHAT I DID WRONG IN #357. I eliminated environment variables one at a time -- relative vs absolute
path, TEMP_GUARD present or absent, main thread vs worker thread, thread count -- and every plain
probe came back clean. Four failed eliminations, and I still had not looked at WHAT the 37 errors
actually said. The log had been sitting there since the previous tick. When I finally read it:

    Unable to find package: core:fmt
    Unable to find package: core:odin/tokenizer
    Unable to find package: core:strings          (x37)

Not a checker defect at all -- ODIN_ROOT stops resolving on the second check.

ROOT CAUSE, package_resolver.odin:784. init_odin_root_from_env caches ODIN_ROOT in a
process-lifetime global, and chose its allocator like this:
    persistent_allocator := context.allocator
    if context.allocator == context.temp_allocator {
        persistent_allocator = runtime.heap_allocator()
    }
It redirects to the heap only when it RECOGNISES the caller's allocator as the temp allocator.
That names one bad allocator and trusts every other one. Odin's test runner hands each test a
per-task allocator and recycles it when the slot is reused -- not the temp allocator, so the guard
did not fire. Before #357 the tests installed context.temp_allocator, the guard fired, and
ODIN_ROOT went to the heap. My #357 edit removed the temp install, the guard stopped firing, and
ODIN_ROOT started living in a recycled per-test arena. I introduced it.

FIXED: always `runtime.heap_allocator()`. A process-lifetime global does not get to depend on
who called it.

    ast + parser, before: parser LIMIT REACHED, 37 "Unable to find package"
    ast + parser, after:  Finished 2 tests. All tests were successful.

THE THIRD INSTANCE OF ONE PATTERN, in three consecutive entries: #354 (alloc_type_pointer spending
context.allocator), #356 (the source-file registry's map), #358 (ODIN_ROOT). Every one is
process-lifetime state built from whatever allocator the caller happened to have installed. The
general rule, now stated once: state whose lifetime is the PROCESS must name its allocator
explicitly at the allocation site. Never inherit, and never try to detect a bad inheritance --
detection only catches the allocator you thought of.

STILL OPEN. The full root suite is still 146 tests / 5 failed, and test_check_parser_package still
reports 37 errors -- but they are now a DIFFERENT 37:
    15  Cannot determine type for implicit selector expression '.Acquire'
     9  ... '.Release'
     6  ... '.Relaxed'
     6  Assignment count mismatch '2' = '1'
The "Unable to find package" class is gone. This residual does NOT reproduce in the ast+parser
pair, only in the full suite, so it is still order-dependent state -- filed, not closed, and NOT
described as pre-existing this time, because I have not established that.

## #359 three of the five root-suite failures were the tests asserting on invalid Odin; the other two are now separable

TRIAGE FIRST, BISECT SECOND. #321 was filed as "bisect which earlier test enables the failures".
Before bisecting I ran each failure alone, which cost three minutes and dissolved most of the item.

THE THREE if-TESTS: FAIL ALONE, so never order-dependent at all. Their sources declare a local and
never use it:
    if x := get_value(); x > 0 { y := x * 2 }          // 'y' declared but not used
    if val, ok := maybe_get(); ok { x := val * 2 }     // 'x'
    if p != nil { x := p^ }                            // 'x'
Oracle and port, byte-identical on all three:
    a.odin(10:3) Error: 'y' declared but not used
So the tests asserted "checks without errors" on code BOTH compilers correctly reject. Fixed by
adding a use (`_ = y`), not by flipping the expectation to expects-error -- flipping it would have
made three tests about `if` stop testing `if`. Same class as the 23 corrected earlier and
ERR-SC-018 in #354.

THE ORDERING QUESTION, ANSWERED BY A PAIR RATHER THAN A BISECT:
    test_check_all_core_packages + test_check_parser_package  ->  parser PASSES
so the 86-package test is not the trigger for parser's implicit-selector failure, and
test_check_all_core_packages' own 14/86 result reproduces with nothing before it -- it is NOT
order-dependent either. Two of the five failures were never about ordering; what remains of #321
is one test in the full suite only.

MADE THE 14 ACTIONABLE. test_check_all_core_packages counted its failures behind a comment reading
"Don't log each failure - just count them", so the result was an unactionable "14/86 packages have
check errors" -- no way to tell a real divergence from a wrong expectation without re-deriving the
list by hand. It now names each one (CHECK FAIL: <path> (<n> errors)). A count is a summary; a list
is a worklist.

VERIFICATION: spec suite 432 tests / 0 failed; both edits are test-only, so the sweeps are
untouched.

## #360 the "14/86 packages" were 13 VENDOR packages parity never covered -- and three of them hide real over-rejections

#359 made test_check_all_core_packages name its failures instead of counting them. The list settles
the item and opens a better one.

THE LIST. 13 of the 14 are under vendor/, not core/ -- the test is called
test_check_all_core_packages and sweeps vendor too. Exactly one is a core package (core/path).
And allpkgs.txt, the parity list, is 223 core + 2 base and ZERO vendor entries. So parity reporting
225/225 clean and this test reporting 14 failures were never in contradiction: they measure
disjoint sets. That is why the apparent conflict resisted explanation.

ORACLE-VS-PORT, error counts, all 14:
    AGREE  11   cgltf fontstash libc nanovg stb/image stb/rect_pack stb/sprintf
                stb/truetype stb/vorbis wgpu core/path
    DIFFER  3   box2d     oracle=1 port=2
                miniaudio oracle=1 port=4
                raylib    oracle=0 port=7      <- oracle is CLEAN
For the 11, both compilers report the same count, so the test's demand for zero diagnostics is
simply the wrong expectation -- the same class as the if-tests in #359. The 3 are real.

TWO NEW DEFECTS, both minimised to a 5-line probe with the oracle clean:
  matvec   m: matrix[4,4]f32; v: [4]f32; (m * v).xyz
           port: '(m * v)' of type 'matrix[4, 4]f32' has no field 'xyz'
           matrix[R,C]T * [C]T must yield [R]T. The port leaves the result typed as the MATRIX --
           the diagnostic names the type and convicts itself.
  quatsw   q: quaternion128; q.xyz
           port: 'q' of type 'quaternion128' has no field 'xyz'
           C++ builds component entities for every quaternion width in the field-lookup path:
           types.cpp ~3986 (quaternion64, f16), ~4024 (quaternion128, f32), ~4062
           (quaternion256, f64), each with x/y/z/w plus an `xyz` of alloc_type_array(elem, 3).
           The port has no such arm at all.
Between them these account for 4 of raylib's 7, and both of the core/math/linalg diagnostics that
raylib drags in. raylib's seventh ("Cannot transmute 'v' to 'quaternion128', 64 vs 16 bytes") may
be a consequence of the matrix mis-typing rather than a third defect -- re-measure after fixing,
do not assume.

THE MEASUREMENT LESSON. Two instruments disagreed for weeks and the disagreement was not a bug in
either: they covered different package sets, and nothing in either output said so. A sweep that
reports "225/225 clean" invites the reading "the tree is clean"; what it licenses is "the 225
packages I was given are clean". The vendor tree was never in the list, and the first time anything
looked there it found two real over-rejections.

## #361 quaternion `.xyz` ported -- and the C++ arm I was about to copy from has a FOURTH case that deliberately lacks it

#360 filed this as "the port has no quaternion component arm at all". Wrong, and reading the port
before editing corrected it: the port already had w/x/y/z for quaternion64/128/256. The gap was
exactly one field, `xyz`, missing from all three.

C++ (types.cpp ~3986/4024/4062) builds it as
    alloc_entity_field(nullptr, make_token_ident(xyz), alloc_type_array(elem, 3), false, -1)
    selection_add_index(&sel, -1)
The -1 goes to BOTH the entity and the selection index -- C++'s marker for "not a single
component" -- so it is reproduced verbatim rather than normalised to something tidier.

THE FOURTH CASE. The port has a fourth quaternion arm keyed on t_untyped_float, and the obvious
edit was "add xyz to every quaternion arm". C++ has that arm too (Basic_UntypedQuaternion) and it
has w/x/y/z and NO xyz -- checked by extracting the arm and grepping it, not assumed. So the
untyped arm is deliberately left alone. Adding xyz there would have been an invention that no
sweep would ever have caught, because nothing in the corpus swizzles an untyped quaternion.

MEASURED:
    probe quatsw   port 1 error -> 0, oracle 0            (quaternion128)
    probe quatall  all three widths, w/x/z and xyz        oracle 0, port 0
    vendor/raylib  port 7 -> 3   (oracle 0)
    the 2 core/math/linalg diagnostics raylib drags in: gone
PREDICTION CONFIRMED. #360 guessed raylib's third family ("Cannot transmute 'v' to
'quaternion128', 64 vs 16 bytes") was a CONSEQUENCE of the matrix mis-typing rather than a third
defect, and said to re-measure rather than assume. The byte counts now settle it: 64 is exactly
matrix[4,4]f32, 16 is quaternion128 -- `v` is being typed as the matrix. All 3 survivors are one
defect, #323.

VERIFICATION for #361: spec 432 tests / 0 failed; parity vet 225/225 0/0/0; corpus 176, no DIFFER.
Plain parity came back attrib_mismatches=1 on the first run and 0 on an immediate re-run of the
SAME binary, so it did not reproduce -- consistent with the family parity.sh already documents
(the core/rexcode/isa/*/tools packages declare `main` in 2-4 files each, so "Redeclaration of
'main'" can be blamed on any of them and C++'s file order decides which).

BUT I COULD NOT NAME IT, and that is my fault, not the tool's. parity.sh prints
`ATTRIB <package> (n diagnostics, same TEXT, different site -- still investigate)` precisely so
the package is identifiable, and I invoked it as `$(... | tail -1)`, which throws that line away
and keeps only the summary. The script's own comment says an ATTRIB is not automatically benign
and demands the #301/#313 discrimination BY PACKAGE; I had thrown away the input to that
discrimination before I knew I needed it. Capture the whole output of these sweeps, not the last
line -- the summary is for reporting, the body is for diagnosis.

## #362 the matrix `*` arm was a reimplementation: two whole shapes missing, one invented, and an asymmetry I would have "corrected"

C++ check_binary_matrix (check_expr.cpp:4196-4293) recognises exactly four shapes under `*`:
    matrix * matrix    (RxN)*(NxP)
    matrix * array     array as a COLUMN vector
    array  * matrix    array as a ROW vector
    scalar * matrix    via are_types_identical(y.elem, x)
The port had matrix*matrix and a scalar arm gated on `is_type_numeric(y_type)`. Both array shapes
were absent entirely -- and because an array of floats IS numeric, `m * v` fell into the scalar arm
and kept the MATRIX type. That single mis-typing produced all three of raylib's surviving
diagnostics: two swizzles rejected on the result, and a transmute that saw 64 bytes
(matrix[4,4]f32) where 16 (quaternion128) belonged.

THE ASYMMETRY, and why I probed instead of reasoning. C++ has NO `matrix * scalar` shape: it falls
out of the Mul block to are_types_identical(xt, yt) and errors. `scalar * matrix` is accepted. That
reads like an oversight, and symmetry was exactly the "correction" I was one step from making.
Oracle, both directions:
    probe mscalar  `m * s`  ->  REJECTED   "Mismatched types in binary matrix expression"
    probe smmat    `s * m`  ->  ACCEPTED
So the asymmetry is the language, and the port's symmetric acceptance was an under-rejection.
Rule pinned by measurement before a line was written.

ALSO RESTORED, both previously dropped: the is_row_major equality check C++ makes BEFORE computing
a matrix*matrix result, and the named-type preference (`if !is_type_named(x) && is_type_named(y)`)
that the port had replaced with a dimension test. The result-dimension rule was wrong too --
`matrix[2,4] * [4]f32` must yield matrix[2,1], the port yielded matrix[2,4].

STATED, NOT SILENTLY DROPPED: C++ routes every success through
check_matrix_type_hint(x->type, type_hint). The port's check_binary_matrix takes no type_hint, so
that refinement is still absent -- unchanged by this edit, and recorded rather than quietly
skipped.

MEASURED, oracle vs port, all six probes AGREE:
    mvec (m*v) 0/0   vmmat (v*m) 0/0   mnonsq (m[2,4]*v) 0/0
    mscalar 1/1      smmat 0/0         matvec ((m*v).xyz) 0/0
And on the vendor packages #360 found:
    vendor/raylib   7 -> 3 (after #361) -> 0    oracle 0   NOW EXACT
    vendor/box2d    2 -> 1                      oracle 1   NOW AGREE
    vendor/miniaudio 4, unchanged               oracle 1   still DIFFER, filed separately

## #363 miniaudio was TWO defects, and the first was hiding in a diagnostic BOTH compilers emit

#324 recorded miniaudio as oracle=1 port=4 and warned to compare TEXTS, not counts. Doing that
paid immediately -- the ONE diagnostic both sides emit is not identical:
    oracle  ... running `"/home/kalsprite/dev/odin/vendor/miniaudio/src/build_miniaudio.sh"`
    port    ... running `"/home/kalsprite/dev/odinvendor/miniaudio/src/build_miniaudio.sh"`
A missing separator, in the middle of a message I would have ticked off as "both report 1 error, agree".

DEFECT 1, FIXED: ODIN_ROOT must end with a path separator. vendor/miniaudio/common.odin:16 writes
`ODIN_ROOT + "vendor/miniaudio/src/build_miniaudio.sh"` with no separator of its own, so the
constant supplies it. C++ guarantees this structurally rather than by appending: 
internal_odin_root_dir walks back from the end of the executable path to the last '/' or '\\' and
BREAKS on it (build_settings.cpp:1219-1225), leaving the separator as the final character. The
port assigned cwd / parent / $ODIN_ROOT verbatim, none of which ends in one.
Probe odinroot (`#assert(ODIN_ROOT[len(ODIN_ROOT)-1] == '/')`): oracle passes, port failed, now
passes. Checked the blast radius first -- ODIN_ROOT has exactly two consumers in the port, a
filepath.join (which tolerates a trailing separator) and the user-visible constant (which needs
it), so normalising is safe at both.
NOT COSMETIC: any #exists or #load built the same way resolved to a path that does not exist.

DEFECT 2, LOCALISED NOT FIXED: `&v.x` on a [3]u32 is rejected as "a swizzle intermediate array
value"; the oracle accepts it (probe swzaddr, oracle clean). The error SITE is faithful -- the port's
gate and C++'s are the same four arms in the same order. The divergence is upstream, in how the
mode is assigned: the port has an invented `if swizzle_count == 1` branch (check_expr.odin:5162)
that routes single-component selects through the swizzle machinery and marks them
Swizzle_Variable/Swizzle_Value. C++'s corresponding block (check_expr.cpp:6083-6098) has NO
count==1 case at all.
THE QUESTION TO SETTLE FIRST, not to assume: if C++ reached that block for `v.x` with
prev_mode==Variable it would set SwizzleVariable and reject `&v.x` too -- which the oracle proves it
does not. So C++ must not route single-component selects there at all. Find where it does route
them before deleting the port's branch; deleting it blind would fix the address-of and could break
the type of every `v.x`.

WHY THE COUNTS AGREED ON THE REST: the oracle's single diagnostic is a #panic, which is fatal, so
it never reaches line 30 where the port reports the three swizzle errors. Count comparison alone
would have called this "port emits 3 extra"; the truth is 1 shared-but-differing message plus 3 the
oracle never had the chance to emit.

## #364 `&v.x` fixed by ADDING the arm C++ has, not by deleting the branch the port invented

#363 localised this to an invented `swizzle_count == 1` branch and explicitly refused to delete it
blind, because deleting it would fix the address-of and could break the TYPE of every `v.x`. The
question it left was: where does C++ route single-component selects? Answered:

    lookup_field_with_selection, types.cpp:4160-4188, via the _ARRAY_FIELD_CASE macro (4147-4157).
    Array and SimdVector each get x/r, y/g, z/b, w/a as ORDINARY INDEXED FIELDS when count <= 4.

So in C++ `v.x` never reaches the swizzle machinery at all: it resolves as a plain field, stays an
lvalue, and `&v.x` is legal. Two independent gates keep it out -- the swizzle block requires
`1 < field_name.len` (check_expr.cpp:6007) AND `entity == nullptr`. The port had neither the arm
nor the length gate, so someone had special-cased count==1 inside the swizzle code instead.

FIXED: the array/simd component arm added to the port's lookup_field. The port's swizzle path is
already gated on `entity == nil`, so with the arm present `v.x` resolves first and the invented
branch stops being reachable for count<=4 arrays -- no deletion required, which is why this was the
safe order to do it in.
RESTRUCTURED, STATED: C++ writes a fallthrough switch (case 4 tries w/a, falls into 3, then 2,
then 1), which admits exactly the names whose index is < count. The port uses a name->index map and
`idx < count`, the same predicate written directly.

MEASURED:
    probe swzaddr  (&v.x on [3]u32)   port 3 errors -> 0, oracle 0    AGREE
    probe quatall                      still 0/0                       AGREE
    vendor/miniaudio                   4 errors -> 1, oracle 1         counts now agree

FOUND BY PROBING THE BOUNDARY, NOT YET FIXED: probe swzbig (`v.x` on a [5]u32) is oracle=1 port=0.
C++ gates the component arm on count <= 4, so `.x` on a 5-element array is "has no field"; the port
still lets it fall through to the swizzle path, which has no `1 < len` gate and happily reads it as
a 1-element swizzle. This is PRE-EXISTING -- before this entry every single-component select went
that way -- and newly visible only because I probed the count>4 boundary rather than stopping at
the case miniaudio happened to use. The remaining fix is the `1 < len` gate plus removing the
now-dead count==1 branch; deliberately left for its own tick rather than stacked unverified onto
the end of this one.

VERIFICATION: spec 432/0; parity vet 225/225 0/0/0; corpus 176 no DIFFER. Plain parity reported
compared=224 excluded=1, `core/crypto/sm3 port=TIMEOUT` -- an EXCLUDED package is unmeasured, not
clean (#275), so it was re-run: 5/5 clean at 47ms against a 90s limit. That is #301's known
intermittent under 32-way parity load, not this change.

## #365 CORRECTION: #364's arm HUNG the checker on `#simd`, and every gate passed anyway

#364 added the array/simd component arm to lookup_field, mirroring C++ types.cpp:4160-4188 which
has arms for BOTH Type_Array and Type_SimdVector. Spec 432/0, parity plain and vet 0/0/0, corpus
clean. All green. The arm was wrong.

    probe simd1   v: #simd[4]f32;  v.x
        oracle             1 error, "prefer `simd.extract`"
        port, pre-#364     1 error, instantly
        port, post-#364    90s TIMEOUT

WHY MIRRORING C++ WAS NOT MATCHING C++. C++ has that SimdVector arm, but it is UNREACHABLE from a
selector: check_selector bails on `is_type_simd_vector` before any lookup happens
(check_expr.cpp:5994-6002) and always errors. The port has no such early bail, so in the port that
same arm IS reachable -- and reaching it hangs. Copying a function faithfully is not the same as
copying its behaviour when the CALLERS differ. The arm is now `.Array` only, with that stated at
the site.

THE PART THAT SHOULD WORRY ME MORE THAN THE HANG. I shipped it. Spec, both parity sweeps, corpus,
the lot -- all clean, because no package in 225 packages or 176 corpus members writes `.x` on a
`#simd` vector. The gates are a regression net for the code paths the corpus exercises, and they
said nothing about a hard hang one probe away. What caught it was writing a probe for the ADJACENT
case (#325 told me to check the SIMD message before assuming the length gate sufficed) -- i.e. the
next tick's homework, not the verification I ran at the time.
Concretely, for next time: when an edit adds a TYPE KIND to a shared lookup, probe that kind
directly. "The sweeps are green" does not cover a kind the sweeps never construct.

RE-MEASURED after narrowing, all at ~65ms:
    simd1  oracle 1 / port 1  AGREE   (was HANG)
    swzaddr, quatall, matvec  AGREE   (#364's gains intact)
    swzbig  oracle 1 / port 0  DIFFER (#325, the `1 < len` gate -- still open, unchanged)
    simd2  oracle 1 / port 0  DIFFER (`v.xy` on #simd: C++'s early bail rejects ANY simd selector,
                                      the port only rejects the len==1 case, and with a different
                                      message -- filed separately)

VERIFICATION for #365: spec 432/0; corpus 176 no DIFFER; parity plain 225/225 0/0/0; parity vet
225/225 with attrib_mismatches=1, NAMED and confirmed this time rather than shrugged at:
    ATTRIB core/rexcode/isa/mos65816/tools
      < dump_verify_input.odin(84:1)      Error: Redeclaration of 'main' in this scope
      > gen_mnemonic_builders.odin(185:1) Error: Redeclaration of 'main' in this scope
Two files in that package declare `main`, so the diagnostic can honestly be blamed on either and
C++'s file order picks; that is exactly the family parity.sh documents. Naming it was only possible
because #363's lesson stuck -- the sweeps are captured in full now instead of piped through
`tail -1`, which last tick threw away the one line that identifies the package.

## #366 the selector path finished: SIMD bail + `1 < len` gate ported, and the invented branch removed with a PROOF that it was dead

Three edits, done together because #365 showed the array and simd halves are entangled in the port
in a way they are not in C++.

1. SIMD EARLY BAIL (check_expr.cpp:5994-6002). C++ rejects ANY `.field` on a #simd vector before
   any lookup, choosing the message by name length. The port had no bail: it fell into the swizzle
   machinery, rejected the len==1 case with an invented message, and ACCEPTED the multi-component
   case outright. Both messages now byte-identical to the oracle:
       .x   Extracting an element from a #simd array using .x syntax is disallowed, prefer `simd.extract`
       .xy  Extracting elements from a #simd array using .xy syntax is disallowed, prefer `swizzle`
2. THE `1 < len` GATE (check_expr.cpp:6007). A one-character name is never a swizzle; it is a
   component, resolved in lookup_field's array arm (#364), itself capped at count <= 4. Without the
   gate a single component on a LARGER array fell through and was read as a 1-element swizzle, so
   `v.x` on a [5]u32 was accepted where C++ says "has no field 'x'".
3. THE INVENTED `swizzle_count == 1` BRANCH, REMOVED -- and this is the part I would previously
   have hand-waved. It is unreachable, and that is a PROOF from two facts, not a judgement:
       - the new gate means this block runs only with len(name) > 1;
       - parse_swizzle_name returns `u8(len(name))` on success and `false` on ANY invalid
         character (it never partially parses), so count == len(name) > 1.
   I read parse_swizzle_name's body before deleting rather than reasoning from its name. #365 was
   caused by exactly the opposite habit.

MEASURED, seven probes, oracle vs port, ALL AGREE:
    simd1 (.x on #simd)  1/1      simd2 (.xy on #simd) 1/1     swzbig (.x on [5]u32) 1/1
    swzaddr (&v.x)       0/0      swzmulti (v.xy read AND assign, a NEW probe written specifically
                                   to catch the multi-component path the removal could have broken)
                                   0/0
    quatall              0/0      matvec               0/0
swzmulti exists because the removal touched the branch that types every multi-component swizzle;
#365's lesson was that the sweeps do not construct these shapes, so the probe has to.

VERIFICATION for #366: spec 432 tests / 0 failed; corpus 176 members, no DIFFER; parity plain
225/225 compared, 0/0/0; parity vet compared=224 excluded=1, `core/crypto/sha3 port=TIMEOUT`.
Re-run in isolation with the same vet binary: 5/5 clean at ~50ms against a 120s limit, so the
sweep event is the load-dependent intermittent, not a hang from these edits.

OBSERVATION, NOT A CLAIM, on #301: that is the SECOND sweep timeout in two consecutive ticks
(core/crypto/sm3 in #364's gates, core/crypto/sha3 here) and both are crypto packages. Across those
two ticks that is roughly 2 events in ~900 package-runs, ~0.22%, against #301's recorded 0.089%
from 2/2250. With n=2 the interval is far too wide to call that a rise, and I am not calling it
one -- but "both were crypto" is a pattern worth a look if a third appears, and #301 is still open
precisely because its mechanism was never found.

## #367 #321 closed by re-measuring, and the last root-suite failure was a false expectation

RE-MEASURE BEFORE RE-INVESTIGATING. #321 was "test_check_parser_package reports 37 implicit-selector
errors, full suite only". Several checker fixes had landed since it was narrowed, so the first move
was to run the suite again rather than resume the bisect:
    before: 146 tests, 5 failed, all_core 72/86
    now:    146 tests, 1 failed, all_core 73/86
The implicit-selector failure is GONE -- fixed as a side effect of #361-#366, not by anything aimed
at it. Bisecting it would have been work spent on a defect that no longer existed.

THE LAST FAILURE WAS THE TEST BEING WRONG. test_check_all_core_packages demanded ZERO diagnostics
from all 86 packages. Thirteen of them legitimately produce diagnostics -- and re-verified TODAY
against the oracle, comparing TEXTS not just counts (#363's lesson), all thirteen match byte for
byte:
    core/path 1   box2d 1   cgltf 1   fontstash 2   libc 1   miniaudio 1   nanovg 5
    stb/image 3   stb/rect_pack 1   stb/sprintf 1   stb/truetype 2   stb/vorbis 1   wgpu 1
raylib is absent from that list because #361/#362 took it from 7 diagnostics to 0.

AN ALLOWLIST WITH COUNTS, NOT A SKIP-LIST, and the distinction is the whole design: a package in
the list still FAILS if its count moves. The old assertion could never pass, so it detected nothing;
a bare skip-list would pass always, so it would detect nothing either. Counts keep the regression
signal while making the claim true. The summary line reports the allowlisted packages separately
from `passed`, so they stay visible rather than being folded into a number that looks clean.

WHAT I DID NOT DO: fold the oracle comparison into this test. parity.sh owns "does the port agree
with C++"; this test owns "does the checker survive 86 real packages in-process". #360 showed what
happens when one instrument half-does another's job -- two measurements that disagreed for weeks
over disjoint package sets.

## #368 #321 solved: three process-global lifetime defects, two of them mine

#321 had been "order-dependent implicit-selector errors, full suite only" for many ticks. It was
never order-dependence in the checker. The symptom was always the same 37 diagnostics --
"Cannot determine type for implicit selector expression '.Acquire'" and friends in
core/sync/extended.odin, plus the "Assignment count mismatch '2' = '1'" that follows when
atomic_compare_exchange_*'s #optional_ok tuple is not understood -- reached through whichever
package the failing test happened to check. 37 is not a count, it is the cap
(DEFAULT_MAX_ERROR_COLLECTOR_COUNT is 36); the real number is unbounded.

BUILD THE PROBE THAT ISOLATES ONE VARIABLE. Four ticks of reasoning about which test ran first got
nowhere. What settled it in minutes was a 30-line harness that takes package paths plus flags for
the two things the suite does and no sweep does -- `-no-threads` and `-session` -- and prints the
runtime type globals either side of each check:
    -no-threads core/sync core/odin/parser    ->  0 errors,  0 errors
    -no-threads -session core/odin/parser     -> 37 errors, cap reached
    pre-check t_atomic_memory_order=0x0          (clean run)
    pre-check t_atomic_memory_order=0x5615B33A6418 (session run)
Single variable, deterministic, two seconds to re-run. #313 and #301 both stalled for want of
exactly this.

DEFECT 1, MINE, #354. acquire_runtime_session left the runtime type globals published. Loading
base:runtime is a real check, so it populates t_context, t_atomic_memory_order and ~40 siblings out
of the SESSION checker's scopes. The next independent check then found them non-nil, so its own
lazy "resolve once" guards never fired and it checked a package against a type it did not own.
Fixed by calling reset_runtime_type_globals at the end of acquire_runtime_session. Only two things
are meant to be shared and adopt_runtime_session copies exactly those: info.runtime_package and its
scope.

DEFECT 2, ALSO MINE, #354. reset_runtime_type_globals had a `if runtime_session_active { return }`
exemption -- "the session owns these, nothing to clear". That exemption is what let defect 1 persist
past teardown. Removed, along with the flag, which now has no reader and no writer.

DEFECT 3, THE ACTUAL CAUSE, and NOT mine. test_checker_lifecycle.odin has four tests --
test_init_destroy_checker, test_checker_context_creation, test_create_scope, test_scope_hierarchy --
that call init_checker/destroy_checker with NO globals lock. destroy_checker calls
reset_runtime_type_globals; the test runner is multi-threaded; so those four nil the process-global
type state at an arbitrary moment, including in the middle of a package check holding the mutex.
A t_atomic_memory_order nilled mid-check is precisely a missing Atomic_Memory_Order hint. That is
why the failure MOVED between test_check_parser_package and test_check_real_package between runs:
the victim is whoever holds the mutex when one of the four lands. The file's own contract, written
at test_checker_integration.odin:26-64, says to take the lock; four tests did not.

THE COUNT WAS THE TELL AND I ALMOST MISSED IT. 9 checker uses, 2 lock calls, in one file. One
`grep -c` per file across the tests directory found it after four hypotheses about init order,
allocator lifetime and thread counts had all been refuted by measurement.

ALSO FIXED, same family: the five spec-suite helpers in test_helpers.odin still installed
`context.allocator = context.temp_allocator` around checker work. #357 removed that pair from the
eight package-driving tests; these five were the rest of the same defect. Type constructors take no
allocator and spend context.allocator (#354), so every type those checks built died at the guard
while the globals that pointed at them survived.

RESULT. Root suite 146 tests, ALL SUCCESSFUL, three consecutive runs -- it has never been green
before. Spec suite re-verified at 432 tests, 0 failures, which also proves the session still does
its job: adopt_runtime_session never needed the type globals, only the package and its scope.

GATES after #368, all re-run against the changed types.odin / runtime_session.odin:
    parity plain   225 packages, 225 compared, 0 excluded, 0 count / 0 text / 0 attrib mismatches
    parity vet     225 packages, 225 compared, 0 excluded, 0 count / 0 text / 0 attrib mismatches
    corpus         176 FULL-MATCH, 0 missing, 12 excluded (all pre-existing, listed by the harness)
    spec suite     432 tests, 0 failures
    root suite     146 tests, 0 failures, 3 consecutive runs
    odin check -vet -strict-style -no-entry-point clean on checker, tests, parser, ast
Zero excluded on both parity sweeps is worth noting on its own: #275's rule is that an excluded
package is UNMEASURED, not clean, and this pair had nothing to exclude.

## #368 continued: two more instances, and a CORRECTION to what #368 claimed above

CORRECTION, and it is mine. #368 above says the five test_helpers entry points were "ALSO FIXED,
same family" by dropping their `context.allocator = context.temp_allocator`. That change is real
but it achieved NOTHING for the spec suite, because the install was never only in the helper:
    grep -rc "context.allocator = context.temp_allocator" core/odin/checker/tests -> 586 sites
Nearly every one is a spec test proc that installs the temp allocator in ITS OWN frame and then
calls check_should_pass. Removing the helper's install left the caller's in force for the whole
check. I verified the claim by reading the helper and not by counting the callers.

THE FIX THAT ACTUALLY HOLDS. Both helper checker constructors now write
`context.allocator = runtime.default_allocator()` before init_checker. Passing default_allocator as
the init_checker ARGUMENT was never enough -- #354's lesson exactly: the argument says nothing
about what the code you call SPENDS, and the type constructors spend context.allocator. Owning the
checker means owning the allocator context for its lifetime, no matter what the caller installed.
Editing ~580 spec procs was the alternative and would have been the wrong layer.

FIFTH INSTANCE OF THE LOCK DEFECT, found by fixing the instrument rather than the code.
test_integration_minimal.odin's test_checker_init_only had no globals lock. My first sweep counted
global-state touches and lock calls PER FILE, and that file's other test does lock -- so the file
looked covered and the test was invisible. A per-TEST-PROC scan found it immediately:

    for each `name :: proc(t: ^testing.T)` body:
        if it touches init_checker/destroy_checker/check_package_from_path/init_error_collector/
           error_count/get_error_values/acquire_runtime_session/check_files/...
        and does not contain lock_checker_globals(t):  report it

That scan now reports unlocked_test_procs=0 across the package. A per-file ratio was the wrong
granularity for a per-proc invariant, and it is worth keeping in mind for the next audit: the unit
of the check has to be the unit of the rule.

VERIFIED after both changes: spec suite 432 tests, 0 failures; tests package clean under
-vet -strict-style -no-entry-point.

## #369 the parity sweeps were counting a package that does not exist

flake.sh reported `packages=224` where both package lists hold 225 entries. The gap is real and it
is the instruments disagreeing about what they measure:
    sweep_det.sh:10   while read -r p; do [ -d "$p" ] || continue     <- guards
    parity.sh:55      while read -r p; do                             <- does not
The unguarded entry is `core/odin/checker/tmp`, a directory THIS BRANCH deleted (#8, removing
committed build artifacts -- `git status` still shows `D core/odin/checker/tmp/file.odin`). It
stayed in the list. parity.sh therefore ran both compilers on a path that is not there, got the
same nothing from each, and scored it as agreement.

So every "225 packages, 225 compared, 0 mismatches" in this ledger was 224 real packages plus one
phantom that could never mismatch. Nothing measured is invalidated -- the 224 real comparisons all
stand -- but the headline number was one too high, and a package that silently cannot fail is the
same species of defect as #367's test that could never pass and #275's excluded-means-unmeasured.
An instrument that reports success for work it did not do is worse than one that reports nothing.

FIXED by dropping the entry from .claude/tools/pkglist.txt and the scratchpad's allpkgs.txt; both
are now 224 and every entry is a directory that exists. Expect 224 from here on; a future 225 means
someone re-added it.

NOT DONE, deliberately: I did not add the `[ -d ]` guard to parity.sh. The guard is what let this
hide in flake.sh for as long as it did -- it skips silently. A list naming something that is not
there should be fixed in the list, and if it happens again the oracle's own "directory does not
exist" output is a louder signal than a silent skip.

#301 EVIDENCE, AND A CORRECTION I NEARLY REPEATED. The screen ran 224 packages x 5 = 1120
package-runs with unstable=0. My first instinct was to write that this tightens #301's 0.089%
timeout rate. It does not, and that is the exact error the task text already records me making
once: "my 'stale' claim retracted -- it compared flake-load to parity-load". #301 is a LOAD-
DEPENDENT intermittent measured while parity runs the port and the reference concurrently;
flake.sh's header says in capitals to RUN IT ALONE, because competing load manufactures false
timeouts. A clean run under low load does not sample the condition at all. What these 1120 runs do
establish is output DETERMINISM -- same binary, same bytes, five times over -- which is what the
screen is for. The timeout rate is untouched and #301 stays where it is.

## #370 runspec.sh reported TOTAL 0/0 for a fully green suite

Third of the family, and I walked into it myself this session. runspec.sh scored each spec package
by grepping for

    [0-9]+/[0-9]+ tests successful

which Odin's test runner emits ONLY when some tests pass and some fail. A package where everything
passes prints "Finished N tests in T. All tests were successful." and matched nothing, so it was
labelled NO-SUMMARY and contributed zero. The whole spec suite passing therefore printed

    TOTAL 0/0

and I had to hand-write a shell loop to get the real number (432) out of the logs -- twice, before
noticing the harness was the problem rather than an inconvenience.

THE WORSE HALF is not the arithmetic. NO-SUMMARY was ALSO what a binary that segfaulted before
printing any summary produced. The best outcome and the worst outcome rendered identically. An
instrument whose success and failure states are the same string cannot be read at all.

FIXED by parsing "Finished N tests" -- the one line both endings share -- and treating its absence
as DID-NOT-COMPLETE, counted separately and never folded into the pass total. summ.sh already did
exactly this and says so in its header; runspec.sh simply never got the same treatment, and having
two summarisers disagree about how to read the same log is its own defect.

POSITIVE CONTROL, because a branch that has never fired is not known to work: three synthetic logs
(all-pass / partial-fail / died mid-run) through the new parse gives
"TOTAL 51 tests, 3 failed, 1 packages did not complete", which is the expected 21+30 and the
segfault landing in its own bucket. Real run after the fix: TOTAL 432 tests, 0 failed, 0 did not
complete.

THE FAMILY, now four: #275 an excluded package read as clean; #367 a test asserting something
false so it could never pass; #369 a package in the sweep list that does not exist so it could
never mismatch; #370 a summariser blind to the success case. Every one reports a number that looks
like a result for work it did not do. The generalisation worth keeping: for each instrument, ask
what its output looks like when the thing it measures did not happen -- if that is
indistinguishable from success, the instrument is broken regardless of what it prints.

## #371 upstream write-ups, and four claims that did not survive re-verification

Wrote one markdown issue file per upstream finding into the repo root, for filing against the Odin
project. EIGHT are verified and ready; SEVEN are held back, and the holding back is the result.

VERIFIED AND WRITTEN: #119 (runtime typo), #159 (Damerau term never checks a transposition, and
USE_DAMERAU_LEVENSHTEIN is 1 so it is live -- it also tightens MAX_SMALLEST_DID_YOU_MEAN_DISTANCE,
so an under-computed distance is scored against a threshold that assumed a correct metric),
#187/#189/#195 (three diagnostic-text slips, each read verbatim at its cited line), #206, #263,
#285.

#206 GOT SHARPER UNDER VERIFICATION. The note said "passes a string to %a (hex-float) --
undefined behaviour". The truth is worse and more definite: gb's formatter implements `%a` as

    case 'a':
    case 'A':
        // TODO(bill):
        break;

which consumes NO vararg. So the following `%s` reads the wrong argument, and the rendered
suggestion is "Suggestion:  may be directly casted to <expression>" -- the type name never appears
at all. Not UB in practice; a deterministic wrong string.

#342 DOES NOT REPRODUCE, and that is the finding. The ledger records "3/3 reproducible" for
complex() into a union-typed return panicking at types.cpp:1985. I recovered the exact original
source from git (the deleted core/odin/checker/tmp/file.odin) and ran it three times, with and
without -no-entry-point: rc=0 every time. Not minimised-away, not mis-transcribed -- the original
file, clean. Held back pending re-establishment.

#161 and #225 CANNOT BE FILED because the notes never recorded the input. "three objc attributes
segfault when written without a value" does not say WHICH three, and `@(objc_class)` with no value
gives a clean diagnostic today. "a prefixed-base literal with an exponent" does not say which
literal, and my guess `0x1p3` is an ordinary syntax error.

THE METHOD FAILURE, which is mine. My first move was to WRITE the four crash reports from the task
titles and construct plausible repros to match. All four constructions failed, which is the only
reason I looked further and found #342 does not reproduce at all. Had I trusted the notes, four
issues would have gone upstream on the strength of a memory rather than a result. A bug report is a
claim about present behaviour; the behaviour has to be observed at filing time.

THE UNDERLYING DEFECT is in how these were recorded: a task title is not a reproduction. Every one
of the seven held items is held because the note captured a CONCLUSION without the INPUT that
produced it. #285 is the counter-example and the model -- it had a probe directory on disk, so it
re-ran in one command and reproduced 3/3.

## #372 #225 RECOVERED: not "prefixed base with an exponent" but any non-decimal base meeting an `e`

The note said "a prefixed-base literal with an exponent aborts the compiler" and recorded no input.
My first guess, `0x1p3`, is an ordinary syntax error -- which is why #371 held the item back.
Recovered it by sweeping the literal grammar instead of guessing: seventeen forms, one command,
looking only at the exit code. Six abort.

    0b1e5 0b1E5 0b1e 0o1e0 0z1e1   ->  big_int.cpp(252)  Assertion Failure: `base == 10`
    0d1e-5                         ->  big_int.cpp(253)  Assertion Failure: `text[i] != '-'`
    0d1e5  0d1e+5  0d1e  0x1e5  0d_1e5  ->  accepted, rc=0
    0b19                           ->  ordinary error, rc=1

TWO assertions, not one, and the note's framing was wrong in a way that mattered: it is not the
exponent that breaks it. `0x1e5` has an `e` and is fine (hex digit); `0d1e5` has an exponent and is
fine (base 10). The trigger is an `e` reaching big_int's exponent branch with base != 10 -- or with
a `-` after it, which even base 10 cannot survive.

MECHANISM, three steps that are each individually reasonable:
  1. Every prefixed base calls scan_mantissa with force_base=FALSE, and scan_mantissa then does
     `base = 16; // always check for any possible letter`. So `0b1e5` is scanned at base 16 and the
     whole thing lands in one token.
  2. The only post-scan validation is `t->curr - prev <= 2`, an emptiness test. Digits invalid for
     the DECLARED base are deliberately left to the consumer.
  3. big_int_from_string exempts e/E from its `v >= base` failure path so decimal exponents
     survive -- but does not condition that exemption on base being 10 -- and then asserts it is.

The exemption and the assertion disagree, and the tokenizer's over-consumption is what lets a
base-2 literal reach the disagreement.

WHY THE SWEEP WORKED AND READING DID NOT. I read scan_number_to_token first and concluded the
crash was impossible: every prefixed branch does `goto end`, skipping the `exponent:` label, so no
prefixed literal can carry an exponent. That reasoning is correct and irrelevant -- the exponent is
never attached by the tokenizer at all; the `e` is swallowed as a MANTISSA digit because
force_base=false widens the base to 16. I had read the branch and missed the argument. Seventeen
one-line files found in one command what careful reading had just talked me out of.

## #373 #161 RECOVERED: the three are objc_superclass, objc_ivar, objc_context_provider

Same technique as #372, and it worked for the same reason. The note said "three objc attributes
segfault/assert when written without a value" and named none of them. Rather than guess again,
enumerated the attribute set from the source itself --

    grep -rhoE '"objc_[a-z_]+"' src/*.cpp | sort -u      ->  12 names

-- and wrote each one bare on a struct. Three crash, nine do not:

    objc_superclass        checker.cpp(52) Assertion Failure: `expr != nullptr`   SIGILL
    objc_ivar              checker.cpp(52) Assertion Failure: `expr != nullptr`   SIGILL
    objc_context_provider  SIGSEGV, no message at all
    (objc_class, objc_implement, objc_instancetype, objc_name, objc_type, objc_selector,
     objc_is_class_method, objc_object, objc_super  ->  clean diagnostics)

CAUSE: a bare attribute has value == nullptr. The two asserting branches pass it straight to
check_type (checker.cpp:4484, 4493), which reaches check_rtti_type_disallowed's
GB_ASSERT(expr != nullptr) at :52. objc_context_provider passes it to check_expr (:4503) and
segfaults instead. The else-branches in the first two even INTEND to diagnose -- but call
`error(value, ...)` on the same null pointer, so that path was never viable either.

THE FIX IS ALREADY IN THE FILE. objc_name, nine lines away, routes through
check_decl_attribute_value (which handles null) and anchors its diagnostic on `elem`, the
attribute element, not on the absent `value`. Nine of twelve do it that way. The issue file quotes
it as the model rather than inventing a shape.

WHY SWEEPING BEAT SAMPLING, again. Guessing gave me `@(objc_class)` last tick, which produces a
clean diagnostic -- a confident negative that would have closed the item as unreproducible had I
stopped there. Twelve one-line files settled it in one command, and the nine that behave correctly
are not noise in the result: they are what proves the three are outliers and what supplies the fix.

## #374 #166 RECOVERED, and the note's word "wraps" was half right in an important way

Third recovery by sweeping rather than guessing. `X : i64 : 18446744073709551615` -- u64 max
declared i64 -- is ACCEPTED by the reference. The boundary sweep pins the enforced bound at 2^64
rather than i64's range:

    i64 = 9223372036854775807   accepted (correct)
    i64 = 9223372036854775808   ACCEPTED (wrong)
    i64 = 18446744073709551615  ACCEPTED (wrong)
    i64 = 18446744073709551616  rejected
    i64 = -9223372036854775809  ACCEPTED (wrong)
    int, i64le                  same
    i32 / u64 boundaries        all correct

CAUSE, check_expr.cpp:2388. For i64/int/i64le/i64be, imin_64 and imax_64 ARE INT64_MIN/INT64_MAX,
so `return imin_64 <= val64 && val64 <= imax_64;` is TRUE FOR EVERY i64 -- a tautology. The only
surviving gate is big_int_can_be_represented_in_64_bits, a WIDTH test admitting the full unsigned
range. Narrower types escape because their bounds are genuinely narrower, which is exactly why i32
is correct and i64 is not. The correct line is present, commented out, immediately above:
`// return imin <= i && i <= imax;` -- the big-int comparison, which has no width to overflow.

WHERE I HAD TO CORRECT MYSELF MID-TICK. I first reported the value wraps to -1, on the strength of
`#assert(X == -1)` returning rc=0. That rc was HEAD's, not odin's -- I had piped through `head`
before reading `$?`. Re-run without the pipe: the assert FAILS, and `#assert(X == 18446744073709551615)`
HOLDS. So the constant keeps its true value.

The distinction matters for the report. big_int_to_i64 DOES wrap during the check -- that is how
u64 max slips past the tautology -- but the stored constant is unwrapped. "The check wraps; the
value does not." A report saying the value wraps would have been refuted by the first person to try
it.

`$?` after a pipeline is the LAST command's status. I have now been bitten by this twice in one
session (also the `./odin check | grep` in the #225 sweep, which happened to be harmless). Read the
exit code from the command, never through a filter.

## #375 #169 CONFIRMED as a defect, but only HALF of it -- and the half I could not get is stated

quote_to_ascii's String16 overload (string.cpp:963) indexes lower_hex -- 16 entries -- with
`s[0]>>4` where s[0] is a u16, so the index ranges 0..4095. Out of bounds by up to 4080. The u8
overload at :865 is the SAME EXPRESSION character for character, and correct there because s[0] is
a byte. The expression was carried into the wider type without widening the shift. The same
function even masks correctly on its \u path at :1002 -- `(r>>i)&0xf` -- so the fix shape is
already present twice over.

TRIGGERING VALUES derived from the guard `width == 1 && r == GB_RUNE_INVALID`:
    s[0] == 0xFFFD              -> 0xFFFD>>4 = 4095   (GB_RUNE_INVALID *is* 0xFFFD)
    unpaired high surrogate     -> 0xD800>>4 = 3456
    high surrogate + bad low    -> decode fails, width stays 1

WHAT I COULD NOT DO, and did not paper over: drive a string16 value through this function from
Odin source. The call site is exact_value_to_string (exact_value.cpp:1116), but every diagnostic I
could reach renders the constant via expr_to_string -- SOURCE TEXT -- instead:

    switch x { case "\ud800": case "\ud800": }  ->  Duplicate case '"\ud800"'

That is the source spelling echoed back, not a quoted exact value. So the note's claim "on every
malformed-input escape" is unsupported: I could not show ANY input that reaches it.

FILED ANYWAY, with the gap named in the issue file itself. An index provably out of range for two
identified values is a defect whether or not I can currently drive it, and the next person to wire
a string16 constant into a diagnostic inherits it. But a maintainer reading the report must not be
left to assume a reproduction exists -- #371's whole lesson. Same disposition as #263: real finding,
honest about which half is verified.

## #376 #156 RECOVERED: `isize i = 0` is never incremented, so every named argument is labelled `named[0]`

check_expr.cpp:7651, the print_argument_types lambda. `i` is declared before the POSITIONAL loop
and incremented nowhere at all; the named loop reads ce->split_args->named[i] every iteration.
Both loops are range-for over the operand arrays, so no other cursor could be advancing it. The
`i < count` guard therefore only fails when there are no named arguments.

REPRODUCED first try, unlike the previous four:

    g(alpha = 1.5, beta = 2.5)      ->   Given argument types:
                                          * alpha = untyped float
                                          * alpha = untyped float      <- should be beta

The operand TYPES are right and paired correctly; only the labels are wrong, which is why this
survived: the diagnostic looks structurally fine and you have to know the parameter names to spot
that the second line is mislabelled. Two call sites (:7684 and :7939) share the lambda.

WHY THIS ONE WAS EASY AND THE OTHERS WERE NOT. #225/#161/#166/#169 all needed the input space
enumerated because the note recorded a conclusion without an input. #156's note named the FUNCTION,
and a function name is a location -- one grep and the defect is visible in nine lines. The
difference is not the difficulty of the bug; it is whether the note pointed at code or at an
outcome. Worth remembering when writing the next note: cite the site, not just the symptom.

## #377 #174 CONFIRMED by inspection, and the note had it BACKWARDS

check_expr.cpp:7119-7148. Two arms of one switch contribute lines to the definitions block and
share `print_count`. The Entity_TypeName arm has its header line COMMENTED OUT at :7125 but still
does `print_count += 1`. So a type name prints its definition, bumps the counter, and the
Entity_Constant arm's `print_count == 0` guard is dead thereafter. The block prints; the header
does not.

    constants only            -> header, then definitions   (correct)
    type names only           -> definitions, NO header
    type name before constant -> definitions, NO header
    constant before type name -> header                     (correct)

THE NOTE'S FRAMING WAS INVERTED. "the header destroys the diagnostic block it announces" -- it is
the other way round: the BLOCK survives intact and the HEADER is what goes missing. Bare
`Name :: Type;` lines hang under the error with nothing introducing them. Had I written the issue
from the note's wording I would have described the wrong symptom, and a maintainer looking for a
destroyed block would have found an intact one and closed it.

Which arm runs first is hash order over scope->elements, so the header's presence is unpredictable
for a scope holding both kinds -- consistent with #173/#185/#201, which spent a lot of effort on
this same block's order-dependence and closed it as IRREDUCIBLE.

REACHABILITY NOT DEMONSTRATED, and stated in the file. Four shapes tried -- failing `where` on a
polymorphic proc with $N, with $T+$N, and both as polymorphic structs -- all produce the
'where' clause error with NO definitions block after it. Either scope is null on those paths or it
holds no TypeName/Constant entries there. Same disposition as #169 and #263: the defect is exact,
the route to it is not mine to claim.

## #378 objchang's two divergences were four, and I promoted four probes on the wrong instrument

THE FIX. objchang's re-probe (#369's exclusion sweep) showed a message-text drift and a position
drift. Reading C++ showed FOUR message divergences in the same objc_send block, not one:

  * ALL FOUR of C++'s messages carry a `, got ...` suffix naming the offending type or expression.
    The port had dropped it from every one -- strictly less useful AND textually divergent.
  * TWO of C++'s spellings are slips and are now reproduced VERBATIM: `@(obj_class=` (missing the
    'c', plus a space before the comma) at check_builtin.cpp:331/357, and "pointer OF a value"
    at :347 where we had written "pointer to". Same rule as #287 and #185: parity, not prose.
  * STRUCTURAL. C++ has ONE branch, `!is_operand_value(self) || !check_is_assignable_to(...)`.
    The port had SPLIT it in two, and the second half's "expected a value assignable to objc_id"
    was INVENTED -- C++ has no such message. Splitting an `||` is only safe when both halves say
    the same thing; here it manufactured a diagnostic the reference never emits.
  * POSITION. C++ anchors the zero-size error on e->token (check_decl.cpp:603) -- the declared
    NAME, column 1. The port used init_expr, column 8, the `struct` keyword. #179/#197 again:
    right message, wrong anchor, invisible to a count-only comparison.

GATES after the fix: parity plain 224/224 0/0/0, parity vet 224/224 0/0/0, corpus 176 FULL-MATCH.

THE MISTAKE, and it is a good one. probe.sh reported objchang MATCH, and also reported fb,
fbisect and p_ppp MATCH. So I promoted all four out of the EXCLUDED list into the corpus. Re-ran
corpus and got FULL-DIFFER=4 -- every one of them.

    probe.sh    objchang MATCH (2 diagnostics)
    cmpfull.py  objchang FULL-DIFFER: oracle also emits
                  main.odin(13:9) Error: 'objc_send' only works on darwin
                which the port does not emit at all.

TWO COMPARATORS, TWO DEFINITIONS OF "MATCH", and I acted on the looser one. probe.sh greps and
counts diagnostics; cmpfull.py compares the FULL output. A diagnostic the port never emits is
invisible to the first and fatal to the second. probe.sh's own header (#283) says it exists to
catch what ad-hoc diffs miss -- it is not the strictest instrument, it is the one with rc
classification. I read "MATCH" and stopped.

WHAT THE STRICTER RUN ACTUALLY FOUND, now recorded in the exclusion notes instead of the stale
#277/#278 text:
  * objchang -- the port never emits "'objc_send' only works on darwin". A REAL remaining gap in
    the darwin gating (#21/#283 territory), which the message fix above did not touch and which
    probe.sh could not see.
  * p_ppp    -- the oracle emits a `<nopos> Note:` continuation block the port does not. #155
    recorded that the OLD comparator could not see continuation lines; cmpfull can, and they are
    genuinely absent.
  * fb / fbisect -- 16 and 15 line FULL diffs, still unexamined.

Promotion reverted; the corpus is 176/12 again, unchanged. Nothing was lost except my claim.
The exclusion notes are now accurate, which is the #369 lesson applied a second time -- except
this time the decayed annotation was replaced with what the strict instrument reports, not with
what the convenient one did.

## #379 CORRECTION to #378: the "darwin gap" is a harness mismatch, and the port was right

#378 recorded, on the strength of cmpfull.py's FULL diff, that the port "never emits
'objc_send only works on darwin' -- a REAL remaining gap in the darwin gating". That is WRONG and
this entry retracts it.

C++ gates the message on the COMMAND, not just the OS (check_builtin.cpp:283-287):

    if (build_context.metrics.os != TargetOs_darwin) {
        // allow on doc generation (e.g. Metal stuff)
        if (build_context.command_kind != Command_doc && build_context.command_kind != Command_check) {
            error(call, "'%.*s' only works on darwin", LIT(builtin_name));
        }
    }

Measured three ways on the same probe:

    oracle, `odin check -no-entry-point`   ->  0   (parity.sh's invocation)
    oracle, `odin build -out:/dev/null`    ->  1   (cmpfull.py:107's invocation)
    port,   command_kind = {.Check}        ->  0

The port agrees with the oracle under the command the port is configured to emulate. There is no
gap. What there IS: corpus.sh compares an oracle running BUILD against a port configured for
CHECK, so every diagnostic whose emission depends on command_kind differs spuriously. Exactly the
class triage_st's own header warns about for -no-entry-point -- "a harness mismatch masquerading as
a regression (cf. #45, #275)" -- reappearing one line below the warning, on a different flag.

TWICE IN TWO TICKS ON THE SAME PROBE, in opposite directions. #378: trusted probe.sh's MATCH, which
was too loose, and promoted four probes wrongly. #379: trusted cmpfull.py's DIFFER, which was too
strict for the wrong reason, and recorded a defect that does not exist. The instruments were not
lying; each was answering a different question than the one I asked, and I did not check which.
Before believing either verdict, establish what the oracle was actually invoked as.

NOT CHANGED YET: aligning cmpfull.py onto `odin check` would make the two harnesses agree, but it
could move any of the 176 probe verdicts, so it is a MEASURED change (#290's precedent) and not a
drive-by edit. Filed as the next item. The exclusion note for objchang now states the mismatch
rather than the phantom defect.

## #380 I reported a zero delta from a run that measured nothing, and corpus.sh let me

Set out to do #379's MEASURED comparator alignment: copy cmpfull.py, change its oracle invocation
from `odin build` to `odin check -no-entry-point`, run the corpus both ways, diff the verdicts.
Reported "zero delta across all 176 corpus members -- both give FULL-MATCH".

THAT WAS PHANTOM. The copy resolves its repo root from its own __file__, so from the scratchpad it
looked for ./odin beside itself, and threw FileNotFoundError on EVERY probe:

    A run (real cmpfull):     176 verdict lines
    B run (my variant):         0 verdict lines
    both runs printed:        CORPUS-DONE members=176 missing=0 excluded=12

B compared nothing at all. The identical summary is what made it look like a result, and I read
the summary instead of counting the verdicts.

THE TOOL LET ME. corpus.sh called the comparator unguarded and echoed its summary regardless of
exit status. So a corpus run whose comparator dies on every probe is byte-identical, in its
headline, to a clean run. That is #275 (excluded read as clean), #367 (assertion that could never
pass), #369 (package that could never mismatch) and #370 (summariser blind to success) -- the fifth
member of the family, and the first one I built myself, inside the rig meant to audit the others.

FIXED: corpus.sh now captures the comparator's exit status and prints
CORPUS-ABORTED ... NOTHING below is a measurement, exiting 1. Positive-controlled against the
broken variant (fires, rc=1) and against the real one (176 members, unchanged).

AND THE GUARD'S FIRST VERSION HAD THE BUG IT WAS GUARDING. I wrote
`if ! python3 ...; then echo "(exit $?)"` -- which reports the IF's status, not python's, and duly
printed "exit 0" while aborting. Third time today that reading `$?` through an intervening
construct gave a wrong answer: twice through pipelines (#374's `#assert` verdict, and the #225
sweep) and now through an `if !`. The rule is not "beware pipes", it is: `$?` belongs to the last
thing the shell ran, which is rarely the thing you meant. Capture it into a variable on the very
next line or do not use it.

THE ALIGNMENT MEASUREMENT IS STILL NOT DONE. It is not "no difference"; it is unmeasured. The rig
needs the variant to resolve REPO correctly before the A/B means anything.

## #381 STOPPING the comparator A/B: three rigs, three failures, and the change is not needed

#379 proposed aligning cmpfull.py's oracle invocation from `odin build` to `odin check`, as a
MEASURED change. Three attempts, each failing for a different reason, none of them the compiler:

  1. Copied cmpfull.py to the scratchpad. It derives REPO from its own __file__, so it looked for
     ./odin beside itself and threw on every probe. Reported "zero delta"; had measured NOTHING.
     (#380, and the reason corpus.sh now aborts loudly.)
  2. Rebuilt the rig with a fake root so ODIN resolved. But run() passes cwd=REPO, so the PORT was
     then launched from the fake root and could not find core/ -- it started reporting
     "Undeclared name: append". 19 FULL-DIFFER, every one an artefact. Caught by noticing the PORT's
     output changed while the port binary and its arguments had not.
  3. Put the comparator in the real tools dir but copied the DRIVER to the scratchpad, so $HERE
     resolved there and python could not find the comparator: exit 2. The CONTROL failed
     identically, which is the only reason this was obvious.

Each failure was in a different piece of path plumbing, and each produced output that looked like
a result until checked. Attempt 2 is the instructive one: the totals were plausible (157/19) and
only the CONTENT gave it away.

WHY I AM STOPPING RATHER THAN TRYING A FOURTH. The change buys consistency between two harnesses,
nothing more. corpus.sh is currently GREEN at 176/176 FULL-MATCH under `odin build`, and #379
already established, by direct three-way measurement on the probe itself, exactly what the
mismatch is and that the PORT IS CORRECT. The objchang exclusion note records it precisely. So the
open question is cosmetic, the instrument is working, and I have spent four ticks on rig plumbing
instead of the checker. Proportion says stop.

STATE, stated plainly so nobody reads this as done: the alignment is UNMEASURED. Not "no
difference" -- unmeasured. If it is ever attempted again, the right rig is to swap cmpfull.py IN
PLACE (backup, replace, run, restore) so that every path stays identical and only the file
contents differ, and to run an unmodified copy as a control FIRST. All three failures above came
from moving a file to a new path; none would have survived that discipline.

## #382 full gate set re-verified on the current tree

#378 changed check_builtin.odin and check_decl_helpers.odin. Both parity sweeps and the corpus were
re-run at the time; the two SUITES were not. Checked rather than assumed -- `find -newer` against
the last suite binary named exactly those two files -- then ran everything:

    vet     checker / tests / parser / ast        rc=0 on all four
    spec    432 tests, 0 failed, 0 did not complete
    root    146 tests, ALL SUCCESSFUL
    parity  224/224 plain, 224/224 vet, 0/0/0 both      (re-run under #378)
    corpus  176 FULL-MATCH, 0 missing, 12 excluded      (re-run under #378/#379)

Note the spec line is the #370 format: "0 packages did not complete" is now stated separately, so
an all-green run and a run where a binary died are no longer the same string.

The tree is green on every instrument that currently works. Nothing is committed, per CLAUDE.md.

## #383 the five crash repros verified command-INDEPENDENT

#379 found that "'objc_send' only works on darwin" is gated on command_kind, so a diagnostic can
exist under `odin build` and not under `odin check`. That raised a question about the upstream
write-ups: every crash repro in them is stated as `odin check -no-entry-point`. If any of those
crashes were command-gated, the report would mislead whoever runs the other command.

Re-ran all five under BOTH:

    0b1e5                       check 132   build 132     (SIGILL, big_int.cpp:252)
    0d1e-5                      check 132   build 132     (SIGILL, big_int.cpp:253)
    @(objc_superclass)          check 132   build 132     (SIGILL, checker.cpp:52)
    @(objc_ivar)                check 132   build 132     (SIGILL, checker.cpp:52)
    zero-param context_provider check 139   build 139     (SIGSEGV)

All command-independent. UPSTREAM-161/225/285 stand as written.

METHOD SLIP, caught not shipped: the first attempt `cd`-ed into the probe directory, so the
relative `./odin` in the check column was not found and returned 127 for all four rows. 127 is not
a crash and not a pass -- it is the harness failing to run the thing under test. Had I read only
the build column, which was correct, I would have reported a verified result from a half-broken
run. Absolute path on the second attempt. Sixth instance today of a measurement that produced
output without producing evidence.

## #384 the four vet probes were excluded with a correct reason and no tool -- corpus_vet.sh

corpus.sh drives the PLAIN harness, so shadowparam / shadowvar / vetctl / vetmap could never be
members: running a vet probe against a non-vet oracle compares nothing meaningful. They were parked
in EXCLUDED with the note "vet-mode probe -- must be run with triage_vet, not this harness". That
note is TRUE and was also the whole problem: it named the right tool, and no such tool existed, so
nothing ran them. Four probes, written deliberately, measured by nobody.

An exclusion that names the correct instrument without providing it is a coverage hole wearing a
reason. That is a quieter variant of the #275/#367/#369/#370 family: not a summary that overstates,
but a justification that reads as a decision when it is actually a gap.

BUILT corpus_vet.sh: same shape as corpus.sh, oracle invoked exactly as parity_vet.sh does
(`odin check <p> -vet -no-entry-point`), port = triage_vet. Compares TEXTS, not counts -- #363's
rule, and it mattered nowhere more than here: all four AGREE on counts, which on its own would
have proved nothing, since fb2 agrees on counts too and swaps four message kinds.

    shadowparam  TEXT-MATCH (0 lines)      vetctl  TEXT-MATCH (2 lines)
    shadowvar    TEXT-MATCH (0 lines)      vetmap  TEXT-MATCH (3 lines)
    CORPUS-VET-DONE members=4 match=4 differ=0 missing=0     rc=0

POSITIVE CONTROL, because a gate that has only ever passed is not known to fail: pointed it at a
stub "port" that prints one bogus warning -> differ=4, rc!=0. It detects.

corpus.sh's four exclusion notes now point at corpus_vet.sh by name, so the next reader learns
where those probes ARE measured rather than only that they are not measured here.

MEASURED COVERAGE: 176 plain + 4 vet = 180 probes, up from 176, with 8 remaining exclusions --
all of them either oracle-broken, oracle-nondeterministic, or genuinely open.

## #385 catch-up after the master merge -- ten upstream fixes landed, and the port had gone stale at ten sites

The port is deliberately bug-compatible with C++. That is correct while a C++ bug is live and
becomes a DEFECT the moment upstream fixes it. Master was merged carrying fixes for ten of the
fourteen findings written up in UPSTREAM-*.md -- so ten sites in the port were now wrong, each one
with a comment explaining, persuasively and stalely, why it had to be that way.

REBUILT THE ORACLE FIRST. The tree's ./odin was 19:55, src/types.cpp 20:17, still emitting the old
"expected 1+ rows". Every comparison run before that rebuild would have measured the old reference
against the old port and reported agreement.

WHAT WAS STALE, and how each was caught:

  #189 matrix column msg  check_type.odin       "rows" -> "columns"
  #195 field-list msg     parser.odin           "in not allowed" -> "is not allowed"
  #187 import name        check_import_export.odin  both C++ branches now share one text
  #174 definitions header check_proc.odin       BOTH arms, and the two leading spaces are the fix
  vet flag list           file_tags.odin        upstream added "semicolon"/"deprecated" to the print
  #156 named-arg labels   check_proc_group.odin TWO sites, neither reached by any probe
  #225 literal exponent   parser.odin +         TWO sites, neither reached by any probe
                          exact_value.odin

The first five were caught by corpus/parity. The last two were not -- no probe reached them -- and
are the whole lesson of this entry.

#174 IS WORTH THE SPACE. LEDGER 334/#185/#201 measured, correctly, that emitting the header
TRUNCATED the rest of the block, and concluded the truncation was faithful and load-bearing.
It was. The header began "\n", which puts a BLANK line in the message, and print_errors_standard
breaks on the first empty line. Upstream's fix is two characters: "  \n". The line is no longer
empty, so the break never fires, the header appears AND the block survives. C++ even says so at
check_expr.cpp:7869 -- "extra spaces to prevent newlines being consumed by the error handling
syste,". A trade-off three ledger entries had reasoned about carefully was dissolved by two spaces.

#225 WAS A REAL UNDER-REJECTION, not a wording drift. C++ used to guard the exponent branch with
GB_ASSERT(base == 10) and GB_ASSERT(text[i] != '-'), and they FIRED -- `0b1e5` aborted the compiler.
There was no oracle behaviour to match, so the port chose to accept silently. Upstream replaced both
with early `success = false` returns. The reference now REJECTS `0b1e5`, `0b1E5`, `0b1e`, `0o1e0`,
`0z1e1`, `0d1e-5`, `0d1e`, `0d1e+5`, `1e` -- and the port accepted every one of them. Fixed in both
implementations of the predicate (parser integer_value_is_valid, checker big_int_from_string);
enumerated the input space from the C++ source rather than guessing, 20 literals, all MATCH.

THE INSTRUMENT DEFECT THIS TURN. Invoking parity.sh without its package-list argument produced:

    parity.sh: line 113: : No such file or directory
    PARITY-DONE packages=0 compared=0 excluded=0 count_mismatches=0 text_mismatches=0 ...

Three zeroes that read exactly like a clean sweep. `done < "$LIST"` failed, the loop body never ran,
and the summary printed anyway. That is #380's failure mode -- a summariser that cannot distinguish
"nothing was wrong" from "nothing ran" -- reappearing in a second instrument, and it is now the
seventh member of that family (#275, #367, #369, #370, #380, #384, this). Both parity scripts now
abort with PARITY-ABORTED / PARITY-VET-ABORTED rc=2 on a missing or unreadable PORT or LIST;
verified by invoking them wrong on purpose.

NEW PROBES, because the two sites the gates missed must not be missable again:
  nameidx   the "Given argument types:" block -- alpha then beta, not alpha twice
  nameidx2  the try_addr "Suggestion:" line -- same, with a leading positional and an `&`
  intlit    the literal-exponent input space, rejected forms in a.odin, accepted set in b.odin
Both nameidx probes first read FULL-DIFFER on a line the port never emits -- "Undefined entry point
procedure 'main'". cmpfull.py runs the oracle as `odin build`; the probes had no main. Added one.
That is the #379 harness mismatch, caught this time before it was written up as a port defect.

UPSTREAM WRITE-UPS RE-VERIFIED RATHER THAN REMEMBERED. Ten moved to upstream-merged/, each confirmed
by fresh measurement -- crash claims re-run from their recorded inputs, text claims re-grepped at
their cited lines. #119 is why that mattered: `intrinicss.byte_swap` WAS fixed in
random_generator_chacha8_simd128.odin and an identical typo survives in
random_generator_chacha8_ref.odin:26. A status edit made from memory would have closed a live bug.
Four remain open: #119 (relocated), #263, and the two objc crashes (#161, #285), which are someone
else's work and were deliberately not re-measured.

GATES, all after the last edit:
    vet (checker, tests, parser, ast)  0 lines each
    corpus                             179 FULL-MATCH / 0 FULL-DIFFER / 12 excluded
    corpus_vet                         4/4
    parity plain                       224/224 compared, 0 excluded, 0/0/0
    parity vet                         224/224 compared, 0 excluded, 0/0/0
    spec suite                         432 tests, 0 failures
    root suite                         146 tests, 0 failures

One ATTRIB event appeared in an intermediate vet-parity run (core/rexcode/isa/rsp/tools,
"Redeclaration of 'main'" blamed on a different file). Run alone, oracle and port BOTH say
gen_mnemonic_builders.odin(72:1), 5/5 each -- the sweep-time oracle picked the other file. That is
the file-order nondeterminism parity.sh's own header documents, on the ORACLE's side, and it did
not recur in the final run.

MEASURED COVERAGE: 179 plain + 4 vet = 183 probes, up from 180.
