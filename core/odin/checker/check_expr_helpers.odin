package checker

import "core:math/big"
import "core:odin/ast"
import "core:odin/tokenizer"
import "core:strings"

// elem_type_can_be_constant checks if an element type can participate in constant compound literals
// C++ Reference: types.cpp:2549-2564
//
// IMPORTANT: Almost all types CAN be constant! This includes:
// - Pointers (nil is a valid constant pointer)
// - Procedures (proc values and nil are valid constants)
// - Slices (empty slice {} is a valid constant)
// - Maps, dynamic arrays, etc.
//
// Only returns false for:
// - Invalid types (t_invalid)
// - any type
// - Raw unions and unions (unless all variants are constantable)
elem_type_can_be_constant :: proc(t: ^Type) -> bool {
	bt := base_type(t)

	// Invalid type cannot be constant
	if bt == t_invalid {
		return false
	}

	// any type cannot be constant
	if is_type_any(bt) {
		return false
	}

	// Raw unions require special check
	if is_type_raw_union(bt) {
		return is_type_raw_union_constantable(bt)
	}

	// Unions require special check
	if is_type_union(bt) {
		return is_type_union_constantable(bt)
	}

	// DEFAULT: Everything else CAN be constant
	// This includes pointers, procs, slices, maps, structs, arrays, etc.
	return true
}

// elem_cannot_be_constant checks if an element type CANNOT be used in constant compound literals
// C++ Reference: types.cpp:2566-2577
//
// IMPORTANT: This is NOT the inverse of elem_type_can_be_constant!
// Returns true only for:
// - any type (always non-constant)
// - Unions with non-constantable variants
// - Raw unions with non-constantable variants
//
// Everything else returns false (CAN be constant).
elem_cannot_be_constant :: proc(t: ^Type) -> bool {
	// any type cannot be constant
	// C++ Reference: line 2567-2569
	if is_type_any(t) {
		return true
	}

	// Non-constantable unions cannot be constant
	// C++ Reference: lines 2570-2572
	if is_type_union(t) {
		return !is_type_union_constantable(t)
	}

	// Non-constantable raw unions cannot be constant
	// C++ Reference: lines 2573-2575
	if is_type_raw_union(t) {
		return !is_type_raw_union_constantable(t)
	}

	// DEFAULT: Everything else CAN be constant (return false)
	// C++ Reference: line 2576
	return false
}

// check_is_operand_compound_lit_constant checks if an operand can be used in a constant compound literal
// Reference: check_expr.cpp:8678-8701
//
// Returns true if:
// - Operand is nil
// - Operand is a procedure entity or literal
// - Operand is a type being used as typeid
// - Operand is constant (for all other cases)
//
// Special cases:
// - Procedure entities are constant in compound literals
// - Procedure literals get marked as constant
// - Type operands can be constant when assigned to typeid fields
// - any type fields cannot be constant
check_is_operand_compound_lit_constant :: proc(ctx: ^Checker_Context, o: ^Operand, field_type: ^Type) -> bool {
	// Nil is constant
	// Reference: C++ line 8679-8681
	if is_operand_nil(o^) {
		return true
	}

	// Check for procedure entity or literal
	// Reference: C++ lines 8682-8691
	expr := unparen_expr(o.expr)
	if expr != nil {
		e := strip_entity_wrapping(ctx, expr)
		if e != nil && e.kind == .Procedure {
			return true
		}
		if _, is_proc_lit := expr.derived.(^ast.Proc_Lit); is_proc_lit {
			// Procedure literals are constant in compound literals
			// Reference: C++ lines 8688-8690
			return true
		}
	}

	// Check for type operand being used as typeid
	// Reference: C++ lines 8693-8696
	if field_type != nil && is_type_typeid(field_type) && o.mode == .Type {
		// Type operands can be constant when assigned to typeid fields
		// Reference: C++ line 8694
		return true
	}

	// any type cannot be constant
	// Reference: C++ lines 8697-8699
	if is_type_any(field_type) {
		return false
	}

	// Default: check if mode is constant
	// Reference: C++ line 8700
	return o.mode == .Constant
}

// expr_to_string converts an AST expression to a string representation
// Reference: check_expr.cpp:11945-12575 (write_expr_to_string/expr_to_string)
//
// Handles most common expression types for readable error reporting.
expr_to_string :: proc(expr: ^ast.Node, allocator := context.allocator) -> string {
	if expr == nil {
		// NOTE: must be allocator-owned like the builder path below. Returning a string literal
		// here made every `delete(expr_to_string(...))` call site an invalid free whenever the
		// expression happened to be nil.
		return strings.clone("<nil>", allocator)
	}

	builder := strings.builder_make(allocator)
	write_expr_to_string(&builder, expr, false)
	return strings.to_string(builder)
}

// expr_to_string_shorthand is like expr_to_string but uses "..." for compound types
expr_to_string_shorthand :: proc(expr: ^ast.Node, allocator := context.allocator) -> string {
	if expr == nil {
		// NOTE: see expr_to_string - must be allocator-owned so callers can free it
		// unconditionally. name_canonicalization.odin:397 picks between the two helpers in a
		// ternary and deletes the result, so both nil paths have to agree.
		return strings.clone("<nil>", allocator)
	}

	builder := strings.builder_make(allocator)
	write_expr_to_string(&builder, expr, true)
	return strings.to_string(builder)
}

