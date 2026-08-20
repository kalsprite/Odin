package checker

import "core:odin/ast"
import x86 "core:rexcode/isa/x86"
import "core:math/big"
import "core:odin/tokenizer"
import "core:slice"

// C++ Reference: src/check_asm.cpp, src/asm_tables.cpp.
//
// This file is the port of the reference's inline-asm semantic analysis. The reference splits
// it across two translation units -- asm_tables.cpp holds the operand/register-class
// vocabulary and #includes the GENERATED asm_tables_amd64.cpp, and check_asm.cpp holds the
// analysis -- and is #included from check_decl.cpp:2119 rather than compiled separately.
//
// SCOPE NOTE (do not re-derive): asm_tables_amd64.cpp is generated. Its source of truth is
// core/rexcode/isa/x86 (package rexcode_x86), which is already Odin in this repository, so the
// port imports it where the reference embeds a generated table. That is why this file is much
// shorter than the two it replaces.

// C++ Reference: src/asm_tables.cpp:37-45 -- `enum AsmOperandKind : u8`.
//
// Asm_Reg_Class is NOT here: it lives in core/odin/ast (semantic_types.odin) because
// Asm_Template_Entity_Decl.reg_class needs it and that struct hangs off an Entity. The
// reference makes the same split for the same reason (src/entity.cpp:186).
Asm_Operand_Kind :: enum u8 {
	Invalid,
	Register,
	Memory,
	Register_Or_Memory,
	Immediate,
	Label,
}

// C++ Reference: src/asm_tables.cpp:10-25. Two tables, not one with an article prepended:
// "a"/"an" is baked in because the reference has no article-selection helper.
asm_reg_class_strings := [ast.Asm_Reg_Class]string {
	.Unknown = "unknown",
	.Integer = "integer",
	.Float   = "float",
	.Vector  = "vector",
	.Mask    = "mask",
}

asm_reg_class_strings_with_article := [ast.Asm_Reg_Class]string {
	.Unknown = "an unknown",
	.Integer = "an integer",
	.Float   = "a float",
	.Vector  = "a vector",
	.Mask    = "a mask",
}

// C++ Reference: src/asm_tables.cpp:47-64. The Invalid slot is the empty string in both
// tables, deliberately -- it is never formatted into a diagnostic.
asm_operand_kind_strings := [Asm_Operand_Kind]string {
	.Invalid            = "",
	.Register           = "register",
	.Memory             = "memory",
	.Register_Or_Memory = "register or memory",
	.Immediate          = "immediate",
	.Label              = "label",
}

asm_operand_kind_expected_strings := [Asm_Operand_Kind]string {
	.Invalid            = "",
	.Register           = "a register",
	.Memory             = "a memory",
	.Register_Or_Memory = "a register or memory",
	.Immediate          = "an immediate",
	.Label              = "a label",
}

// check_asm_operand_bit_width returns the bit width the operand's Odin type occupies in a
// register or immediate slot. Integers/floats/bools/pointers give their size; #simd gives the
// total vector width. 0 if unknown, -1 if untyped.
//
// C++ Reference: src/check_asm.cpp:1-18
check_asm_operand_bit_width :: proc(type: ^Type) -> i32 {
	if type == nil || type == t_invalid {
		return 0
	}
	if is_type_untyped(type) {
		return -1
	}
	if is_type_boolean(type) {
		return 1
	}
	sz := type_size_of(base_type(type))
	if sz <= 0 {
		return 0
	}
	return i32(sz * 8)
}

// C++ Reference: src/check_asm.cpp:20-37
is_valid_asm_parameter_type :: proc(type: ^Type) -> bool {
	if is_type_integer(type) {
		return true
	}
	if is_type_float(type) {
		return true
	}
	if is_type_boolean(type) {
		return true
	}
	if is_type_pointer(type) || is_type_multi_pointer(type) {
		return true
	}
	if is_type_simd_vector(type) {
		return true
	}
	return false
}

// C++ Reference: src/check_asm.cpp:39-56.
//
// NOTE the ordering: booleans are tested AFTER integers and floats, and map to Integer. A
// b8/b16/b32/b64 is not is_type_integer, so the earlier test does not swallow it.
check_asm_reg_class_from_type :: proc(type: ^Type) -> ast.Asm_Reg_Class {
	if is_type_integer(type) {
		return .Integer
	}
	if is_type_float(type) {
		return .Float
	}
	if is_type_boolean(type) {
		return .Integer
	}
	if is_type_pointer(type) || is_type_multi_pointer(type) {
		return .Integer
	}
	if is_type_simd_vector(type) {
		return .Vector
	}
	return .Unknown
}

// asm_template_entity_decl_default builds the operand declaration an asm template parameter
// gets before any [spec] has been applied to it.
//
// C++ Reference: src/entity.cpp:378-391. It lives in entity.cpp there only because that is
// where the struct is; it calls check_asm_reg_class_from_type, which is forward-declared at
// src/entity.cpp:364 and defined in check_asm.cpp. Keeping it beside its one dependency is
// the same code with one fewer forward declaration.
//
// The five -1 initialisers are load-bearing: 0 is a valid total_index/param_index, so an
// unset field must be distinguishable from index zero.
asm_template_entity_decl_default :: proc(entity: ^Entity) -> ast.Asm_Template_Entity_Decl {
	ed := ast.Asm_Template_Entity_Decl{}
	ed.kind = .Register
	if is_type_internally_pointer_like(entity_type(entity)) {
		ed.kind = .Memory
	}
	ed.reg_class    = check_asm_reg_class_from_type(entity_type(entity))
	ed.entity       = entity
	ed.total_index  = -1
	ed.param_index  = -1
	ed.result_index = -1
	ed.tie          = -1
	ed.view_of      = -1
	ed.view_bits    =  0

	return ed
}

// check_asm_pin_type_compat reports when a parameter's declared type cannot live in the
// physical register it was pinned to.
//
// C++ Reference: src/check_asm.cpp:88-116.
//
// Note the two silent returns at the top: an unknown register class, a zero-width register,
// or an absent/invalid declared type all mean "nothing can be concluded", and the reference
// deliberately says nothing rather than guessing. Likewise got_w < 0 (an untyped constant)
// skips the width test -- only got_w > 0 is a real measurement.
check_asm_pin_type_compat :: proc(
	reg_class: ast.Asm_Reg_Class,
	reg_w: i32,
	decl_type: ^Type,
	at: ^ast.Node,
	pin_name: string,
	param_name: string,
) {
	if reg_class == .Unknown ||
	   reg_w == 0 ||
	   decl_type == nil || decl_type == t_invalid {
		return
	}
	got_class := check_asm_reg_class_from_type(decl_type)
	got_w     := check_asm_operand_bit_width(decl_type)

	class_ok: bool
	#partial switch reg_class {
	case .Integer: class_ok = got_class == .Integer
	case .Vector:  class_ok = got_class == .Vector || got_class == .Float
	case .Mask:    class_ok = got_class == .Mask
	case:          class_ok = true
	}
	if !class_ok {
		error(at, "Parameter '%s' is pinned to %%%s, but its type is in the wrong register class for that register",
		      param_name, pin_name)
		return
	}
	// got_w < 0 == untyped constant: skip. Otherwise the value must fit the register.
	if got_w > 0 && got_w > reg_w {
		error(at, "Parameter '%s' (%d-bit) is wider than its pinned register %%%s (%d-bit)",
		      param_name, int(got_w), pin_name, int(reg_w))
	}
}

// check_asm_template_signature_params resolves one side (params or results) of an asm
// template's signature into a tuple, and appends one Asm_Template_Entity_Decl per name.
//
// C++ Reference: src/check_asm.cpp:374-467.
//
// Differences from the reference that are shape, not behaviour:
//   * C++ allocates the empty tuple up front and returns it on a nil field list; the port's
//     alloc_type_tuple takes the variables slice, so the variables are gathered first.
//   * C++ `ast_node_expect(name, Ast_Ident)` is inlined -- see syntax_error_node in
//     error.odin, added for exactly this call.
//
// NOTE the `continue` on an invalid parameter type: it skips the whole FIELD, so
// `asm(a, b: struct{})` declares neither a nor b and reports once. That is the reference's
// control flow and it is why param_index is only bumped inside the names loop.
check_asm_template_signature_params :: proc(
	ctx: ^Checker_Context,
	scope: ^Scope,
	_params: ^ast.Node,
	input_parameters: bool,
	asm_template_entity_decls: ^[dynamic]ast.Asm_Template_Entity_Decl,
) -> ^Type {
	if _params == nil {
		return alloc_type_tuple(nil)
	}
	field_list := _params.derived.(^ast.Field_List)

	variables := make([dynamic]^Entity, 0, len(field_list.list), ctx.checker.allocator)

	param_index: i32 = 0
	for field in field_list.list {
		// C++ Reference: src/check_asm.cpp:387-390 -- polymorphic types are DISALLOWED while
		// the parameter's type is resolved. `$T` in an asm signature is not a type parameter;
		// `$x` on a NAME is handled below and means "immediate", not "polymorphic type".
		prev := ctx.allow_polymorphic_types
		ctx.allow_polymorphic_types = false
		type := check_type(ctx, field.type)
		ctx.allow_polymorphic_types = prev

		if !is_valid_asm_parameter_type(type) {
			s := type_to_string(type)
			error(field.type, "Invalid type for an asm template. It must be an integer, float, boolean, pointer, multi-pointer, or #simd vector, got '%s'", s)
			continue
		}

		for name_ in field.names {
			name := name_

			// C++ Reference: src/check_asm.cpp:397-407
			is_poly_name := false
			#partial switch pt in name.derived {
			case ^ast.Poly_Type:
				assert(pt.specialization == nil)
				is_poly_name = true
				name = pt.type
			}

			ident, is_ident := name.derived.(^ast.Ident)
			if !is_ident {
				// C++ Reference: src/parser.cpp:666-672, ast_node_expect.
				syntax_error(name, "Expected identifier, got %s", ast_kind_string(name))
				continue
			}

			if is_blank_ident(ident.name) {
				error(name, "All parameters must have a name in an asm template")
				continue
			}
			// The port's ^ast.Ident carries only `name`; the reference's Ast_Ident carries a
			// whole Token. Every other site that needs one synthesises it the same way
			// (check_type.odin:6296), and pos/text are the only fields any consumer reads.
			name_token := tokenizer.Token{kind = .Ident, text = ident.name, pos = name.pos}

			// C++ Reference: src/check_asm.cpp:417-426. EntityFlag_Used is set
			// unconditionally: an asm parameter that no instruction mentions is still part of
			// the template's ABI, so the unused-parameter machinery must not see it.
			entity := alloc_entity_param(scope, name_token, type, false, true)
			entity.flags += {.Used}
			if is_poly_name {
				entity.flags += {.Poly_Const}
				if is_type_internally_pointer_like(type) {
					error(name, "Parameters with a pointer-like type cannot be used as $ immediates")
				}
			}

			found := scope_insert(scope, entity)
			if found == nil {
				append(&variables, entity)

				ed := asm_template_entity_decl_default(entity)
				if is_poly_name {
					ed.kind = .Immediate
				}
				if input_parameters {
					ed.param_group  = .Input
					ed.param_index  = param_index
					param_index += 1
					ed.result_index = -1
				} else {
					ed.param_group  = .Output
					ed.param_index  = -1
					ed.result_index = param_index
					param_index += 1
				}

				ed.total_index = i32(len(asm_template_entity_decls))
				append(asm_template_entity_decls, ed)
			} else {
				pos := found.token.pos
				error(name_token,
				      "Redeclaration of '%s' in this scope\n" +
				      "\tat %s",
				      name_token.text, token_pos_to_string(pos))
				entity = found
			}
		}
	}

	return alloc_type_tuple(variables[:])
}

