package checker

/*
Helper functions for declaration checking.

These functions are required by check_decl.odin and provide various utilities
for type checking, attribute processing, and entity management.
*/

import "core:container/queue"
import "core:math/big"
import "core:odin/ast"
import "core:odin/tokenizer"
import "core:strings"
import "core:sync"
import "core:unicode"
import "core:unicode/utf8"

// ======================================================================================
// HELPER FUNCTIONS FOR DECLARATION CHECKING
// ======================================================================================

// Unpack_Flag controls unpacking behavior for check_unpack_arguments
// C++ Reference: check_expr.cpp:6039-6043
Unpack_Flag :: enum {
	Allow_Ok, // Allow optional-ok unpacking (x, ok := map[key])
	Allow_Undef, // Allow uninitialized values (---)
}

// entity_of_node extracts the entity from an AST node
// C++ Reference: checker.cpp entity_of_node:1804-1839
entity_of_node :: proc(info: ^Checker_Info, expr: ^ast.Node) -> ^Entity {
	if expr == nil {
		return nil
	}

	expr_unparen := unparen_expr(expr)
	if expr_unparen == nil {
		return nil
	}

	// C++ Reference: checker.cpp entity_of_node:1806-1837
	#partial switch node in expr_unparen.derived {
	case ^ast.Ident:
		// C++ Reference: checker.cpp entity_of_node:1808-1814
		// In C++: `Entity *e = ident->entity;` then `return e`.
		// In Odin: retrieve from ast_entity_map.
		//
		// #715: THE `Overridden` EARLY RETURN WAS A DEFECT, AND ITS COMMENT WAS WRONG TWICE.
		// It read: "C++ has a panic here for debugging, but we'll just return nil to match the
		// defensive behavior". C++ (checker.cpp:1810-1813) actually reads:
		//     Entity *e = ident->entity;
		//     if (e && e->flags & EntityFlag_Overridden) {
		//         // GB_PANIC("use of an overriden entity: %.*s", LIT(e->token.string));
		//     }
		//     return e;
		// The GB_PANIC is COMMENTED OUT. C++ enters the `if`, does nothing, and returns the entity
		// REGARDLESS. So there was never a choice between "panic" and "defensively return nil" --
		// the port invented a THIRD behaviour neither the live reference nor the disabled one has,
		// and every caller then saw an absent entity where one exists. LEDGER #174: a commented-out
		// panic is the reference DECLINING to enforce an invariant; the surrounding code is the
		// behaviour.
		return get_ast_entity(info, expr)

	case ^ast.Selector_Expr:
		// C++ Reference: checker.cpp entity_of_node:1815-1818 -- C++ uses unselector_expr (a LOOP over
		// nested SelectorExprs); the port strips one level here and re-enters, reaching the same node
		s := unparen_expr(node.field)
		if s != nil {
			return entity_of_node(info, s)
		}
		return nil

	case ^ast.Case_Clause:
		// C++ Reference: checker.cpp entity_of_node:1819-1821
		// In C++: return cc->implicit_entity
		// In Odin: retrieve from ast_entity_map
		return get_ast_entity(info, expr)

	case ^ast.Call_Expr:
		// C++ Reference: checker.cpp entity_of_node:1823-1825
		// In C++: return ce->entity_procedure_of
		// In Odin: retrieve from ast_entity_map
		return get_ast_entity(info, expr)

	case ^ast.Ternary_When_Expr:
		// C++ Reference: checker.cpp entity_of_node:1827-1836 -- C++ uses `goto retry` after selecting
		// the branch; the port recurses, which re-runs the same unparen + switch
		// Optimization: Constant when expressions can be evaluated at compile time
		// to return the entity from the selected branch (x or y)

		if node.cond == nil {
			return nil
		}

		// Access tav directly from AST node (no pointer indirection needed!)
		// NOTE: C++ explicitly recommends NOT using pointers for tav as it's much faster.
		// The AST now stores tav as a direct value, matching the C++ performance optimization.
		tav := node.cond.tav

		// Check if we have a valid exact value
		if tav.value == nil {
			return nil
		}

		// Check if condition is a compile-time boolean constant (C++ checker.cpp entity_of_node:1831)
		if cond_bool, ok := tav.value.(bool); ok {
			// Recursively find entity in the selected branch (C++ checker.cpp entity_of_node:1834)
			selected_expr := node.y if !cond_bool else node.x
			return entity_of_node(info, selected_expr)
		}

		return nil
	}

	return nil
}

// decl_info_of_entity is defined in entity_helpers.odin

// check_unpack_arguments unpacks tuple/multi-value expressions for assignments
// C++ Reference: check_expr.cpp:6046-6181
check_unpack_arguments :: proc(ctx: ^Checker_Context, lhs: []^Entity, operands: ^[dynamic]Operand, rhs_arguments: []^ast.Expr, flags: bit_set[Unpack_Flag], variadic_index: int = -1) -> bool {
	// C++ Reference: check_expr.cpp:6046-6181 (135 lines)

	// Helper: Add dependencies from unpacking tuples (C++ lines 6057-6079)
	add_dependencies_from_unpacking :: proc(c: ^Checker_Context, lhs: []^Entity, tuple_index: int, tuple_count: int) -> int {
		if len(lhs) == 0 || c.decl == nil {
			return tuple_count
		}

		// C++ lines 6061-6077: Copy dependencies from unpacked entities to current decl
		for j in 0 ..< tuple_count {
			if (tuple_index + j) >= len(lhs) {
				break
			}
			e := lhs[tuple_index + j]
			if e == nil {
				continue
			}

			decl := decl_info_of_entity(e)
			if decl == nil {
				continue
			}

			// Copy dependencies (C++ lines 6070-6076)
			sync.shared_guard(&decl.deps_mutex)
			sync.guard(&c.decl.deps_mutex)
			for dep in decl.deps {
				c.decl.deps[dep] = {}
			}
		}
		return tuple_count
	}

	// C++ lines 6081-6082
	allow_ok := .Allow_Ok in flags
	allow_undef := .Allow_Undef in flags

	// C++ lines 6084-6087
	is_variadic := variadic_index > -1
	var_index := variadic_index
	if !is_variadic {
		var_index = len(lhs)
	}

	// C++ lines 6089-6090
	optional_ok := false
	tuple_index := 0

	// C++ lines 6091-6178: Process each RHS expression
	for rhs in rhs_arguments {
		// C++ lines 6092-6095: Field values not allowed in unpacking
		rhs_to_check := rhs
		if fv, ok := rhs.derived.(^ast.Field_Value); ok {
			error(rhs, "Invalid use of 'field = value'")
			rhs_to_check = fv.value
		}

		// C++ lines 6097-6098: Create checker context copy
		c := ctx

		// C++ lines 6100-6119: Determine type hint from LHS
		o := Operand{}
		type_hint: ^Type = nil

		if len(lhs) > 0 {
			if tuple_index < var_index && tuple_index < len(lhs) {
				// C++ lines 6105-6110: Non-variadic parameter
				e := lhs[tuple_index]
				if e != nil {
					type_hint = e.type
				}
			} else if is_variadic && var_index >= 0 && var_index < len(lhs) {
				// C++ lines 6111-6118: Variadic parameter
				// C++ GB_ASSERTs that the entity is an ellipsis slice; the port
				// degrades to "no type hint" instead so a malformed signature
				// cannot take the process down.
				e := lhs[var_index]
				if e != nil && e.type != nil && .Ellipsis in e.flags {
					if slice, is_slice := e.type.variant.(Type_Slice); is_slice {
						type_hint = slice.elem
					}
				}
			}
		}

		// C++ lines 6121-6134: Check expression or handle uninitialized
		rhs_expr := unparen_expr(rhs_to_check)
		if allow_undef && rhs_expr != nil {
			if _, ok := rhs_expr.derived.(^ast.Undef); ok {
				// C++ lines 6123-6127
				o.type = t_untyped_uninit
				o.mode = .Value
				o.expr = rhs_to_check
				add_type_and_value(c, rhs_to_check, o.mode, o.type, o.value)
			} else {
				check_expr_base(c, &o, rhs_to_check, type_hint)
			}
		} else {
			check_expr_base(c, &o, rhs_to_check, type_hint)
		}

		// C++ lines 6131-6134
		if o.type != nil {
		} else {
		}
		if o.mode == .No_Value {
			error_operand_no_value(&o)
			o.mode = .Invalid
		}

		// C++ lines 6136-6177: Handle result (single value, optional-ok, or tuple)
		if o.type == nil || o.type.kind != .Tuple {
			// C++ lines 6137-6167: Check for optional-ok unpacking
			if allow_ok && len(lhs) == 2 && len(rhs_arguments) == 1 &&
			   (o.mode == .Map_Index || o.mode == .Optional_Ok || o.mode == .Optional_Ok_Ptr) {
				// C++ lines 6139-6162: Split into value and ok
				expr := unparen_expr(o.expr)

				val0 := o
				val1 := o
				val0.mode = .Value
				val1.mode = .Value
				val1.type = t_untyped_bool

				// C++ line 6147
				check_promote_optional_ok(c, &o, nil, &val1.type)

				// C++ lines 6149-6158: Mark ignores for type assertion optimization
				if expr != nil {
					if ta, ok := expr.derived.(^ast.Type_Assertion); ok {
						if o.mode == .Optional_Ok || o.mode == .Optional_Ok_Ptr {
							if len(lhs) > 0 && lhs[0] != nil && is_blank_ident(lhs[0].token.text) {
								ta.ignores[0] = true
							}
							if len(lhs) > 1 && lhs[1] != nil && is_blank_ident(lhs[1].token.text) {
								ta.ignores[1] = true
							}
						}
					}
				}

				// C++ lines 6160-6163
				append(operands, val0)
				append(operands, val1)
				optional_ok = true
				tuple_index += add_dependencies_from_unpacking(c, lhs, tuple_index, 2)
			} else {
				// C++ lines 6164-6167: Single value
				append(operands, o)
				tuple_index += 1
			}
		} else {
			// C++ lines 6168-6177: Unpack tuple
			tuple := &o.type.variant.(Type_Tuple)
			for e in tuple.variables {
				tuple_operand := o
				tuple_operand.type = e.type
				append(operands, tuple_operand)
			}

			count := len(tuple.variables)
			tuple_index += add_dependencies_from_unpacking(c, lhs, tuple_index, count)
		}
	}

	// C++ line 6180
	return optional_ok
}

// ======================================================================================
// TYPE AND UTILITY FUNCTIONS
// ======================================================================================

// add_type_info_type is defined in type_info.odin

// The following exact_value constructor functions are defined in exact_value.odin:
// - exact_value_typeid
// - exact_value_procedure
// - exact_value_compound
// - exact_value_pointer
// - exact_value_complex
// - exact_value_quaternion
// - exact_value_string16

// is_type_distinct checks if a type expression is marked as distinct
// C++ Reference: check_decl.cpp:354-386
is_type_distinct :: proc(node: ^ast.Expr) -> bool {
	// C++ Reference: check_decl.cpp:354-386
	expr := node
	for {
		if expr == nil {
			return false
		}
		#partial switch e in expr.derived {
		case ^ast.Paren_Expr:
			expr = e.expr
		case ^ast.Helper_Type:
			expr = e.type
		case:
			break
		}
		break
	}

	#partial switch e in expr.derived {
	case ^ast.Distinct_Type:
		return true
	case ^ast.Struct_Type, ^ast.Union_Type, ^ast.Enum_Type, ^ast.Proc_Type, ^ast.Bit_Field_Type:
		return true
	case ^ast.Pointer_Type, ^ast.Array_Type, ^ast.Dynamic_Array_Type, ^ast.Map_Type:
		return false
	}
	return false
}

// remove_type_alias_clutter removes parentheses and distinct wrappers
// C++ Reference: check_decl.cpp:388-401
remove_type_alias_clutter :: proc(node: ^ast.Expr) -> ^ast.Expr {
	// C++ Reference: check_decl.cpp:388-401
	expr := node
	for {
		if expr == nil {
			return nil
		}
		#partial switch e in expr.derived {
		case ^ast.Paren_Expr:
			expr = e.expr
		case ^ast.Distinct_Type:
			expr = e.type
		case:
			return expr
		}
	}
}

