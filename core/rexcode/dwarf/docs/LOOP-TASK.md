# Loop task: make `core:rexcode/dwarf` a library clODIN can rely on

Written 2026-08-18 for an unattended turn-loop stint, max 5 days. This file is the
anchor: it must be readable with NO conversation context, because the run will cross
several compactions. Re-read it at the start of every iteration.

## Goal

`core:rexcode/dwarf` emits DWARF debug information as a standalone library -- bytes
and fixups, no knowledge of ELF, no coupling to any backend. Bring it to the point
where clODIN (`/home/kalsprite/dev/rexcode-mir`, a self-hosted debug-only x86-64
backend) can adopt it and get a debugging experience at PARITY with the reference
LLVM-built compiler: breakpoints by `file:line`, source stepping, backtraces with
function names, and `print`/`ptype` on locals and their types.

WIRING IT INTO clODIN IS NOT THIS TASK. The deliverable is the library and the
instruments that prove it. Another agent is live in `rexcode-mir` and this loop
must not touch that tree.

## Boundaries -- these are hard

* **Modify only** `/home/kalsprite/dev/odin/core/rexcode/dwarf/**`. Nothing else,
  ever.
* **Do not touch** `core/rexcode/abi/**` (a peer session maintains it),
  `core/odin/checker/**`, `core/rexcode/isa/**`, or anything under
  `/home/kalsprite/dev/rexcode-mir/**`.
* **Never run `git checkout`, `git commit`, `git stash` or `git branch` in
  `/home/kalsprite/dev/odin`.** The tree is shared, it sits on branch `checker`,
  and it is `ODIN_ROOT` for another agent's sweeps. Moving that branch has
  already cost this project two full rounds of false findings, both times with an
  honest-looking version stamp nobody could read the mistake out of.
* Scratch files go in a `mktemp -d` or the session scratchpad. Never in the Odin
  tree root -- it already accumulated a pile of core dumps that way.

## Definition of done -- the halt criteria, all of them

Emit `LOOP-DONE` only when ALL of these hold in ONE run:

    odin check                 core/rexcode/dwarf and core/rexcode/dwarf/tests both
                               clean under -vet -strict-style
    tests/line_test.odin       0 failed (the unit suite, covering every section
                               this package emits, not only .debug_line)
    tests/decode-check.sh      PASS -- every installed external decoder agrees
                               with the emitter's intent, row for row
    tests/fuzz-check.sh        0 disagreements over at least 5000 randomised
                               programs, and it prints the count it actually ran
    tests/parity-check.sh      0 disagreements re-encoding the REFERENCE
                               compiler's own debug info across the corpus, and
                               it prints which packages it covered and which it
                               skipped
    tests/gdb-check.sh         every behavioural assertion passes: break by
                               file:line, step, backtrace with function names,
                               print a local, ptype an aggregate
    docs/open-issues.md        no open entries

Nothing else is grounds to halt. Not "it feels complete", not "the hard part is
done". If an instrument does not exist yet, it cannot be green, so it cannot halt.

## Blocker policy -- park, do not halt

A stalled experiment, a missing tool, a question that needs the user: write it into
`docs/open-issues.md` with what was tried and what would unblock it, then PIVOT to
something that is not blocked. Halting on the first obstacle wastes the remaining
budget; grinding on a wedged task wastes it too. Parking is the third option and it
is nearly always the right one.

## State as of 2026-08-18 (start of the stint)

`.debug_line` for DWARF 4 is written and externally verified. What exists:

    doc.odin                  scope, why v4, and the verification story
    dwarf.odin                Section / Fixup / Error, LEB128, LE writers, opcodes
    line.odin                 DWARF 4 .debug_line: line_validate + line_emit
    tests/line_test.odin      34 checks, all green; also `-emit <hex> <path>` mode
    tests/decode-check.sh     the external-decoder oracle; PASS

Verified, not assumed: a golden 125-byte unit was injected into a real linked
executable with `llvm-objcopy --update-section`, its base fixed up to `main`'s real
address, and decoded by llvm-dwarfdump, binutils readelf and elfutils eu-readelf.
All three agreed row-for-row with the emitter's intent across special opcodes,
`DW_LNS_copy` at a repeated address, a negative SLEB line advance, `set_file`,
`prologue_end`/`epilogue_begin`, `negate_stmt` and a 379-byte `advance_pc`. A
one-byte corruption of that same program was caught by all three.