// C++ Reference: src/check_asm.cpp:469-479
check_asm_find_group :: proc(
	entity: ^Entity,
	asm_template_entity_decls: []ast.Asm_Template_Entity_Decl,
	index_: ^i32 = nil,
) -> ast.Asm_Template_Entity_Decl_Param_Group {
	for ed, i in asm_template_entity_decls {
		if ed.entity == entity {
			if index_ != nil {
				index_^ = i32(i)
			}
			return ed.param_group
		}
	}
	if index_ != nil {
		index_^ = -1
	}
	return .Unknown
}

// C++ Reference: src/check_asm.cpp:481-488
check_asm_find_kind :: proc(
	entity: ^Entity,
	asm_template_entity_decls: []ast.Asm_Template_Entity_Decl,
) -> ast.Asm_Template_Entity_Decl_Kind {
	for ed in asm_template_entity_decls {
		if ed.entity == entity {
			return ed.kind
		}
	}
	return .Invalid
}

// asm_did_you_mean_append mirrors did_you_mean_append (src/common.cpp), which SKIPS empty
// targets and "_" before scoring. check_asm.cpp builds its suggestion lists inline rather than
// through check_did_you_mean_type, and -- unlike the check_expr.cpp helpers -- it carries NO
// build_context.terse_errors guard, so none is added here.
@(private="file")
asm_did_you_mean_append :: proc(suggestions: ^[dynamic]Distance_And_Target, key: string, target: string) {
	if len(target) == 0 || target == "_" {
		return
	}
	append(suggestions, Distance_And_Target{levenshtein_distance(key, target), target})
}

// check_register resolves a `%reg` (or `%flags.<flag>`) operand and gives it a type.
//
// C++ Reference: src/check_asm.cpp:760-843.
//
// Returns false when the register could not be resolved; the caller keeps checking either way,
// which is why the flag path returns `ok` rather than bailing at the first error.
//
// DIVERGENCE, DELIBERATE -- `%rip`. The reference reaches
//     default: GB_PANIC("Unhandled register width size: %d", width_in_bits);
// for it, because %rip IS in the register table (code 0xFFFE) but its class 0xFF00 is not one
// of the sixteen the width switch knows, so reg_size returns 0. `mov %rip, %rax` and
// `mov %rax, [%rip + 8]` both abort the compiler with SIGILL, exit 132, printing nothing but
// "This is a compiler error". Reproduced on 1a808b4a4 and filed as
// COMPILER_ISSUES/UPSTREAM-UNFILED-asm-template-referencing-rip-panics-the-compiler.md.
// Jon's standing ruling is that a reference quirk is the contract EXCEPT when it is a crash,
// so the port diagnoses it instead, in the shape of the reference's own adjacent arm for the
// 80-bit x87 registers.
check_register :: proc(operand: ^Operand, asm_reg: ^ast.Asm_Register) -> bool {
	init_asm_tables()
	name := asm_reg.name.text

	// C++ Reference: src/check_asm.cpp:762-784 -- the `%flags.<flag>` accessor form.
	if asm_reg.flag.kind == .Ident {
		ok := true
		width: i32 = 0

		flag := asm_reg.flag.text
		if name != "flags" {
			error(asm_reg.name, "Register flags can only be called on %%flags")
			ok = false
		} else {
			bit := asm_flag_bit_from_name(flag, &width)
			if bit < 0 {
				error(asm_reg.flag, "Unknown register %%flags name: %s", flag)
				ok = false
			}
		}

		// A single flag bit is a bool; the one multi-bit field (iopl, 2 bits) is a u8.
		// NOTE that this is assigned even on the error paths, where width stays 0 -- the
		// operand still needs a type so that checking can continue.
		operand.type = t_bool
		if width > 1 {
			operand.type = t_u8
		}
		return ok
	}

	r := asm_register_lookup(name)
	if r != 0 {
		operand.mode = .Value

		// C++ Reference: src/check_asm.cpp:790-795 has an opmask special case here whose body
		// is entirely commented out ("classify as a mask, not a 64-bit integer" / "see note if
		// this type does not yet exist"). It is reproduced as a comment rather than as code
		// because there is nothing to reproduce. Worth recording that its one live line,
		// `asm_ctx->reg_class(r)`, passes the DENSE INDEX to a function that masks 0xFF00 off a
		// register CODE -- reg_size(r) right below correctly writes reg_class(register_codes[r])
		// -- so the value it computes is meaningless. No observable effect, since the block it
		// guards is empty.

		width_in_bits := u16(0)
		code := asm_register_codes[r]
		switch x86.reg_class(code) {
		case x86.REG_GPR64:                 width_in_bits = 64
		case x86.REG_GPR32:                 width_in_bits = 32
		case x86.REG_GPR16:                 width_in_bits = 16
		case x86.REG_GPR8, x86.REG_GPR8H:   width_in_bits = 8
		case x86.REG_XMM:                   width_in_bits = 128
		case x86.REG_YMM:                   width_in_bits = 256
		case x86.REG_ZMM:                   width_in_bits = 512
		case x86.REG_K:                     width_in_bits = 64
		case x86.REG_MM:                    width_in_bits = 64
		case x86.REG_ST:                    width_in_bits = 80
		case x86.REG_SEG:                   width_in_bits = 16
		case x86.REG_CR, x86.REG_DR:        width_in_bits = 64
		case x86.REG_BND:                   width_in_bits = 128
		}

		switch width_in_bits {
		case 8:
			operand.type = t_u8
		case 16:
			operand.type = t_u16
		case 32:
			operand.type = t_u32
		case 64:
			operand.type = t_u64
		case 80:
			error(operand.expr, "80-bit width asm registers are not supported")
			return false
		case 128:
			operand.type = alloc_type_simd_vector(4, t_f32)
		case 256:
			operand.type = alloc_type_simd_vector(8, t_f32)
		case 512:
			operand.type = alloc_type_simd_vector(16, t_f32)
		case:
			// See the DIVERGENCE note above: this is the reference's GB_PANIC arm, and %rip is
			// the only input that reaches it.
			error(operand.expr, "Asm registers with no defined width are not supported: %%%s", name)
			return false
		}

		return true
	}

	// C++ Reference: src/check_asm.cpp:830-842
	begin_error_block()
	defer end_error_block()
	error(asm_reg.name, "Unknown register for this target platform: %%%s", name)
	{
		suggestions: [dynamic]Distance_And_Target
		defer delete(suggestions)
		// The reference iterates its StringMap, i.e. in HASH order; the port walks the dense
		// table in REGISTER order. Both feed the same unstable sort, so this can only differ
		// between two candidates that tie on edit distance. Recorded rather than hidden.
		for i in 1 ..< ASM_REG_COUNT {
			asm_did_you_mean_append(&suggestions, name, asm_register_names[i])
		}
		check_did_you_mean_print(did_you_mean_results(&suggestions))
	}
	return false
}

// C++ Reference: src/check_asm.cpp:844-848
Check_Mnemonic_Result :: enum {
	Invalid,
	Mnemonic,
	Prefix,
}

// check_mnemonic_name resolves an instruction's leading identifier to a prefix or a mnemonic.
//
// C++ Reference: src/check_asm.cpp:850-884.
//
// NOTE the asymmetry in the failure path, which is not a slip: an instruction WITH operands
// cannot be a prefix (prefixes take none), so its diagnostic says "mnemonic" and its suggestion
// list omits the prefixes. Only the no-operand form says "mnemonic/prefix" and offers both.
check_mnemonic_name :: proc(instr: ^ast.Asm_Instruction, mnemonic_: ^u16 = nil) -> Check_Mnemonic_Result {
	init_asm_tables()
	ident := instr.name.derived.(^ast.Ident)
	name := ident.name

	if p := asm_prefix_lookup(name); p != .Invalid {
		if mnemonic_ != nil {
			mnemonic_^ = u16(p)
		}
		return .Prefix
	}
	if m := asm_mnemonic_lookup(name); m != .INVALID {
		if mnemonic_ != nil {
			mnemonic_^ = u16(m)
		}
		return .Mnemonic
	}

	begin_error_block()
	defer end_error_block()
	if len(instr.operands) == 0 {
		error(instr.name, "Unknown mnemonic/prefix for this target platform: %s", name)
	} else {
		error(instr.name, "Unknown mnemonic for this target platform: %s", name)
	}

	suggestions: [dynamic]Distance_And_Target
	defer delete(suggestions)
	{
		// C++ Reference: src/check_asm.cpp:871-875 -- every mnemonic string EXCEPT M_INVALID.
		for i in 1 ..< ASM_MNEMONIC_COUNT {
			asm_did_you_mean_append(&suggestions, name, asm_mnemonic_string(x86.Mnemonic(i)))
		}
	}
	if len(instr.operands) == 0 {
		for p in Asm_Prefix {
			if p == .Invalid {
				continue
			}
			asm_did_you_mean_append(&suggestions, name, asm_prefix_string(p))
		}
	}
	check_did_you_mean_print(did_you_mean_results(&suggestions))
	return .Invalid
}

