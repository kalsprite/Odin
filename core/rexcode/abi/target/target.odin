// Selecting a convention BY TARGET TRIPLE.
//
// THIS PACKAGE FOLLOWS CLANG. Where a triple is ambiguous, the reading is the
// STANDARDISED one -- what `clang --target=X` does after normalising X -- and
// not what any particular compiler happens to do with the string verbatim.
// Stated first because it is a policy and not an implementation detail: the ABI
// layer's job is to be right about the ABI, and reproducing a producer's
// misparse in order to agree with it would make it wrong on purpose.
//
// Where the two readings differ, `Target.disputed` says so. That is a report,
// not a choice: which one is correct is a fact about the build system, and the
// caller is the one who can fix it. Four of Odin's own triples currently trip it
// -- see COMPILER_ISSUES/UPSTREAM-UNFILED-abi-unnormalised-target-triples-*.md.
//
// Every consumer of this package writes the same switch: map a target to a
// convention row, and map it AGAIN to a classifier. The oracle had nine copies
// of it across seven files before this existed, and the duplication is not
// harmless -- two of the pairings are ones nobody guesses right the first time:
//
//     win64      the WIN64 row runs `x86_64.classify_win64`, not `classify`
//     arm32      the AAPCS32 rows run `aarch64.classify` -- AAPCS32 is a ROW
//                over that classifier, and there is no `arm32.classify` at all
//
// A consumer that pairs those wrongly gets a confident, wrong answer rather than
// a compile error. So the pairing lives here, once, and `Target` hands back both
// halves together.
//
//
// WHY A SEPARATE PACKAGE, and not `abi` itself.
//
// `abi` must not import `abi/x86_64`. That is the layering the whole tree rests
// on -- `signature.odin` takes `classify` as a PROCEDURE for exactly this reason
// -- and it is what lets a backend depend on `isa/` alone, or on one
// architecture without dragging in four. This package is the opposite end: it
// imports every arch, because naming a triple means being able to answer for any
// of them. A consumer that only ever targets one should keep importing that one
// and never touch this file.
//
//
// WHY THE TRIPLE IS THE RIGHT KEY -- and the one place it is not.
//
// Measured, clang 22, one variable at a time:
//
//     arm-none-unknown-eabi     double -> r0:r1 (vmov d0, r2, r3 ...)   SOFT
//     arm-none-unknown-eabihf   double -> d0    (vadd.f64 d0, d0, d1)   HARD
//
// so on ARM the ENVIRONMENT decides the float ABI and the triple is sufficient.
// The same is true of the vendor on Darwin (`arm64-apple-*` is a different row
// from AAPCS64, not a spelling of it) and of the OS on Windows.
//
// RISC-V IS THE EXCEPTION, and it is not a detail that can be hidden. The float
// ABI there lives in `-mabi`, not in the triple:
//
//     riscv64-unknown-linux-gnu -mabi=lp64    double -> a0:a1   INTEGER file
//     riscv64-unknown-linux-gnu -mabi=lp64d   double -> fa0:fa1 FLOAT file
//
// One triple, two conventions, and no amount of parsing separates them. So
// `Float_Abi` is a parameter, defaulted to the hardware-float row because that
// is what every Linux RISC-V toolchain and Odin's own riscv64 target use --
// documented here rather than assumed silently. On ARM the same parameter can
// override the environment, for the case where a triple is unavailable or wrong.
//
//
// A NOTE ON ODIN'S OWN TABLE. The compiler keeps target triples in
// `src/build_settings.cpp` and mirrors them in `core:odin/checker`
// (`Target_Metrics.target_triplet`). Neither is reused here. The mirror is 88k
// lines across 50 files and pulls in `core:fmt`, `core:odin/ast` and
// `core:math/big`, which is a dependency this package cannot take; and its
// `Target_ABI_Kind` is `{Default, Win64, SysV}`, which exists to separate two
// freestanding amd64 rows rather than to choose an ABI. The two tables also
// already disagree with reality in the same place -- both spell freestanding
// arm32 `arm-none-eabihf`, a three-component triple whose `hf` LLVM parses as
// the OS, so the environment is empty and the target is soft-float in practice.
// Taking a triple as a STRING means a consumer can pass whichever table it has,
// including a corrected one.
//
// TODO(checker): once `core:odin/checker` lands, take its `Target_Metrics`
// DIRECTLY rather than re-deriving from a string. An inter-core dependency is
// acceptable and the string is a lossy intermediate: the checker already knows
// the arch, the pointer and int widths, the max alignment and the triple, and
// re-parsing a triple to recover facts it holds as typed fields is a translation
// step that can only lose or corrupt them. Speaking the same types removes it.
//
// Two things to settle when that happens, both decided already and recorded here
// so the decision is not re-litigated:
//
//   * `for_triple` STAYS. A backend that is not the Odin compiler -- which is
//     the case this package was reviewed from -- has a triple and no checker.
//     The typed entry point is an addition, not a replacement.
//
//   * THE STANDARDISED READING WINS -- the policy at the top of this file
//     applies to the checker's table too, not only to hand-written triples.
//     `arm32` was an afterthought there (`arm-none-eabihf` is soft-float in
//     practice despite its name), so taking typed metrics must not be allowed
//     to import that reading along with the types.
package rexcode_abi_target

