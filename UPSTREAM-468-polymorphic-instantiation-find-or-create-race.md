# Polymorphic instantiation cache: find-or-create is not atomic, so concurrent callers create duplicates

**Component:** `src/check_expr.cpp` — `GenProcsData` cache in the polymorphic-procedure instantiation path
**Severity:** duplicated work and duplicated entities; no wrong diagnostic observed
**Status:** **INFERRED, NOT REPRODUCED IN THE REFERENCE COMPILER.** Measured in a line-for-line port
of this function (see *Evidence* — the measurement is real, its transfer to `src/` is an inference
from code identity). Read this as a code-review finding with supporting numbers, not as a filed repro.

## The shape

`check_expr.cpp:483-638` looks up an existing specialization, and creates one if absent:

```cpp
mutex_lock(&base_entity->Procedure.gen_procs_mutex);        // 488
gen_procs = base_entity->Procedure.gen_procs;
if (gen_procs) {
    rw_mutex_shared_lock(&gen_procs->mutex);                // 491
    mutex_unlock(&base_entity->Procedure.gen_procs_mutex);  // 493
    for (Entity *other : gen_procs->procs) {                // 495   SCAN 1
        if (are_types_identical(pt, final_proc_type)) { ...; return true; }
    }
    rw_mutex_shared_unlock(&gen_procs->mutex);              // 507   <-- lock released
} else { ...create gen_procs...; mutex_unlock(...); }        // 509-512

// ... check_procedure_type(), AST clone, scope work -- NO LOCK HELD ...

rw_mutex_shared_lock(&gen_procs->mutex);                    // 534
for (Entity *other : gen_procs->procs) {                    // 535   SCAN 2 (double-check)
    if (are_types_identical(pt, final_proc_type)) { ...; return true; }
}
rw_mutex_shared_unlock(&gen_procs->mutex);                  // 562   <-- lock released again

// ... create the specialized entity ...

rw_mutex_lock(&gen_procs->mutex);                           // 636
    array_add(&gen_procs->procs, entity);                   // 637
rw_mutex_unlock(&gen_procs->mutex);                         // 638
```

Scan 2 is clearly there *as* a double-checked retry — it exists because the author knew another
thread could have created the specialization during the expensive work above it. But the shared lock is released at 562, and the entry is not added until 637. Two workers that both reach 562 before either reaches 637 will both proceed to create, and both will `array_add`. Nothing between those points makes the pair atomic, and `array_add` does not de-duplicate.

The window is not narrow: between 562 and 637 sits entity allocation and the surrounding
specialization work.

## Evidence

Measured in the self-hosted Odin checker, whose `check_poly_proc.odin` is a line-for-line port of this function — same two scans, same locks, same order, same release points. Counting entities marked as polymorphic instantiations in a semantic-model dump of `core:strings`:

| mode | instantiation count |
|---|---|
| `-no-threads`, 4 runs | 47, 47, 47, 47 — and the whole dump is byte-identical |
| threaded, 6 runs | 47, 49, 51, 53, 53, 54 |
| threaded, another 6 runs | 50, 51, 52, 54, 56, 57 |

Two things point at duplication specifically rather than loss:

1. **The sequential count is the minimum of the threaded range.** Threading only ever *adds*.
   If the race dropped instantiations instead, threaded runs would sometimes fall below 47.
2. The extra entries are indistinguishable from the originals in the dump — same name, same
   rendered type, same flags — which is what a second copy of the same specialization looks like.

`core:os` and `core:odin/parser` show the same pattern at larger scale (412-433 and 937-946).

## Why it may be considered benign

Each duplicate is a distinct `Entity` and `Type` for one specialization, so:

- the duplicate's body is queued and checked again — wasted work proportional to how often the race
  lands, not a correctness problem on its own;
- `are_types_identical` is structural, so later lookups still match *a* copy;
- no diagnostic difference was observed across any of the runs above.

It is filed because a compiler's semantic model containing a variable number of entities run-to-run
is a hazard for anything downstream that enumerates it (documentation output, RTTI generation,
incremental caching), and because the double-check at 534 shows the race was already anticipated —
it just is not closed.

## Possible fix

Hold the exclusive lock across the second check and the add, i.e. promote 534-562 to
`rw_mutex_lock`, keep it held through entity creation, and add under the same acquisition. That
serialises specialization creation per generic. If that is too coarse, the usual alternative is to
insert a placeholder under the exclusive lock at 534 and have the loser wait on it.

## What would turn this into a filed repro

A way to observe the reference compiler's instantiation count directly — `-show-timings` does not
expose it, and no flag dumps the entity set. `odin doc` output is the nearest observable and was not
tried. Anyone with a debug build can settle it by counting `gen_procs->procs.count` per generic at
the end of checking, over repeated threaded runs of `core:strings`.