## The work, in order

Tick items as they land. An item is done when its instrument is green, not when
the code is written.

### Phase A -- harden `.debug_line` to parity

- [x] A1 `tests/fuzz-check.sh` + `tests/fuzz.odin`. DONE 2026-08-18: 5025
      randomised programs over 56 batches, 0 disagreements, in ~3s. Own
      splitmix64 PRNG so a seed reproduces a failure exactly; a failing batch
      keeps its artifacts and prints the reproduce command.
- [x] A2 Multiple sequences and multiple units in one section. DONE 2026-08-18:
      `test_multi_unit` in the unit suite emits two units into one buffer and
      asserts each fixup lands three bytes into a DW_LNE_set_address in the
      SECTION buffer, that the sites are still zero-filled, that symbols come
      back in emission order, and that the units tile the section exactly by
      their own length fields. The fuzz harness emits 20 units per batch, so
      this is also covered at scale.
- [x] A3 `tests/parity-check.sh` + `tests/reencode.odin`. DONE 2026-08-18:
      12 packages built with `-build-mode:obj -debug`, 208 objects seen, 196
      distinct compared (runtime objects repeat across packages and are deduped
      by sha256), **14,032 real reference rows re-encoded with 0
      disagreements**, ~9s. Objects are compared on the full canonical row --
      address, line, column, file number, discriminator and all four flags.
      The script prints what it skipped and why; nothing was inexpressible.
- [x] A4 DWARF 5 line header. DONE 2026-08-18: `emit_tables_v5` writes the
      format-described directory and file tables, `address_size` and
      `segment_selector_size` go BEFORE `header_length` (v5 moved them), and
      `line_file_number` is the single place the v4/v5 file bias lives -- it is
      public because `DW_AT_decl_file` in `.debug_info` must use the same
      numbering. v4 stays the default. All three instruments now run BOTH
      versions: decode-check both green on three decoders, fuzz 10,042 programs,
      parity 14,032 rows per version.
      NOTE, deliberate: paths go inline as `DW_FORM_string` rather than as
      offsets into `.debug_line_str`. Both are legal and every reader takes
      either; inline needs no second section. Revisit in B3 when the string
      table exists -- it changes two format pairs and nothing else.
      The subtlety that would have bitten: the `file` register still
      initialises to 1 in v5, even though index 0 became legal. A v5 row naming
      file 1 therefore needs no `set_file` and one naming file 0 does.
- [x] A5 Edge cases. DONE 2026-08-18.
        * line 0, column 0, address deltas past the ULEB single-byte boundary,
          files with a real dir index: generated by the fuzzer, present in the
          reference corpus.
        * `DW_LNS_set_basic_block` and `DW_LNE_set_discriminator`: implemented
          and fuzzed -- 86 non-zero discriminators and 82 basic-block rows in one
          540-row sample, compared against llvm's own columns.
        * `min_inst_len != 1`: the fuzzer now varies it over {1, 2, 4} per unit
          (measured: 8 units at 2 and 7 at 4 in a 30-unit batch) and generates
          aligned deltas. Thinking about it found a real hole -- the emitter
          DIVIDES by min_inst_len and truncates, so a misaligned address would
          have moved a row backwards silently. `line_validate` now returns
          `MISALIGNED_ADDRESS` for that and for `min_inst_len == 0`.
        * `default_is_stmt = false`: varied by the fuzzer (9 of 30 units), plus
          a byte-level unit test that the same row costs a `negate_stmt` under a
          true header and nothing under a false one.
        * the file PATH: closed. `-emit-files` prints the resolved path per
          entry and `decode-check.sh` compares it against the decoded table for
          both versions. Teeth-tested: a corrupted filename byte is now caught,
          and the three ROW legs still report "all agree" on that same file --
          which is exactly why the leg had to exist.

### Phase B -- `.debug_abbrev`, `.debug_info`, `.debug_str`

- [x] B1 Abbreviation table builder with dedup. DONE 2026-08-18: shapes are
      keyed by (tag, has_children, the ordered attribute/form pairs) and codes
      are assigned in first-use order from 1, since 0 terminates a sibling
      chain. `test_abbrev_dedup` builds three identically shaped subprograms
      plus one that differs by a single attribute and asserts the emitted table
      holds THREE declarations, parsed back with a test-side ULEB reader rather
      than with the emitter's own.