// check_asm_specs resolves the `[...]` specification list of an asm template: scratch operand
// declarations, register pins, width-views, and input/output ties.
//
// C++ Reference: src/check_asm.cpp:491-757.
//
// The reference is `template <typename AsmCtx>` and threads an `asm_ctx` through purely to
// reach check_register. The port targets amd64 only -- parse_asm_template rejects every other
// target at src/parser.cpp:2782-2784, which the port reproduces -- so the ISA is resolved
// statically by check_asm_tables.odin and the parameter is not needed.
//
// The shape is one loop over the specs with THREE mutually exclusive bodies, selected by which
// of `tied_name` and `type` is present:
//   * tied_name != nil            -> an input/output tie: `in -> out`.
//   * tied_name == nil, type      -> a NEW scratch declaration: `s: u64`, `s: u8 = p0`.
//   * tied_name == nil, no type   -> a pin on an EXISTING parameter: `p0 = %rax`.
// `value` is parsed for all three before the split, because all three can carry `= %reg`.
check_asm_specs :: proc(
	ctx: ^Checker_Context,
	scope: ^Scope,
	specs: []^ast.Expr,
	asm_template_entity_decls: ^[dynamic]ast.Asm_Template_Entity_Decl,
) {
	pin_set := make(map[string]bool, allocator = context.temp_allocator)
	defer delete(pin_set)

	pin_flag_set := make(map[string]bool, allocator = context.temp_allocator)
	defer delete(pin_flag_set)

	for spec_ in specs {
		// C++ Reference: src/check_asm.cpp:500-505 -- the list also holds Asm_Clobber nodes,
		// which are handled by check_asm_template, not here.
		spec, is_spec := spec_.derived.(^ast.Asm_Spec)
		if !is_spec {
			continue
		}

		name_ident := spec.name.derived.(^ast.Ident)

		input := scope_lookup_current(scope, name_ident.name)
		other_scratch: ^Entity = nil

		pin: string
		pin_flag: string
		pin_reg_class := ast.Asm_Reg_Class.Unknown
		pin_reg_w: i32 = 0

		if spec.value != nil {
			if value_ident, is_ident := spec.value.derived.(^ast.Ident); is_ident {
				other_scratch = scope_lookup_current(scope, value_ident.name)
				if other_scratch != nil {
					group := check_asm_find_group(other_scratch, asm_template_entity_decls[:])
					// C++ writes `if (!group)`, i.e. the .Unknown member (value 0) is the
					// falsy one -- "this name resolved, but it is not one of my operands".
					if group == .Unknown {
						error(spec.value, "This must be another parameter, got %s", other_scratch.token.text)
					}
				} else {
					error(spec.value, "Undefined parameter declaration '%s'", value_ident.name)
				}
			} else {
				reg, is_reg := spec.value.derived.(^ast.Asm_Register)
				if !is_reg {
					s := expr_to_string(spec.value)
					error(spec.value, "Expected an asm register or scratch parameter, got %s", s)
					continue
				}

				pin = reg.name.text
				if len(pin) != 0 {
					op := Operand{}
					op.expr = spec.value
					if check_register(&op, reg) {
						if len(reg.flag.text) != 0 {
							assert(pin == "flags")
							pin_flag = reg.flag.text
							if pin_flag in pin_flag_set {
								error(spec.value, "Pinned register flag %%%s.%s has already been assigned", pin, pin_flag)
							}
							pin_flag_set[pin_flag] = true
						}
						// NOTE the ordering: `%flags` itself is exempt from the
						// already-assigned test, because several specs may each pin a
						// DIFFERENT flag bit of the one flags register.
						already := pin in pin_set
						pin_set[pin] = true
						if already && pin != "flags" {
							error(spec.value, "Pinned register %%%s has already been assigned", pin)
						}
						if len(reg.flag.text) == 0 {
							pin_reg_class = check_asm_reg_class_from_type(op.type)
							pin_reg_w     = check_asm_operand_bit_width(op.type)
						}
					}
				}
			}
		}

		if spec.tied_name == nil {
			if spec.type != nil {
				// ---- a NEW scratch operand declaration ----
				// C++ Reference: src/check_asm.cpp:558-658
				type := check_type(ctx, spec.type)
				if !is_valid_asm_parameter_type(type) {
					s := type_to_string(type)
					error(spec.type, "Invalid type for an asm template. It must be an integer, float, boolean, pointer, multi-pointer, or #simd vector, got '%s'", s)
					continue
				}

				name_token := tokenizer.Token{kind = .Ident, text = name_ident.name, pos = spec.name.pos}

				entity := alloc_entity_param(scope, name_token, type, false, true)
				entity.flags += {.Used}

				found := scope_insert(scope, entity)
				if found == nil {
					ed := asm_template_entity_decl_default(entity)
					ed.param_group = .Scratch
					ed.total_index = i32(len(asm_template_entity_decls))
					ed.pin         = pin
					ed.pin_flag    = pin_flag
					if len(pin) != 0 {
						check_asm_pin_type_compat(pin_reg_class, pin_reg_w, type, spec.value, pin, name_ident.name)
					}

					if other_scratch != nil {
						// Width-view of another operand: `p0b: u8 = p0`.
						// p0b shares p0's register, viewed at p0b's declared width.
						assert(spec.value != nil)

						src_index: i32 = -1
						src_group := check_asm_find_group(other_scratch, asm_template_entity_decls[:], &src_index)

						// 1. The source must already exist and be a register-class operand
						//    (you cannot take a width-view of an immediate or memory operand).
						if src_index < 0 {
							error(spec.value, "'%s' must refer to a previously declared parameter", other_scratch.token.text)
						} else {
							src := &asm_template_entity_decls[src_index]

							src_is_reg := src_group == .Input || src_group == .Output || src_group == .Scratch
							if src.kind == .Immediate || src.kind == .Memory {
								src_is_reg = false
							}
							if !src_is_reg {
								error(spec.value, "A width-view can only be taken of a register operand, not '%s'", other_scratch.token.text)
							}

							// 2. The view width must be a legal sub-register width and no wider
							//    than the source (only narrowing views exist).
							view_w := check_asm_operand_bit_width(type)                        // this decl's type (u8 -> 8)
							src_w  := check_asm_operand_bit_width(entity_type(src.entity))
							view_class := check_asm_reg_class_from_type(type)
							src_class  := check_asm_reg_class_from_type(entity_type(src.entity))

							if view_class != .Integer || src_class != .Integer {
								error(spec.type, "Width-views are only supported for integer registers")
							} else {
								switch view_w {
								case 8, 16, 32, 64:
									if view_w > src_w {
										error(spec.type, "A width-view (%d-bit) cannot be wider than its source '%s' (%d-bit)",
										      int(view_w), other_scratch.token.text, int(src_w))
									}
								case:
									error(spec.type, "A width-view must be an 8, 16, 32, or 64-bit integer type, got a %d-bit type", int(view_w))
								}
							}

							// 3. A view does not carry its own pin; it inherits the source's register.
							if len(pin) != 0 {
								error(spec.value, "A width-view cannot also be pinned to a register; it inherits the source operand's register")
							}

							ed.kind      = .Register
							ed.view_of   = src_index
							ed.view_bits = view_w
							// A view is not itself an input/output/scratch slot for allocation:
							// mark it so the lowering passes skip it. Reuse the Scratch group but
							// with view_of >= 0 as the discriminator (see lowering note).
						}
					}

					append(asm_template_entity_decls, ed)
				} else {
					pos := found.token.pos
					error(name_token,
					      "Redeclaration of '%s' in this scope\n" +
					      "\tat %s",
					      name_token.text, token_pos_to_string(pos))
					continue
				}
			} else if input == nil {
				error(spec.name, "Undefined parameter declaration '%s'", name_ident.name)
				continue
			} else {
				// ---- a pin on an EXISTING parameter ----
				// C++ Reference: src/check_asm.cpp:663-684
				index: i32 = -1
				group := check_asm_find_group(input, asm_template_entity_decls[:], &index)
				assert(index >= 0)
				i := &asm_template_entity_decls[index]
				if len(i.pin) == 0 {
					i.pin = pin
					i.pin_flag = pin_flag
					if len(pin_flag) != 0 && group != .Output {
						error(spec.value, "Input parameters cannot be pinned to a flag style register")
					} else if len(pin) != 0 && len(pin_flag) == 0 {
						check_asm_pin_type_compat(pin_reg_class, pin_reg_w, entity_type(input), spec.value, pin, input.token.text)
					}
				} else {
					error(spec_, "Asm register has already been pinned")
				}

				if other_scratch != nil {
					assert(spec.value != nil)
					error(spec.value, "Another parameter must be assigned/paired with a scratch parameter declaration")
				}
			}
		} else {
			// ---- an input/output tie ----
			// C++ Reference: src/check_asm.cpp:685-756
			tied_ident := spec.tied_name.derived.(^ast.Ident)

			if spec.type != nil {
				error(spec.type, "Tied register definitions cannot have a defined type since the values are already defined")
			}

			if input == nil {
				error(spec.name, "Undefined parameter declaration '%s'", name_ident.name)
				continue
			}
			output := scope_lookup_current(scope, tied_ident.name)
			if output == nil {
				// NOTE, not a slip: the reference reports spec->name here, not the tied name,
				// so an unresolvable OUTPUT is blamed on the input's identifier.
				error(spec.name, "Undefined parameter declaration '%s'", name_ident.name)
				continue
			}

			input_index:  i32 = -1
			output_index: i32 = -1

			input_group  := check_asm_find_group(input,  asm_template_entity_decls[:], &input_index)
			output_group := check_asm_find_group(output, asm_template_entity_decls[:], &output_index)
			if input_group != .Input {
				error(input.token, "Parameter tied with '%s' must be an input parameter", output.token.text)
				continue
			}
			if output_group != .Output {
				error(output.token, "Parameter tied with '%s' must be an output parameter", input.token.text)
				continue
			}

			assert(input_index >= 0)
			assert(output_index >= 0)

			i := &asm_template_entity_decls[input_index]
			o := &asm_template_entity_decls[output_index]

			i.tie = output_index
			o.tie = input_index

			i.pin = pin
			o.pin = pin
			if len(pin) != 0 {
				check_asm_pin_type_compat(pin_reg_class, pin_reg_w, entity_type(input),  spec.value, pin, input.token.text)
				check_asm_pin_type_compat(pin_reg_class, pin_reg_w, entity_type(output), spec.value, pin, output.token.text)
			}
			// Tied parameters share one physical register, so they must be the same register
			// family (both integer, or both vector/float). Width may legitimately differ (a
			// narrow read feeding a wide write), so width is intentionally NOT checked.
			{
				ic := check_asm_reg_class_from_type(entity_type(input))
				oc := check_asm_reg_class_from_type(entity_type(output))
				i_int := ic == .Integer
				o_int := oc == .Integer
				i_vec := ic == .Vector || ic == .Float
				o_vec := oc == .Vector || oc == .Float
				if (i_int && o_vec) || (i_vec && o_int) {
					error(spec.name, "Tied parameters '%s' and '%s' share a register but are in different register classes",
					      input.token.text, output.token.text)
				}
			}

			if other_scratch != nil {
				assert(spec.value != nil)
				error(spec.value, "Another parameter must be assigned/paired with a scratch parameter declaration, not a tie")
			}

			if len(pin_flag) != 0 {
				error(spec.value, "Input parameters, and thus tied parameters, cannot be pinned to a flag style register")
			}
		}
	}
}

// C++ Reference: src/check_asm.cpp:58-86.
//
// Classifies a CHECKED operand by what it is, for matching against an encoding form's slot.
// The `expr->tav.mode` test is the reference's, comment and all -- it reads the type-and-value
// recorded on the node rather than operand->mode, which is why an Ident that resolved to a
// constant is an immediate even though the operand itself was not marked constant.
determine_asm_operand_kind :: proc(info: ^Checker_Info, operand: ^Operand) -> Asm_Operand_Kind {
	if operand.mode == .Constant {
		return .Immediate
	}
	expr := operand.expr
	if expr == nil {
		return .Invalid
	}
	#partial switch e in expr.derived {
	case ^ast.Asm_Label_Decl:
		return .Label
	case ^ast.Asm_Register:
		return .Register
	case ^ast.Asm_Memory_Operand:
		return .Memory
	case ^ast.Ident:
		// TODO(bill): Is this correct?
		// C++ reads `expr->tav.mode` -- the type-and-value recorded ON THE NODE, not
		// operand->mode. The port's ast.Node carries the same field (ast.odin:111).
		if expr.tav.mode == .Constant {
			return .Immediate
		}
		en := entity_of_node(info, expr)
		if en != nil && en.kind == .Variable && .Poly_Const in en.flags {
			return .Immediate
		}
		return .Register
	}
	return .Invalid
}

// C++ Reference: src/check_asm.cpp:149-156
Asm_Mismatch :: enum u8 {
	None,
	Size,      // register / vector width mismatch
	Class,     // register class mismatch
	Imm_Range, // constant immediate does not fit the slot width
	Imm_Type,  // non-integer constant where an integer immediate is required
}

