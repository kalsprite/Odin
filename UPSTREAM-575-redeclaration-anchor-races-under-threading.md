# Redeclaration diagnostics anchor on whichever file won a race

**Kind:** nondeterministic diagnostic output (same input, same binary, two different messages)
**Status:** **SYMPTOM REPRODUCED** (2/30 threaded, 0/20 single-threaded). Mechanism **inferred** from
the emitter's source, not instrumented.
**Filed:** upstream **PR #7253** — which fixes the two-declaration case. The n > 2 case remains open
and needs deterministic collection order, not a change to this emitter; see "Limits" below.
**Site:** `redeclaration_error`, `src/checker.cpp:2027` — the `else` branch, currently `:2058-2064`.
**Found:** 2026-08-07, by whole-diagnostic-block comparison against the self-hosted port.

## What happens

For a package with the same name declared at file scope in two files, the reference compiler
reports one of *two different diagnostics* depending on the run. Both are well-formed; they differ
in which file is the error anchor and which is named in the `at` continuation:

```
# the usual result (28/30)
.../gen_mnemonic_builders.odin(185:1) Error: Redeclaration of 'main' in this scope
	at .../dump_verify_input.odin(84:1)

# the other result (2/30)
.../dump_verify_input.odin(84:1) Error: Redeclaration of 'main' in this scope
	at .../gen_mnemonic_builders.odin(185:1)
```

This matters beyond cosmetics: the anchor is the position an editor jumps to and the position a
build log is grepped for, and `error()` anchors are what determines the *file* the diagnostic is
attributed to. A CI job that diffs compiler output against a golden file will fail intermittently
at roughly a 7% rate on any package with a file-scope redeclaration.

## Why

The emitter chooses its anchor by *scope-insertion order*, not by source position:

```cpp
// src/checker.cpp:2058-2064
error(prev->token,                                 // <-- anchor
      "Redeclaration of '%.*s' in this scope\n"
      "\tat %s",
      LIT(name),
      token_pos_to_string(pos));                   // <-- pos = found->token.pos, set at :2028
```

**The parameter names invert their meaning, so read the call site before this one.** The sole
caller shape is `add_entity_with_name` (`checker.cpp:2089-2092`):

```cpp
Entity *ie = scope_insert(scope, entity);          // returns the INCUMBENT on collision
if (ie != nullptr) {
        return redeclaration_error(name, entity, ie);
}
```

So `prev` is the **new** declaration — the one that just failed to insert, and the one the error
anchors on — while `found` is the **incumbent** already in the scope, named in the `at` line. The
anchor is therefore the *loser* of the race, and the incumbent is whichever declaration was
collected **first**. File-scope collection runs concurrently across the files of a package, so which
one wins is a race, and the diagnostic text inherits it. The `up != nullptr` (`using`) branch just
above, at `:2036-2047`, has the same shape and the same exposure.

The mechanism is an inference from that code plus the threading evidence below; I did not instrument
the insertion order itself. The *symptom* is reproduced.

Note that the insert itself is **not** the race: `scope_insert_with_name` (`checker.cpp:479`) holds
an exclusive `rw_mutex_lock` across the `scope_map_get` and the `scope_map_insert`, so exactly one
entity can win. What varies is only *which* thread arrives first.

## Reproduction

A package with two files, each declaring `main` at file scope. Measured on
`core/rexcode/isa/mos65816/tools` (two files, both declaring `main`):

```sh
for i in $(seq 1 30); do
  ./odin check core/rexcode/isa/mos65816/tools -no-entry-point 2>&1 \
    | grep -m1 "Redeclaration of 'main'" | grep -oP '(?<=tools/)[a-z_]+\.odin'
done | sort | uniq -c
```

| configuration | runs | result |
|---|---|---|
| default (threaded) | 30 | **28 `gen_mnemonic_builders`, 2 `dump_verify_input`** |
| `-thread-count:1` | 20 | 20 `gen_mnemonic_builders`, 0 flips |

The single-threaded column is the control: pinning one thread removes the variance entirely, which
is what places the cause in concurrent collection rather than in hash iteration or ASLR.

**Second control, from the port.** The line-for-line self-hosted checker, run threaded with the
same input, anchors `gen_mnemonic_builders` 30/30. It differs from the reference only in that its
scope insertions are ordered, so it has no race to lose — the divergence is not a property of the
shared algorithm.

## Suggested fix

**This fixes the two-declaration case only.** See "Limits" below — for three or more declarations
of one name the *set of pairs* reported is itself order-dependent, and no change local to this
function can settle it.