- [x] B2 CU DIE and `DW_TAG_subprogram` children. DONE 2026-08-18: `info.odin`
      holds a flat DIE array (children and references are indices, never
      pointers -- a `[dynamic]Die` reallocates and any kept `^Die` would dangle,
      which is the class of bug the `abi` review found in a returned slice), one
      `Attr` constructor per form, and CU-relative `DW_FORM_ref4` patched after
      emission because a forward reference to a type declared later is the
      normal case. `DW_AT_high_pc` is a LENGTH via `data8`. The v4/v5 CU header
      field order differs (v5: unit_type, address_size, abbrev_offset) and is
      asserted byte-wise in `test_info_header`.
- [x] B3 `.debug_str` with dedup. DONE 2026-08-18: `Str_Table` is caller-held so
      one table spans every unit, which is the entire point of the section; keys
      are cloned because a caller's string may be a temporary and a map key that
      outlives its backing memory returns wrong answers rather than crashing.
      The v5 companion `.debug_line_str` is DELIBERATELY not used -- paths stay
      inline as `DW_FORM_string`. Recorded with its reasoning and its reversal
      recipe in `docs/known-divergences.txt`.
- [x] B4 `tests/gdb-check.sh` first leg. DONE 2026-08-18: 12 assertions, both
      versions, all passing. The host's own `.debug_*` sections are removed
      outright and replaced with ours, and the CU describes the host's real
      functions under an INVENTED file name and INVENTED line numbers, so a
      correct answer cannot have come from anywhere else. gdb resolves
      `break widget.odin:41` to widget_alpha's real address, `info line` agrees
      for a second function, and a backtrace at a breakpoint names the function
      AND resolves its caller frame through our CU.

### Phase C -- types, variables, locations

- [x] C1 `DW_TAG_base_type`. DONE 2026-08-18: int, long, char emitted with
      byte size and `DW_AT_encoding`, and gdb prints values through them. The
      encoding is not cosmetic -- a `long` declared `DW_ATE_unsigned` prints
      18446744073709551574 for -42.
- [x] C2 Aggregates. DONE 2026-08-18, each proved by a `print` in gdb rather
      than by a dump: `structure_type` with members, `union_type` (members
      sharing offset 0), `array_type` with a child `subrange_type` (an array has
      no length without it), `pointer_type` (dereferenced), `enumeration_type`
      with enumerators (printed as `W_GREEN`, not 7), and `typedef`.
      The Odin shapes: `string` and `[]T` are a pointer and a length -- an
      ordinary two-word struct, needing no language extension, which is the
      useful thing to know. The tagged union `struct{payload: union, tag}` is
      emitted too, and it is the only one that exercises a MEMBER WHOSE TYPE IS
      ANOTHER AGGREGATE; `print wtagged.u.i` reaches through both levels.
      `map` is not separately modelled: it is a struct of pointers and counts,
      which is the shape already proved. Say so rather than claim it was tested.
- [x] C3 `DW_TAG_variable` / `formal_parameter` with `DW_AT_location`, and
      `expr.odin`. DONE 2026-08-18: `DW_OP_fbreg`, `DW_OP_addr` (with its
      embedded relocation), `DW_OP_breg`, `DW_OP_reg`, `DW_OP_call_frame_cfa`,
      `DW_OP_plus_uconst`. A `DW_OP_addr` inside an expression block needs a
      fixup the expression builder cannot make -- it does not know where the
      block will land -- so the offset travels on the attribute and `emit_die`
      adds the block's own position.
      CONFIRMED against the reference: clang at -O0 emits
      `DW_AT_frame_base (DW_OP_reg6 RBP)`, not `DW_OP_call_frame_cfa`. That is
      the shape clODIN wants -- it needs no CFI at all, matching this item's
      original note.
- [x] C4 `DW_TAG_lexical_block` scoping. DONE 2026-08-18, and tested by making
      the answer AMBIGUOUS without correct scoping: the host declares `inner` in
      a nested block, our CU names that same storage `n` inside a
      `DW_TAG_lexical_block` while an outer `n` lives at a different frame
      offset. `print n` yields 777 stopped inside the block and 42 stopped
      outside it. One `low_pc`/`high_pc` wrong and one of those two is wrong.
