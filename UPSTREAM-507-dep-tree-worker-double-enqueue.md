# checker.cpp: the dependency-tree worker enqueues every child twice, giving 2^depth tasks

**File:** `src/checker.cpp:7546-7563` (the live `#else` branch)
**Severity:** performance only — no wrong output observed. Compile time doubles per level of
procedure-literal nesting.

## The code

```cpp
gb_internal WORKER_TASK_PROC(check_walk_all_dependencies_worker_proc) {
	...
	for (DeclInfo *child = decl->next_child; child != nullptr; child = child->next_sibling) {
		thread_pool_add_task(check_walk_all_dependencies_worker_proc, child);
		check_walk_all_dependencies(child);
	}
	add_deps_from_child_to_parent(decl);
	return 0;
}

gb_internal void check_walk_all_dependencies(DeclInfo *decl) {
	if (decl != nullptr) {
		thread_pool_add_task(check_walk_all_dependencies_worker_proc, decl);
	}
}
```

The two statements in the loop body are the same operation. `check_walk_all_dependencies(child)` is
nothing but `thread_pool_add_task(check_walk_all_dependencies_worker_proc, child)` — the same proc,
the same data. So each child is enqueued twice, each of those tasks enqueues each of *its* children
twice, and the task count for a node at depth `d` is `2^d`.

The sequential form this replaced (`#if 0`, :7522-7530) recurses once per child, which is what the
loop body appears to have been intended to do.

## Reproduction

Generate a file with `d` nested procedure literals:

```odin
package nest
main :: proc() {
	p1 := proc() {
		p2 := proc() {
			// ... d levels ...
			x := 1; _ = x
		}
		_ = p2
	}
	_ = p1
}
```

`odin check <dir> -no-entry-point`, wall clock on 32 cores:

| depth | time    | ratio vs previous |
|-------|---------|-------------------|
| 16    |   88 ms |                   |
| 18    |  280 ms | 3.2× over 2 levels|
| 20    | 1020 ms | 3.6× over 2 levels|
| 21    | 2146 ms | **2.10×**         |
| 22    | 4389 ms | **2.05×**         |

Each additional level of nesting doubles the time, which is the signature the double-enqueue
predicts. Depth 22 is already 4.4 s for a file whose entire body is one integer assignment.

## Suggested fix

Drop one of the two calls. Either

```cpp
	for (DeclInfo *child = ...) {
		thread_pool_add_task(check_walk_all_dependencies_worker_proc, child);
	}
```

or keep `check_walk_all_dependencies(child)` alone — they are the same call.

## A second observation, NOT verified

`add_deps_from_child_to_parent(decl)` runs immediately after the loop, without waiting for the child
tasks that loop just enqueued. A parent's dependency propagation can therefore run before its
children's have finished. I have **not** observed a consequence of this — it is a reading of the
code, and it may well be benign because the dependency sets converge. It is mentioned only because
it is adjacent to the fix above, and whoever fixes the double-enqueue should decide whether the
ordering is intended.

## Provenance

Found while porting this walker to the self-hosted checker in `core/odin/checker`. That port uses
the plain bottom-up recursion — all children walked, then the parent's `add_deps` — matching the
`#if 0` sequential form. On the same inputs it stays flat at ~27 ms from depth 16 through 22,
against the reference's 88 ms → 4389 ms.