// write_expr_to_string recursively writes an expression to a string builder
// Reference: check_expr.cpp:11945-12564 (write_expr_to_string)
//
// shorthand: if true, use "..." for compound literals instead of full contents
write_expr_to_string :: proc(builder: ^strings.Builder, node: ^ast.Node, shorthand: bool) {
	if node == nil {
		return
	}

	#partial switch derived in node.derived {
	// ===== Basic Nodes =====
	case ^ast.Ident:
		strings.write_string(builder, derived.name)

	case ^ast.Implicit:
		// Context or other implicit value
		strings.write_string(builder, derived.tok.text)

	case ^ast.Basic_Lit:
		strings.write_string(builder, derived.tok.text)

	case ^ast.Basic_Directive:
		strings.write_rune(builder, '#')
		strings.write_string(builder, derived.name)

	case ^ast.Undef:
		strings.write_string(builder, "---")

	// ===== Unary Expressions =====
	case ^ast.Unary_Expr:
		strings.write_string(builder, derived.op.text)
		write_expr_to_string(builder, derived.expr, shorthand)

	case ^ast.Deref_Expr:
		write_expr_to_string(builder, derived.expr, shorthand)
		strings.write_rune(builder, '^')

	// ===== Binary Expressions =====
	case ^ast.Binary_Expr:
		write_expr_to_string(builder, derived.left, shorthand)
		strings.write_rune(builder, ' ')
		strings.write_string(builder, derived.op.text)
		strings.write_rune(builder, ' ')
		write_expr_to_string(builder, derived.right, shorthand)

	// ===== Ternary Expressions =====
	case ^ast.Ternary_If_Expr:
		// Check order to determine syntax (x if cond else y vs cond ? x : y)
		x_pos := derived.x.pos.offset
		cond_pos := derived.cond.pos.offset
		if x_pos < cond_pos {
			write_expr_to_string(builder, derived.x, shorthand)
			strings.write_string(builder, " if ")
			write_expr_to_string(builder, derived.cond, shorthand)
			strings.write_string(builder, " else ")
			write_expr_to_string(builder, derived.y, shorthand)
		} else {
			write_expr_to_string(builder, derived.cond, shorthand)
			strings.write_string(builder, " ? ")
			write_expr_to_string(builder, derived.x, shorthand)
			strings.write_string(builder, " : ")
			write_expr_to_string(builder, derived.y, shorthand)
		}

	case ^ast.Ternary_When_Expr:
		write_expr_to_string(builder, derived.x, shorthand)
		strings.write_string(builder, " when ")
		write_expr_to_string(builder, derived.cond, shorthand)
		strings.write_string(builder, " else ")
		write_expr_to_string(builder, derived.y, shorthand)

	case ^ast.Or_Else_Expr:
		write_expr_to_string(builder, derived.x, shorthand)
		strings.write_string(builder, " or_else ")
		write_expr_to_string(builder, derived.y, shorthand)

	case ^ast.Or_Return_Expr:
		write_expr_to_string(builder, derived.expr, shorthand)
		strings.write_string(builder, " or_return")

	case ^ast.Or_Branch_Expr:
		write_expr_to_string(builder, derived.expr, shorthand)
		strings.write_rune(builder, ' ')
		strings.write_string(builder, derived.token.text)
		if derived.label != nil {
			strings.write_rune(builder, ' ')
			write_expr_to_string(builder, derived.label, shorthand)
		}

	// ===== Parentheses =====
	case ^ast.Paren_Expr:
		strings.write_rune(builder, '(')
		write_expr_to_string(builder, derived.expr, shorthand)
		strings.write_rune(builder, ')')

	// ===== Selector Expressions =====
	case ^ast.Selector_Expr:
		write_expr_to_string(builder, derived.expr, shorthand)
		strings.write_string(builder, derived.op.text) // Usually "."
		write_expr_to_string(builder, derived.field, shorthand)

	case ^ast.Implicit_Selector_Expr:
		strings.write_rune(builder, '.')
		write_expr_to_string(builder, derived.field, shorthand)

	case ^ast.Selector_Call_Expr:
		write_expr_to_string(builder, derived.expr, shorthand)
		strings.write_string(builder, "(")
		// Print the call arguments (excluding modified first arg if present)
		if call, ok := derived.call.derived.(^ast.Call_Expr); ok {
			start := 1 if derived.modified_call else 0
			for i in start ..< len(call.args) {
				if i > start {
					strings.write_string(builder, ", ")
				}
				write_expr_to_string(builder, call.args[i], shorthand)
			}
		}
		strings.write_string(builder, ")")

	// ===== Type Assertions =====
	case ^ast.Type_Assertion:
		write_expr_to_string(builder, derived.expr, shorthand)
		if derived.type != nil {
			if unary, ok := derived.type.derived.(^ast.Unary_Expr); ok && unary.op.kind == .Question {
				strings.write_string(builder, ".?")
			} else {
				strings.write_string(builder, ".(")
				write_expr_to_string(builder, derived.type, shorthand)
				strings.write_rune(builder, ')')
			}
		}

	// ===== Type Casts =====
	case ^ast.Type_Cast:
		strings.write_string(builder, derived.tok.text) // cast, transmute, etc.
		strings.write_rune(builder, '(')
		write_expr_to_string(builder, derived.type, shorthand)
		strings.write_rune(builder, ')')
		write_expr_to_string(builder, derived.expr, shorthand)

	case ^ast.Auto_Cast:
		strings.write_string(builder, derived.op.text) // "auto_cast"
		strings.write_rune(builder, ' ')
		write_expr_to_string(builder, derived.expr, shorthand)

	// ===== Index/Slice Expressions =====
	case ^ast.Index_Expr:
		write_expr_to_string(builder, derived.expr, shorthand)
		strings.write_rune(builder, '[')
		write_expr_to_string(builder, derived.index, shorthand)
		strings.write_rune(builder, ']')

	case ^ast.Slice_Expr:
		write_expr_to_string(builder, derived.expr, shorthand)
		strings.write_rune(builder, '[')
		write_expr_to_string(builder, derived.low, shorthand)
		strings.write_string(builder, derived.interval.text) // ":" or ".."
		write_expr_to_string(builder, derived.high, shorthand)
		strings.write_rune(builder, ']')

	case ^ast.Matrix_Index_Expr:
		write_expr_to_string(builder, derived.expr, shorthand)
		strings.write_rune(builder, '[')
		write_expr_to_string(builder, derived.row_index, shorthand)
		strings.write_string(builder, ", ")
		write_expr_to_string(builder, derived.column_index, shorthand)
		strings.write_rune(builder, ']')

	// ===== Call Expressions =====
	case ^ast.Call_Expr:
		// Handle inlining directives
		switch derived.inlining {
		case .Inline:
			strings.write_string(builder, "#force_inline ")
		case .No_Inline:
			strings.write_string(builder, "#force_no_inline ")
		case .None:
		// No prefix
		}

		write_expr_to_string(builder, derived.expr, shorthand)
		strings.write_string(builder, "(")
		// Skip first argument if it was modified by a selector call
		start_idx := 0
		for i in start_idx ..< len(derived.args) {
			if i > start_idx {
				strings.write_string(builder, ", ")
			}
			write_expr_to_string(builder, derived.args[i], shorthand)
		}
		strings.write_string(builder, ")")

	// ===== Compound Literals =====
	case ^ast.Comp_Lit:
		write_expr_to_string(builder, derived.type, shorthand)
		strings.write_rune(builder, '{')
		if shorthand {
			strings.write_string(builder, "...")
		} else {
			for elem, i in derived.elems {
				if i > 0 {
					strings.write_string(builder, ", ")
				}
				write_expr_to_string(builder, elem, shorthand)
			}
		}
		strings.write_rune(builder, '}')

	case ^ast.Field_Value:
		write_expr_to_string(builder, derived.field, shorthand)
		strings.write_string(builder, " = ")
		write_expr_to_string(builder, derived.value, shorthand)

	case ^ast.Enum_Field_Value:
		// C++ Reference: src/check_expr.cpp:13269-13275 -- the ` = value` half is emitted only
		// when a value is present, so a bare member prints as just its name.
		write_expr_to_string(builder, derived.name, shorthand)
		if derived.value != nil {
			strings.write_string(builder, " = ")
			write_expr_to_string(builder, derived.value, shorthand)
		}

	// ===== Nodes C++'s printer handles that the port did not (#250) =====
	//
	// C++ Reference: src/check_expr.cpp write_expr_to_string. Each of these fell to the
	// `<unprintable %T>` fallback below, so any diagnostic naming one printed a type dump
	// instead of the expression. NOTE C++ writes these arms with the case_ast_node() MACRO,
	// not `case Ast_X:` -- grepping for the literal form finds nothing and reads as proof
	// they are unhandled, which is exactly the false negative that derailed #243's audit.

	case ^ast.Bit_Field_Field:
		write_expr_to_string(builder, derived.name, shorthand)
		strings.write_string(builder, ": ")
		write_expr_to_string(builder, derived.type, shorthand)
		strings.write_string(builder, " | ")
		write_expr_to_string(builder, derived.bit_size, shorthand)

	case ^ast.Bit_Field_Type:
		strings.write_string(builder, "bit_field ")
		if !shorthand {
			write_expr_to_string(builder, derived.backing_type, shorthand)
		}
		strings.write_string(builder, " {")
		if shorthand {
			strings.write_string(builder, "...")
		} else {
			for f, i in derived.fields {
				if i > 0 {
					strings.write_string(builder, ", ")
				}
				write_expr_to_string(builder, f, false)
			}
		}
		strings.write_string(builder, "}")

	case ^ast.Helper_Type:
		strings.write_string(builder, "#type ")
		write_expr_to_string(builder, derived.type, shorthand)

	case ^ast.Inline_Asm_Expr:
		strings.write_string(builder, "asm(")
		for pt, i in derived.param_types {
			if i > 0 {
				strings.write_string(builder, ", ")
			}
			write_expr_to_string(builder, pt, shorthand)
		}
		strings.write_string(builder, ")")
		if derived.return_type != nil {
			strings.write_string(builder, " -> ")
			write_expr_to_string(builder, derived.return_type, shorthand)
		}
		if derived.has_side_effects {
			strings.write_string(builder, " #side_effects")
		}
		if derived.is_align_stack {
			strings.write_string(builder, " #stack_align")
		}
		// C++ guards this with `if (ia->dialect)`, and InlineAsmDialect_Default is 0 --
		// FALSY -- so nothing is emitted for the default dialect. Only ATT and Intel print.
		// (My first draft emitted a bare " #" for Default, from reading the table
		// inline_asm_dialect_strings = {"", "att", "intel"} without the enclosing guard.)
		#partial switch derived.dialect {
		case .ATT:   strings.write_string(builder, " #att")
		case .Intel: strings.write_string(builder, " #intel")
		}
		strings.write_string(builder, " {")
		if shorthand {
			strings.write_string(builder, "...")
		} else {
			write_expr_to_string(builder, derived.asm_string, shorthand)
			strings.write_string(builder, ", ")
			write_expr_to_string(builder, derived.constraints_string, shorthand)
		}
		strings.write_string(builder, "}")

	case ^ast.Relative_Type:
		// C++ appends an empty string between the two -- no separator.
		write_expr_to_string(builder, derived.tag, shorthand)
		write_expr_to_string(builder, derived.type, shorthand)

	// ===== Procedure Literals =====
	case ^ast.Proc_Lit:
		write_expr_to_string(builder, derived.type, shorthand)
		if derived.body != nil {
			strings.write_string(builder, " {...}")
		} else {
			strings.write_string(builder, " ---")
		}

	case ^ast.Proc_Group:
		strings.write_string(builder, "proc{")
		for arg, i in derived.args {
			if i > 0 {
				strings.write_string(builder, ", ")
			}
			write_expr_to_string(builder, arg, shorthand)
		}
		strings.write_rune(builder, '}')

	// ===== Ellipsis =====
	case ^ast.Ellipsis:
		strings.write_string(builder, "..")
		write_expr_to_string(builder, derived.expr, shorthand)

	// ===== Tag Expressions =====
	case ^ast.Tag_Expr:
		strings.write_rune(builder, '#')
		strings.write_string(builder, derived.name)
		write_expr_to_string(builder, derived.expr, shorthand)

	// ===== Type Expressions (for error messages) =====
	case ^ast.Pointer_Type:
		if derived.tag != nil {
			write_expr_to_string(builder, derived.tag, false)
		}
		strings.write_rune(builder, '^')
		write_expr_to_string(builder, derived.elem, shorthand)

	case ^ast.Multi_Pointer_Type:
		strings.write_string(builder, "[^]")
		write_expr_to_string(builder, derived.elem, shorthand)

	case ^ast.Array_Type:
		if derived.tag != nil {
			write_expr_to_string(builder, derived.tag, false)
		}
		strings.write_rune(builder, '[')
		if derived.len != nil {
			if unary, ok := derived.len.derived.(^ast.Unary_Expr); ok && unary.op.kind == .Question {
				strings.write_string(builder, "?")
			} else {
				write_expr_to_string(builder, derived.len, shorthand)
			}
		}
		strings.write_rune(builder, ']')
		write_expr_to_string(builder, derived.elem, shorthand)

	case ^ast.Dynamic_Array_Type:
		if derived.tag != nil {
			write_expr_to_string(builder, derived.tag, false)
		}
		strings.write_string(builder, "[dynamic]")
		write_expr_to_string(builder, derived.elem, shorthand)

	case ^ast.Fixed_Capacity_Dynamic_Array_Type:
		// `[dynamic; N]T`. The checker does not yet build a type for this (see the open parity
		// task), but it must at least be printable - without this case it fell through to the
		// fallback below and every diagnostic mentioning one said "(BadExpr)", which reads as a
		// parse failure. The parser handles this form fine, including a polymorphic capacity.
		if derived.tag != nil {
			write_expr_to_string(builder, derived.tag, false)
		}
		strings.write_string(builder, "[dynamic; ")
		write_expr_to_string(builder, derived.capacity, shorthand)
		strings.write_string(builder, "]")
		write_expr_to_string(builder, derived.elem, shorthand)

	case ^ast.Map_Type:
		strings.write_string(builder, "map[")
		write_expr_to_string(builder, derived.key, shorthand)
		strings.write_rune(builder, ']')
		write_expr_to_string(builder, derived.value, shorthand)

	case ^ast.Bit_Set_Type:
		strings.write_string(builder, "bit_set[")
		write_expr_to_string(builder, derived.elem, shorthand)
		strings.write_string(builder, "]")

	case ^ast.Matrix_Type:
		strings.write_string(builder, "matrix[")
		write_expr_to_string(builder, derived.row_count, shorthand)
		strings.write_string(builder, ", ")
		write_expr_to_string(builder, derived.column_count, shorthand)
		strings.write_rune(builder, ']')
		write_expr_to_string(builder, derived.elem, shorthand)

	case ^ast.Distinct_Type:
		strings.write_string(builder, "distinct ")
		write_expr_to_string(builder, derived.type, shorthand)

	case ^ast.Poly_Type:
		strings.write_rune(builder, '$')
		write_expr_to_string(builder, derived.type, shorthand)
		if derived.specialization != nil {
			strings.write_rune(builder, '/')
			write_expr_to_string(builder, derived.specialization, shorthand)
		}

	case ^ast.Typeid_Type:
		strings.write_string(builder, "typeid")
		if derived.specialization != nil {
			strings.write_string(builder, "/")
			write_expr_to_string(builder, derived.specialization, shorthand)
		}

	case ^ast.Proc_Type:
		strings.write_string(builder, "proc(")
		write_expr_to_string(builder, derived.params, shorthand)
		strings.write_string(builder, ")")
		if derived.results != nil {
			strings.write_string(builder, " -> ")

			// Check if results need parentheses (have names)
			parens_needed := false
			if field_list, ok := derived.results.derived.(^ast.Field_List); ok {
				for field_node in field_list.list {
					if field, is_field := field_node.derived.(^ast.Field); is_field {
						if len(field.names) != 0 {
							parens_needed = true
							break
						}
					}
				}
			}

			if parens_needed {
				strings.write_rune(builder, '(')
			}
			write_expr_to_string(builder, derived.results, shorthand)
			if parens_needed {
				strings.write_rune(builder, ')')
			}
		}

	case ^ast.Struct_Type:
		strings.write_string(builder, "struct ")
		if derived.poly_params != nil {
			strings.write_rune(builder, '(')
			write_expr_to_string(builder, derived.poly_params, shorthand)
			strings.write_string(builder, ") ")
		}
		if derived.is_packed {
			strings.write_string(builder, "#packed ")
		}
		if derived.is_raw_union {
			strings.write_string(builder, "#raw_union ")
		}
		// C++ Reference: check_expr.cpp:13533-13536 prints FOUR flags; the port had two.
		// Both fields exist on ast.Struct_Type and the port's parser sets them, so any message
		// naming an anonymous `struct #all_or_none {...}` or `struct #simple {...}` lost the tag.
		if derived.is_all_or_none {
			strings.write_string(builder, "#all_or_none ")
		}
		if derived.is_simple {
			strings.write_string(builder, "#simple ")
		}
		if derived.align != nil {
			strings.write_string(builder, "#align ")
			write_expr_to_string(builder, derived.align, shorthand)
			strings.write_rune(builder, ' ')
		}
		strings.write_rune(builder, '{')
		if shorthand {
			strings.write_string(builder, "...")
		} else if derived.fields != nil {
			if field_list, ok := derived.fields.derived.(^ast.Field_List); ok {
				write_struct_fields_to_string(builder, field_list.list)
			}
		}
		strings.write_rune(builder, '}')

	case ^ast.Union_Type:
		strings.write_string(builder, "union ")
		if derived.poly_params != nil {
			strings.write_rune(builder, '(')
			write_expr_to_string(builder, derived.poly_params, shorthand)
			strings.write_string(builder, ") ")
		}
		// Union kind tags
		#partial switch derived.kind {
		case .no_nil:
			strings.write_string(builder, "#no_nil ")
		case .shared_nil:
			strings.write_string(builder, "#shared_nil ")
		}
		if derived.align != nil {
			strings.write_string(builder, "#align ")
			write_expr_to_string(builder, derived.align, shorthand)
			strings.write_rune(builder, ' ')
		}
		strings.write_rune(builder, '{')
		if shorthand {
			strings.write_string(builder, "...")
		} else {
			for variant, i in derived.variants {
				if i > 0 {
					strings.write_string(builder, ", ")
				}
				write_expr_to_string(builder, variant, false)
			}
		}
		strings.write_rune(builder, '}')

	case ^ast.Enum_Type:
		strings.write_string(builder, "enum ")
		if derived.base_type != nil {
			write_expr_to_string(builder, derived.base_type, shorthand)
			strings.write_rune(builder, ' ')
		}
		strings.write_rune(builder, '{')
		if shorthand {
			strings.write_string(builder, "...")
		} else {
			for field, i in derived.fields {
				if i > 0 {
					strings.write_string(builder, ", ")
				}
				write_expr_to_string(builder, field, shorthand)
			}
		}
		strings.write_rune(builder, '}')

	case ^ast.Field_List:
		// Decide whether to print `name: type` or just `type` for every field.
		//
		// C++ Reference: check_expr.cpp write_expr_to_string.
		//
		// The test on the first name MUST be `!is_blank_ident_node(...)`, not "is an Ident
		// whose name is not _". The two agree on every ordinary name and INVERT on names that
		// are not Idents at all - which is exactly what a polymorphic parameter is, since `$E`
		// parses to an ^ast.Poly_Type. C++'s is_blank_ident(Ast *) returns false for any
		// non-Ident node (parser.cpp:1750-1756), so a poly name counts as a name; the earlier
		// Ident-only form let it fall through, so a field list whose names were ALL polymorphic
		// scored has_name = false and printed as bare types: `proc($E: typeid)` came out as
		// `proc(typeid)`, and `struct($T: typeid)` as `struct (typeid)`. A list mixing poly and
		// ordinary names was unaffected, because the ordinary name set the flag - which is why
		// this only ever showed up on fully-polymorphic signatures.
		has_name := false
		for field_node in derived.list {
			field, ok := field_node.derived.(^ast.Field)
			if !ok {
				continue
			}
			if len(field.names) > 1 {
				has_name = true
				break
			}
			if len(field.names) == 0 {
				continue
			}
			if !is_blank_ident_node(field.names[0]) {
				has_name = true
				break
			}
		}

		for field_node, i in derived.list {
			if i > 0 {
				strings.write_string(builder, ", ")
			}
			if has_name {
				write_expr_to_string(builder, field_node, shorthand)
			} else {
				// Just print type without name
				if field, ok := field_node.derived.(^ast.Field); ok {
					write_field_flags(builder, field)
					write_expr_to_string(builder, field.type, shorthand)
				}
			}
		}

	case ^ast.Field:
		write_field_flags(builder, derived)

		for name, i in derived.names {
			if i > 0 {
				strings.write_string(builder, ", ")
			}
			write_expr_to_string(builder, name, shorthand)
		}
		if len(derived.names) > 0 {
			if derived.type == nil && derived.default_value != nil {
				strings.write_rune(builder, ' ')
			}
			strings.write_string(builder, ":")
		}
		if derived.type != nil {
			strings.write_rune(builder, ' ')
			write_expr_to_string(builder, derived.type, shorthand)
		}
		if derived.default_value != nil {
			if derived.type != nil {
				strings.write_rune(builder, ' ')
			}
			strings.write_string(builder, "= ")
			write_expr_to_string(builder, derived.default_value, shorthand)
		}

	case:
		// C++ Reference: check_expr.cpp:12882-12884 -- the `default:` arm of
		// write_expr_to_string writes the literal "(BadExpr)".
		//
		// This previously wrote "<unprintable %T>" instead, on the reasoning that "(BadExpr)"
		// is misleading because it names a real AST node and so reads as "the parser failed
		// here". That reasoning is about which text is BETTER, which is not the question this
		// port answers -- the oracle writes "(BadExpr)" and matching it is the whole job. The
		// substitute was also broken in its own right: node.derived is a UNION, and %T on a
		// union prints the union's own name, so every unhandled node rendered identically as
		// "<unprintable Any_Node>" and the format verb could never name the kind it promised.
		//
		// The nil case is not handled here because it cannot arrive: the prologue returns
		// early for a nil node, exactly as C++ does. The old `else` branch was dead.
		strings.write_string(builder, "(BadExpr)")
	}
}