For n = 2 the pair being reported is not in question; only which half is the anchor. Making that
choice a function of the *source positions* rather than of arrival order removes the
nondeterminism without changing the diagnostic's content — anchor on the earlier position and name
the later one in the `at` line:

```cpp
TokenPos lo = prev->token.pos, hi = pos;                 // pos == found->token.pos, set at :2028
if (hi < lo) { TokenPos t = lo; lo = hi; hi = t; }
error(lo, "Redeclaration of '%.*s' in this scope\n\tat %s", LIT(name), token_pos_to_string(hi));
```

Both pieces already exist: `operator<` on `TokenPos` (`tokenizer.cpp:225`, over `token_pos_cmp` at
`:210`) and the `error(TokenPos, ...)` overload (`error.cpp:756`) — the site currently uses the
`error(Token const &, ...)` overload at `:749`, and only needs the position.

That also gives the more useful anchor by convention — the first declaration — instead of an
arbitrary one. The `using` branch at `:2036-2047` wants the same treatment.

**Submitted upstream as PR #7253.**

## Limits — n > 2 is not fixed by the above

With three or more declarations of one name, the *incumbent* is reported against every later
arrival, so the diagnostics come in pairs `(incumbent, loser)`. Which declaration becomes the
incumbent still depends on arrival order, and it appears in **every** pair — so the whole set moves,
not just the orientation within one message. Sorting a pair cannot fix a set.

Measured on a three-file package (`aaa/bbb/ccc.odin`, each declaring `main`), oracle threaded,
40 runs — reported as `anchor at` per error:

| outcome | runs |
|---|---|
| `bbb→aaa`, `ccc→aaa` | 39 |
| `bbb→aaa`, `ccc→bbb` | 1 |

The positional swap normalises each pair's orientation but leaves the pair *membership* varying:
`{aaa,bbb},{aaa,ccc}` in the common case versus `{aaa,bbb},{bbb,ccc}` in the outlier. A consumer
diffing against golden output still fails, just less often.

**The outlier is not fully explained by the single-incumbent model, and I have not established
why.** If one entity wins the scope insert, every later collision should name that same winner —
yet the outlier names two different incumbents (`aaa` for `bbb`, then `bbb` for `ccc`) within one
run, which the exclusive lock in `scope_insert_with_name` should prevent. Candidate explanations not
yet distinguished: collisions raised from more than one scope or call site
(`checker.cpp:2092`, `:2113`, `check_type.cpp:3217` all reach this emitter), or a transition of the
`in_single_threaded_checker_stage` flag at `:526` selecting the `_no_mutex` variant concurrently.
Stated as an open question rather than guessed at.

### n > 2 also DROPS a diagnostic entirely

Worse than the ordering, and **deterministic on both sides** — this one is not a race.
`core/rexcode/isa/x86/tools` has **four** files declaring `main`:

```
ORACLE (2 errors, 25/25 runs)              PORT (3 errors, 3/3 runs)
  dump_verify_input(101:1)                   verify_tables(15:1)
      at gen_mnemonic_builders(50:1)             at dump_verify_input(101:1)
  verify_against_llvm(146:1)                 gen_mnemonic_builders(50:1)
      at dump_verify_input(101:1)                at dump_verify_input(101:1)
                                             verify_against_llvm(146:1)
                                                 at dump_verify_input(101:1)
```

Four declarations should yield three collisions, which is what the port reports — every duplicate
against a single incumbent. The reference reports **two**, names **two different incumbents**
(`gen_mnemonic_builders` in the first, `dump_verify_input` in the second), and **never reports
`verify_tables.odin` at all**. A genuine duplicate `main` goes unreported.

Two different incumbents in one run is the same shape as the n=3 outlier above, but here it is
stable rather than 1-in-40 — so whatever produces it is not only the thread race. I have not
established the mechanism; `scope_insert_with_name` never replaces an incumbent, so something
outside that function is involved. Recorded as observed behaviour, not explained.

The general fix is to make collection order deterministic, which would settle n > 2 and everything
else that inherits the same order. That is a much larger change than the two-line patch above, and
the two are complementary rather than alternatives: the patch stabilises the common case now, the
ordering work is what actually closes the class.

## Relationship to other findings

Same family as the port's LEDGER #197/#341: reference diagnostic output that varies run to run,
where a port-vs-reference comparison cannot converge because the reference has no single answer.
This one is sharper than those — it has a named site, a clean single-threaded control, and a
two-line fix.
