# Upstream findings — filing status

Bugs in the **reference Odin compiler** (`src/*.cpp`) and in `base/runtime`, found while building a
self-hosted Odin checker and diffing it against the reference over 224 core/base packages, 179
curated probes and a 432-test spec suite. None of these are defects in the port; at every one of
these sites the port and the reference disagree and the reference is wrong.

Each verified finding has its own `UPSTREAM-<n>-<slug>.md` alongside this file.

**Re-verified against current master on 2026-08-04**, after pulling the merge. Ten of the fourteen
original findings are now fixed upstream; their write-ups moved to `upstream-merged/`. Verification
was a fresh measurement in every case, not a reading of the earlier note — the crash claims were
re-run from their recorded inputs, and the text claims re-grepped at their cited lines.

## Still open — verified 2026-08-04

| file | kind | how verified |
|---|---|---|
| `UPSTREAM-119-runtime-byte-swap-typo.md` | latent build break | source read; **the address moved** — the simd128 instance was fixed, an identical one survives in `random_generator_chacha8_ref.odin:26` |
| `UPSTREAM-263-procs-vs-proc-entities-index.md` | suspected wrong index | still at `check_expr.cpp:7610`, still inconsistent with its neighbours at `:7622` and `:7629` |
| `UPSTREAM-161-objc-attributes-without-value-crash.md` | **crash** | 3 of 12 objc attributes; 2 assert, 1 segfaults. *Someone else is working the objc surface — not re-measured this round.* |
| `UPSTREAM-285-objc-context-provider-segfault.md` | **crash** | zero-parameter `@(objc_context_provider)`. *Same objc caveat as above.* |

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