- [x] C5 `tests/gdb-check.sh` second leg. DONE 2026-08-18: 40 assertions across
      both DWARF versions, all passing -- print a local, a formal parameter, an
      aggregate, a global through `DW_OP_addr`, an array, a dereferenced
      pointer, a union, an enum by name, a two-word string, a tagged union and a
      member reached through two levels; `ptype` both through a variable and by
      name; the shadowed name; and `step` landing on the next row of our line
      table.

### Phase D -- parity and consumability

- [x] D1 `.debug_info` parity. DONE 2026-08-18: `tests/canon-info.py` reduces a
      decoded DIE tree to a comparable form (pre-order depth, tag, and the
      attributes that can be compared by VALUE, with type references rewritten
      from section offsets to pre-order indices), `tests/reinfo.odin` rebuilds
      it with this library, and the two are required to be identical.
      **29,664 DIEs per version, 0 disagreements, 0 skipped.**
      Attributes that cannot be compared are excluded BY NAME and tallied with
      the reason, printed at the end of every run: `decl_file` (the reference
      resolves it to a path through its line table), `low_pc`/`high_pc`,
      `location`/`frame_base` (expressions -- covered behaviourally by
      gdb-check), `stmt_list`, and two GNU extensions.
      TWO REAL FINDINGS, both recorded in `docs/known-divergences.txt`:
      the reference writes NEGATIVE `DW_AT_const_value` in an unsigned form
      (`AT_FDCWD` as 18446744073709551516) where this library writes sdata --
      same 64 bits, so the comparison normalises the pattern rather than the
      spelling; and Odin type names really do contain double quotes
      (`proc"contextless"(...)`), which the dumper escapes, so the canonicaliser
      has to unescape or the round trip re-escapes what was already escaped.
- [x] D2 API review for a consuming backend. DONE 2026-08-18, and it found a
      real defect rather than producing prose. `Attr` BORROWED both the caller's
      strings and an `Expr`'s buffer, so a DIE name built with `fmt.tprintf` --
      which is how a backend spells a composite type -- became garbage at the
      next temp-allocator reset, still emitting and still decoding.
      `Info_Unit` now OWNS a copy of every string and expression block, taken by
      `die_add` / the new `die_attr_add`. `test_lifetime` makes the hazard
      happen -- tprintf a name, destroy the Expr, free the temp arena, then
      SCRIBBLE OVER it, then emit -- and it fails on both counts with the
      interning disabled. `.debug_line`'s different rule (borrowed, needs only
      to survive the call) is stated alongside it in doc.odin, with the fixup
      contract and the decl_file numbering rule a consumer must follow.
- [x] D3 Every instrument green in one run, `docs/open-issues.md` empty. DONE
      2026-08-18. Nothing was ever parked: no item in this checklist turned out
      to be blocked.

## What this package does NOT do, so it is not rediscovered

* No `.eh_frame` or `.debug_frame`. Deliberate: a backend that keeps a frame
  pointer uses a `DW_OP_reg6`-style frame base, which needs no unwind tables --
  confirmed to be what clang itself emits at -O0. A backend that omits the frame
  pointer WILL need CFI, and none of this helps it.
* No `.debug_line_str`; v5 paths are inline. Recorded in known-divergences.txt
  with the reversal recipe.
* No `.debug_ranges` / `.debug_rnglists`, so a subprogram or block whose code is
  discontiguous cannot be described -- only `low_pc`/`high_pc` pairs.
* 32-bit DWARF only. The 64-bit format (unit lengths above 0xfffffff0) is
  refused by construction rather than mis-emitted, since `line_emit` and
  `info_emit` write a `u32` length.
* Register numbers are named for x86-64 only. The expression builder takes any
  number, so another architecture needs constants and nothing else.
* NOT wired into clODIN. That was out of scope by design; `docs/` and `doc.odin`
  are what the adoption should be read from.

## How to run things

    ODIN=/home/kalsprite/dev/odin/odin
    export ODIN_ROOT=/home/kalsprite/dev/odin        # tree is on branch `checker`

    $ODIN check core/rexcode/dwarf       -vet -strict-style -no-entry-point
    $ODIN check core/rexcode/dwarf/tests -vet -strict-style
    $ODIN run   core/rexcode/dwarf/tests -vet -strict-style     # the unit suite
    core/rexcode/dwarf/tests/decode-check.sh