// alloc_type_enum is defined in types.odin

// alloc_type_named allocates a named type
// C++ Reference: types.cpp:1120-1129
alloc_type_named :: proc(name: string, base: ^Type, type_name: ^Entity, allocator := context.allocator) -> ^Type {
	// C++ line 1121-1128: Create named type with entity reference
	t := new(Type, allocator)
	t.kind = .Named
	t.variant = Type_Named {
		name      = name,
		base      = base != nil ? base_type(base) : nil,
		type_name = type_name, // C++ line 1125: t->Named.type_name = type_name
	}
	return t
}

// make_attribute_context creates an attribute context
// C++ Reference: checker.hpp:169-174
make_attribute_context :: proc(link_prefix, link_suffix: string) -> Attribute_Context {
	// C++ Reference: checker.hpp:169-174
	ac := Attribute_Context{}
	ac.link_prefix = link_prefix
	ac.link_suffix = link_suffix
	return ac
}

// check_decl_attribute_value evaluates an attribute value expression
// C++ Reference: checker.cpp:3395-3410
check_decl_attribute_value :: proc(ctx: ^Checker_Context, value: ^ast.Expr, type_hint: ^Type = nil) -> Exact_Value {
	// C++ Reference: checker.cpp:3396-3409
	ev := Exact_Value{}
	if value != nil {
		operand := Operand{}
		// The hint is what lets an untyped bit_set literal such as `@(fast_math = {.No_NaNs})`
		// resolve its element type; without it the literal has nothing to infer from.
		if type_hint != nil {
			check_expr_with_type_hint(ctx, &operand, value, type_hint)
		} else {
			check_expr(ctx, &operand, value)
		}
		if operand.mode != .Invalid {
			if operand.mode == .Constant {
				ev = operand.value
			} else {
				error(value, "Expected a constant attribute element")
			}
		}
	}
	return ev
}

// Attribute_Decl_Kind selects which attribute table applies, as C++ does by passing a
// different DECL_ATTRIBUTE_PROC to check_decl_attributes.
//
// C++ Reference: src/checker.cpp -- foreign_block_decl_attribute (3706), proc_group_attribute
// (3779), proc_decl_attribute (3833), var_decl_attribute (4285), const_decl_attribute (4431),
// type_decl_attribute (4456), import_decl_attribute (5570), foreign_import_decl_attribute
// (5671). The caller picks the table; a name absent from it makes the handler return false,
// which lands on the "Unknown attribute element name" path.
//
// The port previously had ONE flat chain shared by every declaration kind, so it accepted
// every attribute everywhere: @(objc_class) on a procedure, @(cold) on a variable,
// @(priority_index) on anything. See LEDGER task 251/253.
Attribute_Decl_Kind :: enum {
	Proc,
	Var,
	Const,
	Type,
	Proc_Group,
	Foreign_Block,
	Foreign_Import,
	Import,
}

// The tables below were derived EMPIRICALLY from the oracle, one attribute per package so
// that attributes cannot interact, with the error cap raised and runs that crashed or hit the
// cap discarded rather than read as "accepted". A static read of checker.cpp disagreed with
// reality in both directions -- it over-assigned names to proc_decl_attribute because the
// function's line range ran past its end, and it missed that `private` is accepted on every
// kind.
//
// Each name is probed in SEVERAL forms (bare, ="none", =1, =helper, =int) and counted valid
// if ANY form avoids the unknown-name error. Probing only the bare form is not enough: an
// attribute whose handler needs a value returns false when written bare, which is
// indistinguishable from "not in this table". That mistake put `linkage` in no table but
// const, and cost a 6 -> 3048 sweep before the corpus caught it.
// LEDGER task 252/253 records the four failed derivations and why each was wrong.
@(rodata) attr_names_proc := [?]string{
	"cold", "deferred", "deferred_in", "deferred_in_by_ptr", "deferred_in_out",
	"deferred_in_out_by_ptr", "deferred_none", "deferred_out", "deferred_out_by_ptr",
	"deprecated", "disabled", "enable_target_feature", "entry_point_only", "export",
	"fast_math", "fini", "init", "instrumentation_enter", "instrumentation_exit", "link_name",
	"link_prefix", "link_section", "link_suffix", "linkage", "no_instrumentation",
	"no_sanitize_address",
	"no_sanitize_memory", "no_sanitize_thread", "objc_implement", "objc_is_class_method",
	"objc_name", "objc_selector", "objc_type", "optimization_mode", "private", "require",
	"require_results", "require_target_feature", "test",
}
@(rodata) attr_names_var := [?]string{
	"export", "link_name", "link_prefix", "link_section", "link_suffix", "linkage", "private",
	"require", "rodata", "static", "thread_local",
}
@(rodata) attr_names_const := [?]string{
	"link_name", "link_prefix", "link_suffix", "linkage", "private", "require", "rodata",
	"static", "thread_local",
}
@(rodata) attr_names_type := [?]string{
	"deprecated", "objc_class", "objc_context_provider", "objc_implement", "objc_ivar",
	"objc_superclass", "private", "raddbg_type_view",
}
@(rodata) attr_names_proc_group := [?]string{
	"objc_is_class_method", "objc_name", "objc_type", "private", "require_results",
}
@(rodata) attr_names_foreign_block := [?]string{
	"default_calling_convention", "link_prefix", "link_suffix", "private", "require_results",
}
@(rodata) attr_names_foreign_import := [?]string{
	"export", "extra_linker_flags", "force", "ignore_duplicates", "priority_index", "require",
}
@(rodata) attr_names_import := [?]string{"require"}

attribute_is_valid_for_kind :: proc(name: string, kind: Attribute_Decl_Kind) -> bool {
	// C++ handles `builtin` before the table is consulted (checker.cpp:4623), gated on the
	// declaration being in base:runtime, so it is never subject to the per-kind tables.
	if name == "builtin" {
		return true
	}
	table: []string
	switch kind {
	case .Proc:           table = attr_names_proc[:]
	case .Var:            table = attr_names_var[:]
	case .Const:          table = attr_names_const[:]
	case .Type:           table = attr_names_type[:]
	case .Proc_Group:     table = attr_names_proc_group[:]
	case .Foreign_Block:  table = attr_names_foreign_block[:]
	case .Foreign_Import: table = attr_names_foreign_import[:]
	case .Import:         table = attr_names_import[:]
	}
	for n in table {
		if n == name {
			return true
		}
	}
	return false
}

// report_unknown_attribute emits C++'s unknown-attribute diagnostic, honouring the two build
// flags that suppress it. C++ Reference: checker.cpp:4627-4633.
report_unknown_attribute :: proc(elem: ^ast.Node, name: string) {
	if build_context.ignore_unknown_attributes || name in build_context.custom_attributes {
		return
	}
	begin_error_block()
	defer end_error_block()
	error(elem, "Unknown attribute element name '%s'", name)
	error_line("\tDid you forget to use the build flag '-ignore-unknown-attributes' or '-custom-attribute:%s'?\n", name)
}