import abi "core:rexcode/abi"
import x64 "core:rexcode/abi/x86_64"
import a64 "core:rexcode/abi/aarch64"
import rv "core:rexcode/abi/riscv64"
import a32 "core:rexcode/abi/arm32"

// Target is a convention and the classifier that goes with it.
//
// Returned together because they are not independently choosable: see the
// win64/arm32 pairings in the note above.
Target :: struct {
	conv:     abi.Convention,
	classify: abi.Classify_Proc,
	// THIS SELECTOR AND LLVM DISAGREE about the triple, and the answer above is
	// the intended reading rather than the one LLVM will generate.
	//
	// Not "the triple is unnormalised" -- that fires on `x86_64-linux-gnu` and
	// eleven of the thirteen triples in the test, which is noise nobody reads.
	// It is computed by running the selection TWICE, once recognising components
	// wherever they appear and once strictly positionally as LLVM's verbatim
	// in-file parse does, and comparing the rows that come out. It is set only
	// when they differ.
	//
	// One triple in ordinary use trips it: `arm-none-eabihf`, Odin's own
	// freestanding arm32 target. A component says `hf`, so the intent is plainly
	// hard-float and that is what `conv` says; LLVM reads `eabihf` as the OS,
	// finds no environment, and emits the SOFT-float convention. Both readings
	// are defensible, they disagree, and which one is right is a fact about the
	// build system rather than about this file -- so it is reported, not chosen.
	//
	// Answer still valid, flag raised: use the convention, and fix the triple.
	disputed: bool,
}

// Which language row to compose. The platform decides where things go; the
// language decides whether there is an implicit context pointer, how multiple
// results come back, and when an aggregate is replaced by a pointer.
Lang :: enum u8 {
	C,
	ODIN,
	ODIN_CONTEXTLESS,
}

// The float ABI, for the targets whose triple does not carry it.
//
// DEFAULT reads the triple where the triple says (ARM's `eabihf`), and takes the
// hardware-float row where it does not (RISC-V). Set it explicitly to override
// either.
Float_Abi :: enum u8 {
	DEFAULT,
	SOFT,
	HARD,
}

// A parsed LLVM target triple, kept as its COMPONENTS.
//
// `parts` rather than four named slots, and the reason is measured. LLVM's raw
// `Triple` constructor is positional, but every real producer normalises first,
// and normalisation RECOGNISES components rather than trusting their index:
//
//     x86_64-windows-gnu       ->  x86_64-unknown-windows-gnu
//     armv7-linux-gnueabihf    ->  armv7-unknown-linux-gnueabihf
//     i386-linux-gnu           ->  i386-unknown-linux-gnu
//
// A three-component triple therefore has `windows` in the VENDOR slot while
// meaning it as the OS. Selecting on slots got this wrong on the first attempt
// -- `x86_64-windows-gnu`, which is the triple the sweep actually uses for its
// Win64 row, came out SysV -- so selection below asks whether a component is
// present, not where it sits. The positional slots are still exposed, because
// modelling what LLVM does with an UNNORMALISED in-file triple needs them.
Triple :: struct {
	parts:                 []string, // as written, split on '-'
	arch, vendor, os, env: string,   // positional, LLVM's raw parse
}

