package rexcode_dwarf

// DWARF debug-information emission.
//
// Scope, and the reason it is drawn here:
//
//   * `.debug_line`  -- COMPLETE for DWARF 4. The line-number program is the
//     whole deliverable of a debug backend's first debug-info slice: it is what
//     turns `break file.odin:47`, source stepping and a backtrace with line
//     numbers on. Nothing else in DWARF is worth anything without it.
//   * everything else -- NOT YET. `.debug_info`, `.debug_abbrev`, `.debug_str`
//     (types, variables, scopes) are a much larger project and are deliberately
//     a separate step.
//
// This package emits BYTES and nothing else. It does not know what an ELF is,
// it does not know what a symbol table is, and it does not allocate section
// indices. References it cannot resolve -- the run-time address of a function,
// the link-time offset of another debug section -- come back as `Fixup`s for
// the object writer to turn into whatever that format calls a relocation. That
// is what keeps one emitter correct for ELF and COFF both, and it is the reason
// a Fixup names a `Section` rather than an `R_X86_64_*`.
//
// DWARF 4 rather than 5, for now. The reference Odin compiler emits version 4
// (`DW_AT_producer "odin"`, `DW_AT_language DW_LANG_C99`), so v4 keeps our
// output directly comparable with a known-good producer over the SAME source,
// and v4's line header is a plain list of NUL-terminated strings where v5's is
// form-encoded. The v5 header also renumbered the file table -- index 0 is the
// primary source file in v5 and is INVALID in v4 -- which is a one-line change
// here and an every-row-attributed-to-the-wrong-file bug if it is made by
// accident. `line_emit` refuses a version it does not implement rather than
// emitting a v4 header under a v5 version stamp.
//
// -----------------------------------------------------------------------------
// Ownership and lifetime -- read this before building anything
// -----------------------------------------------------------------------------
//
// The two halves of this package have DIFFERENT rules, because they are used
// differently, and the difference is the thing to remember:
//
//   * `.debug_line` is described and emitted in one breath. `Line_Program` holds
//     BORROWED slices -- dirs, files, sequences, and each sequence's rows -- and
//     they need only survive the `line_emit` call itself. Nothing is copied,
//     because nothing needs to be.
//   * `.debug_info` is BUILT UP and emitted later, so an `Info_Unit` OWNS
//     everything an attribute names. `die_add` and `die_attr_add` take a private
//     copy of every string and every expression block. A name built with
//     `fmt.tprintf` -- which is how a backend spells a composite type -- is safe
//     across a temp-allocator reset, and an `Expr` may be destroyed the moment
//     it has been attached.
//
// The one way to lose is to append to `unit.dies[i].attrs` by hand, which skips
// that copy. Use `die_attr_add`.
//
// `info_emit` uses `context.temp_allocator` for its abbreviation bookkeeping and
// frees nothing itself; a consumer emitting many units in a loop should reset
// temp between them.
//
// Nothing in this package returns a slice into memory the caller does not own,
// and nothing caches a value that a later call mutates in place. Both are
// deliberate: the `abi` package's review found exactly those two shapes, and a
// consumer that has to know which returned slice is safe to keep has been handed
// a problem rather than a library.
//
// -----------------------------------------------------------------------------
// What the consumer still has to do
// -----------------------------------------------------------------------------
//
// FIXUPS. This package emits zeroes and a `Fixup` wherever a value depends on
// where things land. Two kinds, and the object writer maps each onto whatever
// its format calls that relocation:
//
//   ABS64_SYM   8 bytes, the run-time address of a symbol plus an addend.
//               ELF x86-64 calls it R_X86_64_64; COFF calls it
//               IMAGE_REL_AMD64_ADDR64; AArch64 ELF calls it R_AARCH64_ABS64.
//   SECOFF32    4 bytes, the offset at which a named section was placed, plus
//               an addend. `DW_AT_stmt_list`, a CU's abbreviation offset and
//               every `DW_FORM_strp` are this.
//
// FILE NUMBERING. `DW_AT_decl_file` indexes the SAME table as the line program,
// and the two versions number it differently. Use `line_file_number` for both
// rather than writing the bias twice; a CU whose decl_file numbering disagrees
// with its line table sends a debugger to the wrong source file for every
// declaration it describes.
//
// -----------------------------------------------------------------------------
// Notes for a consumer, measured rather than assumed
// -----------------------------------------------------------------------------
//
// A NAMED STRUCT IS NOT ENOUGH TO NAME A TYPE. `DW_AT_language` decides how a
// debugger reads the DIE tree, and this package declares `DW_LANG_C99` because
// that is what the reference Odin compiler declares and what every reader
// implements well. Under C rules a `DW_TAG_structure_type`'s name is a TAG, not
// an ordinary identifier: gdb answers `ptype Widget` with "No symbol Widget in
// current context" and needs `ptype struct Widget`. A language whose type names
// are ordinary identifiers -- Odin's are -- must therefore emit a
// `DW_TAG_typedef` carrying the name alongside the struct, which is exactly what
// C producers do for a `typedef struct`. Measured against gdb 17.2 on
// 2026-08-18; `print aStructValue` and member access work either way, so this
// only shows up when a user asks about the TYPE by name.
//
// -----------------------------------------------------------------------------
// How this gets verified, since "it decodes" is not the same as "it is right"
// -----------------------------------------------------------------------------
//
// `llvm-dwarfdump --verify` is a necessary gate and NOT a sufficient one. It
// checks structure and cross-references -- abbreviation codes, DIE references in
// range, file indices valid -- and it does not check that a line program means
// anything. Measured on 2026-08-18: a clang object with one byte flipped inside
// its line program decodes to line 4294967293 and `--verify` still exits 0 with
// "No errors."
//
// The oracle that does measure correctness is a diff against the producer's own
// intent, because the producer is the only party that knows what the answer was
// supposed to be:
//
//   1. the backend dumps the rows it INTENDED -- (text offset, file, line,
//      column, is_stmt) -- straight out of its per-instruction provenance;
//   2. an EXTERNAL reader decodes the `.debug_line` we emitted;
//   3. the two are required to be equal as sets.
//
// Step 2 must not use a decoder from this package, or the test proves only that
// we are self-consistent. Run more than one external reader and require them to
// agree with each other as well: llvm-dwarfdump, binutils readelf and elfutils
// eu-readelf are independent implementations, and a disagreement between them
// means our encoding is being tolerated rather than understood.
