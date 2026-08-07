# `odin doc <pkg> -doc-format` aborts on any package that imports another package

**Component:** `src/docs_writer.cpp` — `odin_doc_token_pos_cast`
**Severity:** hard abort (`GB_ASSERT`), 100% reproducible
**Status:** **REPRODUCED IN THE REFERENCE COMPILER.** Not inferred — run the commands below.

## Reproduction

```
$ ./odin doc core/c/libc -doc-format
src/docs_writer.cpp(268): Assertion Failure: `file_index_found != nullptr`
This is a compiler error. Please report this.
Illegal instruction (core dumped)
```

6/6 runs. Also reproduces on `core/strings` and `core/fmt`. It is not specific to those:
any package whose documented entities reference a file outside the documented set will do.

Text-mode `odin doc` is unaffected (`./odin doc core/c/libc` succeeded 8/8) — the fault is in the
**binary** writer, which is what `-doc-format` selects and what `.odin-doc` consumers read.

## The shape

`src/docs_writer.cpp:262-270`:

```cpp
gb_internal OdinDocPosition odin_doc_token_pos_cast(OdinDocWriter *w, TokenPos const &pos) {
    OdinDocFileIndex file_index = 0;
    if (pos.file_id != 0) {
        AstFile *file = global_files[pos.file_id];
        if (file != nullptr) {
            OdinDocFileIndex *file_index_found = map_get(&w->file_cache, file);
            GB_ASSERT(file_index_found != nullptr);      // <-- 268
            file_index = *file_index_found;
        }
    }
    ...
```

`w->file_cache` is populated only for the files of packages that are being **documented**. But an
entity that IS documented can carry a position in a file that is NOT — anything reachable from an
import. The lookup then returns null and the assert fires.

The function already has the right instincts either side of that line: it guards `pos.file_id != 0`
and it guards `file != nullptr`, both falling back to `file_index = 0`. The third failure mode of
exactly the same kind — the file is real but is not in the documented set — asserts instead of
taking that same fallback.

## Evidence that this is the mechanism

Documenting *every* package puts every file in `file_cache`, and the crash disappears:

| command | result |
|---|---|
| `./odin doc <trivial pkg with no imports> -doc-format` | OK |
| `./odin doc core/c/libc -doc-format` | **abort** |
| `./odin doc core/strings -doc-format` | **abort** |
| `./odin doc core/fmt -doc-format` | **abort** |
| `./odin doc core/c/libc -doc-format -all-packages` | **OK** |

The trivial package (no imports, so nothing outside the documented set) and the `-all-packages` run
are the two controls: both make the documented set a superset of the referenced files, and both
pass. That is the condition, stated two different ways.

## Possible fix

Fall back rather than assert, consistent with the two guards already present:

```cpp
OdinDocFileIndex *file_index_found = map_get(&w->file_cache, file);
if (file_index_found != nullptr) {
    file_index = *file_index_found;
}
```

`file_index = 0` is already the documented "no file" value used by both existing guards, so an
out-of-set file degrades to a position without a file rather than killing the compiler. If instead
the intent is that such files SHOULD be in the cache, the fix belongs at the population site — but
then the assert is diagnosing a missing-population bug, and the message should say so.

## How it was found

Building a doc-flag gate for a self-hosted Odin checker. The port's own doc writer aborts on the
same package at a *different* assertion (an item-tracker capacity overflow), so the two
implementations fail on the same input for two unrelated reasons. Checking whether the reference
compiler shared the port's defect is what surfaced this one; it does not, and this is worse,
because it is deterministic rather than intermittent.
