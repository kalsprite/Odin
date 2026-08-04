# Upstream findings — filing status

Bugs in the **reference Odin compiler** (`src/*.cpp`) and in `base/runtime`, found while building a
self-hosted Odin checker and diffing it against the reference over 224 core/base packages, 176
curated probes and a 432-test spec suite. None of these are defects in the port; at every one of
these sites the port and the reference disagree and the reference is wrong.

Each verified finding has its own `UPSTREAM-<n>-<slug>.md` alongside this file.

## Ready to file — verified 2026-08-04

| file | kind | how verified |
|---|---|---|
| `UPSTREAM-119-runtime-byte-swap-typo.md` | latent build break | source read, typo present at cited line |
| `UPSTREAM-156-named-argument-labels-never-advance.md` | wrong diagnostic text | reproduced: prints `alpha` twice for `alpha=`/`beta=` |
| `UPSTREAM-159-damerau-transposition-unchecked.md` | wrong suggestions | source read; `USE_DAMERAU_LEVENSHTEIN 1` confirms it is live |
| `UPSTREAM-174-definitions-header-suppressed-by-typename.md` | missing diagnostic header | commented-out header + shared counter; **reachability unproven** |
| `UPSTREAM-187-import-name-grammar.md` | diagnostic text | source read, verbatim |
| `UPSTREAM-189-matrix-column-message-says-rows.md` | diagnostic text | source read, verbatim |
| `UPSTREAM-195-field-list-in-not-allowed.md` | diagnostic text | source read, verbatim |
| `UPSTREAM-206-format-a-consumes-no-argument.md` | wrong output | call site + `gb.h` formatter stub both read |
| `UPSTREAM-169-quote-to-ascii-string16-oob.md` | out-of-bounds read | u16 indexes a 16-entry table; **reachability from source unproven** |
| `UPSTREAM-263-procs-vs-proc-entities-index.md` | suspected wrong index | inconsistency confirmed against 3 neighbouring sites |
| `UPSTREAM-166-i64-constant-range-check-is-a-tautology.md` | wrong acceptance | boundary sweep; only 64-bit signed affected, i32/u64 correct |
| `UPSTREAM-161-objc-attributes-without-value-crash.md` | **crash** | 3 of 12 objc attributes; 2 assert, 1 segfaults; sweep covered all 12 |
| `UPSTREAM-225-prefixed-base-exponent-assert.md` | **crash** | reproduced, deterministic, 6 inputs, 2 distinct assertions |
| `UPSTREAM-285-objc-context-provider-segfault.md` | **crash** | reproduced 3/3, core dumped |

## NOT ready — reproduction must be re-established first

These were recorded earlier in the porting notes but could **not** be reproduced today, or the
recorded reproduction was never minimised to a standalone file. Filing them as-is would waste a
maintainer's time, so they are held back deliberately.

| item | claim | why it is held |
|---|---|---|
| `#342` | `complex()` into a union-typed return panics at `src/types.cpp:1985` | **does not reproduce.** The original source was recovered from git (`core/odin/checker/tmp/file.odin`, since deleted) and run 3× with and without `-no-entry-point`: `rc=0` every time. The note recorded 3/3 panics when written. Either the reference binary in this tree has moved since, or the trigger is narrower than recorded. Needs re-establishing before it can be filed. |

## Method note

The first pass at this write-up guessed at reproductions for the four crash claims rather than
recovering the recorded ones. All four guesses failed — and one of them, `#342`, then turned out
not to reproduce even from its **original** source. Had the guesses not been run, four issues would
have been filed on the strength of a note rather than a result. A bug report is a claim about
behaviour, so the behaviour has to be observed at the time of filing, not remembered.
