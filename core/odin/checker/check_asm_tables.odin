package checker

import "core:odin/ast"
import "core:reflect"
import "core:sync"
import x86 "core:rexcode/isa/x86"

// C++ Reference: src/asm_tables.cpp + src/asm_tables_amd64.cpp.
//
// src/asm_tables_amd64.cpp is a GENERATED file, 2119 lines, whose header says so:
//
//     // GENERATED FILE - DO NOT EDIT
//     // Produces a C++ equivalent of the encoding table from core:rexcode written in Odin
//
// Its source of truth is core/rexcode/isa/x86, which is already Odin in this repository. C++
// needs a generated copy only because C++ cannot import an Odin package. The port can, so this
// file DERIVES the same tables from `core:rexcode/isa/x86` instead of carrying a second copy.
// That is not a shortcut: a hand-copied 2000-line table is a table that will silently drift.
//
// VERIFIED, not assumed: the 211 dense register entries produced below were diffed against
// `Asm_amd64::register_strings` and `Asm_amd64::register_codes` in the generated C++.
// All 211 NAMES match exactly, in order. 209 of 211 CODES match; the two that do not are
// DR6 and DR7, and the generated C++ is the correct one -- see the note on Debug registers
// below and COMPILER_ISSUES/UPSTREAM-UNFILED-rexcode-x86-DREG-enum-numbers-DR6-DR7-as-4-and-5.md

// The dense register table, index 0 being the invalid/empty entry, exactly as the reference's
// `enum Register : u16 { REG_INVALID, ... REG_COUNT }` is laid out.
ASM_REG_COUNT :: 211

asm_register_names: [ASM_REG_COUNT]string
asm_register_codes: [ASM_REG_COUNT]x86.Register

// Names are lowercased into this fixed buffer rather than allocated. init_asm_tables can be
// reached from any thread under any context.allocator (the reference calls it once from main,
// which the port has no equivalent of), and a table that outlives every allocator in the
// process must not depend on which one happened to be installed at first use.
@(private="file") asm_register_name_buf:  [2048]u8
@(private="file") asm_register_name_used: int
@(private="file") asm_tables_once:        sync.Once

// C++ Reference: src/asm_tables.cpp:66-68 -- `void init_asm_tables() { g_asm_amd64.init(); }`,
// called once from src/main.cpp:4324. The port is a library with no main, so the table is
// built on first use behind a sync.Once instead. It is read-only afterwards, which is what
// makes it safe to share across the checker's worker threads.
init_asm_tables :: proc() {
	sync.once_do(&asm_tables_once, init_asm_tables_impl)
}

@(private="file")
asm_intern_lower :: proc(s: string) -> string {
	start := asm_register_name_used
	for i in 0 ..< len(s) {
		c := s[i]
		if 'A' <= c && c <= 'Z' {
			c += 'a' - 'A'
		}
		asm_register_name_buf[asm_register_name_used] = c
		asm_register_name_used += 1
	}
	return string(asm_register_name_buf[start:asm_register_name_used])
}

@(private="file") asm_reg_next: int

@(private="file")
asm_add_reg_group :: proc($T: typeid, class: u16) {
	values := reflect.enum_field_values(T)
	for name, i in reflect.enum_field_names(T) {
		asm_register_names[asm_reg_next] = asm_intern_lower(name)
		asm_register_codes[asm_reg_next] = x86.Register(class | u16(values[i]))
		asm_reg_next += 1
	}
}

@(private="file")
asm_add_reg :: proc(name: string, code: x86.Register) {
	asm_register_names[asm_reg_next] = asm_intern_lower(name)
	asm_register_codes[asm_reg_next] = code
	asm_reg_next += 1
}