// check_decl_attributes checks declaration attributes
// C++ Reference: checker.cpp:4227-4311
// Extended to handle common attributes: deprecated, warning, link_name, test, init, fini, etc.
check_decl_attributes :: proc(ctx: ^Checker_Context, attributes: []^ast.Attribute, ac: ^Attribute_Context, kind: Attribute_Decl_Kind) {
	// C++ Reference: checker.cpp:4228 - Early return if no attributes
	if len(attributes) == 0 {
		return
	}

	// C++ Reference: checker.cpp:4565-4569. Snapshot the INHERITED link_prefix/link_suffix so the
	// epilogue can tell "inherited from the foreign block, untouched" from "set by this
	// declaration". C++ compares the string DATA POINTER, not the contents -- a declaration that
	// re-states the same prefix text is an override (and so a genuine conflict), not an
	// inheritance. Note this snapshot is taken AFTER the empty-attribute early return, exactly as
	// C++ does: a declaration with no attributes at all keeps its inherited prefix.
	original_link_prefix := ac != nil ? ac.link_prefix : ""
	original_link_suffix := ac != nil ? ac.link_suffix : ""

	// Process each attribute
	// C++ Reference: checker.cpp:4253-4299
	for attr in attributes {
		// attr is already ^ast.Attribute, no need for type switch
		// Process attribute elements
		for elem in attr.elems {
			name := ""
			value: ^ast.Expr = nil

			// Extract attribute name and value (C++ checker.cpp:4258-4281)
			#partial switch e in elem.derived {
			case ^ast.Ident:
				name = e.name
			case ^ast.Field_Value:
				// Attribute with value like @(deferred_in=target)
				if field_ident, ok := e.field.derived.(^ast.Ident); ok {
					name = field_ident.name
					value = e.value
				}
			case:
				error(elem, "Invalid attribute element")
				continue
			}

			// C++ selects the attribute table by declaration kind; a name the table does not
			// name makes the handler return false, landing on the unknown-attribute path.
			if !attribute_is_valid_for_kind(name, kind) {
				report_unknown_attribute(elem, name)
				continue
			}

			// Process attributes based on name
			// C++ Reference: checker.cpp proc_decl_attribute:3841-4291

			// @(deprecated="message") - C++ line 3774-3786
			if name == "deprecated" {
				ev := check_decl_attribute_value(ctx, value)
				// C++ reads the RAW string here (`ev.value_string`, e.g. checker.cpp:4030), not a
				// formatted one. Binding the type assertion is what makes it raw; going through
				// exact_value_to_string couples attribute READS to the diagnostic formatter -- see
				// LEDGER task 232, where quoting that formatter broke every one of these.
				msg, ok := ev.(string)
				if ok {
					if len(msg) == 0 {
						error(elem, "Deprecation message cannot be an empty string")
					} else {
						ac.deprecated_message = msg
					}
				} else {
					error(elem, "Expected a string value for '%s'", name)
				}
				continue
			}

			// @(warning="message") - C++ line 3762-3773
			if name == "warning" {
				ev := check_decl_attribute_value(ctx, value)
				msg, ok := ev.(string)   // raw, as C++ does
				if ok {
					if len(msg) == 0 {
						error(elem, "Warning message cannot be an empty string")
					} else {
						ac.warning_message = msg
					}
				} else {
					error(elem, "Expected a string value for '%s'", name)
				}
				continue
			}

			// @(test) - C++ line 3548-3554
			if name == "test" {
				if value != nil {
					error(value, "'%s' expects no parameter", name)
				}
				ac.test = true
				continue
			}

			// @(init) - C++ line 3613-3619
			if name == "init" {
				if value != nil {
					error(value, "'%s' expects no parameter", name)
				}
				ac.init = true
				continue
			}

			// @(fini) - C++ line 3620-3626
			if name == "fini" {
				if value != nil {
					error(value, "'%s' expects no parameter", name)
				}
				ac.fini = true
				continue
			}

			// @(export) or @(export=true/false) - C++ line 3555-3569
			if name == "export" {
				ev := check_decl_attribute_value(ctx, value)
				if ev == nil {
					ac.is_export = true
				} else if _, ok := ev.(bool); ok {
					ac.is_export = exact_value_to_bool(ev)
				} else {
					error(value, "Expected either a boolean or no parameter for 'export'")
				}
				continue
			}

			// @(link_name="symbol") - C++ line 3715-3726
			if name == "link_name" {
				ev := check_decl_attribute_value(ctx, value)
				// C++ reads the RAW string here (`ev.value_string`, e.g. checker.cpp:4030), not a
				// formatted one. Binding the type assertion is what makes it raw; going through
				// exact_value_to_string couples attribute READS to the diagnostic formatter -- see
				// LEDGER task 232, where quoting that formatter broke every one of these.
				raw, ok := ev.(string)
				if ok {
					ac.link_name = raw
					if !is_foreign_name_valid(ac.link_name) {
						error(elem, "Invalid link name: %s", ac.link_name)
					}
				} else {
					error(elem, "Expected a string value for '%s'", name)
				}
				continue
			}

			// @(link_prefix="prefix") - C++ line 3727-3738
			if name == "link_prefix" {
				ev := check_decl_attribute_value(ctx, value)
				// C++ reads the RAW string here (`ev.value_string`, e.g. checker.cpp:4030), not a
				// formatted one. Binding the type assertion is what makes it raw; going through
				// exact_value_to_string couples attribute READS to the diagnostic formatter -- see
				// LEDGER task 232, where quoting that formatter broke every one of these.
				raw, ok := ev.(string)
				if ok {
					ac.link_prefix = raw
					if !is_foreign_name_valid(ac.link_prefix) {
						error(elem, "Invalid link prefix: %s", ac.link_prefix)
					}
				} else {
					error(elem, "Expected a string value for '%s'", name)
				}
				continue
			}

			// @(link_suffix="suffix") - C++ line 3739-3750
			if name == "link_suffix" {
				ev := check_decl_attribute_value(ctx, value)
				// C++ reads the RAW string here (`ev.value_string`, e.g. checker.cpp:4030), not a
				// formatted one. Binding the type assertion is what makes it raw; going through
				// exact_value_to_string couples attribute READS to the diagnostic formatter -- see
				// LEDGER task 232, where quoting that formatter broke every one of these.
				raw, ok := ev.(string)
				if ok {
					ac.link_suffix = raw
					if !is_foreign_name_valid(ac.link_suffix) {
						error(elem, "Invalid link suffix: %s", ac.link_suffix)
					}
				} else {
					error(elem, "Expected a string value for '%s'", name)
				}
				continue
			}

			// @(private) or @(private="file"|"package") - C++ line 4119-4121
			if name == "private" {
				// NOTE: Visibility is handled in check_collect_value_decl
				// The actual visibility parsing happens there, not in Attribute_Context
				// We just validate the syntax here
				if value != nil {
					ev := check_decl_attribute_value(ctx, value)
					visibility, ok := ev.(string)
					if ok {
						if visibility != "file" && visibility != "package" {
							error(value, "Expected 'file' or 'package' for @(private), got '%s'", visibility)
						}
					} else {
						error(value, "Expected a string for @(private)")
					}
				}
				// No fields to set - visibility is processed in check_collect_value_decl
				continue
			}

			// @(require_results) - C++ line 3787-3791
			if name == "require_results" {
				if value != nil {
					error(elem, "Expected no value for '%s'", name)
				}
				ac.require_results = true
				continue
			}

			// @(require) - C++ line 3602-3612
			if name == "require" {
				ev := check_decl_attribute_value(ctx, value)
				if ev == nil {
					ac.require_declaration = true
				} else if _, ok := ev.(bool); ok {
					ac.require_declaration = exact_value_to_bool(ev)
				} else {
					error(value, "Expected either a boolean or no parameter for 'require'")
				}
				continue
			}

			// @(linkage="...") - C++ line 3570-3601
			if name == "linkage" {
				ev := check_decl_attribute_value(ctx, value)
				_, ok := ev.(string)
				if !ok {
					error(value, "Expected a string for 'linkage'")
					continue
				}
				linkage, _ := ev.(string)   // raw, as C++ does
				if linkage == "internal" || linkage == "strong" || linkage == "weak" || linkage == "link_once" {
					ac.linkage = linkage
				} else {
					error(elem, "Invalid linkage '%s'. Valid kinds: internal, strong, weak, link_once", linkage)
				}
				continue
			}

			// @(static) - C++ line 3974-3980
			if name == "static" {
				if value != nil {
					error(elem, "'static' does not have any parameters")
				}
				ac.is_static = true
				continue
			}

			// @(rodata) - C++ line 3980-3986
			if name == "rodata" {
				if value != nil {
					error(elem, "'rodata' does not have any parameters")
				}
				ac.rodata = true
				continue
			}

			// @(thread_local) or @(thread_local="model") - C++ line 3986-4012
			if name == "thread_local" {
				// C++ line 3988-3992: Error checking for invalid use cases
				if ac.init_expr_list_count > 0 {
					error(elem, "A thread local variable declaration cannot have initialization values")
				}
				if ctx.foreign_context.curr_library != nil {
					error(elem, "A foreign block variable cannot be thread local")
				}
				if ac.is_export {
					error(elem, "An exported variable cannot be thread local")
				}

				ev := check_decl_attribute_value(ctx, value)
				if ev == nil {
					// No value specified, use default model
					ac.thread_local_model = "default"
				} else if v_str, ok := ev.(string); ok {
					model := v_str
					if model == "default" || model == "localdynamic" || model == "initialexec" || model == "localexec" {
						ac.thread_local_model = model
					} else {
						error(elem, "Invalid thread local model '%s'. Valid models: default, localdynamic, initialexec, localexec", model)
					}
				} else {
					error(elem, "Expected either no value or a string for '%s'", name)
				}
				continue
			}

			// @(link_section="section_name") - C++ line 4096-4108
			if name == "link_section" {
				ev := check_decl_attribute_value(ctx, value)
				if v_str, ok := ev.(string); ok {
					ac.link_section = v_str
					if !is_foreign_name_valid(ac.link_section) {
						error(elem, "Invalid link section: %s", ac.link_section)
					}
				} else {
					error(elem, "Expected a string value for '%s'", name)
				}
				continue
			}

			// Process deferred procedure attributes (C++ checker.cpp:3641-3723)
			// These attributes specify procedure deferrals for automatic calling
			if name == "deferred_in" || name == "deferred_out" || name == "deferred_in_out" || name == "deferred_in_by_ptr" || name == "deferred_out_by_ptr" || name == "deferred_in_out_by_ptr" || name == "deferred_none" {

				if value == nil {
					error(elem, "Expected a procedure entity for '%s'", name)
					continue
				}

				// Evaluate the value to get the target procedure
				o := Operand{}
				check_expr(ctx, &o, value)
				e := entity_of_node(ctx.info, o.expr)

				if e == nil || e.kind != .Procedure {
					error(elem, "Expected a procedure entity for '%s'", name)
					continue
				}

				// Check for duplicate deferred attributes (C++ checker.cpp:3647,3663,3679,3695,3711)
				if ac.deferred_procedure.entity != nil {
					error(elem, "Previous usage of a 'deferred_*' attribute")
					continue
				}

				// Set deferred procedure kind based on attribute name
				switch name {
				case "deferred_none":
					ac.deferred_procedure.kind = .None
				case "deferred_in":
					ac.deferred_procedure.kind = .In
				case "deferred_out":
					ac.deferred_procedure.kind = .Out
				case "deferred_in_out":
					ac.deferred_procedure.kind = .In_Out
				case "deferred_in_by_ptr":
					ac.deferred_procedure.kind = .In_By_Ptr
				case "deferred_out_by_ptr":
					ac.deferred_procedure.kind = .Out_By_Ptr
				case "deferred_in_out_by_ptr":
					ac.deferred_procedure.kind = .In_Out_By_Ptr
				}

				ac.deferred_procedure.entity = e
				continue
			}

			// @(raddbg_type_view="view_string") - C++ line 3842-3850
			// RAD Debugger type view annotation for custom type visualizers
			if name == "raddbg_type_view" {
				ev := check_decl_attribute_value(ctx, value)
				if v_str, ok := ev.(string); ok {
					ac.raddbg_type_view = true
					ac.raddbg_type_view_string = v_str
				} else {
					error(elem, "Expected a string value for '%s'", name)
				}
				continue
			}

			// Objective-C attributes - C++ check_decl.cpp check_type_decl:517-610
			// @(objc_class="ClassName") - ObjC class binding
			if name == "objc_class" {
				ev := check_decl_attribute_value(ctx, value)
				if v_str, ok := ev.(string); ok {
					ac.objc_class = v_str
				} else {
					error(elem, "Expected a string value for '%s'", name)
				}
				continue
			}

			// @(objc_name="name") - ObjC method name
			if name == "objc_name" {
				ev := check_decl_attribute_value(ctx, value)
				if v_str, ok := ev.(string); ok {
					ac.objc_name = v_str
				} else {
					error(elem, "Expected a string value for '%s'", name)
				}
				continue
			}

			// @(objc_selector="selector:name:") - ObjC selector
			if name == "objc_selector" {
				ev := check_decl_attribute_value(ctx, value)
				if v_str, ok := ev.(string); ok {
					ac.objc_selector = v_str
				} else {
					error(elem, "Expected a string value for '%s'", name)
				}
				continue
			}

			// @(objc_type=Type) - ObjC type annotation
			if name == "objc_type" {
				if value != nil {
					type_val := check_type(ctx, value)
					ac.objc_type = type_val
				} else {
					error(elem, "Expected a type for '%s'", name)
				}
				continue
			}

			// @(objc_superclass=SuperType) - ObjC superclass
			if name == "objc_superclass" {
				if value != nil {
					type_val := check_type(ctx, value)
					ac.objc_superclass = type_val
				} else {
					error(elem, "Expected a type for '%s'", name)
				}
				continue
			}

			// @(objc_ivar=FieldType) - ObjC instance variable type
			if name == "objc_ivar" {
				if value != nil {
					type_val := check_type(ctx, value)
					ac.objc_ivar = type_val
				} else {
					error(elem, "Expected a type for '%s'", name)
				}
				continue
			}

			// @(objc_context_provider=proc_name) - procedure supplying the `context` for
			// Odin-calling-convention ObjC methods on this class.
			// C++ Reference: checker.cpp, check_decl_attribute (the `name ==
			// "objc_context_provider"` branch, between "objc_ivar" and "raddbg_type_view").
			if name == "objc_context_provider" {
				if value == nil {
					error(elem, "Expected a procedure entity for '%s'", name)
					continue
				}

				o := Operand{}
				check_expr(ctx, &o, value)
				e := entity_of_node(ctx.info, o.expr)

				// C++ only acts when an entity was resolved; an unresolvable value falls
				// through to the generic unknown-attribute handling.
				if e != nil {
					if ac.objc_context_provider != nil {
						error(elem, "Previous usage of a 'objc_context_provider' attribute")
					}
					if e.kind != .Procedure {
						error(elem, "'objc_context_provider' must refer to a procedure")
					} else {
						ac.objc_context_provider = e
					}
					continue
				}
			}

			// @(objc_is_class_method=<bool>) - Mark as ObjC class method (not instance method)
			//
			// C++ Reference: checker.cpp:4151-4158 --
			//     ExactValue ev = check_decl_attribute_value(c, value);
			//     if (ev.kind == ExactValue_Bool) { ac->objc_is_class_method = ev.value_bool; }
			//     else { error(elem, "Expected a boolean value for '%.*s'", LIT(name)); }
			//
			// The port required exactly the OPPOSITE: it rejected any value with "expects no
			// parameter" and then set the flag true unconditionally -- so the reference's required
			// form `@(objc_is_class_method=true)` errored, and `=false` errored yet still set the
			// flag TRUE. core/sys/darwin/Foundation writes that form throughout, which was the
			// entirety of its 36-diagnostic divergence from the reference (#277).
			if name == "objc_is_class_method" {
				ev := check_decl_attribute_value(ctx, value)
				if b, ok := ev.(bool); ok {
					ac.objc_is_class_method = b
				} else {
					error(elem, "Expected a boolean value for '%s'", name)
				}
				continue
			}

			// C++ Reference: checker.cpp:4174-4183 and 4474-4483. The attribute is spelled
			// "objc_implement"; the port handled "objc_is_implement", which C++ does not have.
			// Since the port ALSO lists "objc_implement" as a legal attribute name,
			// `@(objc_implement)` was accepted and then silently ignored -- so
			// ac.objc_is_implementation never became true and the whole gate below was DEAD
			// CODE. LEDGER #283.
			//
			// C++ also accepts an optional BOOLEAN (`@(objc_implement=false)`); the port
			// rejected any value at all.
			if name == "objc_implement" {
				if value == nil {
					ac.objc_is_implementation = true
				} else {
					ev := check_decl_attribute_value(ctx, value)
					if b, ok := ev.(bool); ok {
						ac.objc_is_implementation = b
					} else {
						error(elem, "Expected a boolean value, or no value, for '%s'", name)
					}
				}
				continue
			}

			// @(objc_is_disabled_implement) - Disable ObjC implementation for this method
			if name == "objc_is_disabled_implement" {
				if value != nil {
					error(elem, "'%s' expects no parameter", name)
				}
				ac.objc_is_disabled_implement = true
				continue
			}

			// ---- Attributes the port does not act on, but MUST still validate ----
			//
			// These are all backend/codegen directives: the checker's job is to accept the
			// name and check the shape of its value, exactly as C++ does. Nothing here
			// stores the value, because no consumer in the port reads it -- inventing
			// fields nobody reads is the antipattern task #104 swept out. The VALIDATION
			// is what C++ performs and the port did not.
			//
			// C++ Reference: checker.cpp, the `else if (name == ...)` chain.
			switch name {
			// No parameter, or an optional boolean.
			case "cold", "force":
				// C++ Reference: checker.cpp:4103-4114 ('cold' STORES into ac->set_cold).
				b := true
				if value != nil {
					ev := check_decl_attribute_value(ctx, value)
					if bv, ok := ev.(bool); ok {
						b = bv
					} else {
						error(elem, "Expected a boolean value for '%s' or no value whatsoever", name)
						continue
					}
				}
				if name == "cold" {
					ac.set_cold = b
				}
				continue

			// No parameter at all.
			// C++ Reference: checker.cpp:4218-4268. Each of these STORES a flag; the port
			// used to validate and drop it, leaving every reader dead.
			// NOTE: no_instrumentation is deliberately NOT in this group -- C++ gives it an
			// OPTIONAL BOOLEAN (checker.cpp:4224-4238), so treating it as no-parameter made
			// `@(no_instrumentation=false)` a spurious error.
			case "no_sanitize_address", "no_sanitize_memory", "no_sanitize_thread",
			     "entry_point_only", "objc_implement", "instrumentation_enter",
			     "instrumentation_exit":
				if value != nil {
					error(elem, "'%s' expects no parameter", name)
				}
				switch name {
				case "no_sanitize_address":   ac.no_sanitize_address = true
				case "no_sanitize_memory":    ac.no_sanitize_memory = true
				case "entry_point_only":      ac.entry_point_only = true
				case "instrumentation_enter": ac.instrumentation_enter = true
				case "instrumentation_exit":  ac.instrumentation_exit = true
				case "no_sanitize_thread":    ac.no_sanitize_thread = true
				// objc_implement is handled by the objc path.
				}
				continue

			// An optional boolean; absent means "disabled".
			// C++ Reference: checker.cpp:4224-4238
			case "no_instrumentation":
				if value == nil {
					ac.no_instrumentation = .Disabled
				} else {
					ev := check_decl_attribute_value(ctx, value)
					if b, ok := ev.(bool); ok {
						ac.no_instrumentation = .Disabled if b else .Enabled
					} else {
						error(value, "Expected either a boolean or no parameter for '%s'", name)
					}
				}
				continue

			// A boolean is required.
			case "disabled":
				// C++ Reference: checker.cpp:4093-4102. The value is not merely validated,
				// it is STORED. Task 44 added the validation here without the storage, so
				// ac.disabled_proc stayed false forever and `.Disabled` was never set on any
				// entity -- making check_decl.odin's `if ac.has_disabled_proc` arm and every
				// `.Disabled in e.flags` reader dead.
				ev := check_decl_attribute_value(ctx, value)
				if b, ok := ev.(bool); ok {
					ac.has_disabled_proc = true
					ac.disabled_proc = b
				} else {
					error(elem, "Expected a boolean value for '%s'", name)
				}
				continue

			// A string is required AND STORED. C++ checker.cpp:4202-4219 assigns each of these to
			// its AttributeContext field; the port validated the value and dropped it, so
			// ac.require_target_feature/enable_target_feature were always empty. That made the whole
			// target-feature block in check_decl (check_decl.odin:1209) dead: no validity
			// diagnostic, nothing written to Type_Proc, and therefore
			// intrinsics.has_target_feature(type_of(p)) could never see a procedure's features
			// and matched_target_features always scored 0. LEDGER #543.
			case "require_target_feature":
				ev := check_decl_attribute_value(ctx, value)
				if str, ok := ev.(string); ok {
					ac.require_target_feature = str
				} else {
					error(elem, "Expected a string value for '%s'", name)
				}
				continue

			case "enable_target_feature":
				ev := check_decl_attribute_value(ctx, value)
				if str, ok := ev.(string); ok {
					ac.enable_target_feature = str
				} else {
					error(elem, "Expected a string value for '%s'", name)
				}
				continue

			// A string is required. extra_linker_flags is stored on the foreign-library path
			// (check_decl.odin:2015) and default_calling_convention through foreign_context
			// (check_collect.odin:1205), so these two are validate-only HERE by design.
			case "extra_linker_flags", "default_calling_convention":
				ev := check_decl_attribute_value(ctx, value)
				if _, ok := ev.(string); !ok {
					error(elem, "Expected a string value for '%s'", name)
				}
				continue

			// An integer is required.
			case "priority_index":
				ev := check_decl_attribute_value(ctx, value)
				if _, ok := ev.(big.Int); !ok {
					error(elem, "Expected an integer value for '%s'", name)
				}
				continue

			// A string from a fixed set. C++ checker.cpp: "minimal" was removed and gets
			// its own message pointing at "none".
			case "optimization_mode":
				// C++ Reference: checker.cpp:4115-4137. Only "none" and "favor_size" remain
				// valid; "speed" and "size" were REMOVED and get their own messages. The port
				// used to accept both silently, and stored nothing.
				ev := check_decl_attribute_value(ctx, value)
				mode, ok := ev.(string)
				if !ok {
					error(elem, "Expected a string for '%s'", name)
				} else {
					switch mode {
					case "none":
						ac.optimization_mode = u32(Procedure_Optimization_Mode.None)
					case "favor_size":
						ac.optimization_mode = u32(Procedure_Optimization_Mode.Favor_Size)
					case "minimal":
						error(elem, "Invalid optimization_mode 'minimal' for '%s', mode has been removed due to confusion, but 'none' has the same behaviour", name)
					case "size":
						error(elem, "Invalid optimization_mode 'size' for '%s', mode has been removed due to confusion, but 'favor_size' has the same behaviour", name)
					case "speed":
						error(elem, "Invalid optimization_mode 'speed' for '%s', mode has been removed due to confusion, but 'favor_size' has the same behaviour", name)
					case:
						begin_error_block()
						error(elem, "Invalid optimization_mode for '%s'. Valid modes:", name)
						error_line("\tnone\n")
						error_line("\tfavor_size\n")
						end_error_block()
					}
				}
				continue

			// A constant bit_set; the parameter is NOT optional.
			case "fast_math":
				if value == nil {
					error(elem, "Expected a constant bit_set of type 'intrinsics.Fast_Math_Flags' for '%s'", name)
				} else {
					ev := check_decl_attribute_value(ctx, value, ctx.checker.t_fast_math_flags)
					if bi, ok := ev.(big.Int); !ok {
						error(elem, "Expected a constant bit_set of type 'intrinsics.Fast_Math_Flags' for '%s'", name)
					} else {
						// C++ Reference: checker.cpp:4277 -- the value is STORED, not merely
						// validated. The port validated and dropped it (#138/#139 shape).
						v, err := big.int_get_u64(&bi)
						if err == nil {
							ac.fast_math_flags = v
						}
					}
				}
				continue
			}

			// Attributes this chain does not handle, but the port DOES consume elsewhere.
			// They must be accepted here or the catch-all below rejects valid code:
			//   builtin           -> consumed during collection (task #64); 24,167 uses
			//                        across the corpus, all of base/runtime's @(builtin).
			//   ignore_duplicates -> handled in check_decl.odin.
			// Both are genuine C++ attributes, so accepting them is parity, not a hole.
			switch name {
			case "builtin", "ignore_duplicates":
				continue
			}

			// C++ Reference: checker.cpp check_decl_attributes:4627-4633. Anything still unmatched is an error,
			// unless the build asked for unknown attributes to be tolerated.
			//
			// The accept-list above was derived EMPIRICALLY: a probe build with this
			// catch-all made unconditional was run over all 169 packages, and `builtin` was
			// the ONLY name it flagged. CORRECTION (task 251): that sweep bounds what this
			// chain wrongly REJECTS -- every name in a corpus `./odin check` accepts is
			// valid by construction -- but it says nothing about what the chain wrongly
			// ACCEPTS, because a name the corpus never uses in the wrong place cannot show
			// up in it. `priority_index` on a procedure is exactly that case. See the
			// per-declaration-kind gap recorded alongside this task.
			//
			// The two guards were both missing: ignore_unknown_attributes was declared in
			// Build_Context and never read by anything, and there was no custom-attribute
			// set at all.
			report_unknown_attribute(elem, name)
		}
	}

	// C++ Reference: checker.cpp check_decl_attributes:4638-4650. An INHERITED link_prefix/link_suffix is silently
	// dropped when this declaration supplies its own link_name; only a prefix set on the SAME
	// declaration as the link_name is the conflict that handle_link_name reports. Without this,
	// the common idiom of @(link_prefix="CF") on a foreign block plus @(link_name=...) on one
	// member inside it is rejected -- see core/sys/darwin/CoreFoundation/CFString.odin:179.
	if ac != nil {
		if raw_data(ac.link_prefix) == raw_data(original_link_prefix) && len(ac.link_name) > 0 {
			ac.link_prefix = ""
		}
		if raw_data(ac.link_suffix) == raw_data(original_link_suffix) && len(ac.link_name) > 0 {
			ac.link_suffix = ""
		}
	}
}