// write_struct_fields_to_string writes a comma-separated list of fields
write_struct_fields_to_string :: proc(builder: ^strings.Builder, fields: []^ast.Field) {
	for field, i in fields {
		if i > 0 {
			strings.write_string(builder, ", ")
		}
		write_expr_to_string(builder, field, false)
	}
}

// write_field_flags writes field modifier flags like "using", "#no_alias", etc.
write_field_flags :: proc(builder: ^strings.Builder, field: ^ast.Field) {
	if .Using in field.flags {
		strings.write_string(builder, "using ")
	}
	if .No_Alias in field.flags {
		strings.write_string(builder, "#no_alias ")
	}
	if .C_Vararg in field.flags {
		strings.write_string(builder, "#c_vararg ")
	}
	if .Any_Int in field.flags {
		strings.write_string(builder, "#any_int ")
	}
	if .No_Broadcast in field.flags {
		strings.write_string(builder, "#no_broadcast ")
	}
	if .Const in field.flags {
		strings.write_string(builder, "#const ")
	}
	if .Subtype in field.flags {
		strings.write_string(builder, "#subtype ")
	}
}

// is_constant_string checks if an expression is a constant string value
// C++ Reference: check_builtin.cpp:253-260
//
// Parameters:
//   ctx: Checker context
//   builtin_name: Name of builtin for error messages
//   expr: Expression to check
//   name_: Optional output parameter to receive the string value
//
// Returns true if the expression is a constant string, false otherwise.
// Errors if the expression is not a constant string.
is_constant_string :: proc(ctx: ^Checker_Context, builtin_name: string, expr: ^ast.Node, name_: ^string = nil) -> bool {
	op := Operand{}
	check_expr(ctx, &op, expr)

	// Check if mode is Constant and value is a string
	if op.mode == .Constant {
		if str, ok := op.value.(string); ok {
			// Optionally return the string value
			if name_ != nil {
				name_^ = str
			}
			return true
		}
	}

	// Error: not a constant string
	// C++ Reference: line 260-262
	// Must include both expression string and type string
	expr_str := expr_to_string(op.expr)
	defer delete(expr_str)
	type_str := type_to_string(op.type)
	error_node(op.expr, "'%s' expected a constant string value, got %s of type %s", builtin_name, expr_str, type_str)
	return false
}