@(private="file")
init_asm_tables_impl :: proc() {
	// Slot 0 is REG_INVALID and its name is the empty string, matching
	// `register_strings[0] == str_lit("")`.
	asm_reg_next = 1

	// The class order below IS the reference's Register enum order. It is not arbitrary: the
	// generated table walks the classes in exactly this sequence, and the port's table has to
	// agree index-for-index for `register_codes[r]`-style indexing to mean the same thing.
	asm_add_reg_group(x86.GPR64, x86.REG_GPR64)
	asm_add_reg_group(x86.GPR32, x86.REG_GPR32)
	asm_add_reg_group(x86.GPR16, x86.REG_GPR16)
	asm_add_reg_group(x86.GPR8,  x86.REG_GPR8)
	asm_add_reg_group(x86.GPR8H, x86.REG_GPR8H)
	asm_add_reg_group(x86.XMM,   x86.REG_XMM)
	asm_add_reg_group(x86.YMM,   x86.REG_YMM)
	asm_add_reg_group(x86.ZMM,   x86.REG_ZMM)
	asm_add_reg_group(x86.KREG,  x86.REG_K)
	asm_add_reg_group(x86.SREG,  x86.REG_SEG)
	asm_add_reg_group(x86.CREG,  x86.REG_CR)

	// Debug registers are NOT taken from x86.DREG. That enum is written
	// `DREG :: enum u8 { DR0, DR1, DR2, DR3, DR6, DR7 }` with no explicit values, so DR6 and
	// DR7 are numbered 4 and 5 -- disagreeing with the x86.DR6/x86.DR7 CONSTANTS beside it
	// (REG_DR|6 and REG_DR|7), with the hardware, and with the generated C++ table, which
	// carries its own explicit numbering at tablegen/cpp-compiler/cpp-gen.odin:1289.
	// The constants are the correct source. Filed as
	// UPSTREAM-UNFILED-rexcode-x86-DREG-enum-numbers-DR6-DR7-as-4-and-5.md; this stays correct
	// either way, since it reads the constants rather than the enum.
	asm_add_reg("DR0", x86.DR0)
	asm_add_reg("DR1", x86.DR1)
	asm_add_reg("DR2", x86.DR2)
	asm_add_reg("DR3", x86.DR3)
	asm_add_reg("DR6", x86.DR6)
	asm_add_reg("DR7", x86.DR7)

	asm_add_reg_group(x86.BND, x86.REG_BND)
	asm_add_reg_group(x86.MM,  x86.REG_MM)
	asm_add_reg_group(x86.ST,  x86.REG_ST)

	asm_add_reg("RIP", x86.RIP)

	assert(asm_reg_next == ASM_REG_COUNT, "asm register table size disagrees with the reference's REG_COUNT")

	init_asm_name_tables()
}

// asm_register_lookup resolves a register name to its dense table index, or 0 for "not found".
//
// C++ Reference: src/asm_tables_amd64.cpp:474-479, `Register register_lookup(String const &)`,
// which reads a StringMap built over the same 211 names. A linear scan over the dense table is
// used here instead: it is called once per asm operand, and it makes the "did you mean"
// candidate order a property of the table rather than of a hash function.
asm_register_lookup :: proc(name: string) -> int {
	init_asm_tables()
	for i in 1 ..< ASM_REG_COUNT {
		if asm_register_names[i] == name {
			return i
		}
	}
	return 0
}

// C++ Reference: src/asm_tables_amd64.cpp:242-274 -- `flag_bit_from_name`.
//
// Returns the EFLAGS bit position for a `%flags.<name>` accessor, or -1 if the name is not a
// flag. `width_` receives the field width in bits: 2 for iopl (bits 12-13), 1 for every other
// entry. The bit numbers are the architectural EFLAGS layout.
asm_flag_bit_from_name :: proc(name: string, width_: ^i32 = nil) -> i32 {
	Entry :: struct {
		name: string,
		bit:  i32,
	}
	@(static, rodata) table := []Entry{
		{"c",    0},  // Carry
		{"p",    2},  // Parity
		{"a",    4},  // Auxiliary Carry
		{"z",    6},  // Zero
		{"s",    7},  // Sign
		{"t",    8},  // Trap
		{"i",    9},  // Interrupt Enable
		{"d",   10},  // Direction
		{"o",   11},  // Overflow
		{"iopl",12},  // I/O Privilege Level (2-bit field: bits 12-13, low bit)
		{"nt",  14},  // Nested Task
		{"r",   16},  // Resume
		{"vm",  17},  // Virtual-8086 Mode
		{"ac",  18},  // Alignment Check / Access Control
		{"vi",  19},  // Virtual Interrupt Flag
		{"vip", 20},  // Virtual Interrupt Pending
		{"id",  21},  // Identification
	}

	for t in table {
		if name == t.name {
			if width_ != nil {
				width_^ = 2 if t.name == "iopl" else 1
			}
			return t.bit
		}
	}
	return -1
}