// handle_link_name processes link name with prefix/suffix
// C++ Reference: check_decl.cpp:1016-1050
handle_link_name :: proc(ctx: ^Checker_Context, token: tokenizer.Token, link_name, link_prefix, link_suffix: string) -> string {
	// C++ Reference: check_decl.cpp:1017
	original_link_name := link_name
	result := link_name

	// C++ Reference: check_decl.cpp:1018-1030
	// Handle link_prefix
	if len(link_prefix) > 0 {
		if len(original_link_name) > 0 {
			error(token, "'link_name' and 'link_prefix' cannot be used together")
		} else {
			// Concatenate: link_prefix + token.text
			// Use context allocator for link names that must persist through compilation
			result = strings.concatenate({link_prefix, token.text}, context.allocator)
		}
	}

	// C++ Reference: check_decl.cpp handle_link_name:1032-1048
	// Handle link_suffix
	if len(link_suffix) > 0 {
		if len(original_link_name) > 0 {
			error(token, "'link_name' and 'link_suffix' cannot be used together")
		} else {
			// Use the current result (which may be from link_prefix) or token.text
			new_name := token.text
			if result != original_link_name {
				new_name = result
			}
			// Concatenate: new_name + link_suffix
			// Use context allocator for link names that must persist through compilation
			result = strings.concatenate({new_name, link_suffix}, context.allocator)
		}
	}

	return result
}

// is_arch_wasm is defined in build_settings.odin

// is_platform_darwin checks if target OS is Darwin (macOS, iOS, etc.)
// C++ Reference: check_builtin.cpp:271
// Used to validate that Objective-C intrinsics are only used on Darwin platforms
// C++ Reference: check_builtin.cpp:283-287, inside check_builtin_objc_procedure:
//
//     if (build_context.metrics.os != TargetOs_darwin) {
//         // allow on doc generation (e.g. Metal stuff)
//         if (build_context.command_kind != Command_doc && build_context.command_kind != Command_check) {
//             error(call, "'%.*s' only works on darwin", LIT(builtin_name));
//         }
//     }
//
// So the diagnostic is suppressed under `odin check` and `odin doc` even off-darwin. That
// exemption was never ported. Until #329 the omission was invisible, because build_context was
// always nil and the guard below returned true unconditionally -- accidentally matching the
// reference under `odin check`, and accidentally NOT matching it under `odin build`. Wiring the
// field (#329) turned core/sys/darwin/Foundation from 0 diagnostics to 36 against an oracle
// reporting 0, which is what surfaced this.
is_platform_darwin :: proc(ctx: ^Checker_Context) -> bool {
	bc := ctx.info.build_context
	if bc == nil {
		return true
	}
	if bc.metrics.os == .Darwin {
		return true
	}
	if .Check in bc.command_kind || .Doc in bc.command_kind {
		return true
	}
	return false
}

