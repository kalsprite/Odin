package rexcode_dwarf

// DWARF expressions (§2.5) -- the little stack language that answers "where is
// this variable".
//
// A location is a PROGRAM, not an address, which is what lets one attribute
// describe a variable in a register, at a fixed address, at an offset from a
// frame, or computed from several of those. This package emits the handful of
// operations a debug-build backend actually needs; the rest of the language
// exists for optimised code, where a value can be in two places at once or in
// none.

// -----------------------------------------------------------------------------
// Operations (§7.7.1, Table 7.9)
// -----------------------------------------------------------------------------

DW_OP_addr           :: u8(0x03) // an address operand, target-sized
DW_OP_deref          :: u8(0x06)
DW_OP_consts         :: u8(0x11) // SLEB
DW_OP_plus_uconst    :: u8(0x23) // ULEB
DW_OP_reg0           :: u8(0x50) // the value IS in register N
DW_OP_breg0          :: u8(0x70) // register N plus an SLEB offset
DW_OP_fbreg          :: u8(0x91) // SLEB offset from the frame base
DW_OP_call_frame_cfa :: u8(0x9c)
DW_OP_stack_value    :: u8(0x9f)

// x86-64 DWARF register numbers, in the order the psABI assigns them -- which
// is NOT the encoding order of the instruction set. RBP is 6 because the ABI
// says so, not because it is the seventh register in any table worth having.
DWREG_X86_64_RAX :: u8(0)
DWREG_X86_64_RDX :: u8(1)
DWREG_X86_64_RCX :: u8(2)
DWREG_X86_64_RBX :: u8(3)
DWREG_X86_64_RSI :: u8(4)
DWREG_X86_64_RDI :: u8(5)
DWREG_X86_64_RBP :: u8(6)
DWREG_X86_64_RSP :: u8(7)

// An expression under construction.
//
// `sym` is here rather than in a fixup list because an expression holds AT MOST
// one link-time address in practice, and the alternative -- a per-expression
// fixup array -- makes every caller manage a second lifetime for a case that
// does not arise.
Expr :: struct {
	buf:        [dynamic]u8,
	has_sym:    bool,
	sym:        u32,
	sym_offset: u32, // byte offset within `buf` of the 8-byte address
}

expr_destroy :: proc(e: ^Expr) {
	delete(e.buf)
	e.buf = nil
}

// The value is at `offset` from the frame base -- the usual shape for a local.
// What the frame base MEANS is the subprogram's own `DW_AT_frame_base`, which is
// why a variable's location says nothing about whether the function keeps a
// frame pointer.
expr_fbreg :: proc(e: ^Expr, offset: i64) {
	append(&e.buf, DW_OP_fbreg)
	put_sleb128(&e.buf, offset)
}

// The canonical frame address: the value of the stack pointer at the call site,
// before the call pushed anything. Computing it needs unwind information --
// `.eh_frame` or `.debug_frame` -- which this package does not emit, so a
// producer that has no CFI should use `expr_breg` on its frame-pointer register
// instead.
expr_call_frame_cfa :: proc(e: ^Expr) {
	append(&e.buf, DW_OP_call_frame_cfa)
}

// Register `reg` plus `offset`. `expr_breg(e, DWREG_X86_64_RBP, 16)` is the
// frame base of a function with a conventional `push rbp; mov rbp,rsp`
// prologue, and needs no unwind tables to evaluate.
expr_breg :: proc(e: ^Expr, reg: u8, offset: i64) {
	append(&e.buf, DW_OP_breg0 + reg)
	put_sleb128(&e.buf, offset)
}

// The value is IN register `reg`, not at an address it holds. A debugger asked
// to take the address of such a variable will refuse, correctly.
expr_reg :: proc(e: ^Expr, reg: u8) {
	append(&e.buf, DW_OP_reg0 + reg)
}

// A fixed address -- a global. Emitted as eight zero bytes and reported as an
// ABS64_SYM fixup when the expression is attached to a DIE.
expr_addr :: proc(e: ^Expr, sym: u32) {
	append(&e.buf, DW_OP_addr)
	e.has_sym = true
	e.sym = sym
	e.sym_offset = u32(len(e.buf))
	for _ in 0 ..< 8 {
		append(&e.buf, 0)
	}
}

expr_plus_uconst :: proc(e: ^Expr, v: u64) {
	append(&e.buf, DW_OP_plus_uconst)
	put_uleb128(&e.buf, v)
}

expr_op :: proc(e: ^Expr, op: u8) {
	append(&e.buf, op)
}

// Attach an expression to an attribute as a `DW_FORM_exprloc`.
//
// The bytes are borrowed HERE and copied by `die_add` / `die_attr_add`, so an
// `Expr` may be destroyed as soon as it has been attached. Building an Attr and
// appending it to `dies[i].attrs` by hand skips that copy.
attr_expr :: proc(at: u64, e: ^Expr) -> Attr {
	return Attr{
		at            = at,
		form          = DW_FORM_exprloc,
		block         = e.buf[:],
		block_sym     = e.has_sym,
		sym           = e.sym,
		block_sym_off = e.sym_offset,
	}
}
