package rexcode_abi

// The LANGUAGE axis.
//
// `Convention` began as one flat row and was quietly two things:
//
//   arch x OS   register files, sizes, HFA and split rules, shadow space,
//               the return files, positional-vs-independent assignment
//   language    the implicit `^Context`, whether large aggregates go by
//               pointer, the multi-value return protocol, how varargs work
//
// Conflating them costs a row per (platform, language) pair, and the bill came
// due twice already. `ODIN` existed only for x86-64, so the sweep's
// Odin-convention column had to be disabled on every other target -- and before
// that it did not fail, it CRASHED, because an AArch64 classifier was being run
// against an x86-64 row. A language expressed as a delta composes onto any
// platform and neither happens.
//
// Fortran is the case that makes the axis obvious: pass-by-reference for
// everything and hidden string-length arguments appended after the declared
// ones. That is a pure language delta over whatever platform ABI is underneath,
// and writing it as eight more rows would be absurd.

// Multi_Return is HOW a platform returns several values -- a platform property,
// not a language one, exactly as `Varargs_Kind` is. The language says only
// WHETHER it has multi-value returns at all; `compose` combines the two.
//
// That split is measured, not assumed. Odin implements THREE protocols across
// the five targets an Odin caller can be built for, and they are not
// interchangeable:
//
//     amd64                    always trailing pointers
//     arm64, riscv64, i386     the tuple in registers when it fits, else
//                              trailing pointers
//     arm32                    the tuple always, through sret when it does not
//                              fit
//
// This field said TRAILING_POINTERS for every platform until an Odin caller was
// first run on AArch64, where `-> (i64, i64)` comes back in x0:x1 with no hidden
// pointer at all. The model was right on x86-64 and wrong on the other four,
// and the type sweep could not see it: it asks what class ONE result is.
Multi_Return :: enum u8 {
	// One result, or none. C -- and any platform whose multi-value protocol has
	// not been measured, so that `classify_signature` refuses rather than
	// guesses.
	SINGLE,
	// The LAST result comes back in registers and every earlier one through a
	// hidden pointer appended after the declared arguments
	// (mir_design.md:474). x86-64, whatever the tuple's size.
	TRAILING_POINTERS,
	// The results are laid out as one anonymous STRUCT and returned by the
	// platform's ordinary return rules. If that struct would be returned in
	// memory, fall back to TRAILING_POINTERS instead. AArch64, RISC-V, i386.
	TUPLE_ELSE_POINTERS,
	// As above, but with no fallback: a memory-class tuple is returned through
	// an sret pointer as a whole rather than split into hidden pointers.
	// AAPCS32, which sret's anything over four bytes and so takes this path for
	// nearly every tuple.
	TUPLE_ALWAYS,
}

// Varargs_Kind is HOW a platform passes variadic arguments -- a platform
// property, not a language one, which the measurements settle: Darwin and Linux
// on the same architecture disagree, and both are C.
//
// The language only says WHETHER it has them. `compose` combines the two.
Varargs_Kind :: enum u8 {
	// The language has no C-style varargs. Odin's `..T` is a slice -- an
	// ordinary two-word aggregate -- so nothing here applies to it.
	NONE,
	// Passed exactly like named arguments. AAPCS64 on Linux.
	SAME_AS_NAMED,
	// x86-64 SysV: placed like named arguments, but the caller must set AL to
	// the number of VECTOR registers used, so `va_start` knows whether to spill
	// them. Measured: `v(1, 2, 3.5, 4, 5.5)` emits `movb $2, %al`.
	SYSV_AL,
	// Win64: a variadic FLOAT is duplicated into the integer register of the
	// same slot, because the callee has no prototype to know which file to
	// read. Measured: `movq %xmm2, %r8` for the slot-2 argument.
	WIN64_DUPLICATE,
	// Darwin AArch64: EVERY variadic argument goes on the stack, registers
	// untouched. Measured: `stp x9, x8, [sp]` and no d0/w0 at all, where
	// aarch64-linux passes the same call in d0, d1, w0, w1, w2.
	ALL_STACK,
	// RISC-V: variadic floats travel in INTEGER registers. Measured: the
	// double 3.5 built with `lui`/`slli` into a2 rather than loaded into fa0.
	INT_REGS,
}

// Language is the delta a source language adds on top of any platform.
//
// Every field is an override or an addition; nothing here restates something
// the platform already decided.
Language :: struct {
	name: string,
	// Hidden arguments the language appends. Odin's `^Context`, Fortran's
	// string lengths.
	implicit: []Implicit_Arg,
	// Override the platform's rule for an aggregate too large for registers.
	// Odin passes those by POINTER where SysV C copies them to the stack
	// (mir_design.md:1373) -- a language choice, and the same one on every
	// platform, which is exactly why it belongs here.
	over_max: Maybe(Over_Max),
	// The THRESHOLD the override applies above, in WORDS.
	//
	// `over_max` says what happens above the limit; the limit itself was a
	// platform field, and that was wrong. Odin's rule is "above two words, by
	// pointer" on every platform that has the rule at all -- a LANGUAGE
	// threshold. Measured from Odin's own IR, `proc "odin" (a: struct{w: [N]T})`:
	//
	//     linux_amd64    [1]i64 i64      [2]i64 {i64,i64}   [3]i64 ptr
	//     linux_arm64    [1]i64 i64      [2]i64 [2 x i64]   [3]i64 ptr
	//     linux_riscv64  [1]i64 i64      [2]i64 {i64,i64}   [3]i64 ptr
	//     linux_arm32    [1]i32 [1 x i32] [2]i32 [2 x i32]  [3]i32 ptr
	//
	// It survived unnoticed because x86-64's `max_by_value` is 16, which is two
	// eightbytes, which is Odin's own threshold -- the rule was right on the one
	// target where the platform limit and the language limit coincide. AAPCS32
	// sets `max_by_value = 1 << 20` (correct for C, which really does pass
	// 40-byte aggregates by value), so the gate never fired there and the
	// override was dead code.
	over_max_above_words: Maybe(u32),
	// Whether the language HAS multi-value returns at all. Which protocol is
	// then used is the platform's business -- see `Multi_Return`.
	has_multi_return: bool,
	// Whether the language HAS C-style varargs at all. How they are then
	// passed is the platform's business.
	has_varargs: bool,
}