// is_foreign_name_valid checks if a string is a valid foreign identifier
// C++ Reference: Inferred from usage in checker.cpp:3440, 3452, 3742
// Validates that a name is a valid C identifier (used for link names, sections, etc.)
// is_foreign_name_valid reports whether a string may be used as a link name.
//
// C++ Reference: checker.cpp:3656-3701. A link name is a LINKER SYMBOL, not an Odin
// identifier, and C++ is correspondingly permissive:
//   - first rune: one of `- $ . _ :` or an alphabetic character
//   - every later rune: anything PRINTABLE (utf8proc_charwidth > 0)
// C++ carries a note that even these limits are more assumption than technical necessity.
//
// This port had an IDENTIFIER check instead — letter/underscore first, then alphanumeric or
// underscore — which rejected every symbol containing `$`, `.`, `-` or `:`. base/runtime
// alone declares `__$startup_runtime` and `__$cleanup_runtime`, and the sweep carried 5,183
// "Invalid link name" diagnostics because of it.
//
// The class never surfaced in the top-N aggregation because the message embeds an UNQUOTED
// symbol name, so normalisation left every distinct link name as its own singleton class.
is_foreign_name_valid :: proc(name: string) -> bool {
	if len(name) == 0 {
		return false
	}

	for r, i in name {
		if r == utf8.RUNE_ERROR {
			return false
		}
		if i == 0 {
			// C++ lines 3675-3687
			switch r {
			case '-', '$', '.', '_', ':':
				// explicitly permitted leaders
			case:
				if !unicode.is_alpha(r) {
					return false
				}
			}
		} else {
			// C++ lines 3688-3694: any printable rune.
			if !unicode.is_print(r) {
				return false
			}
		}
	}

	return true
}

// init_entity_foreign_library initializes foreign library linkage
// C++ Reference: check_decl.cpp:972-1014
init_entity_foreign_library :: proc(ctx: ^Checker_Context, e: ^Entity) -> ^Entity {
	// C++ Reference: check_decl.cpp:973-987
	// Extract ident and foreign_library pointer based on entity kind
	ident: ^ast.Node = nil
	foreign_library: ^^Entity = nil

	#partial switch e.kind {
	case .Procedure:
		if proc_ent, ok := &e.variant.(Entity_Procedure); ok {
			ident = proc_ent.foreign_library_ident
			foreign_library = &proc_ent.foreign_library
		}
	case .Variable:
		if var_ent, ok := &e.variant.(Entity_Variable); ok {
			ident = var_ent.foreign_library_ident
			foreign_library = &var_ent.foreign_library
		}
	case:
		return nil
	}

	// C++ Reference: check_decl.cpp init_entity_foreign_library:989-1013
	if ident == nil {
		error(e.token, "foreign entities must declare which library they are from")
	} else if ident_node, ok := ident.derived.(^ast.Ident); !ok {
		error(ident, "foreign library names must be an identifier")
	} else {
		name := ident_node.name
		found := scope_lookup(ctx.scope, name)

		if found == nil {
			if is_blank_ident(name) {
				// NOTE(bill): link against nothing
			} else {
				error(ident, "Undeclared name: %s", name)
			}
		} else if found.kind != .Library_Name {
			error(ident, "'%s' cannot be used as a library name", name)
		} else {
			// NOTE: Library name found and validated - set reference
			foreign_library^ = found
			found.flags += {.Used}
			add_entity_use(ctx, ident, found)
			return found
		}
	}
	return nil
}

// token_pos_to_string is defined in error.odin

// signature_parameter_similar_enough checks if two types are ABI-compatible
// C++ Reference: check_decl.cpp:786-844
signature_parameter_similar_enough :: proc(x, y: ^Type) -> bool {
	// C++ Reference: check_decl.cpp:786-844
	// Check if two types have similar enough signatures for foreign declarations
	// This allows bit_set to integer conversions and various pointer type equivalences

	x := x
	y := y

	// C++ Reference: check_decl.cpp:787-792
	if is_type_bit_set(x) {
		x = bit_set_to_int(x)
	}
	if is_type_bit_set(y) {
		y = bit_set_to_int(y)
	}

	// C++ Reference: check_decl.cpp signature_parameter_similar_enough:794-832
	// Helper for signature comparison
	sig_compare :: proc(a: proc(_: ^Type) -> bool, x, y: ^Type) -> bool {
		x_ct := core_type(x)
		y_ct := core_type(y)
		return a(x_ct) && a(y_ct)
	}

	sig_compare_pair :: proc(a, b: proc(_: ^Type) -> bool, x, y: ^Type) -> bool {
		x_ct := core_type(x)
		y_ct := core_type(y)
		return (a(x_ct) && b(y_ct)) || (b(x_ct) && a(y_ct))
	}

	// C++ Reference: check_decl.cpp signature_parameter_similar_enough:794-802
	// Check various pointer type combinations
	if sig_compare(is_type_pointer, x, y) {
		return true
	}
	if sig_compare(is_type_multi_pointer, x, y) {
		return true
	}
	if sig_compare(is_type_proc, x, y) {
		return true
	}

	// C++ Reference: check_decl.cpp signature_parameter_similar_enough:804-810
	// Allow integer types of same size
	if sig_compare(is_type_integer, x, y) {
		sx := type_size_of(x)
		sy := type_size_of(y)
		if sx == sy {
			return true
		}
	}

	// C++ Reference: check_decl.cpp signature_parameter_similar_enough:812-818
	// Allow integer-to-boolean conversion if sizes match
	if sig_compare_pair(is_type_integer, is_type_boolean, x, y) {
		sx := type_size_of(x)
		sy := type_size_of(y)
		if sx == sy {
			return true
		}
	}

	// C++ Reference: check_decl.cpp signature_parameter_similar_enough:819-830
	// cstring equivalences
	if sig_compare_pair(is_type_cstring, is_type_u8_ptr, x, y) {
		return true
	}
	if sig_compare_pair(is_type_cstring, is_type_u8_multi_ptr, x, y) {
		return true
	}
	if sig_compare_pair(is_type_cstring16, is_type_u16_ptr, x, y) {
		return true
	}
	if sig_compare_pair(is_type_cstring16, is_type_u16_multi_ptr, x, y) {
		return true
	}

	// C++ Reference: check_decl.cpp signature_parameter_similar_enough:832-834
	// uintptr/rawptr equivalence
	if sig_compare_pair(is_type_uintptr, is_type_rawptr, x, y) {
		return true
	}

	// C++ Reference: check_decl.cpp signature_parameter_similar_enough:836-844
	// Additional pointer type pair checks
	if sig_compare_pair(is_type_proc, is_type_pointer, x, y) {
		return true
	}
	if sig_compare_pair(is_type_pointer, is_type_multi_pointer, x, y) {
		return true
	}
	if sig_compare_pair(is_type_proc, is_type_multi_pointer, x, y) {
		return true
	}

	// C++ Reference: check_decl.cpp signature_parameter_similar_enough:846-852
	// Slice recursion: allow slices with similar element types
	if sig_compare(is_type_slice, x, y) {
		s1 := core_type(x)
		s2 := core_type(y)
		slice1 := s1.variant.(Type_Slice)
		slice2 := s2.variant.(Type_Slice)
		if signature_parameter_similar_enough(slice1.elem, slice2.elem) {
			return true
		}
	}

	// C++ Reference: check_decl.cpp signature_parameter_similar_enough:854-895
	// Struct ABI compatibility: allow structs with same size/alignment
	x_base := base_type(x)
	y_base := base_type(y)

	if x_base == y_base {
		return true
	}

	if x_base.kind == y_base.kind && x_base.kind == .Struct {
		xs := type_size_of(x_base)
		ys := type_size_of(y_base)
		xa := type_align_of(x_base)
		ya := type_align_of(y_base)

		x_struct := x_base.variant.(Type_Struct)
		y_struct := y_base.variant.(Type_Struct)

		if x_struct.is_raw_union == y_struct.is_raw_union && xs == ys && xa == ya {
			// C++ Reference: check_decl.cpp signature_parameter_similar_enough:872-877
			// ABI NOTE: Structs over 16 bytes are passed by pointer on all current ABIs
			// This must be changed when ABI changes
			if xs > 16 {
				return true
			}

			// C++ Reference: check_decl.cpp signature_parameter_similar_enough:878-880
			// Raw unions with same size/alignment are compatible
			if x_struct.is_raw_union {
				return true
			}

			// C++ Reference: check_decl.cpp signature_parameter_similar_enough:881-893
			// Check field-by-field compatibility
			if len(x_struct.fields) == len(y_struct.fields) {
				all_similar := true
				for i in 0 ..< len(x_struct.fields) {
					a := x_struct.fields[i]
					b := y_struct.fields[i]
					if !signature_parameter_similar_enough(a.type, b.type) {
						all_similar = false
						break
					}
				}
				// C++ Reference: check_decl.cpp signature_parameter_similar_enough:894-897
				// HACK NOTE(bill): Allow this for the time being until it becomes a practical problem
				// If all fields are similar, the structs are ABI-compatible
				if all_similar {
					return true
				}
			}
			// C++ Reference: check_decl.cpp signature_parameter_similar_enough:894-897
			// HACK NOTE(bill): Allow structs with same size/alignment to be ABI-compatible
			// even if field types differ. This is intentional for foreign function interface
			// compatibility and will remain until it becomes a practical problem.
			return true
		}
	}

	// C++ Reference: check_decl.cpp signature_parameter_similar_enough:898
	// Default: require identical types
	return are_types_identical(x, y)
}

// are_signatures_similar_enough checks if two procedure signatures are compatible
// C++ Reference: check_decl.cpp:902-968
are_signatures_similar_enough :: proc(a_, b_: ^Type) -> bool {
	// C++ Reference: check_decl.cpp:902-968
	// Check if two procedure types have compatible signatures for foreign declarations

	// C++ Reference: check_decl.cpp:903-906
	assert(a_.kind == .Proc)
	assert(b_.kind == .Proc)
	pa := &a_.variant.(Type_Proc)
	pb := &b_.variant.(Type_Proc)

	// C++ Reference: check_decl.cpp are_signatures_similar_enough:908-910
	// Parameter count must match
	if pa.param_count != pb.param_count {
		return false
	}

	// C++ Reference: check_decl.cpp are_signatures_similar_enough:911-913
	// Result count must match
	if pa.result_count != pb.result_count {
		return false
	}

	// C++ Reference: check_decl.cpp are_signatures_similar_enough:915-917
	// C vararg must match
	if pa.c_vararg != pb.c_vararg {
		return false
	}

	// C++ Reference: check_decl.cpp are_signatures_similar_enough:919-921
	// Variadic must match
	if pa.variadic != pb.variadic {
		return false
	}

	// C++ Reference: check_decl.cpp are_signatures_similar_enough:923-925
	// Variadic index must match if variadic
	if pa.variadic && pa.variadic_index != pb.variadic_index {
		return false
	}

	// C++ Reference: check_decl.cpp are_signatures_similar_enough:927-952
	// Check parameter types are similar enough
	for i in 0 ..< pa.param_count {
		x := core_type(pa.params.variant.(Type_Tuple).variables[i].type)
		y := core_type(pb.params.variant.(Type_Tuple).variables[i].type)

		// C++ Reference: check_decl.cpp are_signatures_similar_enough:931-936
		// Convert BitSet to underlying type for comparison
		if x.kind == .Bit_Set {
			if bs := x.variant.(Type_Bit_Set); bs.underlying != nil {
				x = core_type(bs.underlying)
			}
		}
		if y.kind == .Bit_Set {
			if bs := y.variant.(Type_Bit_Set); bs.underlying != nil {
				y = core_type(bs.underlying)
			}
		}

		// C++ Reference: check_decl.cpp are_signatures_similar_enough:938-947
		// Allow a `#c_vararg args: ..any` to match `#c_vararg args: ..foo`
		if pa.variadic && i == pa.variadic_index {
			assert(x.kind == .Slice)
			assert(y.kind == .Slice)
			x_elem := core_type(x.variant.(Type_Slice).elem)
			y_elem := core_type(y.variant.(Type_Slice).elem)
			if is_type_any(x_elem) || is_type_any(y_elem) {
				continue
			}
		}

		// C++ Reference: check_decl.cpp are_signatures_similar_enough:949-951
		if !signature_parameter_similar_enough(x, y) {
			return false
		}
	}

	// C++ Reference: check_decl.cpp are_signatures_similar_enough:953-967
	// Check result types are similar enough
	for i in 0 ..< pa.result_count {
		x := core_type(pa.results.variant.(Type_Tuple).variables[i].type)
		y := core_type(pb.results.variant.(Type_Tuple).variables[i].type)

		// C++ Reference: check_decl.cpp are_signatures_similar_enough:957-962
		// Convert BitSet to underlying type for comparison
		if x.kind == .Bit_Set {
			if bs := x.variant.(Type_Bit_Set); bs.underlying != nil {
				x = core_type(bs.underlying)
			}
		}
		if y.kind == .Bit_Set {
			if bs := y.variant.(Type_Bit_Set); bs.underlying != nil {
				y = core_type(bs.underlying)
			}
		}

		// C++ Reference: check_decl.cpp are_signatures_similar_enough:964-966
		if !signature_parameter_similar_enough(x, y) {
			return false
		}
	}

	// C++ Reference: check_decl.cpp are_signatures_similar_enough:969
	return true
}