// is_ise_expr checks if a node is an implicit selector expression (.Foo)
// C++ Reference: check_expr.cpp:3814-3817
is_ise_expr :: proc(node: ^ast.Node) -> bool {
	n := unparen_expr(node)
	if n == nil {
		return false
	}
	_, ok := n.derived.(^ast.Implicit_Selector_Expr)
	return ok
}

// can_use_other_type_as_type_hint determines if a type can be used as a type hint
// C++ Reference: check_expr.cpp:3819-3824
//
// This is used in binary expressions to determine if the RHS type can be used as
// a hint for the LHS, when use_lhs_as_type_hint is true.
can_use_other_type_as_type_hint :: proc(use_lhs_as_type_hint: bool, other_type: ^Type) -> bool {
	if use_lhs_as_type_hint { 	// RHS in this case
		return other_type != nil && other_type != t_invalid && is_type_typed(other_type)
	}
	return false
}

// check_matrix_type_hint checks if a type hint is compatible with a matrix type
// C++ Reference: check_expr.cpp:3826-3850
//
// Returns the appropriate type hint for a matrix, considering:
// - Exact type match returns the hint
// - Matrix-to-matrix with same dimensions returns the hint
// - Matrix-to-array (for row/column vectors) returns the hint
// - Otherwise returns the original matrix type
check_matrix_type_hint :: proc(matrix_type: ^Type, type_hint: ^Type) -> ^Type {
	xt := base_type(matrix_type)
	if type_hint != nil {
		th := base_type(type_hint)

		// Exact match
		if are_types_identical(th, xt) {
			return type_hint
		}

		// Matrix to matrix conversion
		if xt.kind == .Matrix && th.kind == .Matrix {
			xt_matrix := &xt.variant.(Type_Matrix)
			th_matrix := &th.variant.(Type_Matrix)

			// C++ Reference: check_expr.cpp check_matrix_type_hint (merge ebac23eb0).
			// TWO changes upstream, only one of which the port needed:
			//   (a) `} if (` -> `} else if (` -- upstream's missing `else` meant the "ignore"
			//       branch FELL THROUGH into the dimension test, so two matrices with different
			//       ELEMENT types could still return type_hint. The port already had `else if`
			//       here, so it never carried that bug and needs no change for it.
			//   (b) a THIRD conjunct, `is_row_major` equality -- that one WAS missing here. Two
			//       matrices of identical element type and dimensions but opposite majorness are
			//       not interchangeable, and the hint must not be returned for them. LEDGER #798.
			if !are_types_identical(xt_matrix.elem, th_matrix.elem) {
				// ignore - fall through
			} else if xt_matrix.row_count == th_matrix.row_count &&
			          xt_matrix.column_count == th_matrix.column_count &&
			          xt_matrix.is_row_major == th_matrix.is_row_major {
				return type_hint
			}
		}

		// Matrix to array conversion (for vectors)
		if xt.kind == .Matrix && th.kind == .Array {
			xt_matrix := &xt.variant.(Type_Matrix)
			th_array := &th.variant.(Type_Array)

			// If elements don't match, ignore
			if !are_types_identical(xt_matrix.elem, th_array.elem) {
				// ignore - fall through
			} else if xt_matrix.row_count == 1 && xt_matrix.column_count == th_array.count {
				// Row vector to array
				return type_hint
			} else if xt_matrix.column_count == 1 && xt_matrix.row_count == th_array.count {
				// Column vector to array
				return type_hint
			}
		}
	}
	return matrix_type
}

