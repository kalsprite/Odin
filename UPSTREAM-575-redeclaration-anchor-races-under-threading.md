# Redeclaration diagnostics anchor on whichever file won a race

**Kind:** nondeterministic diagnostic output (same input, same binary, two different messages)
**Status:** **SYMPTOM REPRODUCED** (2/30 threaded, 0/20 single-threaded). Mechanism **inferred** from
the emitter's source, not instrumented.
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
error(prev->token,                                 // <-- the entity ALREADY in the scope
      "Redeclaration of '%.*s' in this scope\n"
      "\tat %s",
      LIT(name),
      token_pos_to_string(pos));                   // <-- the position of the NEW entity
```

`prev` is whatever was found in the scope; `pos` belongs to the entity being inserted. So the
anchor names whichever declaration was collected **first**. File-scope entity collection runs
concurrently across the files of a package, so which of the two lands first is a race — and the
diagnostic text inherits it directly. The `up != nullptr` (`using`) branch just above, at
`:2036-2047`, has the same shape and the same exposure.

The mechanism is an inference from that code plus the threading evidence below; I did not
instrument the insertion order itself. The *symptom* is reproduced.

One observation that argues against the order being any intended sort: `dump_verify_input.odin`
precedes `gen_mnemonic_builders.odin` in basename order — the order `check_create_file_scopes`
(`checker.cpp:6052`) uses for file scopes — yet the majority outcome anchors the *later* name.

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

The pair being reported is not in question; only which half is the anchor. Making that choice a
function of the *source positions* rather than of arrival order removes the nondeterminism without
changing the diagnostic's content — anchor on the earlier position and name the later one in the
`at` line:

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

Ordering the collection phase itself would fix this too, and would fix anything else that inherits
the same order, but it is a much larger change and is not required to make this output stable.

## Relationship to other findings

Same family as the port's LEDGER #197/#341: reference diagnostic output that varies run to run,
where a port-vs-reference comparison cannot converge because the reference has no single answer.
This one is sharper than those — it has a named site, a clean single-threaded control, and a
two-line fix.