// ======================================================================================
// ENTITY MANAGEMENT HELPERS
// ======================================================================================

// add_entity_definition is defined in entity_helpers.odin

// redeclaration_error is defined in entity_helpers.odin

// add_entity_flags_from_file is defined in entity_helpers.odin

// add_entity_with_name_ctx is defined in entity_helpers.odin

// add_entity_with_name_info is defined in entity_helpers.odin

// add_entity_with_name is defined in entity_helpers.odin

// add_entity is defined in entity_helpers.odin

// add_entity_use marks entity as used and tracks dependencies
// C++ Reference: checker.cpp:1934-1961
add_entity_use :: proc(ctx: ^Checker_Context, identifier: ^ast.Node, entity: ^Entity) {
	// C++ Reference: checker.cpp:1935-1936
	if entity == nil {
		return
	}

	// C++ Reference: checker.cpp:1938-1945
	add_declaration_dependency(ctx, entity)
	entity.flags += {.Used}

	// C++ Reference: checker.cpp:1940-1945: Track deferred procedure dependencies
	// When an entity with a @(deferred_*) attribute is used, we also mark the
	// deferred procedure as used to ensure it's included in the compilation
	if entity_has_deferred_procedure(entity) {
		if proc_data, ok := entity.variant.(Entity_Procedure); ok {
			deferred := proc_data.deferred_procedure.entity
			if deferred != entity {
				add_entity_use(ctx, nil, deferred)
			}
		}
	}

	// C++ Reference: checker.cpp:1946-1947
	if identifier == nil {
		return
	}
	_, ok := identifier.derived.(^ast.Ident)
	if !ok {
		return
	}

	// C++ Reference: checker.cpp:1949-1951
	// Thread-safe atomic store of identifier pointer
	// C++ uses: entity.identifier.store(identifier, std::memory_order_relaxed)
	sync.atomic_store(&entity.identifier, identifier)

	// Set entity on AST node so it can be retrieved later
	// (e.g., for polymorphic procedure instantiation)
	set_ast_entity(ctx.info, identifier, entity)

	// C++ Reference: checker.cpp:1953-1960
	dmsg := entity.deprecated_message
	if len(dmsg) > 0 {
		warning(identifier, "%s is deprecated: %s", entity.token.text, dmsg)
	}
	wmsg := entity.warning_message
	if len(wmsg) > 0 {
		warning(identifier, "%s: %s", entity.token.text, wmsg)
	}
}

// ======================================================================================
// VARIABLE AND CONSTANT INITIALIZATION HELPERS
// ======================================================================================


// The following functions are defined in check_decl.odin:
// - check_init_variable
// - check_init_variables
// - override_entity_in_scope
// - check_override_as_type_due_to_aliasing
// - check_try_override_const_decl
// - check_init_constant

// clone_enum_type clones an enum type for distinct declarations
// C++ Reference: check_decl.cpp:403-447
clone_enum_type :: proc(ctx: ^Checker_Context, original_enum_type: ^Type, named_type: ^Type) -> ^Type {
	// C++ Reference: check_decl.cpp:404-414
	// NOTE(bill, 2022-02-05): Stupid edge case for `distinct` declarations
	//
	//         X :: enum {A, B, C}
	//         Y :: distinct X
	//
	// To make Y be just like X, it will need to copy the elements of X and change their type
	// so that they match Y rather than X.
	assert(original_enum_type != nil)
	assert(named_type != nil)
	assert(original_enum_type.kind == .Enum)
	assert(named_type.kind == .Named)

	// C++ Reference: check_decl.cpp clone_enum_type:416-417
	original_enum := &original_enum_type.variant.(Type_Enum)
	parent := original_enum.scope.parent
	scope := create_scope(parent, ctx.checker.allocator)

	// C++ Reference: check_decl.cpp clone_enum_type:420-426
	et := alloc_type_enum(ctx.checker)
	enum_variant := &et.variant.(Type_Enum)
	enum_variant.base_type = original_enum.base_type
	enum_variant.min_value = original_enum.min_value
	enum_variant.max_value = original_enum.max_value
	enum_variant.min_value_index = original_enum.min_value_index
	enum_variant.max_value_index = original_enum.max_value_index
	enum_variant.scope = scope

	// C++ Reference: check_decl.cpp clone_enum_type:428-445
	fields := make([dynamic]^Entity, 0, len(original_enum.fields), ctx.checker.allocator)
	for old in original_enum.fields {
		e := alloc_entity_constant(scope, old.token, named_type, old.variant.(Entity_Constant).value)
		e.file = old.file
		// C++ line 434: Clone identifier node for distinct enum fields
		e.identifier = clone_ast_node(old.identifier)
		e.flags += {.Visited}
		e.state = .Resolved
		// C++ lines 437-439: Copy flags, docs, and comment fields from original enum field
		if old_const, ok1 := &old.variant.(Entity_Constant); ok1 {
			if new_const, ok2 := &e.variant.(Entity_Constant); ok2 {
				new_const.flags = old_const.flags
				new_const.docs = old_const.docs
				new_const.comment = old_const.comment
			}
		}

		append(&fields, e)
		add_entity(ctx, scope, nil, e)
		add_entity_use(ctx, e.identifier, e)
	}
	enum_variant.fields = fields

	return et
}

// ======================================================================================
// TYPE CHECKING PROCEDURES
// ======================================================================================