// make_operand_from_node creates an operand from an AST node that has type/value info
// C++ Reference: check_expr.cpp:4468-4476
//
// Extracts the type and value information that was previously stored in the node's
// tav (Type And Value) field during earlier checking phases.
make_operand_from_node :: proc(node: ^ast.Node) -> Operand {
	assert(node != nil)

	o := Operand{}
	o.expr = node

	// Extract type/value from node's tav (Type And Value) field
	// C++ Reference: check_expr.cpp:4468-4476
	// The tav field is populated by add_type_and_value during expression checking
	o.type = node.tav.type
	o.mode = node.tav.mode
	o.value = node.tav.value

	// If type is nil, treat as invalid
	if o.type == nil {
		o.mode = .Invalid
		o.type = t_invalid
	}

	return o
}

// convert_exact_value_for_type converts an exact value to match a target type
// C++ Reference: check_expr.cpp:4649-4665
//
// Performs conversions like:
// - Boolean types: (currently commented out in C++)
// - Float types: convert to float representation
// - Integer/pointer types: convert to integer representation
// - Complex types: convert to complex representation
// - Quaternion types: convert to quaternion representation
convert_exact_value_for_type :: proc(v: Exact_Value, type: ^Type) -> Exact_Value {
	t := core_type(type)

	result := v

	// Convert based on target type
	if is_type_boolean(t) {
		// Note: C++ has this commented out
		// result = exact_value_to_boolean(v)
	} else if is_type_float(t) {
		result = exact_value_to_float(v)
	} else if is_type_integer(t) {
		result = exact_value_to_integer(v)
	} else if is_type_pointer(t) {
		result = exact_value_to_integer(v)
	} else if is_type_complex(t) {
		result = exact_value_to_complex(v)
	} else if is_type_quaternion(t) {
		result = exact_value_to_quaternion(v)
	}

	return result
}

// unselector_expr strips selector expressions to get the innermost selector field
// C++ Reference: parser.cpp:1891-1900
//
// Example: a.b.c -> c
// Returns the rightmost identifier in a chain of selector expressions
unselector_expr :: proc(node: ^ast.Node) -> ^ast.Node {
	n := unparen_expr(node)
	if n == nil {
		return nil
	}

	// Keep descending through selector expressions
	// C++ Reference: lines 1896-1897 - accesses node->SelectorExpr.selector
	// In Odin AST, the field is called 'field' instead of 'selector'
	for {
		if sel, ok := n.derived.(^ast.Selector_Expr); ok {
			// Access the selector field (called 'field' in Odin, 'selector' in C++)
			// sel.field is ^Ident which embeds Node, so this assignment is valid
			n = sel.field
		} else {
			break
		}
	}

	return n
}

// check_is_not_addressable checks if an operand cannot have its address taken
// C++ Reference: check_expr.cpp:2584-2618
//
// Returns true if the operand is not addressable, meaning you cannot use & on it.
// This includes:
// - Bit field fields (cannot take address of bit-packed fields)
// - Most optional-ok values (except pointers, variable unions, and any)
// - Non-map-index, non-compound-lit values that aren't variables or SoA variables
check_is_not_addressable :: proc(ctx: ^Checker_Context, o: ^Operand) -> bool {
	// Bit field fields cannot be addressed
	// C++ Reference: lines 2585-2588
	// Check stored is_bit_field flag from type_and_value_map
	// This catches both direct bit field access and nested access through bit fields
	if o.expr != nil {
		if tv, found := tav_lookup(ctx.info, o.expr); found {
			if tv.is_bit_field {
				return true // Not addressable
			}
		}
	}

	// Optional-ok addressing rules
	// C++ Reference: lines 2590-2607
	if o.mode == .Optional_Ok {
		expr := unselector_expr(o.expr)
		if expr == nil {
			return true
		}

		// Type assertion is special case
		if ta, ok := expr.derived.(^ast.Type_Assertion); ok {
			// C++ Reference: check_expr.cpp:2821-2832 --
			//     TypeAndValue tv = ta->expr->tav;
			//     if (is_type_pointer(tv.type))                                  return false;
			//     if (is_type_union(tv.type) && tv.mode == Addressing_Variable)   return false;
			//     if (is_type_any(tv.type))                                       return false;
			//     return true;
			// THREE divergences in the port's version, of which the second is the live one:
			//  1. it tested is_type_pointer(o.type) -- the assertion's RESULT type -- where the
			//     reference tests tv.type, the type of the asserted-FROM expression;
			//  2. it OMITTED `tv.mode == Addressing_Variable` on the union arm, so a union RVALUE
			//     (a call result) was treated as addressable;
			//  3. it applied type_deref to the source type, which the reference does not.
			// WITNESSED as a COUNT divergence by the text instrument (wit_b3rest/d_optional_ok):
			// `p := &get().(int)` on `get :: proc() -> U` -- the oracle emits
			// "Cannot take the pointer address of 'get().(int)'" and the port emitted nothing,
			// so the port hands back a pointer into a temporary.
			// *** I HAD LOGGED THIS CELL AS "NOT REPRODUCED" ON VERDICT ALONE. *** Both compilers
			// exit 1 (for an unrelated reason), so only comparing OUTPUT could see it -- exactly the
			// case my own note about "static confirmation of a code difference is not confirmation
			// of an effect" was written for, now resolved in the direction of the code read.
			tv, _ := tav_lookup(ctx.info, ta.expr)
			if is_type_pointer(tv.type) {
				return false
			}
			if is_type_union(tv.type) && tv.mode == .Variable {
				return false
			}
			if is_type_any(tv.type) {
				return false
			}
		}
		// All other optional-ok cases are not addressable
		return true
	}

	// Map index results are not addressable (special case: always addressable)
	// C++ Reference: lines 2608-2610
	if o.mode == .Map_Index {
		return false
	}

	// Compound literals are addressable
	// C++ Reference: lines 2612-2615
	expr := unparen_expr(o.expr)
	if expr != nil {
		if _, ok := expr.derived.(^ast.Comp_Lit); ok {
			return false
		}
	}

	// Only Variable and SoaVariable modes are addressable
	// C++ Reference: lines 2617
	return o.mode != .Variable && o.mode != .Soa_Variable
}