// C++ Reference: src/asm_tables_amd64.cpp:96-99 -- `enum Prefix : u8`, and its
// `prefix_strings` at :773-775, which are just the lowercased member names.
//
// This one enum genuinely has to be RE-DECLARED rather than derived. The generator's Prefix
// enum lives in the TOOL -- core/rexcode/isa/x86/tablegen/cpp-compiler/cpp-gen.odin:899 -- not
// in the `core:rexcode/isa/x86` package, so there is nothing to import. It is 13 entries and it
// is architectural, so a copy is acceptable where a copy of the 1239-entry mnemonic table or
// the 211-entry register table would not be.
Asm_Prefix :: enum u8 {
	Invalid,
	ES,
	CS,
	SS,
	DS,
	REX,
	EVEX,
	FS,
	GS,
	VEX,
	LOCK,
	REPNE,
	REP,
}

// VERIFIED, not assumed: `x86.Mnemonic`'s member names were diffed against the generated
// `enum Mnemonic : u16 { M_... }` in src/asm_tables_amd64.cpp. All 1239 match, in order, and
// the values are dense 0..1238 -- so `mnemonic_strings[m]` is exactly
// `to_lower(enum_field_names(x86.Mnemonic)[m])` and no copy of the table is needed.
ASM_MNEMONIC_COUNT :: 1239

asm_mnemonic_names: [ASM_MNEMONIC_COUNT]string
asm_prefix_names:   [len(Asm_Prefix)]string

// ~9 KB of lowercased mnemonic text plus the prefixes. Sized with headroom and asserted
// against at fill time, for the same reason the register buffer is: this table outlives every
// allocator in the process and must not depend on which one was installed at first use.
@(private="file") asm_name_buf:  [16384]u8
@(private="file") asm_name_used: int

// asm_mnemonic_string returns the lowercase spelling of a mnemonic, i.e. the reference's
// `mnemonic_strings[m]`. Index 0 (.INVALID) is the empty string, as it is there.
asm_mnemonic_string :: proc(m: x86.Mnemonic) -> string {
	init_asm_tables()
	i := int(m)
	if i < 0 || i >= ASM_MNEMONIC_COUNT {
		return ""
	}
	return asm_mnemonic_names[i]
}

// asm_prefix_string returns the lowercase spelling of a prefix -- `prefix_strings[p]`.
asm_prefix_string :: proc(p: Asm_Prefix) -> string {
	init_asm_tables()
	return asm_prefix_names[int(p)]
}

// asm_prefix_lookup resolves a lowercase prefix name, or .Invalid.
//
// C++ Reference: src/asm_tables_amd64.cpp:470-473. The reference's map is built skipping index
// 0 (src/asm_tables_amd64.cpp:455-458), so the empty string is not a key -- which is why the
// loop below starts after .Invalid rather than relying on "" never being passed in.
asm_prefix_lookup :: proc(name: string) -> Asm_Prefix {
	init_asm_tables()
	for p in Asm_Prefix {
		if p == .Invalid {
			continue
		}
		if asm_prefix_names[int(p)] == name {
			return p
		}
	}
	return .Invalid
}

// asm_mnemonic_lookup resolves a lowercase mnemonic, or .INVALID.
//
// C++ Reference: src/asm_tables_amd64.cpp:466-469, a StringMap over `mnemonic_strings` built
// skipping M_INVALID. A linear scan is used instead: it needs no allocator (see the note on
// init_asm_tables), and a mnemonic is looked up once per instruction in a hand-written asm
// body, which is not a hot path.
asm_mnemonic_lookup :: proc(name: string) -> x86.Mnemonic {
	init_asm_tables()
	for i in 1 ..< ASM_MNEMONIC_COUNT {
		if asm_mnemonic_names[i] == name {
			return x86.Mnemonic(i)
		}
	}
	return .INVALID
}