// parse_triple splits on '-'.
//
// The positional fields do NOT normalise, deliberately: LLVM's own in-file
// `target triple` parse does not either, and that is the entire mechanism behind
// the freestanding-arm32 defect described at the top of this file. A helper that
// silently repaired it would disagree with the compiler it models.
// `triple_looks_unnormalised` reports the condition instead.
parse_triple :: proc(s: string, allocator := context.temp_allocator) -> (t: Triple) {
	n := 1
	for c in s { if c == '-' { n += 1 } }
	parts := make([]string, n, allocator)
	k, start := 0, 0
	for i in 0 ..< len(s) {
		if s[i] == '-' {
			parts[k] = s[start:i]
			k += 1
			start = i + 1
		}
	}
	parts[k] = s[start:]
	t.parts = parts
	if len(parts) > 0 { t.arch   = parts[0] }
	if len(parts) > 1 { t.vendor = parts[1] }
	if len(parts) > 2 { t.os     = parts[2] }
	if len(parts) > 3 { t.env    = parts[3] }
	return
}

// triple_looks_unnormalised reports a triple with fewer than four components,
// whose trailing field LLVM will read as the OS rather than as the environment
// when it appears verbatim in a module.
//
// Worth its own procedure because the failure is silent and DIRECTIONAL: it can
// only turn a specified environment into an unspecified one, which on ARM means
// a hard-float target quietly becoming soft-float. Odin ships exactly that today
// in `target_freestanding_arm32` (`arm-none-eabihf`). A build system that emits
// triples should assert on this.
triple_looks_unnormalised :: proc(s: string) -> bool {
	dashes := 0
	for c in s { if c == '-' { dashes += 1 } }
	return dashes < 3
}

// The two readings, behind one pair of predicates.
//
// `strict` is LLVM's verbatim in-file parse: the component must be in its own
// slot. Otherwise a component is recognised wherever it appears, which is what
// `Triple::normalize` does and what every producer relies on.

@(private)
has :: proc(t: Triple, name: string, strict: bool) -> bool {
	if strict { return t.vendor == name || t.os == name }
	for i in 1 ..< len(t.parts) { if t.parts[i] == name { return true } }
	return false
}

@(private)
ends :: proc(s, suffix: string) -> bool {
	return len(suffix) <= len(s) && s[len(s) - len(suffix):] == suffix
}

@(private)
has_suffix_any :: proc(t: Triple, suffix: string, strict: bool) -> bool {
	// STRICT: only the environment slot. That is the whole defect -- `eabihf`
	// sitting in the OS slot is not an environment, and the ARM backend reads
	// the float ABI from the environment alone.
	if strict { return ends(t.env, suffix) }
	for i in 1 ..< len(t.parts) {
		if ends(t.parts[i], suffix) { return true }
	}
	return false
}

// for_triple maps a target triple to its convention and classifier.
//
// `ok` is false for a triple this package has no row for -- wasm, and any
// architecture not among the five. A caller must check it: the zero `Target` has
// a nil classifier and a zero convention, and `classify_signature` refuses a
// zero convention rather than answering from it, but only if it is reached.
for_triple :: proc(
	triple: string,
	lang := Lang.C,
	float_abi := Float_Abi.DEFAULT,
	riscv_hard_float := true,
) -> (t: Target, ok: bool) {
	p := parse_triple(triple)
	t, ok = select(p, lang, float_abi, riscv_hard_float, false)
	if !ok { return }
	// The second reading, and the ONLY reason to compute it: to find out whether
	// the two disagree. Cheap -- no allocation, the components are already split.
	strict, sok := select(p, lang, float_abi, riscv_hard_float, true)
	t.disputed = !sok || strict.conv.id != t.conv.id
	return
}