// check_type_decl checks type declarations
// C++ Reference: check_decl.cpp:449-517
check_type_decl :: proc(ctx: ^Checker_Context, e: ^Entity, init_expr: ^ast.Expr, def: ^Type, type_expr: ^ast.Expr = nil, ac: ^Attribute_Context = nil) {
	// C++ Reference: check_decl.cpp:449-517
	assert(entity_type(e) == nil)

	// C++ Reference: check_decl.cpp check_type_decl:520-524
	//
	// ORDER DIFFERENCE, DISPOSITIONED INERT (#610). The port runs this attribute processing at the
	// TOP of check_type_decl; C++ runs it at 520-524, i.e. AFTER it has built `named` and assigned
	// `e->type = named` (465). Settled by ENUMERATION, not assumption:
	//
	//   The attribute handler CANNOT SEE THE DECLARATION ENTITY AT ALL. C++'s signature is
	//     DECL_ATTRIBUTE_PROC(_name) bool _name(CheckerContext *c, Ast *elem, String name,
	//                                           Ast *value, AttributeContext *ac)   [checker.hpp:179]
	//   -- no entity parameter. type_decl_attribute (checker.cpp:4464-4558) only validates attribute
	//   VALUES and fills `ac`; it references `ac->` 11 times and an entity twice, both at 4516-4522
	//   where `e` is a LOCAL resolved from the attribute's own value (the objc_context_provider's
	//   referenced procedure), never the declaration's entity.
	//
	//   Everything entity-dependent happens AFTER the call, reading `ac`: the objc_class name store
	//   (528) and the zero-size check `type_size_of(e->type) > 0` (602). The port has both inside its
	//   objc block, which runs later -- so nothing reads `e.type` before it is set.
	//
	// **NOT INVESTIGATED:** whether an attribute whose VALUE names the type being declared
	// (e.g. a self-referential `@(objc_superclass=Self)`) resolves differently when the entity's type
	// is still nil. Resolution goes through the SCOPE, where the entity exists either way, so this is
	// unlikely -- but it is not measured, and it is the one edge this enumeration does not cover.
	//
	// CITATION CORRECTED (#610): cited 592-609, the objc_superclass / zero-size region. C++ processes
	// type-decl attributes at `if (decl != nullptr) { AttributeContext ac = {};
	// check_decl_attributes(ctx, decl->attributes, type_decl_attribute, &ac); ... }` = 520-524.
	// This was the FIRST citation in the proc, so its too-high anchor inverted the four that follow (#52).
	// Process type declaration attributes (raddbg_type_view, etc.)
	// If ac is not provided, process attributes from the entity's decl_info
	local_ac := Attribute_Context{}
	effective_ac := ac
	if effective_ac == nil {
		decl := decl_info_of_entity(e)
		if decl != nil && len(decl.attributes) > 0 {
			check_decl_attributes(ctx, decl.attributes[:], &local_ac, .Type)
			effective_ac = &local_ac
		}
	}

	// C++ Reference: check_decl.cpp check_type_decl:506-515
	// Process explicit type annotation if provided
	if type_expr != nil {
		type_type := check_type(ctx, type_expr)
		if type_type != nil && !is_type_typeid(type_type) {
			error(type_expr, "Expected 'typeid' for type declaration annotation, got '%s'", type_to_string(type_type))
		}
	}

	is_distinct := is_type_distinct(init_expr)
	te := remove_type_alias_clutter(init_expr)
	set_entity_type(e, t_invalid)

	name := e.token.text
	named := alloc_type_named(name, nil, e, ctx.checker.allocator)
	if def != nil && def.kind == .Named {
		if named_variant, ok := &def.variant.(Type_Named); ok {
			named_variant.base = named
		}
	}
	set_entity_type(e, named)

	if !is_distinct {
		if type_name, ok := &e.variant.(Entity_Type_Name); ok {
			type_name.is_type_alias = true
		}
	}

	check_type_path_push(ctx, e)
	bt := check_type_expr(ctx, te, named)
	check_type_path_pop(ctx)

	base := base_type(bt)

	// C++ Reference: check_decl.cpp check_type_decl:473-475
	// For distinct enum types, clone the enum to have separate field entities
	if is_distinct && is_type_enum(base) {
		base = clone_enum_type(ctx, base, named)
	}

	if named_variant, ok := &named.variant.(Type_Named); ok {
		named_variant.base = base
	}

	// Validation for distinct/alias
	if is_distinct {
		if is_type_typeid(entity_type(e)) {
			error(init_expr, "'distinct' cannot be applied to 'typeid'")
			is_distinct = false
		} else if is_type_any(entity_type(e)) {
			error(init_expr, "'distinct' cannot be applied to 'any'")
			is_distinct = false
		} else if is_type_simd_vector(entity_type(e)) || is_type_soa_pointer(entity_type(e)) {
			// C++ lines 485-490: SIMD vector and SOA pointer validation
			type_str := type_to_string(entity_type(e))
			error(init_expr, "'distinct' cannot be applied to '%s'", type_str)
			is_distinct = false
		}
	} else {
		if is_type_typeid(entity_type(e)) {
			error(init_expr, "'typeid' cannot be aliased")
		} else if is_type_any(entity_type(e)) {
			error(init_expr, "'any' cannot be aliased")
		}
	}

	if !is_distinct {
		set_entity_type(e, bt)
		// C++ Reference: check_decl.cpp check_type_decl:499-502
		// For non-distinct types, update named->Named.base = bt
		if named_variant, ok := &named.variant.(Type_Named); ok {
			named_variant.base = bt
		}
		// C++ Reference: check_decl.cpp check_type_decl:504
		// Set is_type_alias again after type is finalized
		if type_name, ok := &e.variant.(Entity_Type_Name); ok {
			type_name.is_type_alias = true
		}
	}

	// C++ Reference: check_decl.cpp check_type_decl:618-621
	//
	// ORDER DIFFERENCE, DISPOSITIONED INERT (#610). The port emits this BEFORE the raddbg block
	// below; C++ has raddbg (609-614) first and this (618-621) second. Inert for the same reason
	// #666 dispositioned check_call_expr's Step 11: the two blocks share no state -- raddbg reads
	// `effective_ac` and enqueues, this reads `ctx.decl.is_using` and `base` -- and **only ONE of
	// them emits a diagnostic**, so no swap of the two can reorder any output. Contrast #664, where
	// the moved block DID emit and the reorder cost a diagnostic.
	//
	// CITATION CORRECTED (#610): cited 614-616, which is the CLOSING BRACE of the raddbg block plus
	// blank lines. C++'s `// using decl` / `if (decl->is_using) { error(init_expr, "'using' an enum
	// declaration is not allowed...") }` is 618-621. Swapped with the raddbg citation below.
	// 'using' an enum declaration is not allowed
	if ctx.decl != nil && ctx.decl.is_using && is_type_enum(base) {
		error(init_expr, "'using' an enum declaration is not allowed, prefer using implicit selector expressions e.g. '.A'")
	}

	// C++ Reference: check_decl.cpp check_type_decl:609-614
	// CITATION CORRECTED (#610): cited 604-609, which is the `@(objc_class) marked type must be of
	// zero size` error and the objc_implement else-if. C++'s raddbg block is
	// `if (ac.raddbg_type_view) { ... mpsc_enqueue(&ctx->info->raddbg_type_views_queue, ...) }` = 609-614.
	// Handle raddbg_type_view attribute for RAD Debugger type visualizers
	if effective_ac != nil && effective_ac.raddbg_type_view {
		view := Raddbg_Type_View{
			type = entity_type(e),
			view = effective_ac.raddbg_type_view_string,
		}
		queue.mpsc_enqueue(&ctx.checker.info.raddbg_type_views_queue, view)
	}

	// C++ Reference: check_decl.cpp check_type_decl:526-607
	// CITATION CORRECTED (#610): cited 517-610; 517-518 are the CLOSING BRACES of the constant-decl
	// block above, and 520-524 is the attribute processing already cited at the top of this proc.
	// The objc block proper is `if (e->kind == Entity_TypeName && ac.objc_class != "") { ... }` = 526-607.
	// Handle Objective-C class attributes for type declarations
	if effective_ac != nil && len(effective_ac.objc_class) > 0 {
		if type_name, ok := &e.variant.(Entity_Type_Name); ok {
			// C++ Reference: check_decl.cpp check_type_decl:521-528
			// Verify the type is zero-size (ObjC class bindings must be opaque)
			// e.token, NOT init_expr. C++ anchors this on the ENTITY (check_decl.cpp check_type_decl:603,
			// `error(e->token, ...)`), i.e. the declared name, so `Foo :: struct {}` reports at
			// column 1. Anchoring on the initialising expression put us at column 8 -- the `struct`
			// keyword -- for every @(objc_class) type. Same class as #179 and #197: the message was
			// right and the anchor was not, which a count-only comparison cannot see.
			if type_size_of(base) != 0 {
				error_token(e.token, "@(objc_class) marked type must be of zero size")
			}

			// C++ Reference: check_decl.cpp check_type_decl:530-540
			type_name.objc_class_name = effective_ac.objc_class

			// C++ Reference: check_decl.cpp check_type_decl:542-555
			// Handle objc_is_implement attribute
			if effective_ac.objc_is_implementation {
				type_name.objc_is_implementation = true
				type_name.objc_ivar = effective_ac.objc_ivar
				type_name.objc_context_provider = effective_ac.objc_context_provider

				// C++ Reference: check_decl.cpp check_type_decl:536-541 --
				//     mutex_lock(&ctx->info->objc_class_name_mutex);
				//     bool class_exists = string_set_update(&ctx->info->obcj_class_name_set, ac.objc_class);
				//     mutex_unlock(&ctx->info->objc_class_name_mutex);
				//     if (class_exists) { error(e->token, "@(objc_class) name '%.*s' has already been used elsewhere", ...); }
				//
				// string_set_update INSERTS AND REPORTS whether the name was already present -- a
				// plain insert would not detect anything. The port previously carried a
				// "NOTE: This would require a global map ... For now, just store the name"
				// placeholder here, so two implementations claiming one name were accepted
				// silently (probe objcdup2, #165).
				//
				// The check sits INSIDE this objc_is_implementation branch exactly as C++ has it:
				// declarations without @(objc_implement) are not registered and must stay silent
				// (probe objcdup covers that direction).
				info := &ctx.checker.info
				class_exists: bool
				{
					sync.lock(&info.objc_class_name_mutex)
					defer sync.unlock(&info.objc_class_name_mutex)
					class_exists = effective_ac.objc_class in info.objc_class_names
					info.objc_class_names[effective_ac.objc_class] = true
				}
				if class_exists {
					error(
						e.token,
						"@(objc_class) name '%s' has already been used elsewhere",
						effective_ac.objc_class,
					)
				}

				// Queue for later processing
				queue.mpsc_enqueue(&ctx.checker.info.objc_class_implementations, e)

				// Enqueue the context_provider proc to be checked once it is resolved.
				// C++ Reference: check_decl.cpp, immediately after the
				// objc_class_implementations enqueue in the same block. This is the sole
				// producer for procs_with_objc_context_provider_to_check; without it
				// check_objc_context_provider_procedures always sees an empty queue.
				if type_name.objc_context_provider != nil {
					queue.mpsc_enqueue(
						&ctx.checker.procs_with_objc_context_provider_to_check,
						e,
					)
				}

				// C++ Reference: check_decl.cpp check_type_decl:532 and 557-592. Both the objc_superclass STORE
				// and the validation walk live INSIDE the objc_is_implementation gate. The port
				// had the validation as a SIBLING, so every @(objc_class) type carrying a
				// superclass but no @(objc_implement) was checked -- and rejected -- where C++
				// never looks. Probe objcsuper: oracle 0 diagnostics, port 2 errors. LEDGER #283.
				//
				// C++ walks the ENTIRE ancestry with a TypeSet seeded from e->type, validating
				// every ancestor and detecting cycles; the port inspected one level and had only
				// the LAST of C++'s four ordered checks, firing it where C++ fires the third.
				type_name.objc_superclass = effective_ac.objc_superclass

				// Keyed by canonical type hash, mirroring C++'s `TypeSet super_set` (check_decl.cpp
				// check_type_decl:559) as #691 and #693 did. Nothing iterates this set -- it is pure
				// membership -- but keying it the same way as its two siblings is the point: the
				// #112 sweep exists because ONE of three canonical-hash containers had been modelled
				// with pointer identity while the others were correct, and inconsistency between
				// siblings is what makes that class hard to spot (#114).
				//
				// HONESTLY LABELLED: unlike #693 this is INERT on every input I can construct, and
				// is a faithfulness change rather than a defect fix. The loop below rejects anything
				// that is not `.Named` before testing membership, and a named type is created once
				// per declaration, so pointer identity and canonical hash coincide for every value
				// that can reach the set. LEDGER #695.
				super_set := make(map[u64]^Type)
				defer delete(super_set)
				super_set[type_hash_canonical_type(e.type)] = e.type

				super := effective_ac.objc_superclass
				for super != nil {
					// C++ Reference: check_decl.cpp check_type_decl:566-569
					if super.kind != .Named {
						error(e.token, "@(objc_superclass) Referenced type must be a named struct")
						break
					}
					// C++ Reference: check_decl.cpp check_type_decl:571-574. C++'s type_set_update returns true
					// when the type was ALREADY present -- that is the cycle.
					if type_hash_canonical_type(super) in super_set {
						error(e.token, "@(objc_superclass) Superclass hierarchy cycle encountered")
						break
					}
					super_set[type_hash_canonical_type(super)] = super

					// C++ Reference: check_decl.cpp check_type_decl:576 calls check_single_global_entity here to
					// force the superclass to resolve. OMITTED: C++ runs this block from
					// generate_minimum_dependency_set, a LATER pass, while the port runs it at
					// DECLARATION time, so re-entering global entity checking here is not safe.
					named_type := base_named_type(super)
					if named_type == nil || named_type.kind != .Named {
						break
					}
					nt := named_type.variant.(Type_Named)

					// C++ Reference: check_decl.cpp check_type_decl:581-584
					if !is_type_objc_object(ctx.checker, named_type) {
						error(e.token, "@(objc_superclass) Superclass '%s' must be an Objective-C class", nt.name)
						break
					}
					// C++ Reference: check_decl.cpp check_type_decl:586-589
					if !has_type_got_objc_class_attribute(named_type) {
						error(e.token, "@(objc_superclass) Superclass '%s' must have a valid @(objc_class) attribute", nt.name)
						break
					}

					if nt.type_name == nil {
						break
					}
					super = nt.type_name.variant.(Entity_Type_Name).objc_superclass
				}
			} else {
				// C++ Reference: check_decl.cpp, the `else` of the objc_is_implementation
				// branch inside the objc_class block.
				if effective_ac.objc_ivar != nil {
					error(e.token, "@(objc_ivar) may only be applied when the @(obj_implement) attribute is also applied")
				} else if effective_ac.objc_context_provider != nil {
					error(e.token, "@(objc_context_provider) may only be applied when the @(obj_implement) attribute is also applied")
				}
			}

		}
	} else if effective_ac != nil && effective_ac.objc_is_implementation {
		// C++ Reference: check_decl.cpp check_type_decl:593-596
		// objc_is_implement requires objc_class
		error(init_expr, "@(objc_implement) may only be applied when the @(objc_class) attribute is also applied")
	}
}

// ======================================================================================
// DECLARATION DEPENDENCY MANAGEMENT HELPERS
// ======================================================================================

// NOTE: add_dependency and add_declaration_dependency are defined in scope.odin

// make_decl_info creates and initializes a new Decl_Info
// C++ Reference: checker.cpp make_decl_info:183-187 (make_decl_info)
//                checker.cpp init_decl_info:166-181
make_decl_info :: proc(scope: ^Scope, parent: ^Decl_Info = nil, allocator := context.allocator) -> ^Decl_Info {
	// This helper creates a new Decl_Info with proper initialization.
	// In C++, DeclInfo is allocated with gb_alloc_item which zero-initializes,
	// then init_decl_info is called to establish the parent-child hierarchy.

	d := new(Decl_Info, allocator)

	// Establish parent-child linkage (C++ lines 167-171)
	// In C++, this creates a linked list of child declarations under a parent.
	// The parent maintains a list of its children via next_child, and siblings
	// are linked via next_sibling. This enables traversing all nested declarations.
	if parent != nil {
		// C++ line 168: Thread-safe parent-child linkage
		sync.mutex_lock(&parent.next_mutex)
		d.next_sibling = parent.next_child
		parent.next_child = d
		sync.mutex_unlock(&parent.next_mutex)
	}
	d.parent = parent

	d.scope = scope
	d.proc_checked_state = .Unchecked

	// Initialize maps (C++ lines 175-176: ptr_set_init and type_set_init)
	d.deps = make(map[^Entity]struct{})
	d.type_info_deps = make(map[u64]^Type)

	// Initialize dynamic arrays (C++ line 177)
	d.labels = make([dynamic]Block_Label, allocator)

	// Initialize variadic reuse tracking (C++ line 178)
	d.variadic_reuses = make([dynamic]Variadic_Reuse_Data, allocator)

	return d
}


// ======================================================================================
// PROCEDURE DECLARATION HELPERS
// ======================================================================================