Tools present and confirmed working: `clang`, `llvm-dwarfdump`, `llvm-objcopy`,
`readelf` (binutils 2.47), `eu-readelf` (elfutils 0.195), `gdb` 17.2, `lldb`
22.1.8, `nm`, `python3`. NOT installed: `pyelftools` (a pure-Python fourth
decoder; `pip install pyelftools` if a fourth independent reading is wanted),
`dwarfdump` (libdwarf), `pahole`.

## Facts that cost something to learn -- do not re-derive them

* **`llvm-dwarfdump --verify` does not check that a line program means anything.**
  Measured twice, on a clang object and on ours: one flipped byte inside the line
  program yields line 4294967293, and `--verify` still exits 0 with "No errors."
  It validates structure and cross-references. It is a ratchet, never the check.
* **The only real oracle is a diff against the producer's own intent**, decoded by
  a reader that is not ours. That is what `decode-check.sh` does and what every
  new instrument should do.
* **elfutils prints an `end_sequence` row at the last byte covered**, one below
  the exclusive end address llvm and binutils report. A display convention, not a
  disagreement; `decode-check.sh` normalises it.
* **An Odin slice literal written inside a procedure body is backed by that
  call's stack.** Returning a struct that holds one hands back a dangling slice.
  It surfaced here as a spurious `DIR_INDEX_OUT_OF_RANGE` from `line_validate`.
  Hoist shared fixtures to file scope.
* `os.write_entire_file` returns an `Error`, not a `bool`.
* Taking a pointer to a `for` loop variable needs `for &x in xs`.
* The reference Odin compiler emits **DWARF version 4**, `DW_AT_producer "odin"`,
  `DW_AT_language DW_LANG_C99`. Matching its version keeps parity diffs readable;
  the language code is a compatibility choice, not an accident -- readers key name
  formatting off it.
* House conventions: package `rexcode_dwarf`, tests package `rexcode_dwarf_tests`
  importing the parent as `dw ".."`, tests are a `main` program with ok/fail
  counters that exits non-zero, not `core:testing`.

## Handoff

Around day 3, or sooner if compaction has clearly cost context, write
`docs/HANDOFF.md`: current state, what is green, what is parked, and the next
three things to do. A stint longer than that accumulates compaction loss faster
than it accumulates useful state, and the handoff is what makes a fresh session
cheap to start.

## Progress log

Append one entry per iteration. Newest last. Say what was MEASURED, not what was
attempted.

* 2026-08-18 -- stint armed. `.debug_line` v4 emitting and externally verified by
  three independent decoders; unit suite 34/34; `decode-check.sh` PASS, and shown
  to fail on a one-byte corruption. Phases A-D all open.
* 2026-08-18 -- A1 and A2 measured green. `fuzz-check.sh`: 5025 randomised
  programs, 56 batches, 20 units per batch, 0 disagreements against
  llvm-dwarfdump, ~3s wall. Unit suite 45/45 including the new multi-unit
  section test. `decode-check.sh` still PASS on all three decoders.
  THE FINDING OF THIS ITERATION: the teeth test on `fuzz-check.sh` initially
  did NOT fail on an injected byte flip, because the intent dump compared
  address/line/column/is_stmt and never the FILE index -- a wrong
  `DW_LNS_set_file` was invisible in both oracles. Fixed in both: the intent now
  writes the 1-based number a decoder reports, so a wrong file bias disagrees.
  Re-run of the teeth test then caught a single flipped bit, and what it caught
  was the file column. An instrument that has never been shown to fail is not
  evidence.
* 2026-08-18 -- A3 measured green, and it is the strongest number this package
  has: **14,032 rows from the reference compiler's own line tables, across 196
  distinct objects from 12 core packages, re-encoded by this library and decoded
  back identical.** 0 disagreements, 0 inexpressible, ~9s. Two emitter features
  were added to get there rather than to caveat around it --
  `DW_LNS_set_basic_block` (the reference emits it) and
  `DW_LNE_set_discriminator`. All three oracles were then unified on one
  canonical row line (`addr line col file disc flags`), so every instrument now
  compares the discriminator and all four flags instead of address/line/column.
  Full sweep at the end of the iteration: checks clean, unit suite 45/45,
  decode-check PASS, fuzz-check 5014 programs 0 disagreements, parity-check
  PASS.