// check_asm_immediate_value_fits asks whether a constant immediate fits a slot of `bits`
// width (0 == unconstrained). It accepts either a signed or an unsigned reading of the bit
// pattern, which matches how the assembler treats imm fields -- both 200 and -56 fit imm8.
//
// C++ Reference: src/check_asm.cpp:160-216.
//
// `needed_` is what the diagnostic prints, and it is NOT simply the magnitude width: for a
// negative value the reference reports the SIGNED width, mp_count_bits(-v-1) + 1.
check_asm_immediate_value_fits :: proc(ev: Exact_Value, bits: i32, needed_: ^i32 = nil, mismatch_: ^Asm_Mismatch = nil) -> bool {
	ev := ev
	bits := bits
	if _, is_float := ev.(f64); is_float {
		// Try to convert it if possible to an integer
		ev = exact_value_to_integer(ev)
	}

	switch v in ev {
	case bool:
		// Encodes as 0 or 1; fits any immediate slot with a non-zero width.
		if needed_ != nil {
			needed_^ = 1
		}
		return true

	case big.Int:
		bi := v
		mag_bits_int, _ := big.count_bits(&bi)
		mag_bits := i32(mag_bits_int)
		if needed_ != nil {
			needed_^ = mag_bits
		}

		if bits == 0 {
			// TODO(bill): is this a decent width?!
			bits = 64 // slot does not pin a width, just set a decent default
		}
		if is_zero, _ := big.is_zero(&bi); is_zero {
			return true
		}
		if neg, _ := big.is_neg(&bi); !neg {
			// Non-negative: fits if the unsigned bit pattern is <= `bits` wide.
			if mag_bits <= bits {
				return true
			}
		} else {
			// Negative: fits signed in `bits` iff count_bits(-v - 1) <= bits-1.
			// (-v-1 ranges 0 .. 2^(bits-1)-1 for the representable negatives.)
			tmp := &big.Int{}
			defer big.destroy(tmp)
			big.neg(tmp, &bi)         // tmp = -v  (positive magnitude)
			big.sub(tmp, tmp, 1)      // tmp = -v - 1
			nb_int, _ := big.count_bits(tmp)
			nb := i32(nb_int)
			if needed_ != nil {
				needed_^ = nb + 1 // signed bit-width, for the diagnostic
			}
			if nb <= bits - 1 {
				return true
			}
		}
		if mismatch_ != nil {
			mismatch_^ = .Imm_Range
		}
		return false

	case f64:
		// TODO(bill): does any architecture support floating-point immediates?
		// amd64 has no floating-point instruction immediates.
		if needed_ != nil {
			needed_^ = 0
		}
		if mismatch_ != nil {
			mismatch_^ = .Imm_Type
		}
		return false

	case complex128, string, quaternion256, Exact_Value_Pointer, Exact_Value_Compound,
	     Exact_Value_Procedure, Exact_Value_Typeid, Exact_Value_String16:
		// falls through to the shared tail below

	case:
		// nil -- likewise
	}
	if mismatch_ != nil {
		mismatch_^ = .Imm_Type
	}
	return false
}

// C++ Reference: src/check_asm.cpp:334-340
Asm_Addr_Role :: enum {
	Base,
	Index,
}

// check_asm_addr_register validates the base or index register of a memory operand.
//
// C++ Reference: src/check_asm.cpp:342-372.
//
// `width_` is written BEFORE any of the rejections, so the caller's base/index width
// comparison still has both numbers even when one side was rejected.
check_asm_addr_register :: proc(operand: ^Operand, role: Asm_Addr_Role, reg_name: string, width_: ^i32 = nil) -> bool {
	role_name := "base" if role == .Base else "index"

	cls := check_asm_reg_class_from_type(operand.type)
	w   := check_asm_operand_bit_width(operand.type)
	if width_ != nil {
		width_^ = w
	}

	if cls != .Integer {
		got := "non-integer"
		if cls == .Vector {
			got = "vector"
		} else if cls == .Mask {
			got = "mask"
		}
		error(operand.expr, "A memory operand's %s must be an integer register, got a %s value", role_name, got)
		return false
	}
	if w != 32 && w != 64 {
		error(operand.expr, "A memory operand's %s must be a 32-bit or 64-bit register, got a %d-bit register", role_name, int(w))
		return false
	}
	if role == .Index && len(reg_name) != 0 {
		// rsp/esp cannot be encoded as an index register.
		if reg_name == "rsp" || reg_name == "esp" {
			error(operand.expr, "%%%s cannot be used as an index register", reg_name)
			return false
		}
	}
	return true
}

// check_asm_collect_refs walks an operand expression and records every entity it names, plus a
// mask of the physical registers it touches.
//
// C++ Reference: src/check_asm.cpp:122-148.
//
// The two outputs answer two different "is this declared parameter actually used?" questions,
// which is why one walk produces both. An identifier operand refers to a parameter directly. A
// parameter that was PINNED to a register, on the other hand, is written in the body as that
// register -- `%rax`, not the name -- so the only trace it leaves is the register bit. The
// unused check maps decl pins back through that mask.
//
// Note the walk is deliberately shallow: it recurses through a memory operand's five sub-
// expressions and stops. It does not descend into arbitrary expressions, because an asm operand
// is one of Ident / Asm_Register / Asm_Memory_Operand / a constant, and nothing else can name
// an entity or touch a register.
check_asm_collect_refs :: proc(refs: ^map[^Entity]bool, expr: ^ast.Expr, touched_regs_: ^x86.Clobber_Regs = nil) {
	if expr == nil {
		return
	}
	#partial switch e in expr.derived {
	case ^ast.Ident:
		if e.entity != nil {
			refs^[e.entity] = true
		}
		return
	case ^ast.Asm_Register:
		// A literal %reg touches a physical register. A pinned scratch/immediate is
		// referenced in the body via its pinned register, not its identifier, so record
		// the bit; the unused check maps decl pins back through this mask.
		if touched_regs_ != nil {
			touched_regs_^ |= asm_clobber_bit_for_reg_name(e.name.text)
		}
		return
	case ^ast.Asm_Memory_Operand:
		check_asm_collect_refs(refs, e.segment_override, touched_regs_)
		check_asm_collect_refs(refs, e.base,             touched_regs_)
		check_asm_collect_refs(refs, e.index,            touched_regs_)
		check_asm_collect_refs(refs, e.scale,            touched_regs_)
		check_asm_collect_refs(refs, e.disp,             touched_regs_)
		return
	}
}

// check_asm_operand_size_class asks whether an operand's Odin type is size/class-compatible with
// one encoding form's slot. On mismatch it fills `mismatch_` so the caller can print a precise
// diagnostic rather than a bare "no matching form".
//
// `slot` is the resolved Operand_Type at the correct (implicit-skipped) slot -- the caller has
// already been through asm_form_explicit_slot.
//
// C++ Reference: src/check_asm.cpp:218-330.
check_asm_operand_size_class :: proc(
	info: ^Checker_Info,
	slot: x86.Operand_Type,
	operand: ^Operand,
	mismatch_: ^Asm_Mismatch = nil,
	want_bits_: ^i32 = nil,
	got_bits_: ^i32 = nil,
) -> bool {
	if mismatch_ != nil {
		mismatch_^ = .None
	}

	slot_kind := asm_kind_from_operand_type(slot)
	if slot_kind == .Immediate {
		want_w := i32(asm_operand_type_bit_width(slot))   // 32 for OP_IMM32
		if want_bits_ != nil {
			want_bits_^ = want_w
		}
		if operand.mode != .Constant {
			return true   // $-immediate, bound per instantiation; defer
		}
		needed := i32(0)
		ev := operand.value
		ok := check_asm_immediate_value_fits(ev, want_w, &needed, mismatch_)
		if got_bits_ != nil {
			got_bits_^ = needed
		}
		return ok
	}

	// Register / memory-sized slots
	want_class := asm_operand_type_reg_class(slot)
	want_w     := i32(asm_operand_type_bit_width(slot))

	// A pure-label / sizeless slot imposes no reg width/class.
	if want_class == .Unknown && want_w == 0 {
		return true
	}

	// Determine the type whose width/class we actually measure.
	//
	// Memory operands encode their *access* type as a pointer: `[p]:u8` -> `^u8`,
	// with a bare `rawptr` meaning "unsized" (no explicit `:type` annotation). A
	// register/immediate/parameter operand measures its own type directly.
	measured  := operand.type
	is_memory := determine_asm_operand_kind(info, operand) == .Memory
	if is_memory {
		if are_types_identical(measured, t_rawptr) {
			// Unsized memory operand: the width is inferred elsewhere (from the
			// register operand or deferred), so nothing to check against here.
			if want_bits_ != nil {
				want_bits_^ = want_w
			}
			return true
		}
		measured = type_deref(measured) // ^u8 -> u8
	}

	got_class := check_asm_reg_class_from_type(measured)
	got_w     := check_asm_operand_bit_width(measured)
	if got_w < 0 {
		// Untyped constant: width is a property of the value, not the type.
		if bi, is_int := operand.value.(big.Int); operand.mode == .Constant && is_int {
			bi := bi
			n, _ := big.count_bits(&bi)
			got_w = i32(n)
			if got_w == 0 {
				got_w = 1 // zero still occupies a slot
			}
		} else {
			got_w = 0 // unknown; skip the width comparison rather than fake a pass
		}
	}
	if want_bits_ != nil {
		want_bits_^ = want_w
	}
	if got_bits_ != nil {
		got_bits_^ = got_w
	}

	// Class check (only when the slot constrains a class).
	//
	// A *memory* operand against a register-or-memory slot (e.g. OP_XMM_M64) has no
	// lane semantics -- it is just N bytes of memory -- so its integer/vector class
	// must not be held against the slot's register class. Only width matters for the
	// memory interpretation. Register operands still get the full class check.
	if want_class != .Unknown && !is_memory {
		class_ok: bool
		#partial switch want_class {
		case .Integer:
			class_ok = got_class == .Integer
		case .Vector:
			// A scalar float uses only the low lane, so it is valid in any vector
			// register slot; a #simd vector matches the vector class exactly.
			class_ok = got_class == .Vector || got_class == .Float
		case .Mask:
			class_ok = got_class == .Mask
		case:
			class_ok = true
		}
		if !class_ok {
			if mismatch_ != nil {
				mismatch_^ = .Class
			}
			return false
		}
	}

	// Width check.
	if want_w != 0 && got_w != 0 {
		if want_class == .Vector && !is_memory {
			// A scalar float uses only the low lane, so it is valid in any vector
			// register slot as long as it fits; a #simd vector must match exactly.
			width_ok := got_w <= want_w if got_class == .Float else got_w == want_w
			if !width_ok {
				if mismatch_ != nil {
					mismatch_^ = .Size
				}
				return false
			}
		} else {
			// Integer/mask registers, and all memory operands: exact width.
			if want_w != got_w {
				if mismatch_ != nil {
					mismatch_^ = .Size
				}
				return false
			}
		}
	}
	return true
}

// Asm_Mnemonic_Accumulator is the per-template state check_mnemonic threads through the body's
// instructions in textual order. It is what turns a sequence of independent per-instruction
// checks into a linear data-flow model: which registers have been defined so far, which outputs
// have gone stale, whether flow is still straight-line.
//
// C++ Reference: src/check_asm.cpp:887-909 -- `struct AsmMnemonicAccumulator`.
//
// The reference's u16 masks are `bit_set`s here; see the note in check_asm_tables.odin on why
// that is a representation change and not a semantic one.
Asm_Mnemonic_Accumulator :: struct {
	defined_regs: x86.Clobber_Regs,

	// Union of registers implicitly clobbered by matched forms (for redundant-#clobber hints).
	implicit_clobbered_regs: x86.Clobber_Regs,

	straight_line: bool,

	// Whether the most-recently-checked instruction terminates straight-line flow.
	// Reset to false at every label (a label starts a fresh straight-line region whose
	// tail we haven't seen yet). Consulted after the loop for #diverging templates.
	last_is_terminal: bool,

	// Did the template contain any instructions at all? An empty diverging body can't diverge.
	saw_any_instructions: bool,

	explicitly_produced_regs: x86.Clobber_Regs,
	stale_outputs:            x86.Clobber_Regs,

	// #align_stack relevance: any call/branch (CONTROL) or memory effect that could
	// require the stack to be realigned. If none occurred, #align_stack is redundant.
	saw_call_or_mem: bool,
}