@(private)
select :: proc(
	p: Triple,
	lang: Lang,
	float_abi: Float_Abi,
	riscv_hard_float: bool,
	strict: bool,
) -> (t: Target, ok: bool) {
	switch {
	case p.arch == "x86_64" || p.arch == "amd64":
		// Windows is the row, whatever the environment says. `-msvc` and `-gnu`
		// are two toolchains over ONE calling convention: MinGW follows Win64,
		// which the sweep measures on both `x86_64-windows-msvc` and
		// `x86_64-windows-gnu`.
		if has(p, "windows", strict) {
			t.classify = x64.classify_win64
			switch lang {
			case .C:                t.conv = x64.win64()
			case .ODIN:             t.conv = x64.win64_odin()
			case .ODIN_CONTEXTLESS: return {}, false
			}
			return t, true
		}
		t.classify = x64.classify
		switch lang {
		case .C:                t.conv = x64.sysv()
		case .ODIN:             t.conv = x64.sysv_odin()
		case .ODIN_CONTEXTLESS: t.conv = x64.sysv_contextless()
		}
		return t, true

	case p.arch == "i386" || p.arch == "i686" || p.arch == "x86":
		t.classify = x64.classify
		switch lang {
		case .C:                t.conv = x64.cdecl()
		case .ODIN:             t.conv = x64.cdecl_odin()
		case .ODIN_CONTEXTLESS: return {}, false
		}
		return t, true

	case p.arch == "aarch64" || p.arch == "arm64":
		t.classify = a64.classify
		// The VENDOR, not the OS. `arm64-apple-macosx`, `arm64-apple-ios` and
		// `arm64-apple-watchos` are one row, and it differs from AAPCS64 in
		// where things go, not merely in how they are spelled.
		if has(p, "apple", strict) {
			switch lang {
			case .C:                t.conv = a64.darwin()
			case .ODIN:             t.conv = a64.darwin_odin()
			case .ODIN_CONTEXTLESS: return {}, false
			}
			return t, true
		}
		switch lang {
		case .C:                t.conv = a64.aapcs64()
		case .ODIN:             t.conv = a64.aapcs64_odin()
		case .ODIN_CONTEXTLESS: return {}, false
		}
		return t, true

	case p.arch == "arm" || p.arch == "armv7" || p.arch == "thumbv7em" ||
	     p.arch == "thumbv7m" || p.arch == "thumbv6m" || p.arch == "thumbv8m.main":
		// AAPCS32 is a ROW over the AArch64 classifier. There is no
		// `arm32.classify`, and the one thing `abi/arm32` contributes is the
		// register file.
		t.classify = a64.classify
		hard: bool
		switch float_abi {
		case .HARD:    hard = true
		case .SOFT:    hard = false
		case .DEFAULT: hard = has_suffix_any(p, "hf", strict)
		}
		switch lang {
		case .C:                t.conv = hard ? a32.aapcs32()      : a32.aapcs32_soft()
		case .ODIN:             t.conv = hard ? a32.aapcs32_odin() : a32.aapcs32_soft_odin()
		case .ODIN_CONTEXTLESS: return {}, false
		}
		return t, true

	// RISC-V takes its float ABI from `riscv_hard_float`, NOT from the triple
	// and NOT from `float_abi`.
	//
	// A separate knob because it is a separate kind of fact. `float_abi` exists
	// to OVERRIDE a triple that carries the answer; on RISC-V no triple ever
	// does -- `riscv64-unknown-linux-gnu` is lp64, lp64f or lp64d entirely
	// according to `-mabi`. Folding the two together would imply that
	// `Float_Abi.DEFAULT` could read it off the triple here, which it cannot.
	//
	// Defaulted TRUE: every Linux RISC-V toolchain, and Odin's own riscv64
	// target, are lp64d. `false` selects the soft rows, which are measured
	// against clang but not swept -- see the note on `lp64` in `abi/riscv64`.
	//
	// `lp64f` (single-precision hard float) is NOT modelled, and a bool cannot
	// express it. If it is ever needed this becomes an enum; it is a bool today
	// because two of the three states are the ones anyone asks for.
	case p.arch == "riscv64":
		t.classify = rv.classify
		switch lang {
		case .C:                t.conv = riscv_hard_float ? rv.lp64d()      : rv.lp64()
		case .ODIN:             t.conv = riscv_hard_float ? rv.lp64d_odin() : rv.lp64_odin()
		case .ODIN_CONTEXTLESS: return {}, false
		}
		return t, true

	case p.arch == "riscv32":
		t.classify = rv.classify
		switch lang {
		case .C:                t.conv = riscv_hard_float ? rv.ilp32d()      : rv.ilp32()
		case .ODIN:             t.conv = riscv_hard_float ? rv.ilp32d_odin() : rv.ilp32_odin()
		case .ODIN_CONTEXTLESS: return {}, false
		}
		return t, true
	}
	return {}, false
}