@(private="file")
asm_intern_lower_name :: proc(s: string) -> string {
	start := asm_name_used
	for i in 0 ..< len(s) {
		c := s[i]
		if 'A' <= c && c <= 'Z' {
			c += 'a' - 'A'
		}
		asm_name_buf[asm_name_used] = c
		asm_name_used += 1
	}
	return string(asm_name_buf[start:asm_name_used])
}

@(private="file")
init_asm_name_tables :: proc() {
	values := reflect.enum_field_values(x86.Mnemonic)
	names  := reflect.enum_field_names(x86.Mnemonic)
	assert(len(names) == ASM_MNEMONIC_COUNT, "x86.Mnemonic size disagrees with the reference's MNEMONIC_COUNT")
	for n, i in names {
		assert(int(values[i]) == i, "x86.Mnemonic is not densely numbered; the port's table indexes by value")
		// Slot 0 is INVALID, whose reference string is "".
		if i == 0 {
			asm_mnemonic_names[0] = ""
			continue
		}
		asm_mnemonic_names[i] = asm_intern_lower_name(n)
	}

	asm_prefix_names[int(Asm_Prefix.Invalid)] = ""
	for p in Asm_Prefix {
		if p == .Invalid {
			continue
		}
		pn, ok := reflect.enum_name_from_value(p)
		assert(ok, "Asm_Prefix member has no name")
		asm_prefix_names[int(p)] = asm_intern_lower_name(pn)
	}
}

// ---------------------------------------------------------------------------------------------
// The ISA-context query layer.
//
// C++ Reference: src/asm_tables_amd64.cpp:477-701 -- the const member functions of `Asm_amd64`.
// `check_asm.cpp` reaches all of these through `asm_ctx->`, where `asm_ctx` is `&g_asm_amd64`.
// The port has one target's tables and no virtual dispatch, so they are free procedures.
//
// VERIFIED, not assumed, exactly as the register/mnemonic/prefix tables above were:
//   * `x86.Operand_Type`'s 63 members were diffed against the generated `enum OperandType : u8`
//     (src/asm_tables_amd64.cpp:332-395) with the `OP_` prefix stripped. Identical, in order.
//   * `x86.Operand_Encoding`'s 12 members were diffed against `enum OperandEncoding : u8`
//     (:398-410) with `ENC_` stripped. Identical, in order.
//   * `x86.Encoding` is `#packed` and `#assert(size_of(Encoding) == 16)`, matching the C++
//     `#pragma pack(push,1) struct Encoding` and its `GB_STATIC_ASSERT(gb_size_of(Encoding)==16)`.
//     Field order and types agree member for member.
//   * `x86.Encoding_Flags` is a `bit_field u32` whose members land on exactly the bit positions
//     the C++ accessors hard-code: lock_ok at 14, rep_ok at 15, explicit_count at 18..20,
//     has_implicit at 21, op_count at 22..24. So `f.flags.explicit_count` IS
//     `form.explicit_count()`, and no shift/mask needs restating here.
// That last point matters: the C++ side reads these tables through hand-written shifts, and the
// tables themselves are emitted by the Odin generator from the bit_field. Reading the bit_field
// directly is reading the definition rather than a transcription of it.
//
// And the tables are not merely equivalent, they are the SAME BYTES. The three byte arrays in
// the generated C++ were extracted from their initialisers and md5'd against the `#load`ed
// rodata this file reads:
//
//     raw_encode_runs [1239 EncodeRun] == x86.encode_runs.bin    9912 B  01faa0194d41141370794a20e3885a18
//     raw_encode_forms[39264 u8]       == x86.encode_forms.bin  39264 B  f98ee4585e1654f9175d3e8a677c8718
//     raw_clobber_forms[39264 u8]      == x86.clobber_forms.bin 39264 B  814ba05e7531a99359c75413ae7ebb9a
//
// Identical, all three. There is no transcription step left to get wrong.
//
// One measured NON-difference, recorded so it is not re-investigated: `Encoding_Flags.op_count`
// is 0 on all 2454 forms in the shipped table -- the generator never populates it. It is dead on
// the reference side too (`Encoding::op_count()` has no caller in src/), so the port neither
// reproduces nor corrects it. `explicit_count`, `has_implicit`, `lock_ok` and `rep_ok` ARE
// populated (verified: explicit_count agrees with a recount of the ops array on 2454/2454 forms).