// exact_bit_set_all_set_mask computes the mask for a fully populated bit set
// C++ Reference: check_expr.cpp:2620-2695
//
// Returns an ExactValue containing a BigInt mask with bits set for all valid
// values in the bit set range. This is used for validating bit set operations.
//
// Algorithm:
// - For unbounded bit sets (no elem): returns -1 (all bits set)
// - For enum-based bit sets: sets bits corresponding to enum field values
// - For range-based bit sets: sets bits for all values in [lower, upper]
exact_bit_set_all_set_mask :: proc(type: ^Type) -> Exact_Value {
	t := base_type(type)
	assert(t.kind == .Bit_Set)

	bs := &t.variant.(Type_Bit_Set)
	lower := bs.lower
	upper := bs.upper
	elem := bs.elem
	underlying := bs.underlying
	is_backed := underlying != nil

	// Initialize big integers for computation
	b_lower, b_upper, one: big.Int
	big.int_set_from_integer(&b_lower, int(lower))
	big.int_set_from_integer(&b_upper, int(upper))
	big.int_set_from_integer(&one, 1)

	mask: big.Int

	if elem == nil {
		// Unbounded bit set - all bits are valid
		// C++ Reference: lines 2634-2635
		big.int_set_from_integer(&mask, -1)
	} else if is_type_enum(elem) {
		// Enum-based bit set
		// C++ Reference: lines 2636-2668
		e := base_type(elem)
		assert(e.kind == .Enum)
		enum_type := &e.variant.(Type_Enum)

		// Extract enum min/max values and compare with bit_set bounds
		// C++ Reference: lines 2641-2642
		min_match := false
		max_match := false

		if enum_min, is_min_int := enum_type.min_value.(big.Int); is_min_int {
			cmp_result, _ := big.int_cmp(&enum_min, &b_lower)
			if cmp_result == 0 || is_backed {
				min_match = true
			}
		}
		if enum_max, is_max_int := enum_type.max_value.(big.Int); is_max_int {
			cmp_result, _ := big.int_cmp(&enum_max, &b_upper)
			if cmp_result == 0 {
				max_match = true
			}
		}

		if min_match && max_match {
			// Compute mask based on enum field values
			// C++ Reference: lines 2644-2663
			lower_base := is_backed ? min(0, lower) : lower
			b_lower_base: big.Int
			big.int_set_from_integer(&b_lower_base, int(lower_base))

			// Iterate through enum fields and set corresponding bits
			for field in enum_type.fields {
				if field.kind != .Constant {
					continue
				}
				constant := field.variant.(Entity_Constant)
				if field_val, is_int := constant.value.(big.Int); is_int {
					shift_amount: big.Int
					big.int_sub(&shift_amount, &field_val, &b_lower_base)

					value: big.Int
					shift_int, _ := big.int_get_i64(&shift_amount)
					big.int_shl(&value, &one, int(shift_int))

					big.int_bit_or(&mask, &mask, &value)
				}
			}
		} else {
			// Enum range doesn't match - fall back to all bits
			// C++ Reference: lines 2665-2667
			big.int_set_from_integer(&mask, -1)
		}
	} else {
		// Range-based bit set
		// C++ Reference: lines 2669-2680
		lower_base := lower
		for x := lower; x <= upper; x += 1 {
			shift_amount := int(x - lower_base)

			value: big.Int
			big.int_shl(&value, &one, shift_amount)

			big.int_bit_or(&mask, &mask, &value)
		}
	}

	// Return as ExactValue
	// C++ Reference: lines 2691-2694
	result := Exact_Value(mask)
	return result
}

// ======================================================================================
// RANGE EXPRESSION CHECKING
// C++ Reference: check_expr.cpp:8578-8676
// ======================================================================================

// check_range validates range/interval expressions (e.g., 0..<10, 1..=100)
// Used in for-in loops and array literals with range indices
// C++ Reference: check_expr.cpp:8578-8676
check_range :: proc(ctx: ^Checker_Context, node: ^ast.Node, is_for_loop: bool, x: ^Operand, y: ^Operand, inline_for_depth: ^Exact_Value, type_hint: ^Type = nil) -> bool {
	// C++ Reference: check_expr.cpp check_call_parameter_mixture
	if !is_ast_range(cast(^ast.Expr)node) {
		return false
	}

	// C++ Reference: check_expr.cpp check_call_parameter_mixture
	expr := cast(^ast.Expr)node
	binary_expr, ok := expr.derived.(^ast.Binary_Expr)
	if !ok {
		return false
	}

	// Check left and right operands
	// C++ Reference: check_expr.cpp check_call_parameter_mixture
	check_expr_with_type_hint(ctx, x, binary_expr.left, type_hint)
	if x.mode == .Invalid {
		return false
	}
	check_expr_with_type_hint(ctx, y, binary_expr.right, type_hint)
	if y.mode == .Invalid {
		return false
	}

	// Convert operands to compatible types
	// C++ Reference: check_expr.cpp:8594-8610
	convert_to_typed(ctx, x, y.type)
	if x.mode == .Invalid {
		return false
	}
	convert_to_typed(ctx, y, x.type)
	if y.mode == .Invalid {
		return false
	}

	convert_to_typed(ctx, x, default_type(y.type))
	if x.mode == .Invalid {
		return false
	}
	convert_to_typed(ctx, y, default_type(x.type))
	if y.mode == .Invalid {
		return false
	}

	// C++ Reference: check_expr.cpp:8612-8624
	if !are_types_identical(x.type, y.type) {
		if x.type != t_invalid && y.type != t_invalid {
			xt := type_to_string(x.type)
			yt := type_to_string(y.type)
			expr_str := expr_to_string(x.expr)
			defer delete(expr_str)
			error_token(binary_expr.op, "Mismatched types in interval expression '%s' : '%s' vs '%s'", expr_str, xt, yt)
		}
		return false
	}

	type := x.type

	// Validate type for range expressions
	// C++ Reference: check_expr.cpp check_range
	if is_for_loop {
		if !is_type_integer(type) && !is_type_float(type) && !is_type_enum(type) {
			error_token(binary_expr.op, "Only numerical types are allowed within interval expressions")
			return false
		}
	} else {
		if !is_type_integer(type) && !is_type_float(type) && !is_type_pointer(type) && !is_type_enum(type) {
			error_token(binary_expr.op, "Only numerical and pointer types are allowed within interval expressions")
			return false
		}
	}

	// If both operands are constant, validate range and compute depth
	// C++ Reference: check_expr.cpp check_range
	if x.mode == .Constant && y.mode == .Constant {
		a := x.value
		b := y.value

		assert(are_types_identical(x.type, y.type))

		// Determine comparison operator based on range type
		// C++ Reference: check_expr.cpp check_range
		op: tokenizer.Token_Kind
		#partial switch binary_expr.op.kind {
		case .Ellipsis:
			op = .Lt_Eq // ..
		case .Range_Full:
			op = .Lt_Eq // ..=
		case .Range_Half:
			op = .Lt // ..<
		case:
			// UNREACHABLE IN BOTH IMPLEMENTATIONS, and left alone deliberately (#266: do not
			// implement or "fix" unreachable branches). check_range's own entry guard is
			// is_ast_range, which ends in is_token_range (C++ parser.cpp is_token_range) accepting
			// EXACTLY {Ellipsis, RangeFull, RangeHalf} -- the same three the port's
			// is_ast_range accepts (check_stmt.odin:4649). No fourth operator can arrive here.
			//
			// The shapes DO differ and it does not matter: C++ initialises `op = Token_Lt`,
			// reports, and `break`s -- falling through to compare_exact_values with Token_Lt and
			// possibly emitting a SECOND diagnostic. The port returns instead. Since neither arm
			// is reachable, this is a divergence in dead code; converting the port to C++'s
			// fall-through would add an unreachable path and a second unreachable diagnostic.
			error_token(binary_expr.op, "Invalid range operator")
			return false
		}

		// Validate range ordering
		// C++ Reference: check_expr.cpp check_range
		valid_range := compare_exact_values(op, a, b)
		if !valid_range {
			error_token(binary_expr.op, "Invalid interval range")
			return false
		}

		// Compute inline_for_depth if requested (for constant folding)
		// C++ Reference: check_expr.cpp check_range
		//
		// SHAPE DIVERGENCE, verified OBSERVATIONALLY IDENTICAL rather than assumed so. C++
		// computes the depth UNCONDITIONALLY and makes only the STORE conditional:
		//     ExactValue inline_for_depth = exact_value_sub(b, a);
		//     if (ie->op.kind != Token_RangeHalf) { ... increment_one ... }
		//     if (inline_for_depth_) *inline_for_depth_ = inline_for_depth;
		// The port hoists the nil test around the whole computation. That is only safe because
		// both operations are PURE: exact_value_sub and exact_value_increment_one emit no
		// diagnostics and mutate no shared state in either implementation (checked in
		// src/exact_value.cpp exact_value_sub and its sibling, and in the port's own definitions). If either ever
		// gains a diagnostic -- an overflow report, say -- this guard would start SWALLOWING it
		// and the computation must move back out.
		if inline_for_depth != nil {
			depth := exact_value_sub(b, a)
			if binary_expr.op.kind != .Range_Half {
				depth = exact_value_increment_one(depth)
			}
			inline_for_depth^ = depth
		}
	} else if inline_for_depth != nil {
		// C++ Reference: check_expr.cpp check_range
		error_token(binary_expr.op, "Interval expressions must be constant")
		return false
	}

	// Add type information to AST nodes
	// C++ Reference: check_expr.cpp check_range
	add_type_and_value(ctx, binary_expr.left, x.mode, x.type, x.value)
	add_type_and_value(ctx, binary_expr.right, y.mode, y.type, y.value)

	return true
}

// ======================================================================================
// DIRECTIVE HELPERS
// C++ Reference: check_expr.cpp is_load_directive_call
// ======================================================================================