* 2026-08-18 -- A4 and A5 measured green; PHASE A IS COMPLETE. DWARF 5 line
  header implemented and every instrument now runs both versions: unit suite
  55/55, decode-check green on three decoders plus a new file-table leg for
  v4 and v5, fuzz 10,042 programs 0 disagreements, parity 14,032 rows per
  version 0 disagreements. v5 was confirmed non-vacuous by header bytes
  (`5 0 8 0` vs v4's `4 0 31 0`) rather than by the tests passing.
  TWO FINDINGS. (1) A latent emitter hole: address advances are divided by
  `min_inst_len` and truncated, so on a fixed-width target a misaligned address
  would have silently moved a row backwards. Now `MISALIGNED_ADDRESS` from
  `line_validate`. It was found by asking what would exercise min_inst_len,
  not by a failing test. (2) The file-path gap from the last iteration is
  closed, and the teeth test is the interesting part: with a filename byte
  corrupted, all three row legs still say "all agree" and only the new
  file-table leg fails. `llvm-dwarfdump --verify` said "No errors" for the
  third separate time.
* 2026-08-18 -- B1 through B4 measured green; PHASE B IS COMPLETE. `info.odin`
  emits `.debug_info`, `.debug_abbrev` and `.debug_str` with derived,
  deduplicated abbreviations and post-hoc-patched CU-relative DIE references.
  Unit suite 79/79. New instrument `tests/gdb-check.sh`: 12 assertions across
  both DWARF versions, all passing -- **a real gdb, on a real process, resolving
  `break widget.odin:41` to the right address from an invented file name that
  exists nowhere but in the tables this package emitted**, plus `info line`,
  a backtrace naming the function, and its caller frame resolving through our
  CU. Full sweep at the end of the iteration: checks clean, 79/79, gdb-check
  PASS, decode-check PASS, fuzz 10,042 programs, parity 14,032 rows per version.
  THE FINDING: gdb-check's first run failed its caller-frame assertion, and the
  cause was the CHECK, not the library -- the synthesised CU described the three
  leaf functions and not `main`, so gdb fell back to the symbol table for frame
  #1 and produced a frame with no file or line. Describing `main` too made the
  assertion meaningful rather than making it pass: the caller frame now resolves
  through our line table.
* 2026-08-18 -- C1 through C5 measured green; PHASE C IS COMPLETE. `expr.odin`
  adds the DWARF expression language this needs; the synthesised CU now carries
  base types, six aggregate shapes, locals, a formal parameter, globals and a
  lexical block. gdb-check is up to **40 assertions across both versions, all
  passing** -- values printed, types named, a shadowed name resolved, and a step
  landing where our line table says it should. Full sweep: checks clean, 79/79,
  decode-check PASS, fuzz 10,042, gdb-check 40/40, parity 14,032 rows per
  version.
  METHOD NOTE worth keeping: the gdb harness does NOT invent stack offsets. It
  reads the frame-base register, each variable's `DW_OP_fbreg` offset and the
  lexical block's pc range out of the HOST's own debug info and reproduces them.
  A synthesiser that guessed offsets would be testing the guess.
  THE FINDING: `ptype widget_pair` failed while `ptype p` succeeded. Under
  `DW_AT_language = DW_LANG_C99` a `DW_TAG_structure_type`'s name is a C TAG,
  not an ordinary identifier, so gdb answers "No symbol widget_pair in current
  context" unless a `DW_TAG_typedef` also carries the name. Odin's type names
  ARE ordinary identifiers, so clODIN must emit a typedef alongside every named
  struct or `ptype MyStruct` will not work for its users. Recorded in doc.odin
  where a consumer will read it, and both spellings are now asserted separately
  because they fail for different reasons.
* 2026-08-18 -- D1 through D3 measured green; ALL SEVEN HALT CRITERIA HOLD IN ONE
  RUN. Final numbers: checks clean under -vet -strict-style; unit suite 82/82;
  decode-check PASS across llvm-dwarfdump, binutils readelf and elfutils
  eu-readelf plus a file-table leg, for both DWARF versions; fuzz-check 10,042
  randomised programs 0 disagreements; parity-check 14,032 line rows AND 29,664
  DIEs per version, 0 disagreements, 0 skipped, exclusions tallied; gdb-check 40
  behavioural assertions across both versions; open-issues.md empty.
  THE FINDING OF THIS ITERATION was in the library, not the harness: attributes
  borrowed the caller's strings and expression buffers. A consumer naming a
  composite type with `fmt.tprintf` would have shipped DIE names that decode
  cleanly and read as memory corruption. Fixed by interning into the unit, and
  the test that proves it fails when the interning is switched off.