// C++ Reference: src/asm_tables_amd64.cpp:477-490 --
//     Slice<Encoding> encoding_forms(u16 m) const {
//         EncodeRun r = raw_encode_runs[m];
//         ...
//         return Slice<Encoding>{ENCODE_FORMS+r.start, r.count};
//     }
// `x86.encoding_forms` / `x86.clobber_forms` do precisely this, but they are `@(private)` to the
// x86 package, so the port indexes the exported rodata itself. ENCODE_RUNS is shared by both
// tables -- one run index describes the same slice of ENCODE_FORMS and of CLOBBER_FORMS, which
// is why the C++ pair reads `raw_encode_runs[m]` twice rather than keeping two run arrays.
asm_encoding_forms :: proc "contextless" (m: x86.Mnemonic) -> []x86.Encoding {
	r := x86.ENCODE_RUNS[u16(m)]
	return x86.ENCODE_FORMS[r.start:][:r.count]
}

asm_clobber_forms :: proc "contextless" (m: x86.Mnemonic) -> []x86.Clobber {
	r := x86.ENCODE_RUNS[u16(m)]
	return x86.CLOBBER_FORMS[r.start:][:r.count]
}

// C++ Reference: src/asm_tables_amd64.cpp:493-498 -- `u16 reg_size(Register r)`, which takes a
// DENSE INDEX into register_codes, not a register code. Same signature here for the same reason:
// every caller in check_asm.cpp holds a dense index (that is what register_lookup returns).
// x86.reg_size's switch is member-for-member identical to the C++ one, including ST at 80 and
// the fall-through 0 that RIP lands on.
asm_reg_size :: proc "contextless" (r: int) -> u16 {
	if r <= 0 || r >= ASM_REG_COUNT {
		return 0
	}
	return x86.reg_size(asm_register_codes[r])
}

// C++ Reference: src/asm_tables_amd64.cpp:513-544 -- `AsmOperandKind kind_from_operand_type`.
asm_kind_from_operand_type :: proc "contextless" (type: x86.Operand_Type) -> Asm_Operand_Kind {
	#partial switch type {
	case .R8, .R16, .R32, .R64,
	     .SREG, .CR, .DR,
	     .XMM, .YMM, .ZMM,
	     .MM, .K, .STI,
	     .AL_IMPL, .AX_IMPL, .EAX_IMPL, .RAX_IMPL,
	     .CL_IMPL, .DX_IMPL,
	     .ST0_IMPL, .XMM0_IMPL:
		return .Register
	case .RM8, .RM16, .RM32, .RM64,
	     .XMM_M32, .XMM_M64, .XMM_M128,
	     .YMM_M256, .ZMM_M512,
	     .MM_M64,
	     .K_M8, .K_M16, .K_M32, .K_M64:
		return .Register_Or_Memory
	case .M, .M8, .M16, .M32, .M64,
	     .M80, .M128, .M256, .M512,
	     .MOFFS8, .MOFFS16, .MOFFS32, .MOFFS64,
	     .M16_16, .M16_32, .M16_64:
		return .Memory
	case .IMM8, .IMM16, .IMM32, .IMM64,
	     .IMM8SX,
	     .ONE_IMPL,
	     .PTR16_16, .PTR16_32, .PTR16_64:
		return .Immediate
	case .REL8, .REL32:
		return .Label
	}
	// OP_NONE and anything unhandled.
	return .Invalid
}