// check_mnemonic resolves ONE instruction against the encoding table: it picks the form whose
// operand slots the written operands satisfy, records the consequences of that form on the
// template entity (clobbers, volatility, straight-line state), and on failure produces the
// per-operand diagnostics that say exactly which slot went wrong and how.
//
// C++ Reference: src/check_asm.cpp:912-1266.
//
// Three things here are easy to get wrong by tidying, so they are called out rather than left
// to be rediscovered:
//
//  1. `valid_spots` is allocated ONCE, outside the form-search loop, and is never cleared
//     between forms. So a spot marked valid by form 3 stays marked while form 4 is scored.
//     That is the reference's behaviour and it is load-bearing only in the best_form == -1
//     case, because the failure path recomputes every index < len(operands) from best_form
//     before reading them. Reproduced exactly, not "fixed".
//  2. The prefix check runs BEFORE the operand match and independently of it, so an
//     impossible prefix is reported even when the operands also fail. The reference's comment
//     says so; the ordering is the contract.
//  3. `output_only_pin_mask` is computed and never read. It is the reference's, and it is
//     kept so that the pin loop reads as one thing rather than as two loops that drifted.
check_mnemonic :: proc(
	c: ^Checker_Context,
	tmpl_entity: ^Entity,
	instr: ^ast.Asm_Instruction,
	mnemonic: x86.Mnemonic,
	operands: []Operand,
	previous_prefix: Asm_Prefix,
	previous_prefix_instr: ^ast.Node,
	asm_acc: ^Asm_Mnemonic_Accumulator,
) {
	assert(u16(mnemonic) > 0)
	forms := asm_encoding_forms(mnemonic)
	name  := asm_mnemonic_string(mnemonic)

	min_count := int(max(i32))
	max_count := -1

	for form in forms {
		explicit_count := int(form.flags.explicit_count)
		min_count = min(min_count, explicit_count)
		max_count = max(max_count, explicit_count)
	}
	min_count = max(min_count, 0)
	max_count = max(max_count, 0)

	// A prefix that none of this mnemonic's forms can take is unconditionally wrong,
	// independent of whether the operands match -- catch it even on a match failure.
	if previous_prefix != .Invalid {
		any_form_accepts := false
		for form in forms {
			req_mem := false
			if asm_prefix_kind_okay(previous_prefix, form, &req_mem) {
				any_form_accepts = true
				break
			}
		}
		if !any_form_accepts {
			// `instr.name` is a ^ast.Expr and previous_prefix_instr a ^ast.Node; the two
			// arms of a ternary must agree, so the widening happens on assignment instead.
			at: ^ast.Node = instr.name
			if previous_prefix_instr != nil {
				at = previous_prefix_instr
			}
			error(at, "Asm prefix cannot be applied to '%s'", name)
		}
	}

	valid_spots := make([]bool, max_count, context.temp_allocator)
	defer delete(valid_spots, context.temp_allocator)

	possible_kinds := make([]Asm_Operand_Kind, max_count, context.temp_allocator)
	defer delete(possible_kinds, context.temp_allocator)

	possible_class_kinds := make([]ast.Asm_Reg_Class, max_count, context.temp_allocator)
	defer delete(possible_class_kinds, context.temp_allocator)

	matched          := false
	valid_form_index := -1

	best_form  := -1
	best_score := -1
	best_dist  := int(max(i32)) // secondary: prefer smaller width distance
	best_pref  := -1            // tertiary: prefer wider slots (r64 over r32)

	for form, form_index in forms {
		if len(operands) != int(form.flags.explicit_count) {
			continue
		}

		score      := 0
		width_dist := 0
		width_pref := 0

		for _, i in operands {
			slot := asm_form_explicit_slot(form, i)
			type := form.ops[slot] if slot >= 0 else x86.Operand_Type.NONE
			operand := &operands[i]
			dst := asm_kind_from_operand_type(type)
			src := determine_asm_operand_kind(c.info, operand)

			kind_ok := dst == src ||
			           (dst == .Register_Or_Memory && (src == .Register || src == .Memory))

			// Tertiary key: bias toward wider register slots so an r64 form outranks
			// an otherwise-equal r32 form.
			width_pref += int(asm_operand_type_bit_width(type))

			spot_ok := false
			if kind_ok {
				mem_unsized := src == .Memory && are_types_identical(operand.type, t_rawptr)

				if dst == .Register_Or_Memory && src == .Memory && mem_unsized {
					spot_ok = true // memory form accepts memory; no size check
				} else {
					m := Asm_Mismatch.None
					wb_, gb_: i32
					spot_ok = check_asm_operand_size_class(c.info, type, operand, &m, &wb_, &gb_)
					if !spot_ok && (m == .Size || m == .Imm_Range) && wb_ > 0 && gb_ > 0 {
						d := int(wb_) - int(gb_)
						width_dist += -d if d < 0 else d
					}
				}
			}

			if spot_ok {
				score += 2
				valid_spots[i] = true
			} else if kind_ok {
				score += 1 // kind matched, only value/size/class failed
			}
		}

		if score == len(operands)*2 {
			matched = true
			valid_form_index = form_index
			break
		}

		// Lexicographic rank: score desc, then width_dist asc, then width_pref desc.
		better: bool
		if score != best_score {
			better = score > best_score
		} else if width_dist != best_dist {
			better = width_dist < best_dist
		} else {
			better = width_pref > best_pref
		}
		if better {
			best_score = score
			best_dist  = width_dist
			best_pref  = width_pref
			best_form  = form_index
		}
	}

	if len(operands) < min_count || len(operands) > max_count {
		if min_count == max_count {
			error(instr.name, "The asm instruction '%s' expects %d operands, got %d", name, max_count, len(operands))
		} else {
			error(instr.name, "The asm instruction '%s' expects %d..=%d operands, got %d", name, min_count, max_count, len(operands))
		}
		return
	}
	if matched {
		if valid_form_index >= 0 && previous_prefix != .Invalid {
			form := forms[valid_form_index]

			requires_memory_dest := false
			if asm_prefix_kind_okay(previous_prefix, form, &requires_memory_dest) {
				if len(operands) != 0 && determine_asm_operand_kind(c.info, &operands[0]) != .Memory {
					at: ^ast.Node = instr.name
					if previous_prefix_instr != nil {
						at = previous_prefix_instr
					}
					error(at, "Asm prefix requires '%s' to have a memory destination operand", name)
				}
			}
		}

		assert(tmpl_entity.kind == .Asm_Template)

		assert(valid_form_index >= 0)
		instr.mnemonic = u16(mnemonic)
		instr.valid_form_index = i32(valid_form_index)

		// Handle clobbering from mnemonic
		clobbers := asm_clobber_forms(mnemonic)
		clobber  := clobbers[valid_form_index]

		te := &tmpl_entity.variant.(Entity_Asm_Template)

		te.clobber_flags  |= asm_clobber_implies_clobber_flags(clobber)
		te.clobber_memory |= asm_clobber_implies_clobber_memory(clobber)
		te.is_volatile    |= asm_clobber_implies_side_effects(clobber)

		te.has_observable_side_effect |= asm_clobber_implies_side_effects(clobber)
		te.has_observable_side_effect |= clobber.writes_mem

		// #align_stack only matters if the body makes a call (which requires the stack
		// aligned at the call boundary) or manipulates RSP directly. Plain memory access
		// through a parameter pointer does NOT require stack realignment, so
		// implies_clobber_memory() is intentionally NOT used here.
		if .CONTROL in clobber.side_effects || .RSP in clobber.implicit_wr {
			asm_acc.saw_call_or_mem = true
		}

		pinned_mask:          x86.Clobber_Regs
		output_only_pin_mask: x86.Clobber_Regs
		for ed in te.decls {
			if len(ed.pin) != 0 {
				b := asm_clobber_bit_for_reg_name(ed.pin)
				pinned_mask |= b
				if ed.param_group == .Output && ed.tie < 0 {
					output_only_pin_mask |= b
				}
			}
		}

		if asm_acc.straight_line {
			wants     := clobber.implicit_rd & ASM_CLOBBER_REGS_NAMED
			undefined := wants &~ asm_acc.defined_regs &~ pinned_mask
			for bit in undefined {
				rname := asm_clobber_reg_bit_name(bit)
				error(instr.name,
				      "'%s' implicitly reads %%%s, but nothing in this template produces " +
				      "a value for it; pin an input parameter to %%%s, or write %%%s before " +
				      "this instruction",
				      name, rname, rname, rname)
			}
		}

		produced        := clobber.implicit_wr & ASM_CLOBBER_REGS_NAMED
		explicit_writes: x86.Clobber_Regs

		// Explicit destination operands that name a concrete register also produce it
		// (e.g. `mov eax, $leaf` before CPUID). Only literal %reg operands pin a known
		// physical register; parameter operands are register-allocated elsewhere, so they
		// don't tell us which physical register was written.
		written_ops := clobber.written
		for _, i in operands {
			if i >= 4 || i not_in written_ops {
				continue
			}
			e := operands[i].expr
			if e != nil {
				if reg, is_reg := e.derived.(^ast.Asm_Register); is_reg {
					b := asm_clobber_bit_for_reg_name(reg.name.text)
					produced        |= b
					explicit_writes |= b
				}
			}
		}
		asm_acc.defined_regs |= produced

		// Registers this form clobbers implicitly (RDTSC->RAX:RDX, etc.), for the
		// redundant-#clobber hint. Union across the template; pinned regs excluded
		// so a legitimate output pin is never called "redundant".
		{
			implicit_wr := clobber.implicit_wr & ASM_CLOBBER_REGS_NAMED
			asm_acc.implicit_clobbered_regs |= implicit_wr &~ pinned_mask
		}

		// Approximate staleness. An output that was explicitly produced (literal %reg write)
		// and is later implicitly clobbered -- without this same instruction re-producing it --
		// is marked stale. Explicit re-production clears it. Implicitly-produced outputs
		// (RDTSC->RDX) are never tracked, so they never false-fire.
		{
			implicit_clobber := clobber.implicit_wr & ASM_CLOBBER_REGS_NAMED
			asm_acc.explicitly_produced_regs |= explicit_writes
			asm_acc.stale_outputs            &~= explicit_writes
			asm_acc.stale_outputs |= implicit_clobber & asm_acc.explicitly_produced_regs &~ explicit_writes
		}

		// Terminality for a #diverging template: this instruction ends straight-line
		// flow off the end (jmp/ret/etc. -> CONTROL, hlt/ud2 -> HALT). A conditional
		// branch does NOT terminate (it can fall through), so require that the form
		// is not merely CONTROL-with-fallthrough. We approximate "unconditional" as
		// CONTROL|HALT with no explicit label/operand fallthrough below.
		{
			se := clobber.side_effects
			control := .CONTROL in se
			halt    := .HALT    in se
			// A conditional branch reads a flag and can fall through -> not terminal.
			conditional := control && clobber.flags_rd != {}
			asm_acc.last_is_terminal = halt || (control && !conditional)
		}

		// A branch/call inside the template means subsequent instructions may be reached
		// out of textual order; stop trusting the linear def model past this point.
		if .CONTROL in clobber.side_effects {
			asm_acc.straight_line = false
		}
		asm_clobber_implicit_regs(&te.clobber_registers_set, produced)

		return
	}

	// failure path
	MAX_VARIANT_COUNT :: 32
	mismatch:  [MAX_VARIANT_COUNT]Asm_Mismatch // parallels valid_spots for the best form
	want_bits: [MAX_VARIANT_COUNT]i32
	got_bits:  [MAX_VARIANT_COUNT]i32
	if best_form >= 0 {
		form := forms[best_form]
		for _, i in operands {
			slot := asm_form_explicit_slot(form, i)
			type := form.ops[slot] if slot >= 0 else x86.Operand_Type.NONE
			dst := asm_kind_from_operand_type(type)
			src := determine_asm_operand_kind(c.info, &operands[i])
			possible_kinds[i] = dst
			possible_class_kinds[i] = asm_reg_class_from_operand_type(type)

			kind_ok := dst == src ||
			           (dst == .Register_Or_Memory && (src == .Register || src == .Memory))
			if !kind_ok {
				valid_spots[i] = false
			} else {
				m := Asm_Mismatch.None
				wb_: i32
				gb_: i32
				ok := check_asm_operand_size_class(c.info, type, &operands[i], &m, &wb_, &gb_)
				valid_spots[i] = ok
				if !ok && i < MAX_VARIANT_COUNT {
					mismatch[i]  = m
					want_bits[i] = wb_
					got_bits[i]  = gb_
				}
			}
		}
	}

	{
		if best_score >= max(len(operands)*2 - 2, 0) {
			error(instr.name, "'%s' operands nearly matched the expected encoding forms", name)
		} else {
			error(instr.name, "'%s' operands matched none of the expected encoding forms", name)
		}
		for _, i in valid_spots {
			if valid_spots[i] || i >= len(operands) {
				continue
			}
			dst := possible_kinds[i]
			src := determine_asm_operand_kind(c.info, &operands[i])

			dst_reg_class := possible_class_kinds[i]
			src_reg_class := check_asm_reg_class_from_type(operands[i].type)

			m := mismatch[i] if i < MAX_VARIANT_COUNT else Asm_Mismatch.None

			switch {
			case m == .Imm_Range:
				ev := operands[i].value
				vs := exact_value_to_string(ev)
				bits_required := i32(0)
				check_asm_immediate_value_fits(ev, want_bits[i], &bits_required, nil)
				if bits_required > 0 {
					error(operands[i].expr, "'%s' operand-%d is a %d-bit immediate value, but the value %s does not fit in the %d-bit immediate this form encodes",
					      name, i, bits_required, vs, int(want_bits[i]))
				} else {
					error(operands[i].expr, "'%s' operand-%d is an immediate value, but the value %s does not fit in the %d-bit immediate this form encodes",
					      name, i, vs, int(want_bits[i]))
				}
			case m == .Imm_Type:
				error(operands[i].expr, "'%s' operand-%d: a floating-point constant cannot be used as an immediate",
				      name, i)
			case m == .Size && want_bits[i] != 0 && got_bits[i] != 0:
				error(operands[i].expr, "'%s' operand-%d has the wrong size: expected a %d-bit operand, got %d-bit",
				      name, i, u32(want_bits[i]), u32(got_bits[i]))
			case m == .Class:
				error(operands[i].expr, "'%s' operand-%d is in the wrong register class, expected %d-bit %s %s, got %d-bit %s %s",
				      name, i,
				      want_bits[i], asm_reg_class_strings[dst_reg_class], asm_operand_kind_strings[dst],
				      got_bits[i],  asm_reg_class_strings[src_reg_class], asm_operand_kind_strings[src])
			case dst == .Immediate:
				error(operands[i].expr, "'%s' operand-%d must be an assemble-time constant or a $ immediate parameter, got a %s",
				      name, i, asm_operand_kind_strings[src])
			case dst != .Invalid:
				error(operands[i].expr, "'%s' operand-%d has an invalid kind, expected %s operand",
				      name, i, asm_operand_kind_expected_strings[dst])
			case:
				error(operands[i].expr, "'%s' operand-%d has an invalid kind", name, i)
			}
		}
	}
}