// is_load_directive_call checks if an expression is a #load directive call
// C++ Reference: check_expr.cpp is_load_directive_call
is_load_directive_call :: proc(call: ^ast.Expr) -> bool {
	expr := unparen_expr(call)
	if expr == nil {
		return false
	}

	ce, is_call := expr.derived.(^ast.Call_Expr)
	if !is_call {
		return false
	}

	if ce.expr == nil {
		return false
	}

	bd, is_directive := ce.expr.derived.(^ast.Basic_Directive)
	if !is_directive {
		return false
	}

	return bd.name == "load"
}

// is_call_expr_field_value checks if an expression is a field value (field = value)
// C++ Reference: check_expr.cpp (inline pattern check)
// Used in call argument and compound literal parsing
is_call_expr_field_value :: proc(expr: ^ast.Expr) -> bool {
	if expr == nil {
		return false
	}
	_, is_fv := expr.derived.(^ast.Field_Value)
	return is_fv
}

// check_for_dynamic_literals checks if dynamic literals feature is enabled for the current file
// C++ Reference: check_expr.cpp:9727-9734
// Returns true if dynamic literals (dynamic arrays, maps) are allowed
// Reports an error if not enabled
check_for_dynamic_literals :: proc(ctx: ^Checker_Context, node: ^ast.Node) -> bool {
	// C++ Reference: check_expr.cpp:10514 uses check_feature_flags(c, node), NOT ctx.file
	// directly. Reading ctx.file skips the proc-literal and node fallbacks, so the flag was
	// invisible whenever ctx.file was unset (LEDGER task 244).
	// C++ Reference: check_expr.cpp:10620-10643. The reference's flag test is ONE NEGATED
	// CONJUNCTION whose `else` still runs a CONTEXT check:
	//
	//     if ((check_feature_flags(c, node) & OptInFeatureFlag_DynamicLiterals) == 0 &&
	//         !build_context.dynamic_literals) {
	//         ... the error block ...  return false;
	//     } else if (c->curr_proc_decl != nullptr && c->curr_proc_calling_convention != ProcCC_Odin) {
	//         if (c->scope != nullptr && (c->scope->flags & ScopeFlag_ContextDefined) == 0) {
	//             error(node, "Compound literals of dynamic types require a 'context' to defined");
	//         }
	//     }
	//     return true;
	//
	// The port split it into two early `return true`s, so the `else if` had no counterpart and
	// that diagnostic could NEVER fire -- `grep "require a 'context'"` found it nowhere in the
	// port. A dynamic literal inside a non-"odin"-convention procedure with no context was
	// silently accepted. (The reference's missing-apostrophe wording "to defined" is its own;
	// reproduced verbatim.)
	if check_feature_flags(ctx, node) & {.Dynamic_Literals} != {} || build_context.dynamic_literals {
		if ctx.curr_proc_decl != nil && ctx.curr_proc_calling_convention != .Odin {
			if ctx.scope != nil && .Context_Defined not_in ctx.scope.flags {
				error(node, "Compound literals of dynamic types require a 'context' to defined")
			}
		}
		return true
	}

	// C++ Reference: check_expr.cpp:10516-10521.
	//
	// The two continuation lines used to be omitted on the grounds that `error` is buffered
	// while `error_line` writes immediately, so they would print before their own header
	// (LEDGER task 192). That reasoning is obsolete: begin_error_block/end_error_block exist
	// precisely to hold the header and its continuations together, and the same omission has
	// now been found and fixed at four other sites this session.
	begin_error_block()
	defer end_error_block()
	error(node, "Compound literals of dynamic types are disabled by default")
	error_line("\tSuggestion: If you want to enable them for this specific file, add '#+feature dynamic-literals' at the top of the file\n")
	error_line("\tWarning: Please understand that dynamic literals will implicitly allocate using the current 'context.allocator' in that scope\n")
	if build_context.ODIN_DEFAULT_TO_NIL_ALLOCATOR {
		error_line("\tWarning: As '-default-to-panic-allocator' has been set, the dynamic compound literal may not be initialized as expected\n")
	}

	return false
}

// check_assignment_error_suggestion provides helpful hints after an assignment error
// C++ Reference: check_expr.cpp:102, 2434
check_assignment_error_suggestion :: proc(ctx: ^Checker_Context, operand: ^Operand, target_type: ^Type, node: ^ast.Node, max_bit_size: i64 = 0) {
	// C++ Reference: check_expr.cpp:2652-2702.
	//
	// The previous implementation was INVENTED, not ported: its wording differed from C++
	// throughout ("Convert array to slice with 'value[:]'" vs "The array expression may be
	// sliced with arr[:]"), it printed a literal `value` placeholder instead of the actual
	// expression, and it used independent `if`s where C++ has a single else-if CHAIN, so it
	// could emit several suggestions at once where C++ emits at most one.
	if operand == nil || target_type == nil || operand.type == nil {
		return
	}

	a := expr_to_string(operand.expr)
	defer delete(a)
	b := type_to_string(target_type)

	src := base_type(operand.type)
	dst := base_type(target_type)
	if src == nil || dst == nil {
		return
	}

	if is_type_array(src) && is_type_slice(dst) {
		if are_types_identical(src.variant.(Type_Array).elem, dst.variant.(Type_Slice).elem) {
			error_line("\tSuggestion: The array expression may be sliced with %s[:]\n", a)
		}
	} else if is_type_dynamic_array(src) && is_type_slice(dst) {
		if are_types_identical(src.variant.(Type_Dynamic_Array).elem, dst.variant.(Type_Slice).elem) {
			error_line("\tSuggestion: The dynamic array expression may be sliced with %s[:]\n", a)
		}
	} else if are_types_identical(src, dst) && !are_types_identical(operand.type, target_type) {
		error_line("\tSuggestion: The expression may be directly casted to type %s\n", b)
	} else if are_types_identical(src, t_string) && is_type_u8_slice(dst) {
		error_line("\tSuggestion: A string may be transmuted to %s\n", b)
		error_line("\t            This is an UNSAFE operation as string data is assumed to be immutable,\n")
		error_line("\t            whereas slices in general are assumed to be mutable.\n")
	} else if is_type_u8_slice(src) && are_types_identical(dst, t_string) && operand.mode != .Constant {
		error_line("\tSuggestion: The expression may be casted to %s\n", b)
	} else if check_integer_exceed_suggestion(ctx, operand, target_type, max_bit_size) {
		// C++ Reference: check_expr.cpp check_assignment_error_suggestion. This arm was missing entirely, so an
		// out-of-range integer constant got no explanation of what the bound actually is.
		return
	} else if is_expr_inferred_fixed_array(ctx.type_hint_expr) && is_type_array_like(target_type) && is_type_array_like(operand.type) {
		hint := expr_to_string(ctx.type_hint_expr)
		defer delete(hint)
		error_line("\tSuggestion: Make sure that `%s` is attached to the compound literal directly\n", hint)
	} else if is_type_pointer(target_type) && operand.mode == .Variable && are_types_identical(type_deref(target_type), operand.type) {
		error_line("\tSuggestion: Did you mean `&%s`\n", a)
	} else if is_type_pointer(operand.type) && are_types_identical(type_deref(operand.type), target_type) {
		// C++ strips a leading '&' rather than producing `&x^`.
		if len(a) > 0 && a[0] == '&' {
			error_line("\tSuggestion: Did you mean `%s`\n", a[1:])
		} else {
			error_line("\tSuggestion: Did you mean `%s^`\n", a)
		}
	}
}