// C++ Reference: src/asm_tables_amd64.cpp:547-587 -- `AsmRegClass reg_class_from_operand_type`.
//
// NOT the same function as `operand_type_reg_class` below, despite the near-identical name and
// the overlapping bodies. This one classifies STi/ST0 as Float and MM/MM_M64 as Vector; the
// other returns Unknown for all four. The reference keeps both and calls them from different
// places, so the port keeps both under the reference's own two names rather than merging them.
asm_reg_class_from_operand_type :: proc "contextless" (type: x86.Operand_Type) -> ast.Asm_Reg_Class {
	#partial switch type {
	case .R8, .R16, .R32, .R64,
	     .RM8, .RM16, .RM32, .RM64,
	     .AL_IMPL, .AX_IMPL, .EAX_IMPL, .RAX_IMPL,
	     .CL_IMPL, .DX_IMPL:
		return .Integer

	case .XMM, .YMM, .ZMM,
	     .XMM_M32, .XMM_M64, .XMM_M128,
	     .YMM_M256, .ZMM_M512,
	     .XMM0_IMPL:
		return .Vector

	case .K,
	     .K_M8, .K_M16, .K_M32, .K_M64:
		return .Mask

	case .STI, .ST0_IMPL:
		return .Float

	case .MM, .MM_M64:
		return .Vector
	}
	return .Unknown
}

// C++ Reference: src/asm_tables_amd64.cpp:589-599 -- `bool operand_type_is_implicit`.
asm_operand_type_is_implicit :: proc "contextless" (t: x86.Operand_Type) -> bool {
	#partial switch t {
	case .AL_IMPL, .AX_IMPL,
	     .EAX_IMPL, .RAX_IMPL,
	     .CL_IMPL, .DX_IMPL,
	     .ONE_IMPL,
	     .ST0_IMPL, .XMM0_IMPL:
		return true
	}
	return false
}

// C++ Reference: src/asm_tables_amd64.cpp:601-618 -- `AsmRegClass operand_type_reg_class`.
// See the note on asm_reg_class_from_operand_type: this variant deliberately returns Unknown
// for STi/ST0/MM/MM_M64.
asm_operand_type_reg_class :: proc "contextless" (t: x86.Operand_Type) -> ast.Asm_Reg_Class {
	#partial switch t {
	case .R8, .R16, .R32, .R64,
	     .RM8, .RM16, .RM32, .RM64,
	     .AL_IMPL, .AX_IMPL, .EAX_IMPL, .RAX_IMPL,
	     .CL_IMPL, .DX_IMPL:
		return .Integer
	case .XMM, .YMM, .ZMM,
	     .XMM_M32, .XMM_M64, .XMM_M128,
	     .YMM_M256, .ZMM_M512,
	     .XMM0_IMPL:
		return .Vector
	case .K,
	     .K_M8, .K_M16, .K_M32, .K_M64:
		return .Mask
	}
	// OP_M*, OP_IMM*, OP_REL*, OP_SREG/CR/DR/MM/STi, moffs, ptr, m16_16...: no GPR/XMM class
	// constraint here.
	return .Unknown
}

// C++ Reference: src/asm_tables_amd64.cpp:620-637 -- `u16 operand_type_bit_width`.
// The zero returns are meaningful, not a fall-through: OP_M is sizeless, OP_K's opmask width is
// data-dependent, and OP_ONE_IMPL/moffs/ptr/sreg/cr/dr carry no width. Callers test for 0.
asm_operand_type_bit_width :: proc "contextless" (t: x86.Operand_Type) -> u16 {
	#partial switch t {
	case .R8,  .RM8,  .M8,  .AL_IMPL,  .CL_IMPL, .K_M8:  return 8
	case .R16, .RM16, .M16, .AX_IMPL,  .DX_IMPL, .K_M16: return 16
	case .R32, .RM32, .M32, .EAX_IMPL, .XMM_M32, .K_M32: return 32
	case .R64, .RM64, .M64, .RAX_IMPL, .XMM_M64, .K_M64, .MM, .MM_M64: return 64
	case .M128, .XMM, .XMM_M128, .XMM0_IMPL: return 128
	case .M256, .YMM, .YMM_M256: return 256
	case .M512, .ZMM, .ZMM_M512: return 512
	case .IMM8:   return 8
	case .IMM16:  return 16
	case .IMM32:  return 32
	case .IMM64:  return 64
	case .REL8:   return 8
	case .REL32:  return 32
	case .IMM8SX: return 8
	}
	return 0
}