// check_asm_instruction_operand resolves ONE operand of one asm instruction: identifiers against
// the template's parameter scope, `%reg` against the register table, `[...]` against the whole
// base/index/scale/disp address grammar, and `.label` against the template's label scope.
//
// C++ Reference: src/check_asm.cpp:1268-1638.
//
// `allow_memory_operands` is false on every recursive call, which is what stops `[[x]]` -- and
// it is also why a memory operand in a disallowed position falls out of the switch entirely.
// The reference's `break` there is a `break` out of the C++ switch (case_end expands to
// `} break;`), so control reaches the trailing "Invalid asm operand" block rather than
// returning. That is reproduced with an explicit flag; it is behaviour, not a slip: the operand
// keeps the rawptr/Value it was given, AND the error is emitted.
check_asm_instruction_operand :: proc(
	c: ^Checker_Context,
	entity: ^Entity,
	operand: ^Operand,
	expr: ^ast.Expr,
	allow_memory_operands: bool,
) {
	if expr == nil {
		return
	}

	operand.expr = expr
	operand.mode = .Invalid
	operand.type = t_invalid

	assert(entity.kind == .Asm_Template)
	ate := &entity.variant.(Entity_Asm_Template)

	param_scope := ate.param_scope
	label_scope := ate.label_scope

	#partial switch e in expr.derived {
	case ^ast.Paren_Expr:
		check_expr(c, operand, expr)
		if operand.mode != .Constant {
			error(expr, "Asm operands within parentheses can only compile time constants, if they were supported")
		} else {
			error(expr, "Asm operands with parentheses are not currently supported")
		}
		return

	case ^ast.Ident:
		found := scope_lookup_current(param_scope, e.name)
		if found != nil {
			e.entity = found
			operand.mode = .Value
			operand.type = found.type
			return
		}
		found = scope_lookup(param_scope.parent, e.name)
		if found != nil {
			if found.kind == .Constant {
				e.entity = found
				operand.mode  = .Constant
				operand.value = found.variant.(Entity_Constant).value
				operand.type  = found.type

				add_type_and_value(c, expr, operand.mode, operand.type, operand.value)
			} else {
				error(expr, "Only asm parameters or constants are allowed to be used within an 'asm' template")
			}
		} else {
			error(expr, "Undeclared asm parameter or constant '%s'", e.name)
		}
		return

	case ^ast.Basic_Lit:
		check_expr(c, operand, expr)
		return

	case ^ast.Asm_Register:
		check_register(operand, e)
		return

	case ^ast.Asm_Memory_Operand:
		mem_op := e
		operand.type = t_rawptr
		operand.mode = .Value

		if !allow_memory_operands {
			// See the note on the procedure: the reference breaks out of the switch here
			// and lands on the trailing "Invalid asm operand" diagnostic. Odin's `break`
			// inside a switch case does exactly the same thing.
			break
		}

		segment_override: Operand
		check_asm_instruction_operand(c, entity, &segment_override, mem_op.segment_override, false)

		if segment_override.expr == nil {
			// okay
		} else if so_reg, is_reg := segment_override.expr.derived.(^ast.Asm_Register); is_reg {
			reg := asm_register_lookup(so_reg.name.text)
			reg_class := x86.reg_class(asm_register_codes[reg])
			if reg_class != x86.REG_SEG {
				s := expr_to_string(segment_override.expr)
				error(segment_override.expr, "A segment override must be a selector register parameter, got %s", s)
			}
		} else {
			s := expr_to_string(segment_override.expr)
			error(segment_override.expr, "A segment override must be a selector register parameter, got %s", s)
		}

		base:  Operand
		index: Operand
		scale: Operand
		disp:  Operand
		check_asm_instruction_operand(c, entity, &base,  mem_op.base,  false)
		check_asm_instruction_operand(c, entity, &index, mem_op.index, false)
		check_asm_instruction_operand(c, entity, &scale, mem_op.scale, false)
		check_asm_instruction_operand(c, entity, &disp,  mem_op.disp,  false)

		// NOTE(bill): if the base/index is actually an immediate and there is no scale nor disp,
		// then treat it as a disp, and modify the AST too
		if index.expr != nil && scale.expr == nil && disp.expr == nil {
			do_swap := index.mode == .Constant
			if !do_swap {
				param_entity := entity_of_node(c.info, index.expr)
				if param_entity != nil && param_entity.kind == .Variable {
					kind := check_asm_find_kind(param_entity, ate.decls[:])
					do_swap = kind == .Immediate
				}
			}
			if do_swap {
				disp = index
				index = {}

				mem_op.disp = mem_op.index
				mem_op.index = nil

				mem_op.disp_op = mem_op.index_op
				mem_op.index_op = {}
			}
		}
		if base.expr != nil && index.expr == nil && scale.expr == nil && disp.expr == nil {
			do_swap := base.mode == .Constant
			if !do_swap {
				param_entity := entity_of_node(c.info, base.expr)
				if param_entity != nil && param_entity.kind == .Variable {
					kind := check_asm_find_kind(param_entity, ate.decls[:])
					do_swap = kind == .Immediate
				}
			}
			if do_swap {
				disp = base
				base = {}

				mem_op.disp = mem_op.base
				mem_op.base = nil
			}
		}

		base_w:     i32
		index_w:    i32
		have_base:  bool
		have_index: bool

		// base: must resolve to a 32/64-bit integer register
		if base.expr != nil {
			reg_name: string
			ok_kind := true
			if br, is_reg := base.expr.derived.(^ast.Asm_Register); is_reg {
				reg_name = br.name.text
				ok_kind = check_register(&base, br)
			} else {
				param_entity := entity_of_node(c.info, base.expr)
				if param_entity == nil || param_entity.kind != .Variable {
					s := expr_to_string(base.expr)
					error(base.expr, "A base value must be a register parameter, got %s", s)
					ok_kind = false
				} else {
					kind := check_asm_find_kind(param_entity, ate.decls[:])
					// A pointer/integer parameter used as an address base lowers to a
					// register operand, so accept both Register and Memory kinds here.
					if kind != .Register && kind != .Memory {
						s := expr_to_string(base.expr)
						error(base.expr, "A base value must be a register parameter, got %s", s)
						ok_kind = false
					}
				}
			}
			if ok_kind {
				have_base = check_asm_addr_register(&base, .Base, reg_name, &base_w)
			}
		}

		// index: must resolve to a 32/64-bit integer register, and not rsp/esp
		if index.expr != nil {
			reg_name: string
			ok_kind := true
			if ir, is_reg := index.expr.derived.(^ast.Asm_Register); is_reg {
				reg_name = ir.name.text
				ok_kind = check_register(&index, ir)
			} else {
				param_entity := entity_of_node(c.info, index.expr)
				if param_entity == nil || param_entity.kind != .Variable {
					s := expr_to_string(index.expr)
					error(index.expr, "An index value must be an integer register, got %s", s)
					ok_kind = false
				} else {
					kind := check_asm_find_kind(param_entity, ate.decls[:])
					#partial switch kind {
					case .Register, .Immediate:
						// okay
					case:
						s := expr_to_string(index.expr)
						t := type_to_string(index.type)
						error(index.expr, "An index must be an integer register, got %s of type %s", s, t)
						ok_kind = false
					}
				}
			}
			if ok_kind {
				have_index = check_asm_addr_register(&index, .Index, reg_name, &index_w)
			}
		}

		// base and index must be the same width
		if have_base && have_index && base_w != index_w {
			at: ^ast.Node = expr
			if mem_op.base != nil {
				at = mem_op.base
			}
			error(at, "A memory operand's base and index registers must be the same width, got a %d-bit base and a %d-bit index",
			      int(base_w), int(index_w))
		}

		// a scale factor is meaningless without an index
		if scale.expr != nil && index.expr == nil {
			error(scale.expr, "A scale factor requires an index register")
		}

		// scale: constant 1/2/4/8, or an immediate parameter
		//
		// The reference writes this as `for (int i = 0; scale.expr && i == 0; i++)`, i.e. a
		// one-iteration loop used purely so that `break` can mean "stop checking the scale".
		// The port spells that as a labelled block; `break scale_check` reads the same way.
		if scale.expr != nil {
			scale_check: {
				if !is_type_integer(scale.type) {
					s := expr_to_string(scale.expr)
					error(scale.expr, "A scale must be a constant integer or an immediate, got %s", s)
					break scale_check
				}
				if scale.mode == .Constant {
					s := exact_value_to_string(scale.value)
					if _, is_int := scale.value.(big.Int); !is_int {
						error(scale.expr, "A scale must be a constant integer or an immediate, got %s", s)
						break scale_check
					} else {
						v := exact_value_to_i64(scale.value)

						op := mem_op.scale_op
						#partial switch op.kind {
						case .Mul:
							switch v {
							case 1, 2, 4, 8:
								// okay
							case:
								error(scale.expr, "A scale using '*' must be a constant integer or an immediate with the value 1, 2, 4, or 8, got %s", s)
							}
						case .Shl, .Shr:
							switch v {
							case 0, 1, 2, 3:
								// okay
							case:
								error(scale.expr, "A shifting scale using '%s' must be a constant integer or an immediate with the value 0, 1, 2, or 3, got %s", op.text, s)
							}
						case:
							error(op, "Unknown/unhandled scaling operator '%s'", op.text)
						}

						if op.kind == .Shr {
							arch := Target_Arch_Kind.Invalid
							if c.info.build_context != nil {
								arch = c.info.build_context.metrics.arch
							}
							if arch != .Arm64 {
								error(op, "The target platform does not support '%s' for shifting scale parameters in memory operands", op.text)
							}
						}
					}
				} else {
					param_entity := entity_of_node(c.info, scale.expr)
					if param_entity == nil || param_entity.kind != .Variable {
						s := expr_to_string(scale.expr)
						error(scale.expr, "A scale must be a constant integer or an immediate, got %s", s)
						break scale_check
					}
					kind := check_asm_find_kind(param_entity, ate.decls[:])
					if kind != .Immediate {
						s := expr_to_string(scale.expr)
						error(scale.expr, "A scale must be a constant integer or an immediate, got %s", s)
						break scale_check
					}
				}
			}
		}

		// displacement: an integer that fits a signed 32-bit value
		if disp.expr != nil {
			disp_check: {
				if _, is_reg := disp.expr.derived.(^ast.Asm_Register); is_reg {
					error(disp.expr, "A displacement must be a constant integer value, got a register")
					break disp_check
				}

				// A displacement must be assemble-time constant. A register-valued
				// parameter belongs in the index slot, not the displacement.
				if _, is_int := disp.value.(big.Int); disp.mode == .Constant && is_int {
					m := Asm_Mismatch.None
					needed := i32(0)
					if !check_asm_immediate_value_fits(disp.value, 32, &needed, &m) {
						vs := exact_value_to_string(disp.value)
						error(disp.expr, "A memory displacement must fit in a signed 32-bit value, got %s (needs %d bits)", vs, int(needed))
					}
					break disp_check
				}

				param_entity := entity_of_node(c.info, disp.expr)
				if param_entity != nil && param_entity.kind == .Variable {
					kind := check_asm_find_kind(param_entity, ate.decls[:])
					if kind == .Immediate {
						// A $-immediate parameter is a legal (assemble-time) displacement.
						break disp_check
					}
					if kind == .Register {
						// C++ reads disp.expr->Ident.token.string unconditionally here; it is
						// only reachable when the displacement resolved to a Variable entity,
						// which requires an Ident.
						disp_name := ""
						if di, is_ident := disp.expr.derived.(^ast.Ident); is_ident {
							disp_name = di.name
						}
						error(disp.expr, "A register parameter cannot be a displacement; use it as an index, e.g. [base + %s]", disp_name)
						break disp_check
					}
				}

				s := expr_to_string(disp.expr)
				error(disp.expr, "A displacement must be a constant integer or immediate, got %s", s)
			}
		}

		if mem_op.type != nil {
			t := check_type(c, mem_op.type)
			if t != nil && t != t_invalid {
				if is_valid_asm_parameter_type(t) && !is_type_pointer(t) {
					operand.type = alloc_type_pointer(t)
				} else {
					s := type_to_string(t)
					error(mem_op.type, "Asm memory operands type interpretation must be either an integer, boolean, float, or #simd vector, got %s", s)
					// leave operand.type == t_rawptr ("unsized")
				}
			}
		}

		return

	case ^ast.Asm_Label_Decl:
		name := e.name.derived.(^ast.Ident)
		found := scope_lookup_current(label_scope, name.name)
		if found == nil {
			error(expr, "Undeclared asm label '.%s'", name.name)
		}
		name.entity = found
		if found != nil {
			found.flags |= {.Used}
			add_type_and_value(c, expr, .Value, found.type, nil)
		}
		return
	}

	s := expr_to_string(expr)
	error(expr, "Invalid asm operand, got %s", s)
	return
}

