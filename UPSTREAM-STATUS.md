# Upstream findings — filing status

Bugs in the **reference Odin compiler** (`src/*.cpp`) and in `base/runtime`, found while building a
self-hosted Odin checker and diffing it against the reference over 224 core/base packages, 180
curated probes and a 432-test spec suite. None of these are defects in the port; at every one of
these sites the port and the reference disagree and the reference is wrong.

Each verified finding has its own `UPSTREAM-<n>-<slug>.md` alongside this file.

**Re-verified against current master on 2026-08-05**, after a second merge. Eleven of the fourteen
original findings are now fixed upstream; their write-ups moved to `upstream-merged/`. Verification
was a fresh measurement in every case, not a reading of the earlier note — the crash claims were
re-run from their recorded inputs, and the text claims re-grepped at their cited lines.

## Still open — verified 2026-08-04

| file | kind | how verified |
|---|---|---|
| `UPSTREAM-119-runtime-byte-swap-typo.md` | latent build break | source read; **the address moved** — the simd128 instance was fixed, an identical one survives in `random_generator_chacha8_ref.odin:26` |
| `UPSTREAM-161-objc-attributes-without-value-crash.md` | **crash** | 3 of 12 objc attributes; 2 assert, 1 segfaults. *Someone else is working the objc surface — not re-measured this round.* |
| `UPSTREAM-285-objc-context-provider-segfault.md` | **crash** | zero-parameter `@(objc_context_provider)`. *Same objc caveat as above.* |
| `UPSTREAM-485-doc-format-file-cache-assert.md` | **crash**, deterministic | **REPRODUCED.** `./odin doc <pkg> -doc-format` aborts at `docs_writer.cpp:268` (`GB_ASSERT(file_index_found != nullptr)`) for any package that imports another — reproduced 6/6 on `core/c/libc`, also `core/strings` and `core/fmt`. `w->file_cache` holds only files of DOCUMENTED packages, but a documented entity can carry a position in an imported file. Controls both ways: a no-import package passes, and `-all-packages` on the same failing input passes. Text-mode `odin doc` is unaffected. Filed 2026-08-05. |
| `UPSTREAM-468-polymorphic-instantiation-find-or-create-race.md` | data race (duplicated entities) | **INFERRED, not reproduced in `src/`.** The find-or-create at `check_expr.cpp:483-638` releases its shared lock after each of two scans and only takes the exclusive lock at the `array_add`, so two workers can both miss and both create. Measured in the line-for-line port: `core:strings` instantiation count is a constant 47 sequentially and 47-57 threaded, with the sequential value as the MINIMUM — i.e. threading only ever adds. Filed 2026-08-05. |
| `UPSTREAM-UNFILED-float-to-int-conversion-poison.md` | **poison in output** (uninitialized read) | **REPRODUCED**, 5-line program, `dev-2026-08:4af8f15e3` / LLVM 22.1.8. `llvm_backend_expr.cpp:2557-2578` emits `fptosi`/`fptoui` unguarded; LLVM defines both as **poison** for out-of-range inputs, which `llvm_backend_opt.cpp:19-31` explicitly forbids in Odin's output. At `-o:speed` with the result passed as an `any`, `%d` and `%x` of the *same expression* disagree and the value varies across runs of one binary. Controls: `-o:none`/`-o:minimal` deterministic `0`; runtime-opaque value deterministic at all levels; without `any` deterministic `0` 5/5; `@(fast_math)` ruled out (pass early-returns without explicit flags). Mechanism — elided store leaving `any.data` pointing at unwritten stack — is **inferred, not IR-confirmed**. The same file carries a completed sweep of LLVM's other poison-producing operations: `nsw`/`nuw` and `exact` absent entirely, shifts correctly guarded, `getelementptr` clean (dynamic indexing uses plain GEP; all four `inbounds` sites are compiler-constructed). Two latent items recorded, not claimed as defects: `sdiv INT_MIN/-1` (traps by hardware, UB per LLVM), and **`intrinsics.simd_extract` accepts an unchecked runtime index** — the constant form is correctly rejected, the runtime form passes both phases unchecked into a poison-producing `extractelement`. That last may warrant its own issue. Not yet filed. |
| `UPSTREAM-507-dependency-walk-double-enqueue-and-early-parent.md` | redundant work + incomplete dependency sets | **INFERRED, not reproduced in `src/`.** `checker.cpp:7554` calls `check_walk_all_dependencies(child)` which is itself just `thread_pool_add_task(worker, child)` -- the same task line 7553 queued -- so every child is enqueued TWICE and task count grows 2^depth (measured in the line-for-line port: 778 -> 66,544 tasks on 14 levels of nested proc literals). Separately, `:7557` propagates a parent's deps WITHOUT waiting for the children it just dispatched, and merging is only correct bottom-up. Dep-set totals: 7 of 10 threaded runs of the C++ shape fall strictly below the bottom-up arm's minimum, and the same shape run `-no-threads` matches it exactly (5803, 3/3) -- so the loss is caused by concurrency, not by the shape. C++'s own `#if 0` form at `:7522-7530` does the correct bottom-up walk. Filed 2026-08-05. |