// check_cast_error_suggestion provides helpful hints after a cast error
// C++ Reference: check_expr.cpp:2486-2527
check_cast_error_suggestion :: proc(ctx: ^Checker_Context, operand: ^Operand, target_type: ^Type, node: ^ast.Node) {
	// C++ Reference: check_expr.cpp:2704-2743.
	//
	// The previous implementation was INVENTED, like its assignment sibling (LEDGER task 237):
	// none of its messages ("If reinterpreting bits, use 'transmute(T)value'", "Cast through
	// rawptr", "Use explicit enum member") appear anywhere in C++, and it used independent
	// `if`s where C++ has one else-if chain.
	//
	// NOTE: C++'s uintptr-source arm USED TO write `"\tSuggestion: %a may be directly casted to
	// %s\n"`. `%a` is gb's unimplemented hex-float case, which consumes no vararg, so the
	// following `%s` printed the wrong argument. The port deliberately used `%s` here -- printing
	// what was evidently meant rather than reproducing a garbled line -- and that judgement is now
	// vindicated: filed as #206, fixed upstream and merged, and C++ reads `%s` too. The port needs
	// no change; only this note was stale. LEDGER #385.
	if operand == nil || target_type == nil || operand.type == nil {
		return
	}

	a := expr_to_string(operand.expr)
	defer delete(a)
	b := type_to_string(target_type)

	src := base_type(operand.type)
	dst := base_type(target_type)
	if src == nil || dst == nil {
		return
	}

	if is_type_array(src) && is_type_slice(dst) {
		if are_types_identical(src.variant.(Type_Array).elem, dst.variant.(Type_Slice).elem) {
			error_line("\tSuggestion: the array expression may be sliced with %s[:]\n", a)
		}
	} else if is_type_pointer(operand.type) && is_type_integer(target_type) {
		if is_type_uintptr(target_type) {
			error_line("\tSuggestion: a pointer may be directly casted to %s\n", b)
		} else {
			error_line("\tSuggestion: for a pointer to be casted to an integer, it must be converted to 'uintptr' first\n")
			x := type_size_of(operand.type)
			y := type_size_of(target_type)
			if x != y {
				error_line("\tNote: the type of expression and the type of the cast have a different size in bytes, %d vs %d\n", x, y)
			}
		}
	} else if is_type_integer(operand.type) && is_type_pointer(target_type) {
		if is_type_uintptr(operand.type) {
			error_line("\tSuggestion: %s may be directly casted to %s\n", a, b)
		} else {
			error_line("\tSuggestion: for an integer to be casted to a pointer, it must be converted to 'uintptr' first\n")
		}
	} else if are_types_identical(src, t_string) && is_type_u8_slice(dst) {
		error_line("\tSuggestion: a string may be transmuted to %s\n", b)
	} else if check_integer_exceed_suggestion(ctx, operand, target_type) {
		// C++ Reference: check_expr.cpp check_cast_error_suggestion -- the FINAL arm, which the
		// port was missing. C++ calls check_integer_exceed_suggestion from BOTH
		// check_assignment_error_suggestion AND check_cast_error_suggestion; the port had only
		// the assignment one. So `i64(1e100)` printed the "cannot be represented" line but not
		// the "The maximum value that can be represented by 'i64' is ..." note that follows it,
		// while `x: i64 = 1e100` printed both.
		//
		// INVISIBLE TO parity.sh: the missing text is a CONTINUATION line, and #155 established
		// the comparator cannot see those. Corpus-wide parity was 0/0/0 with this live.
		return
	}
}

// check_integer_exceed_suggestion explains WHY an integer constant does not fit, by computing
// the actual representable bound for the target type.
//
// C++ Reference: check_expr.cpp:2574-2651.
//
// The previous implementation was INVENTED and DEAD, both at once. It was a hardcoded table
// of hand-written strings C++ never emits ("Note: u8 range is 0 to 255", "Suggestion: Use a
// larger unsigned type (u16, u32, u64) or check the value"), covering only the ten named
// basic kinds and silently saying nothing for any other integer type; and it had ZERO callers,
// so none of it ever reached a user. C++ derives the bound arithmetically from the type's bit
// size, so it works for every integer type including bit_field fields of arbitrary width.
//
// Returns whether it handled the operand, because C++ uses it as an arm of an else-if chain.
check_integer_exceed_suggestion :: proc(ctx: ^Checker_Context, operand: ^Operand, type: ^Type, max_bit_size: i64 = 0) -> bool {
	if operand == nil || type == nil || !is_type_integer(type) {
		return false
	}
	value_int, is_integer := operand.value.(big.Int)
	if !is_integer {
		return false
	}

	b := type_to_string(type)

	if is_type_enum(operand.type) {
		if check_is_castable_to(ctx, operand, type) {
			ot := type_to_string(operand.type)
			// NOTE(parity): C++ omits the trailing newline on this one line. Reproduced.
			error_line("\tSuggestion: Try casting the '%s' expression to '%s'", ot, b)
		}
		return true
	}

	bit_size := i64(8 * type_size_of(type))
	size_changed := false
	if max_bit_size > 0 {
		size_changed = bit_size != max_bit_size
		bit_size = min(bit_size, max_bit_size)
	}

	bi := value_int
	negative, _ := big.is_neg(&bi)

	max_size: big.Int
	defer big.destroy(&max_size)
	one: big.Int
	defer big.destroy(&one)
	big.int_set_from_integer(&one, 1)

	print_max :: proc(b: string, size_changed: bool, bit_size: i64, max_size: ^big.Int) {
		str, err := big.int_to_string(max_size)
		if err != nil {
			return
		}
		defer delete(str)
		if size_changed {
			error_line("\tThe maximum value that can be represented with that bit_field's field of '%s | %d' is '%s'\n", b, bit_size, str)
		} else {
			error_line("\tThe maximum value that can be represented by '%s' is '%s'\n", b, str)
		}
	}

	if is_type_unsigned(type) {
		big.int_set_from_integer(&max_size, 1)
		big.int_shl(&max_size, &max_size, int(bit_size))
		big.int_sub(&max_size, &max_size, &one)

		if negative {
			error_line("\tA negative value cannot be represented by the unsigned integer type '%s'\n", b)
			dst: big.Int
			defer big.destroy(&dst)
			big.int_neg(&dst, &bi)
			if cmp, err := big.int_cmp(&dst, &max_size); err == nil && cmp < 0 {
				big.int_sub(&dst, &dst, &one)
				if str, serr := big.int_to_string(&dst); serr == nil {
					defer delete(str)
					error_line("\tSuggestion: ~%s(%s)\n", b, str)
				}
			}
		} else {
			print_max(b, size_changed, bit_size, &max_size)
		}
	} else {
		big.int_set_from_integer(&max_size, 1)
		big.int_shl(&max_size, &max_size, int(bit_size - 1))
		if negative {
			big.int_neg(&max_size, &max_size)
		} else {
			big.int_sub(&max_size, &max_size, &one)
		}
		print_max(b, size_changed, bit_size, &max_size)
	}

	return true
}

// calling_convention_to_string returns a string representation of a calling convention
calling_convention_to_string :: proc(cc: Calling_Convention) -> string {
	switch cc {
	case .Preserve_None: return "preserve/none"
	case .Preserve_Most: return "preserve/most"
	case .Preserve_All: return "preserve/all"
	case .Invalid: return "invalid"
	case .Odin: return "odin"
	case .Contextless: return "contextless"
	case .C: return "c"
	case .Std: return "std"
	case .Fast: return "fast"
	case .None: return "none"
	case .Naked: return "naked"
	case .Inline_Asm: return "inline_asm"
	case .Win64: return "win64"
	case .SysV: return "sysv"
	}
	return "unknown"
}


// populate_proc_parameter_list returns the parameter entity list used as the
// left-hand side when unpacking a call's positional arguments, so that each
// argument gets the matching parameter's type as its type hint.
//
// For an unspecialized polymorphic signature the polymorphic slots are left nil:
// their types are not known until instantiation, so hinting with them would be
// wrong.
//
// C++ Reference: check_expr.cpp populate_proc_parameter_list
populate_proc_parameter_list :: proc(ctx: ^Checker_Context, proc_type: ^Type, allocator := context.temp_allocator) -> []^Entity {
	if proc_type == nil || proc_type == t_invalid {
		return nil
	}

	bt := base_type(proc_type)
	if bt == nil || bt.kind != .Proc {
		return nil
	}
	pt, is_proc := &bt.variant.(Type_Proc)
	if !is_proc {
		return nil
	}
	if pt.params == nil {
		return nil
	}
	params, is_tuple := &pt.params.variant.(Type_Tuple)
	if !is_tuple {
		return nil
	}

	if !pt.is_polymorphic || pt.is_poly_specialized {
		return params.variables[:]
	}

	// NOTE(bill): Create 'lhs' list in order to ignore parameters which are polymorphic
	lhs := make([]^Entity, len(params.variables), allocator)
	for e, i in params.variables {
		if e != nil && !is_type_polymorphic(e.type) {
			lhs[i] = e
		}
	}
	return lhs
}