// check_asm_template is the whole-declaration entry point: it builds the template's two scopes,
// checks its signature, its `[...]` specification block, its clobbers, its labels and every
// instruction in its body, then draws the template-level conclusions (volatility, diverging,
// redundant #align_stack, unused scratch parameters).
//
// C++ Reference: src/check_asm.cpp:1642-2122.
check_asm_template :: proc(c: ^Checker_Context, entity: ^Entity, d: ^Decl_Info) {
	assert(entity.kind == .Asm_Template)
	ate := &entity.variant.(Entity_Asm_Template)

	at := d.init_expr.derived.(^ast.Asm_Template)

	assert(at.signature != nil)
	pt, sig_is_proc_type := at.signature.derived.(^ast.Proc_Type)
	if !sig_is_proc_type {
		error(at.signature, "Expected a valid signature, got %s", ast.node_kind_string(at.signature))
		return
	}

	ate.param_scope = create_scope(c.scope)
	ate.label_scope = create_scope(c.scope)

	params  := check_asm_template_signature_params(c, ate.param_scope, pt.params,  true,  &ate.decls)
	results := check_asm_template_signature_params(c, ate.param_scope, pt.results, false, &ate.decls)

	param_count  := len(params.variant.(Type_Tuple).variables)
	result_count := len(results.variant.(Type_Tuple).variables)

	// NOTE the argument order: C++ is alloc_type_proc(scope, params, param_count, results,
	// result_count, ...) and the port's is (scope, params, results, param_count, result_count,
	// ...). Same values, different positions.
	// C++ reads `pt->calling_convention` as an already-resolved ProcCallingConvention; the
	// port's AST keeps the parser's `union { string, Proc_Calling_Convention_Extra }`, so it
	// is mapped here. src/parser.cpp:2640 assigns ProcCC_InlineAsm to every asm-template
	// signature, so the Extra arm is the only one reachable from real source; the string arm
	// is resolved the same way check_procedure_type does rather than being assumed away.
	cc := Calling_Convention.Inline_Asm
	switch v in pt.calling_convention {
	case string:
		cc = string_to_calling_convention(v)
		if cc == .Invalid {
			cc = .Inline_Asm
		}
	case ast.Proc_Calling_Convention_Extra:
		if v == .Inline_Asm {
			cc = .Inline_Asm
		}
	}

	type := alloc_type_proc(ate.param_scope, params, results, param_count, result_count, false, cc)
	pr := &type.variant.(Type_Proc)
	pr.diverging = pt.diverging
	if !pr.diverging && result_count != 0 {
		// always require the results of `asm` templates
		pr.require_results = true
	}

	entity.type = type

	is_volatile    := false
	is_align_stack := false
	clobber_registers_set := &ate.clobber_registers_set

	check_asm_specs(c, ate.param_scope, at.specs, &ate.decls)
	{ // check clobbers
		clobber_flags  := false
		clobber_memory := false

		for clobber_ in at.clobbers {
			clobber := clobber_.derived.(^ast.Asm_Clobber)

			if clobber.value == nil {
				switch clobber.name.text {
				case "volatile":
					if is_volatile {
						error(clobber.name, "#volatile has already been defined as an asm specification")
					}
					is_volatile = true
				case "align_stack":
					if is_align_stack {
						error(clobber.name, "#align_stack has already been defined as an asm specification")
					}
					is_align_stack = true
				case:
					error(clobber.name, "Unknown clobber directive '#%s'", clobber.name.text)
				}
				continue
			}

			#partial switch cv in clobber.value.derived {
			case ^ast.Asm_Register:
				reg := cv.name.text
				if cv.flag.text != "" {
					error(cv.flag, "#clobber on specific flags is not allowed")
				}
				operand: Operand
				if check_register(&operand, cv) {
					// C++ string_set_update inserts unconditionally and RETURNS whether the
					// key was already present, which is what the diagnostic keys off.
					existed := reg in clobber_registers_set^
					clobber_registers_set^[reg] = true
					if existed {
						error(clobber.value, "#clobber %%%s has already been defined", reg)
					}
				}
			case ^ast.Ident:
				str := cv.name
				switch str {
				case "flags":
					if clobber_flags {
						error(clobber.value, "#clobber flags has already been defined")
					}
					clobber_flags = true
				case "memory":
					if clobber_memory {
						error(clobber.value, "#clobber memory has already been defined")
					}
					clobber_memory = true
				case:
					error(clobber.value, "Expected either a register, 'flags', or 'memory' for a '#clobber' specification, got '%s'", str)
				}
			case:
				error(clobber.value, "Expected either a register, 'flags', or 'memory' for a '#clobber' specification")
			}
		}

		ate.clobber_flags  = clobber_flags
		ate.clobber_memory = clobber_memory
		ate.is_volatile    = is_volatile
		ate.is_align_stack = is_align_stack
	}

	// add normalizations for the reigsters too
	//
	// REPRESENTATION-FORCED, and the only place in this procedure where the port cannot be a
	// transliteration: C++ inserts into `*clobber_registers_set` while iterating it. Odin maps
	// must not be mutated during a range. The keys are snapshotted first instead, which is the
	// intended semantics -- normalisation is idempotent (normalising "eax" gives "rax", and
	// normalising "rax" gives "rax"), so one pass over a snapshot reaches the same fixed point
	// the reference is reaching for, without depending on whether its set rehashed mid-walk.
	{
		existing := make([dynamic]string, 0, len(clobber_registers_set^), context.temp_allocator)
		defer delete(existing)
		for reg in clobber_registers_set^ {
			append(&existing, reg)
		}
		for reg in existing {
			bit := asm_clobber_bit_for_reg_name(reg)
			for b in bit {
				rname := asm_clobber_reg_bit_name(b)
				if rname != reg {
					clobber_registers_set^[rname] = true
				}
			}
		}
	}

	// Two distinct operands pinned to the same physical register only makes sense when
	// they are tied (they intentionally share one register). Compared by bit so %eax
	// and %rax collide. Flag pins ("flags") yield bit 0 and are skipped.
	for i in 0 ..< len(ate.decls) {
		a := ate.decls[i]
		if len(a.pin) == 0 {
			continue
		}
		abit := asm_clobber_bit_for_reg_name(a.pin)
		if abit == {} {
			continue
		}
		for j in i+1 ..< len(ate.decls) {
			b := ate.decls[j]
			if len(b.pin) == 0 || asm_clobber_bit_for_reg_name(b.pin) != abit {
				continue
			}
			tied := a.tie == i32(j) || b.tie == i32(i)
			if tied {
				continue
			}
			bit_name := "<reg>"
			for bb in abit {
				bit_name = asm_clobber_reg_bit_name(bb)
			}
			at_tok := entity.token
			if b.entity != nil {
				at_tok = b.entity.token
			}
			error(at_tok,
			      "Parameters '%s' and '%s' are both pinned to %%%s but are not tied",
			      a.entity.token.text, b.entity.token.text, bit_name)
		}
	}

	asm_acc: Asm_Mnemonic_Accumulator

	// Physical registers known to hold a defined value at the current point in the
	// straight-line instruction stream. Seeded with input-pinned registers (they
	// carry their argument at entry); grows as instructions write registers.
	for ed in ate.decls {
		if len(ed.pin) == 0 {
			continue
		}
		// Only inputs (and the input half of a tie, which is Input-group) hold a
		// value at entry. Output/scratch pins start undefined and become defined
		// when an instruction writes them.
		if ed.param_group == .Input {
			asm_acc.defined_regs |= asm_clobber_bit_for_reg_name(ed.pin)
		}
	}

	// Linear "written earlier in the text" is only a sound proxy for "produced at
	// runtime" while control flow is straight-line. The first label is a potential
	// jump target / back-edge, after which a read can precede its textual def; from
	// there on we stop emitting the implicit-read diagnostic.
	asm_acc.straight_line = true

	// collect label decls
	for instruction_ in at.instructions {
		label, is_label := instruction_.derived.(^ast.Asm_Label_Decl)
		if !is_label {
			continue
		}
		name_ident, name_is_ident := label.name.derived.(^ast.Ident)
		assert(name_is_ident)
		if is_blank_ident(name_ident.name) {
			error(label.name, "Asm label definition cannot be '_'")
			continue
		}
		// The port's ^ast.Ident carries only `name`; C++'s Ast_Ident carries a whole Token,
		// which is what alloc_entity_label wants. Synthesised the same way check_type.odin:6296
		// does it.
		label_tok := tokenizer.Token{kind = .Ident, text = name_ident.name, pos = label.name.pos}
		label_entity := alloc_entity_label(ate.label_scope, label_tok, nil, nil, nil)
		found := scope_insert(ate.label_scope, label_entity)
		if found != nil {
			pos := found.token.pos
			error(label.name,
			      "Redeclaration of the label '%s' in this scope\n" +
			      "\tat %s",
			      name_ident.name, token_pos_to_string(pos))
			continue
		}
		name_ident.entity = label_entity
	}

	operands := make([dynamic]Operand, 0, 16, context.temp_allocator)
	defer delete(operands)

	previous_prefix := Asm_Prefix.Invalid
	previous_prefix_instr: ^ast.Node // for a good error location

	for instruction_ in at.instructions {
		#partial switch node in instruction_.derived {
		case ^ast.Asm_Instruction:
			instr := node
			_, name_is_ident := instr.name.derived.(^ast.Ident)
			assert(name_is_ident)

			mnemonic := u16(0)
			res := check_mnemonic_name(instr, &mnemonic)

			clear(&operands)
			for expr in instr.operands {
				operand: Operand
				check_asm_instruction_operand(c, entity, &operand, expr, true /*allow_memory_operands*/)
				append(&operands, operand)
			}

			switch res {
			case .Prefix:
				if len(instr.operands) != 0 {
					error(instr.name, "A prefix must not have any operands, and be separate from the instruction it is prefixing")
				}
				if previous_prefix != .Invalid {
					error(instr.name, "A prefix cannot immediately follow another prefix")
				}
				previous_prefix = Asm_Prefix(mnemonic)
				previous_prefix_instr = instruction_
			case .Mnemonic:
				check_mnemonic(c, entity, instr, x86.Mnemonic(mnemonic), operands[:],
				               previous_prefix, previous_prefix_instr,
				               &asm_acc)

				asm_acc.saw_any_instructions = true

				previous_prefix = .Invalid
				previous_prefix_instr = nil
			case .Invalid:
				// invalid mnemonic already reported; a pending prefix now has no target
				previous_prefix = .Invalid
				previous_prefix_instr = nil
			}

		case ^ast.Asm_Label_Decl:
			asm_acc.straight_line = false
			// A new straight-line region begins here; its tail is unseen,
			// so the previous instruction's terminality no longer describes the body's end.
			asm_acc.last_is_terminal = false
			if previous_prefix != .Invalid {
				error(previous_prefix_instr, "A prefix must be immediately followed by an instruction, but a label declaration was found")
				previous_prefix = .Invalid
				previous_prefix_instr = nil
			}

		case ^ast.Asm_Directive:
			dir := node
			name := dir.name.text
			switch name {
			case "byte":
				if len(dir.operands) == 0 {
					error(dir.name, "Expected 1 or more integers for the asm directive #%s", name)
					break
				}
				clear(&operands)
				for expr in dir.operands {
					operand: Operand
					check_asm_instruction_operand(c, entity, &operand, expr, true /*allow_memory_operands*/)
					append(&operands, operand)
				}
				for op in operands {
					if op.mode != .Constant {
						error(op.expr, "Expected an integer for the asm directive #%s", name)
						continue
					}
					ev := exact_value_to_integer(op.value)
					if _, is_int := ev.(big.Int); !is_int {
						error(op.expr, "Expected an integer for the asm directive #%s", name)
						continue
					}
					i := exact_value_to_i64(ev)
					if i < 0 || i > 255 {
						error(op.expr, "Expected an integer within 0..<256 for the asm directive #%s, got %d", name, i)
						continue
					}
				}
			case "align":
				if len(dir.operands) != 1 {
					error(dir.name, "Expected 1 integer for the asm directive #%s", name)
					break
				}
				clear(&operands)
				for expr in dir.operands {
					operand: Operand
					check_asm_instruction_operand(c, entity, &operand, expr, true /*allow_memory_operands*/)
					append(&operands, operand)
				}
				for op in operands {
					if op.mode != .Constant {
						error(op.expr, "Expected a power-of-two integer for the asm directive #%s", name)
						continue
					}
					ev := exact_value_to_integer(op.value)
					if _, is_int := ev.(big.Int); !is_int {
						error(op.expr, "Expected a power-of-two integer for the asm directive #%s", name)
						continue
					}
					i := exact_value_to_i64(ev)
					if i < 0 || !is_power_of_two(i) {
						error(op.expr, "Expected a power-of-two integer for the asm directive #%s, got %d", name, i)
						continue
					}
				}

			case "skip", "nop":
				if len(dir.operands) != 1 {
					error(dir.name, "Expected 1 integer for the asm directive #%s", name)
					break
				}
				clear(&operands)
				for expr in dir.operands {
					operand: Operand
					check_asm_instruction_operand(c, entity, &operand, expr, true /*allow_memory_operands*/)
					append(&operands, operand)
				}
				for op in operands {
					if op.mode != .Constant {
						error(op.expr, "Expected an integer >0 for the asm directive #%s", name)
						continue
					}
					ev := exact_value_to_integer(op.value)
					if _, is_int := ev.(big.Int); !is_int {
						error(op.expr, "Expected an integer >0 for the asm directive #%s", name)
						continue
					}
					i := exact_value_to_i64(ev)
					if i < 0 {
						error(op.expr, "Expected an integer >0 for the asm directive #%s, got %d", name, i)
						continue
					}
				}
			case:
				error(dir.name, "Unknown asm directive: #%s", name)
			}

		case:
			error(instruction_, "Unexpected instruction in asm template")
		}
	}
	if previous_prefix != .Invalid {
		error(previous_prefix_instr, "A prefix must be immediately followed by an instruction, but the template ended")
	}

	// C++ Reference: src/check_asm.cpp:1991-2002 -- an "output pinned but never written" check,
	// commented out in the reference. NOT ported: an inert block is not behaviour, and carrying
	// dead code across a port only makes it look like a decision that was made here.

	vet_unused := false
	{
		file := c.file
		if file == nil {
			file = entity.file
		}

		vet_unused = .Unused_Variables in ast_file_vet_flags(file)
	}

	if vet_unused {
		// ORDER: C++ walks `label_scope->elements`, a StringMap, so its diagnostic order is
		// whatever the hash gives. The port sorts by declaration position first, which is the
		// idiom already established for unused-entity reporting (check_proc.odin:1800). A map
		// walk in the port would be nondeterministic RUN TO RUN, which is strictly worse than
		// disagreeing with an arbitrary-but-fixed C++ order.
		labels := make([dynamic]^Entity, 0, len(ate.label_scope.elements), context.temp_allocator)
		defer delete(labels)
		for _, le in ate.label_scope.elements {
			assert(le != nil)
			append(&labels, le)
		}
		slice.sort_by(labels[:], proc(a, b: ^Entity) -> bool {
			return token_pos_cmp(a.token.pos, b.token.pos) < 0
		})
		for le in labels {
			if .Used not_in le.flags {
				error(le.token, "'asm' label '.%s' is declared but never reference by any instruction", le.token.text)
			}
		}
	}

	if vet_unused {
		refs := make(map[^Entity]bool, allocator = context.temp_allocator)
		defer delete(refs)
		touched_regs: x86.Clobber_Regs

		for instruction_ in at.instructions {
			#partial switch node in instruction_.derived {
			case ^ast.Asm_Instruction:
				for op in node.operands {
					check_asm_collect_refs(&refs, op, &touched_regs)
				}
			case ^ast.Asm_Directive:
				for op in node.operands {
					check_asm_collect_refs(&refs, op, &touched_regs)
				}
			}
		}

		for ed in ate.decls {
			is_scratch   := ed.param_group == .Scratch && ed.view_of < 0
			is_immediate := ed.kind == .Immediate
			if (!is_scratch && !is_immediate) || ed.entity == nil {
				continue
			}
			// Used if its identifier is referenced OR (for a pinned scratch) its pinned
			// register is touched in the body. Immediates are never register-touched, so
			// they fall through to the entity check as before.
			if ed.entity in refs {
				continue
			}
			if len(ed.pin) != 0 {
				pin_bit := asm_clobber_bit_for_reg_name(ed.pin)
				if pin_bit != {} && (touched_regs & pin_bit) != {} {
					continue
				}
			}
			error(ed.entity.token, "'asm' %s '%s' is declared but never used",
			      "immediate parameter" if is_immediate else "scratch parameter",
			      ed.entity.token.text)
		}
	}

	assert(entity.kind == .Asm_Template)
	if result_count == 0 && !ate.is_volatile &&
	   !ate.clobber_memory &&
	   ate.has_observable_side_effect {
		warning(entity.token,
		        "This asm template has an observable effect but declares no outputs " +
		        "and does not #volatile in the specification block; it may be optimized away. " +
		        "Please add #volatile if the effect is intended.")
	}

	if ate.is_align_stack && !asm_acc.saw_call_or_mem {
		warning(entity.token,
		        "#align_stack is redundant; this template makes no call and touches no memory " +
		        "that would require the stack to be realigned")
	}

	// C++ Reference: src/check_asm.cpp:2085-2110 -- the redundant-#clobber and redundant-#volatile
	// hints, both inside `if (false)`. Same call as the commented-out block above: not ported.
	// The reference's own comment says it is unsure whether they are a good idea at all.

	if pr.diverging {
		if !asm_acc.saw_any_instructions {
			error(entity.token, "This asm template is declared as diverging (-> !) but its body is empty and cannot diverge")
		} else if !asm_acc.last_is_terminal {
			error(entity.token,
			      "This asm template is declared diverging (-> !) but its final instruction can fall through; " +
			      "end it with an unconditional jump, return, or halt")
		}
	}
}

// C++ Reference: src/check_asm.cpp:2124-2130.
// The reference dispatches on the target arch to pick the AsmCtx; the port has one, so the
// branch is only the diagnostic.
check_asm_template_from_entity :: proc(c: ^Checker_Context, e: ^Entity, d: ^Decl_Info) {
	arch := Target_Arch_Kind.Invalid
	if c.info.build_context != nil {
		arch = c.info.build_context.metrics.arch
	}
	if arch == .Amd64 {
		check_asm_template(c, e, d)
	} else {
		error(e.token, "asm templates are not currently supported for this target")
	}
}
