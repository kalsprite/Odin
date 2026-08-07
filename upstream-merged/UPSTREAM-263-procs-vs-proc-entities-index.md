# Target-feature scoring indexes `procs` where every neighbouring site indexes `proc_entities`

**Component:** `src/check_expr.cpp`
**Severity:** suspected wrong entity / potential out-of-bounds read — needs a maintainer's read
**Status:** inconsistency verified 2026-08-04 by inspection; no reproducing input constructed

## Location

`src/check_expr.cpp:7595`, inside the `max_matched_features > 0` block.

## What is wrong

```cpp
if (max_matched_features > 0) {
    for_array(i, valids) {
        Entity *p = procs[valids[i].index];        // <-- procs
        Type *t = base_type(p->type);
        GB_ASSERT(t->kind == Type_Proc);
        ...
```

`valids[i].index` is used to index `procs` here. Every other site in this function that indexes
by `valids[...].index` uses `proc_entities`:

```
src/check_expr.cpp:7607    Entity *best_entity = proc_entities[valids[0].index];
src/check_expr.cpp:7614    if (best_entity == proc_entities[valids[i].index]) {
src/check_expr.cpp:7992    Entity *e = proc_entities[valids[0].index];
```

Three neighbours agree with each other and the fourth does not, which is the shape of a slip
rather than a deliberate difference.

## Why it matters

If `procs` and `proc_entities` are not the same array with the same ordering and length, then
either `p` is the wrong entity — silently mis-scoring an overload against target features — or
the index is out of range for `procs`. The `GB_ASSERT(t->kind == Type_Proc)` immediately after
would catch some but not all of the wrong-entity cases.

## What I could not establish

I did not construct an input that reaches this block with `procs` and `proc_entities` diverging,
so I cannot say whether it is presently exploitable or merely fragile. It needs someone who
knows the invariant between those two arrays to confirm whether they are guaranteed
index-compatible here. If they are, the line is still worth normalising for the next reader.

## Suggested fix (if the invariant does not hold)

```diff
-			Entity *p = procs[valids[i].index];
+			Entity *p = proc_entities[valids[i].index];
```