// C++ Reference: src/asm_tables_amd64.cpp:639-655 -- `int form_explicit_slot`.
// Maps an EXPLICIT operand index (what the user wrote) onto a SLOT index in form.ops (which also
// holds implicit operands). Returns -1 when the form has no such explicit operand. The `if (!t)
// break` is on OP_NONE, so a form's operand list is terminated by the first NONE rather than run
// to length 4.
asm_form_explicit_slot :: proc "contextless" (form: x86.Encoding, explicit_index: int) -> int {
	seen := 0
	for j in 0 ..< len(form.ops) {
		t := form.ops[j]
		if t == .NONE {
			break
		}
		if asm_operand_type_is_implicit(t) {
			continue
		}
		if seen == explicit_index {
			return j
		}
		seen += 1
	}
	return -1
}

// C++ Reference: src/asm_tables_amd64.cpp:103 -- `enum PrefixKind : u8`.
@(private="file")
Asm_Prefix_Kind :: enum u8 {
	None,
	Lock,
	Rep,
	Repne,
	Other,
}

// C++ Reference: src/asm_tables_amd64.cpp:657-687 -- `bool prefix_kind_okay`.
// `requires_memory_dest_` is an out-parameter the reference only ever WRITES true to; it is
// never cleared, so a caller that reuses one flag across several forms accumulates it. That is
// reproduced: the port takes a pointer and assigns true on the same single path.
asm_prefix_kind_okay :: proc "contextless" (prefix: Asm_Prefix, form: x86.Encoding, requires_memory_dest_: ^bool) -> bool {
	kind := Asm_Prefix_Kind.None
	if prefix != .Invalid {
		#partial switch prefix {
		case .LOCK:  kind = .Lock
		case .REP:   kind = .Rep
		case .REPNE: kind = .Repne
		case:        kind = .Other
		}
	}
	switch kind {
	case .Lock:
		if !form.flags.lock_ok {
			return false
		}
		if requires_memory_dest_ != nil {
			requires_memory_dest_^ = true
		}
		return true
	case .Rep:
		return form.flags.rep_ok
	case .Repne:
		return form.flags.rep_ok
	case .Other, .None:
		return true
	}
	return true
}

// ---------------------------------------------------------------------------------------------
// The clobber layer.
//
// C++ Reference: src/asm_tables_amd64.cpp:174-277 -- ClobberReg_*, CLOBBER_REGS_NAMED,
// clobber_bit_for_reg_name, clobber_reg_bit_name, clobber_implicit_regs, and the three
// `implies_*` predicates on `struct Clobber`.
//
// VERIFIED: `x86.Clobber_Reg`, `x86.Clobber_Flag` and `x86.Side_Effect` are declared in
// core/rexcode/isa/x86/clobber_types.odin in EXACTLY the bit order the C++ enums hard-code
// (RAX=1<<0 .. FPU_SW=1<<13; CF,PF,AF,ZF,SF,OF,DF,IF,TF; FENCE..CET), and `x86.Clobber`'s
// fields match `struct Clobber` member for member. That is not a coincidence to be relied on
// loosely -- the C++ side is generated from these very declarations, and the 39264 bytes of
// CLOBBER_FORMS are byte-identical (see the header note). So the port reads the same bits.
//
// The port carries these as `bit_set`s rather than as u16 masks. That is a representation
// change, not a semantic one: iterating an Odin bit_set yields members in ascending enum order,
// which is the same order the reference's `for (u16 bit = 1; bit != 0; bit <<= 1)` walks.

// C++ Reference: src/asm_tables_amd64.cpp:192-195 -- `CLOBBER_REGS_NAMED`.
// NOTE the omission, which is deliberate on the reference's side and is reproduced: RSP is a
// ClobberReg but is NOT in the named set, so an implicit RSP clobber is never turned into a
// user-visible register name. (VECTOR/MXCSR/FPU_ST/FPU_SW are likewise absent, and those have
// no name arm at all in clobber_reg_bit_name.)
ASM_CLOBBER_REGS_NAMED :: x86.Clobber_Regs{.RAX, .RBX, .RCX, .RDX, .RSI, .RDI, .RBP, .R11, .XMM0}