## Fixed upstream — write-ups retired to `upstream-merged/`

| item | how the fix was confirmed |
|---|---|
| `#156` named-argument labels | the buggy shared-`i` lambda now survives only as a comment at `check_expr.cpp:7636-7664`; the live one uses `for_array(i, ...)`. Probes `nameidx`/`nameidx2` reproduce the corrected output byte-for-byte. |
| `#159` Damerau transposition | `common.cpp:891` now guards the transposition on `a_c == b[j-2] && b_c == a[i-2]` — exactly the missing check. |
| `#166` i64 range tautology | replaced by a magnitude test (`mp_get_mag_u64`) carrying an explanatory NOTE at `check_expr.cpp:2393`. |
| `#169` `quote_to_ascii` string16 OOB | the u16 path at `string.cpp:964` now masks with `&0xf` per nibble. |
| `#174` definitions header | `check_expr.cpp:7140` **and** `:7149` — both arms now emit it, and the leading `"  "` stops the empty-line truncation. |
| `#187` "cannot be use as" | string absent from `src/`. |
| `#189` column message said "rows" | `check_type.cpp:3124` now reads "expected %d+ columns". |
| `#195` "in not allowed" | `parser.cpp:4320` now reads "is not allowed". |
| `#206` `%a` with a string | the format string is gone from `src/`. |
| `#263` procs vs proc_entities index | now reads `proc_entities[valids[i].index]` at `check_expr.cpp:7606`, with the note "a polymorphic candidate appends its instantiated entity to proc_entities above, so valids[i].index can be >= procs.count" -- i.e. the old read could index past the end. The port already used proc_entities and needed no change. |
| `#225` prefixed-base exponent assert | both `GB_ASSERT`s replaced by early `*success = false` returns. All six recorded inputs re-run: clean `Syntax Error: Invalid integer literal`, rc=1, no abort. |

## NOT ready — reproduction must be re-established first

| item | claim | why it is held |
|---|---|---|
| `#342` | `complex()` into a union-typed return panics at `src/types.cpp:1985` | **does not reproduce.** The original source was recovered from git (`core/odin/checker/tmp/file.odin`, since deleted) and run 3× with and without `-no-entry-point`: `rc=0` every time. The note recorded 3/3 panics when written. Needs re-establishing before it can be filed. |

## What the merge cost the port

Ten upstream fixes meant ten sites where the port was *deliberately* bug-compatible and had
therefore gone stale. Seven were caught by the existing gates (corpus/parity); three were not,
because no probe reached them:

- the two `#156` named-argument label sites — now pinned by probes `nameidx`, `nameidx2`
- the whole `#225` literal-exponent surface, in **two** places (the parser's `integer_value_is_valid`
  and the checker's `big_int_from_string`) — now pinned by probe `intlit`

The `#225` one was a real **under-rejection**: with the assertions gone the reference started
diagnosing `0b1e5`, `0d1e-5`, `0d1e+5`, `1e` and friends, and the port silently accepted all of
them. That is the lesson worth keeping: *bug-compatibility is a debt that comes due at the next
merge, and only a probe that exercises the site will tell you when.*

## Method note

The first pass at this write-up guessed at reproductions for the four crash claims rather than
recovering the recorded ones. All four guesses failed — and one of them, `#342`, then turned out
not to reproduce even from its **original** source. Had the guesses not been run, four issues would
have been filed on the strength of a note rather than a result. A bug report is a claim about
behaviour, so the behaviour has to be observed at the time of filing, not remembered.

The same rule applied to retiring them. "Upstream merged my fix" is also a claim about behaviour:
each of the ten entries above was re-measured, and one — `#119` — turned out to be a *relocation*
rather than a fix, which a status-file edit made from memory would have wrongly closed.