// The languages themselves, as PROCEDURES rather than package-level vars.
//
// They were vars, and an arch package's `@(init)` composed from them -- but
// cross-package variable initialisation order is not guaranteed, so the
// language could still be zeroed when `compose` ran. `multi_return` then came
// out SINGLE for Odin and the hidden-pointer protocol vanished.
//
// It was invisible for as long as nothing read the field, which is the second
// bug this project has found by making a declared field load-bearing. A
// procedure has no initialisation order to get wrong.

lang_c :: proc "contextless" () -> Language { return LANG_C_ }
lang_odin :: proc "contextless" () -> Language { return LANG_ODIN_ }
lang_contextless :: proc "contextless" () -> Language { return LANG_CONTEXTLESS_ }

@(private) LANG_C_ := Language{
	name             = "c",
	has_multi_return = false,
	has_varargs      = true,
}

@(private) LANG_ODIN_ := Language{
	name             = "odin",
	implicit         = ODIN_IMPLICIT[:],
	over_max         = Over_Max.INDIRECT,
	over_max_above_words = u32(2),
	has_multi_return = true,
	has_varargs      = false, // `..T` is a slice
}

@(private) LANG_CONTEXTLESS_ := Language{
	name             = "contextless",
	over_max         = Over_Max.INDIRECT,
	// The SAME threshold as `odin`. It was missing, and could not bite: the one
	// composed contextless row is on x86-64, where two words is 16, which is
	// SysV's own `max_by_value` -- the identical coincidence that let the `odin`
	// row's missing threshold survive on x86-64 and go wrong on AAPCS32.
	//
	// `contextless` is `odin` minus the context pointer. It is the same
	// language, so it has the same aggregate rule; a second row for the same
	// language must not be able to disagree with the first about it.
	over_max_above_words = u32(2),
	has_multi_return = true,
	has_varargs      = false,
}

@(private) ODIN_IMPLICIT := [?]Implicit_Arg{
	{name = "context", class = .INTEGER, position = .LAST},
}

// compose applies a language to a platform row, producing the flat Convention
// the classifiers consume.
//
// Deliberately a value-returning function rather than a two-pointer struct: the
// classifiers read one row and should not have to know the axis exists, and a
// composed row can be cached at init.
compose :: proc "contextless" (base: Convention, lang: Language) -> Convention {
	out := base
	out.name = tprint_name(base.name, lang.name)
	out.implicit = lang.implicit
	if o, has := lang.over_max.?; has {
		// A by-POINTER rule needs somewhere to put the pointer.
		//
		// i386 is the counterexample and it is not an exception: cdecl has no
		// argument registers at all, so "pass a pointer instead of a copy"
		// buys nothing -- the pointer would go on the stack beside the copy it
		// replaced. Measured, and Odin agrees: `proc "odin"` on linux_i386
		// emits `ptr byval(...)` at EVERY size, including one word. So the
		// override applies only where the platform can carry a pointer in a
		// register, which is derived rather than listed per target.
		if len(base.int_regs) > 0 {
			out.over_max = o
			// And the threshold comes with it. Without this the override is
			// gated on the PLATFORM's by-value limit, which is 16 on x86-64
			// (right by coincidence) and effectively infinite on AAPCS32
			// (so the override never fired at all).
			if w, has_w := lang.over_max_above_words.?; has_w && base.word_size > 0 {
				out.max_by_value = w * base.word_size
			}
		}
	}
	// The platform already carries HOW; the language says WHETHER. Both axes
	// work this way, and a platform that never had its protocol measured keeps
	// SINGLE, which makes `classify_signature` refuse the signature rather than
	// lay it out under a guessed rule.
	if !lang.has_multi_return {
		out.multi_return = .SINGLE
	}
	if !lang.has_varargs {
		out.varargs = .NONE
	}
	return out
}

@(private)
tprint_name :: proc "contextless" (platform, lang: string) -> string {
	// Names are for diagnostics; a static join avoids an allocator here.
	//
	// KNOWN LIMIT, recorded rather than silently lived with: composing anything
	// but C collapses the name to the LANGUAGE, so `x86_64.ODIN`,
	// `aarch64.AAPCS64_ODIN`, `riscv64.LP64D_ODIN` and `arm32.AAPCS32_SOFT_ODIN`
	// are all "odin". Any consumer keying a diagnostic or a cache on
	// `conv.name` collides across four architectures. Fixing it properly wants
	// a joined string, which wants an allocator this procedure deliberately
	// does not have; the honest interim is that `name` is for humans reading one
	// line of output, and is not an identity.
	if lang == "c" { return platform }
	return lang
}
