# Dependency-tree walk: every child is enqueued twice, and a parent propagates before its children finish

**Component:** `src/checker.cpp` — `check_walk_all_dependencies_worker_proc` / `check_update_dependency_tree_for_procedures`
**Severity:** exponential redundant work in nesting depth; dependency sets that are nondeterministic and sometimes incomplete
**Status:** **INFERRED, NOT REPRODUCED IN THE REFERENCE COMPILER.** Both effects are measured in a
line-for-line port of these functions (see *Evidence*); the transfer to `src/` is an inference from
code identity. Read this as a code-review finding with supporting numbers, not as a filed repro.
Same standard, and same caveat, as `UPSTREAM-468`.

## The shape

`src/checker.cpp:7546-7565`, the live `#else` branch:

```cpp
gb_internal WORKER_TASK_PROC(check_walk_all_dependencies_worker_proc) {
    DeclInfo *decl = cast(DeclInfo *)data;
    for (DeclInfo *child = decl->next_child; child != nullptr; child = child->next_sibling) {
        thread_pool_add_task(check_walk_all_dependencies_worker_proc, child);   // 7553
        check_walk_all_dependencies(child);                                    // 7554
    }
    add_deps_from_child_to_parent(decl);                                       // 7557
    return 0;
}

gb_internal void check_walk_all_dependencies(DeclInfo *decl) {                 // 7561
    if (decl != nullptr) {
        thread_pool_add_task(check_walk_all_dependencies_worker_proc, decl);   // 7563
    }
}
```

Two things follow directly from reading those together.

**(1) Each child is enqueued twice.** Line 7554 calls `check_walk_all_dependencies(child)`, and that
function is *nothing but* `thread_pool_add_task(worker, child)` — the same task line 7553 just
queued. Every worker therefore queues two copies of every child, and each of those copies queues two
copies of every grandchild, so the task count grows as `2^depth` in nesting depth.

**(2) A parent propagates before its children have finished.** Line 7557 runs
`add_deps_from_child_to_parent(decl)` immediately after *dispatching* the children — it does not wait
for them. `add_deps_from_child_to_parent` copies `child->deps` into `child->parent->deps`, so
propagation is only correct bottom-up: a node's own dep set must be complete before it is merged
upward. Here a parent can merge into the *grand*parent before its children have merged into it, and
whatever the children would have contributed is then missing from everything above.

Both look unintended rather than designed. The file's own `#if 0` sequential version at
`checker.cpp:7522-7530` does the strict bottom-up walk — children fully recursed, *then*
`add_deps_from_child_to_parent(decl)` — which is the ordering effect (2) breaks.

## Evidence

Measured in the self-hosted Odin checker, whose `check_proc.odin` is a line-for-line port of these
functions. Two arms were run from the same binary: **arm 0** is the port's bottom-up worker (which
matches C++'s `#if 0` form), **arm 1** is a replica of the live `#else` worker above, with line
7554 written out as the second `thread_pool_add_task` it expands to.

### (1) Task counts — the double-enqueue

Probe `deep` is 14 levels of nested procedure literals; the two core packages are real code.

| target | arm 0 (bottom-up) | arm 1 (C++ live shape) | ratio |
|---|---|---|---|
| `deep` (depth 14) | 778 tasks / 1,011 propagations | **66,544 / 66,544** | **~85x** |
| `core:strings` | 1,916 / 2,220 | 2,539 / 2,539 | 1.3x |
| `core:odin/parser` | 10,873 / 11,942 | 13,161 / 13,161 | 1.2x |

Real code is shallowly nested, so the everyday cost is ~20-30% extra tasks. The synthetic probe is
there to show the growth is exponential in depth, not linear: 66,544 tasks for a file containing 15
procedures.

The redundant *propagation* is harmless in isolation — `add_deps_from_child_to_parent` is a set
union (map insert), so repeating it is idempotent. It is wasted work, not a wrong answer.

### (2) Dependency-set totals — the ordering

Summing `len(decl->deps)` over all entities after the phase, on `deep`, 10 runs per arm:

| arm | totals observed |
|---|---|
| arm 0, threaded | 5803 5803 5803 5803 5803 5810 5803 5803 5810 5811 |
| arm 1, threaded | 5796 5803 5803 5796 5796 5797 5796 5805 5795 5796 |
| **arm 1, `-no-threads`** | **5803 5803 5803** |

**7 of 10 arm-1 runs fall strictly below arm 0's minimum of 5803; arm 0 never does.** The two
distributions barely overlap, and arm 1 is shifted down by about 7 dependencies.

The sequential run is the control that identifies the mechanism: arm 1 executed with
`-no-threads` returns 5803 every time, matching arm 0's mode. So the deficit is not produced by the
*shape* of the walk — it is produced by running that shape *concurrently*, which is exactly what
"the parent propagates without waiting for its children" predicts. Serialise it and the loss
disappears.

`type_info_deps` totals were constant at 2213 across every run in both arms, so only the entity
dep set is affected.

An honest note on the noise: an earlier 3-sample read suggested arm 0 was perfectly deterministic at
5803. Ten samples refuted that — it ranges 5803-5811. The claim above is deliberately stated as the
separation between the two distributions plus the sequential control, not as "one arm is stable",
because only the former survives the larger sample.

## Why it may be considered benign

`decl->deps` feeds `generate_minimum_dependency_set` and from there `min_dep_count`, whose readers
are the LLVM backend, `main.cpp`, `check_unchecked_bodies` and the RTTI type-info table. None of
them emit a diagnostic, which is why a checker can be bit-exact on all 323 packages of a parity
corpus with either walk shape — as this port is. The consequences, if any, would be in code
generation and in what gets emitted into the binary, not in what the compiler says.

## Possible fix

For (1), delete line 7554: line 7553 has already queued that child, and the worker it queues does
the same recursion. That alone removes the `2^depth` growth.

For (2), the ordering needs an actual join. The cheapest correct form is C++'s own `#if 0` version —
recurse into children, then propagate — parallelised at the *roots* only, which is what the port
does and what the numbers above show is stable. Per-node parallelism needs each parent to wait on
its children (a per-decl latch or a completion counter), because the merge is not order-independent.

## What would turn this into a filed repro

A way to observe the reference compiler's dependency sets directly. No flag dumps them, and
`-show-timings` does not expose the task count either. Anyone with a debug build can settle both
halves in minutes: count entries into `check_walk_all_dependencies_worker_proc` over a deeply nested
input, and sum `decl->deps.count` at the end of the phase across repeated threaded runs.