// C++ Reference: src/asm_tables_amd64.cpp:204-222 -- `u16 clobber_bit_for_reg_name`.
// Maps ANY width of an architecturally-clobbered register onto the one bit that stands for the
// whole register, so that pinning `%al` and pinning `%rax` collide. The table is exactly the
// reference's, including that `rsp`/`esp` map to a bit the named set above never reports, and
// that only `xmm0` (not xmm1..) is present.
asm_clobber_bit_for_reg_name :: proc "contextless" (pin: string) -> x86.Clobber_Regs {
	switch pin {
	case "rax", "eax", "ax", "al", "ah":     return {.RAX}
	case "rbx", "ebx", "bx", "bl", "bh":     return {.RBX}
	case "rcx", "ecx", "cx", "cl", "ch":     return {.RCX}
	case "rdx", "edx", "dx", "dl", "dh":     return {.RDX}
	case "rsi", "esi", "si", "sil":          return {.RSI}
	case "rdi", "edi", "di", "dil":          return {.RDI}
	case "rsp", "esp":                       return {.RSP}
	case "rbp", "ebp":                       return {.RBP}
	case "r11", "r11d", "r11w", "r11b":      return {.R11}
	case "xmm0":                             return {.XMM0}
	}
	return {}
}

// C++ Reference: src/asm_tables_amd64.cpp:224-238 -- `char const *clobber_reg_bit_name`.
asm_clobber_reg_bit_name :: proc "contextless" (r: x86.Clobber_Reg) -> string {
	#partial switch r {
	case .RAX:  return "rax"
	case .RBX:  return "rbx"
	case .RCX:  return "rcx"
	case .RDX:  return "rdx"
	case .RSI:  return "rsi"
	case .RDI:  return "rdi"
	case .RSP:  return "rsp"
	case .RBP:  return "rbp"
	case .R11:  return "r11"
	case .XMM0: return "xmm0"
	}
	return "<reg>"
}

// C++ Reference: src/asm_tables_amd64.cpp:317-327 -- `void clobber_implicit_regs`.
asm_clobber_implicit_regs :: proc(clobber_registers_set: ^map[string]bool, implicit_regs: x86.Clobber_Regs) {
	regs := implicit_regs & ASM_CLOBBER_REGS_NAMED
	for r in regs {
		clobber_registers_set^[asm_clobber_reg_bit_name(r)] = true
	}
}

// C++ Reference: src/asm_tables_amd64.cpp:290-295 -- `bool Clobber::implies_clobber_flags`.
// DF/IF/TF are deliberately excluded: they are mode bits a template is expected to restore,
// not arithmetic condition codes.
asm_clobber_implies_clobber_flags :: proc "contextless" (c: x86.Clobber) -> bool {
	FLAGS_MASK :: x86.Clobber_Flags{.CF, .PF, .AF, .ZF, .SF, .OF}
	return ((c.flags_wr | c.flags_undef) & FLAGS_MASK) != {}
}

// C++ Reference: src/asm_tables_amd64.cpp:296-301 -- `bool Clobber::implies_clobber_memory`.
asm_clobber_implies_clobber_memory :: proc "contextless" (c: x86.Clobber) -> bool {
	return c.writes_mem || c.reads_mem ||
		(c.side_effects & x86.Side_Effects{.FENCE, .CACHE, .SERIALIZING}) != {}
}

// C++ Reference: src/asm_tables_amd64.cpp:302-316 -- `bool Clobber::implies_side_effects`.
// HINT is excluded on purpose -- the reference's own comment says it is architecturally inert
// and may be DCE'd -- so `pause` and the prefetch family do not force a template volatile.
asm_clobber_implies_side_effects :: proc "contextless" (c: x86.Clobber) -> bool {
	VOLATILE_SE :: x86.Side_Effects{
		.FENCE, .SERIALIZING, .CACHE, .TRAP,
		.INTERRUPT, .HALT, .PRIVILEGED, .CONTROL, .CET,
	}
	return (c.side_effects & VOLATILE_SE) != {}
}