// check_objc_methods validates Objective-C method declarations
// C++ Reference: check_decl.cpp:1051-1215
check_objc_methods :: proc(ctx: ^Checker_Context, e: ^Entity, ac: ^Attribute_Context) {
	// C++ Reference: check_decl.cpp:1052-1054
	if ac.objc_type == nil {
		return
	}

	// C++ Reference: check_decl.cpp check_objc_methods:1056-1057
	t := ac.objc_type
	assert(t.kind == .Named) // Already checked at attribute resolution stage

	// C++ Reference: check_decl.cpp check_objc_methods:1059-1074
	// Attempt to infer objc_name automatically if proc name contains
	// the type name as prefix followed by underscore
	if len(ac.objc_name) == 0 {
		proc_name := e.token.text
		type_name := t.variant.(Type_Named).name

		if len(proc_name) > len(type_name) + 1 &&
		   proc_name[len(type_name)] == '_' &&
		   proc_name[:len(type_name)] == type_name {
			// C++ line 1069: Infer objc_name from proc name
			ac.objc_name = proc_name[len(type_name)+1:]
		} else {
			// C++ lines 1071-1073
			error(e.token, "@(objc_name) requires that @(objc_type) be set or inferred by prefixing the proc name with the type and underscore: MyObjcType_myProcName :: proc().")
		}
	}

	// C++ Reference: check_decl.cpp check_objc_methods:1076-1077
	tn := t.variant.(Type_Named).type_name
	assert(tn.kind == .Type_Name)

	// C++ Reference: check_decl.cpp check_objc_methods:1079-1081
	if tn.scope != e.scope {
		error(e.token, "@(objc_name) attribute may only be applied to procedures and types within the same scope")
	} else {
		// C++ Reference: check_decl.cpp check_objc_methods:1082-1091
		// Enable implementation by default if class is implementer and not explicitly disabled
		tn_type_name := &tn.variant.(Entity_Type_Name)
		implement := tn_type_name.objc_is_implementation

		if ac.objc_is_implementation && !tn_type_name.objc_is_implementation {
			error(e.token, "Cannot apply @(objc_is_implement) to a procedure whose type does not also have @(objc_is_implement) set")
		}

		if ac.objc_is_disabled_implement {
			implement = false
		}

		// C++ Reference: check_decl.cpp check_objc_methods:1093
		objc_selector := ac.objc_selector if len(ac.objc_selector) > 0 else ac.objc_name

		// C++ Reference: check_decl.cpp check_objc_methods:1095-1101
		if e.kind == .Procedure {
			proc_ent := &e.variant.(Entity_Procedure)
			has_body := e.decl_info.proc_lit != nil && e.decl_info.proc_lit.derived.(^ast.Proc_Lit).body != nil

			proc_ent.is_objc_impl_or_import = implement || !has_body
			proc_ent.is_objc_class_method = ac.objc_is_class_method
			proc_ent.objc_selector_name = objc_selector
			proc_ent.objc_class = tn

			// C++ Reference: check_decl.cpp check_objc_methods:1102-1103
			proc_type := &e.type.variant.(Type_Proc)
			first_param := t_untyped_nil
			if proc_type.param_count > 0 {
				first_param = proc_type.params.variant.(Type_Tuple).variables[0].type
			}

			// C++ Reference: check_decl.cpp check_objc_methods:1105-1148
			if implement {
				// C++ lines 1106-1108
				if !has_body {
					error(e.token, "Procedures with @(objc_is_implement) must have a body")
				} else if !tn_type_name.objc_is_implementation {
					error(e.token, "@(objc_is_implement) attribute may only be applied to procedures whose class also have @(objc_is_implement) applied")
				} else if !ac.objc_is_class_method &&
				          !(first_param.kind == .Pointer && internal_check_is_assignable_to(t, first_param.variant.(Type_Pointer).elem)) {
					// C++ lines 1110-1111
					error(e.token, "Objective-C instance methods implementations require the first parameter to be a pointer to the class type set by @(objc_type)")
				} else if proc_type.calling_convention == .Odin && tn_type_name.objc_context_provider == nil {
					// C++ lines 1112-1113
					error(e.token, "Objective-C methods with Odin calling convention can only be used with classes that have @(objc_context_provider) set")
				} else if ac.objc_is_class_method && proc_type.calling_convention != .C {
					// C++ lines 1114-1115
					error(e.token, "Objective-C class methods (objc_is_class_method=true) that have @objc_is_implementation can only use \"c\" calling convention")
				} else if proc_type.result_count > 1 {
					// C++ lines 1116-1117
					error(e.token, "Objective-C method implementations may return at most 1 value")
				} else {
					// C++ lines 1119-1130
					if ac.is_export {
						error(e.token, "Explicit export not allowed when @(objc_implement) is set. It set exported implicitly")
					}
					if len(ac.link_name) > 0 {
						error(e.token, "Explicit linkage not allowed when @(objc_implement) is set. It set to \"strong\" implicitly")
					}

					ac.is_export = true
					ac.linkage = "strong"

					// C++ lines 1132-1147: Register method implementation
					method := Objc_Method_Data {
						ac = ac^,
						entity = e,
					}
					method.ac.objc_selector = objc_selector

					info := ctx.info
					sync.mutex_lock(&info.objc_method_mutex)
					defer sync.mutex_unlock(&info.objc_method_mutex)

					if t in info.objc_method_implementations {
						append(&info.objc_method_implementations[t], method)
					} else {
						info.objc_method_implementations[t] = make([dynamic]Objc_Method_Data, 0, 8, ctx.checker.allocator)
						append(&info.objc_method_implementations[t], method)
					}
				}
			} else if !has_body {
				// C++ lines 1149-1164: Imported Objective-C methods
				if len(ac.objc_selector) == 0 {
					error(e.token, "The @(objc_selector) attribute is required for imported Objective-C methods.")
					return
				} else if proc_type.calling_convention != .C {
					error(e.token, "Imported Objective-C methods must use the \"c\" calling convention")
					return
				} else if tn_type_name.objc_context_provider != nil {
					error(e.token, "Imported Objective-C class '%s' must not declare context providers.", t.variant.(Type_Named).name)
					return
				} else if tn_type_name.objc_is_implementation {
					error(e.token, "Imported Objective-C methods used in a class with @(objc_implement) is not allowed.")
					return
				} else if !ac.objc_is_class_method &&
				          !(first_param.kind == .Pointer && internal_check_is_assignable_to(t, first_param.variant.(Type_Pointer).elem)) {
					error(e.token, "Objective-C instance methods require the first parameter to be a pointer to the class type set by @(objc_type)")
					return
				}
			} else if len(ac.objc_selector) > 0 {
				// C++ lines 1166-1169
				error(e.token, "@(objc_selector) may only be applied to procedures that are Objective-C method implementations or are imported.")
				return
			}
		} else {
			// C++ lines 1170-1176: Procedure groups
			assert(e.kind == .Proc_Group)
			if tn_type_name.objc_is_implementation {
				error(e.token, "Objective-C procedure groups cannot use the @(objc_implement) attribute.")
				return
			}
		}

		// C++ Reference: check_decl.cpp check_objc_methods:1179-1213
		// Register objc metadata
		sync.mutex_lock(&global_type_name_objc_metadata_mutex)
		defer sync.mutex_unlock(&global_type_name_objc_metadata_mutex)
		if tn_type_name.objc_metadata == nil {
			tn_type_name.objc_metadata = create_type_name_objc_metadata(ctx.checker.allocator)
		}

		md := tn_type_name.objc_metadata
		sync.mutex_lock(&md.mutex)
		defer sync.mutex_unlock(&md.mutex)

		// C++ lines 1189-1213: Check for duplicate objc_name and register
		if !ac.objc_is_class_method {
			// Instance method
			ok := true
			for entry in md.value_entries {
				if entry.name == ac.objc_name {
					error(e.token, "Previous declaration of @(objc_name=\"%s\")", ac.objc_name)
					ok = false
					break
				}
			}
			if ok {
				append(&md.value_entries, Type_Name_ObjC_Metadata_Entry{
					name = ac.objc_name,
					entity = e,
				})
			}
		} else {
			// Class method
			ok := true
			for entry in md.type_entries {
				if entry.name == ac.objc_name {
					error(e.token, "Previous declaration of @(objc_name=\"%s\")", ac.objc_name)
					ok = false
					break
				}
			}
			if ok {
				append(&md.type_entries, Type_Name_ObjC_Metadata_Entry{
					name = ac.objc_name,
					entity = e,
				})
			}
		}
	}
}

// check_foreign_procedure validates foreign procedure declarations
// C++ Reference: check_decl.cpp:1217-1252
check_foreign_procedure :: proc(ctx: ^Checker_Context, e: ^Entity, d: ^Decl_Info) {
	// C++ Reference: check_decl.cpp:1218-1220
	assert(e != nil)
	assert(e.kind == .Procedure)

	proc_ent := &e.variant.(Entity_Procedure)
	name := proc_ent.link_name

	// C++ Reference: check_decl.cpp check_foreign_procedure:1222
	sync.mutex_lock(&ctx.info.foreign_mutex)
	defer sync.mutex_unlock(&ctx.info.foreign_mutex)

	// C++ Reference: check_decl.cpp check_foreign_procedure:1224-1226
	fp := &ctx.info.foreigns
	found, has_found := fp[name]

	// C++ Reference: check_decl.cpp check_foreign_procedure:1227-1244
	if has_found && e != found {
		// C++ lines 1228-1244: Check for signature compatibility
		f := found
		pos := f.token.pos
		this_type := base_type(e.type)
		other_type := base_type(f.type)

		if is_type_proc(this_type) && is_type_proc(other_type) {
			// C++ lines 1233-1238: Procedure signature mismatch
			if !are_signatures_similar_enough(this_type, other_type) {
				pos_str := token_pos_to_string(pos)
				error(d.proc_lit,
					"Redeclaration of foreign procedure '%s' with different type signatures\n\tat %s",
					name, pos_str)
			}
		} else if !signature_parameter_similar_enough(this_type, other_type) {
			// C++ lines 1239-1243: Non-procedure foreign entity type mismatch
			pos_str := token_pos_to_string(pos)
			error(d.proc_lit,
				"Foreign entity '%s' previously declared elsewhere with a different type\n\tat %s",
				name, pos_str)
		}
	} else if name == "main" {
		// C++ lines 1245-1246: Reserved link name check
		error(d.proc_lit, "The link name 'main' is reserved for internal use")
	} else {
		// C++ line 1248: Register this foreign procedure
		fp[name] = e
	}
}

// init_core_load_directory_file ensures base:runtime.Load_Directory_File is loaded and the
// three type globals are built.
//
// C++ Reference: checker.cpp:3594-3601. The port DECLARED t_load_directory_file{,_ptr,_slice}
// (types.odin:250-252) and the only assignments anywhere were the three `= nil` resets, so
// #load_directory could never produce its []Load_Directory_File result type. Called lazily
// from the directive arm, exactly as C++ calls it from check_load_directory_directive.
init_core_load_directory_file :: proc(c: ^Checker) {
	if c.t_load_directory_file != nil {
		return
	}
	ldf := find_core_type(c, "Load_Directory_File")
	if ldf == nil {
		// Runtime package not loaded -- leave the globals nil; the caller guards on them.
		return
	}
	c.t_load_directory_file       = ldf
	c.t_load_directory_file_ptr   = alloc_type_pointer(ldf)
	c.t_load_directory_file_slice = alloc_type_slice(ldf)
}

// init_core_source_code_location ensures core:runtime.Source_Code_Location is loaded
// C++ Reference: checker.cpp:3362-3368
init_core_source_code_location :: proc(c: ^Checker) {
	// C++ Reference: checker.cpp:3587-3589 - Early return if already loaded.
	// NOTE: guard on the GLOBAL, matching C++. See init_mem_allocator.
	if c.t_source_code_location != nil {
		return
	}

	// C++ Reference: checker.cpp:3590 - Load Source_Code_Location from core:runtime
	scl := find_core_type(c, "Source_Code_Location")
	if scl == nil {
		// Runtime package not loaded - skip
		return
	}

	// C++ Reference: checker.cpp:3591 - Create pointer type.
	// The checker reads the globals; the cached_ fields are not read anywhere.
	c.t_source_code_location = scl
	c.t_source_code_location_ptr = alloc_type_pointer(scl)

	c.info.cached_source_code_location = scl
	c.info.cached_source_code_location_ptr = c.t_source_code_location_ptr
}
