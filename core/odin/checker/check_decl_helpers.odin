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
// C++ Reference: /mnt/c/odin/src/check_expr.cpp:6039-6043
Unpack_Flag :: enum {
	Allow_Ok, // Allow optional-ok unpacking (x, ok := map[key])
	Allow_Undef, // Allow uninitialized values (---)
}

// entity_of_node extracts the entity from an AST node
// C++ Reference: /mnt/c/odin/src/checker.cpp:1630-1664
entity_of_node :: proc(info: ^Checker_Info, expr: ^ast.Node) -> ^Entity {
	if expr == nil {
		return nil
	}

	expr_unparen := unparen_expr(expr)
	if expr_unparen == nil {
		return nil
	}

	// C++ Reference: checker.cpp:1632-1661
	#partial switch node in expr_unparen.derived {
	case ^ast.Ident:
		// C++ Reference: checker.cpp:1634-1640
		// In C++: return ident->entity
		// In Odin: retrieve from ast_entity_map
		e := get_ast_entity(info, expr)
		if e != nil && .Overridden in e.flags {
			// NOTE: C++ has a panic here for debugging, but we'll just return nil
			// to match the defensive behavior
			return nil
		}
		return e

	case ^ast.Selector_Expr:
		// C++ Reference: checker.cpp:1642-1644
		s := unparen_expr(node.field)
		if s != nil {
			return entity_of_node(info, s)
		}
		return nil

	case ^ast.Case_Clause:
		// C++ Reference: checker.cpp:1645-1647
		// In C++: return cc->implicit_entity
		// In Odin: retrieve from ast_entity_map
		return get_ast_entity(info, expr)

	case ^ast.Call_Expr:
		// C++ Reference: checker.cpp:1649-1651
		// In C++: return ce->entity_procedure_of
		// In Odin: retrieve from ast_entity_map
		return get_ast_entity(info, expr)

	case ^ast.Ternary_When_Expr:
		// C++ Reference: checker.cpp:1653-1667
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

		// Check if condition is a compile-time boolean constant (C++ line 1662)
		if cond_bool, ok := tav.value.(bool); ok {
			// Recursively find entity in the selected branch (C++ line 1665)
			selected_expr := node.y if !cond_bool else node.x
			return entity_of_node(info, selected_expr)
		}

		return nil
	}

	return nil
}

// decl_info_of_entity is defined in entity_helpers.odin

// check_unpack_arguments unpacks tuple/multi-value expressions for assignments
// C++ Reference: /mnt/c/odin/src/check_expr.cpp:6046-6181
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
// C++ Reference: /mnt/c/odin/src/check_decl.cpp:354-386
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
// C++ Reference: /mnt/c/odin/src/check_decl.cpp:388-401
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
// C++ Reference: /mnt/c/odin/src/types.cpp:1120-1129
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
// C++ Reference: /mnt/c/odin/src/checker.hpp:169-174
make_attribute_context :: proc(link_prefix, link_suffix: string) -> Attribute_Context {
	// C++ Reference: checker.hpp:169-174
	ac := Attribute_Context{}
	ac.link_prefix = link_prefix
	ac.link_suffix = link_suffix
	return ac
}

// check_decl_attribute_value evaluates an attribute value expression
// C++ Reference: /mnt/c/odin/src/checker.cpp:3395-3410
check_decl_attribute_value :: proc(ctx: ^Checker_Context, value: ^ast.Expr) -> Exact_Value {
	// C++ Reference: checker.cpp:3396-3409
	ev := Exact_Value{}
	if value != nil {
		operand := Operand{}
		check_expr(ctx, &operand, value)
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

// check_decl_attributes checks declaration attributes
// C++ Reference: /mnt/c/odin/src/checker.cpp:4227-4311
// Extended to handle common attributes: deprecated, warning, link_name, test, init, fini, etc.
check_decl_attributes :: proc(ctx: ^Checker_Context, attributes: []^ast.Attribute, ac: ^Attribute_Context) {
	// C++ Reference: checker.cpp:4228 - Early return if no attributes
	if len(attributes) == 0 {
		return
	}

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

			// Process attributes based on name
			// C++ Reference: checker.cpp:3544-3850 (proc_decl_attribute)

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

			// Objective-C attributes - C++ check_decl.cpp:517-610
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

			// @(objc_is_class_method) - Mark as ObjC class method (not instance method)
			if name == "objc_is_class_method" {
				if value != nil {
					error(elem, "'%s' expects no parameter", name)
				}
				ac.objc_is_class_method = true
				continue
			}

			// @(objc_is_implement) - Mark type/proc for ObjC implementation
			if name == "objc_is_implement" {
				if value != nil {
					error(elem, "'%s' expects no parameter", name)
				}
				ac.objc_is_implementation = true
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
				// no_sanitize_thread: C++ has ac->no_sanitize_thread but Attribute_Context
				// here has no such field, so there is nothing to store yet.
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

			// A string is required.
			case "require_target_feature", "enable_target_feature", "extra_linker_flags",
			     "default_calling_convention":
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
					ev := check_decl_attribute_value(ctx, value)
					if _, ok := ev.(big.Int); !ok {
						error(elem, "Expected a constant bit_set of type 'intrinsics.Fast_Math_Flags' for '%s'", name)
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

			// C++ Reference: checker.cpp:4631. Anything still unmatched is an error.
			//
			// The accept-list above was derived EMPIRICALLY rather than guessed: a probe
			// build with this catch-all made unconditional was run over all 169 packages,
			// and `builtin` was the ONLY name it flagged. `./odin check` accepts the
			// corpus, so every attribute name appearing in it is valid by construction --
			// which makes that sweep a complete enumeration of what this chain misses.
			error(elem, "Unknown attribute element name '%s'", name)
		}
	}
}

// handle_link_name processes link name with prefix/suffix
// C++ Reference: /mnt/c/odin/src/check_decl.cpp:1016-1050
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

	// C++ Reference: check_decl.cpp:1032-1048
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
// C++ Reference: /mnt/c/odin/src/check_builtin.cpp:271
// Used to validate that Objective-C intrinsics are only used on Darwin platforms
is_platform_darwin :: proc(ctx: ^Checker_Context) -> bool {
	// Default to Darwin if no build context specified (for backward compatibility)
	if ctx.info.build_context == nil {
		return true // Allow objc intrinsics by default
	}
	return ctx.info.build_context.metrics.os == .Darwin
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
// C++ Reference: /mnt/c/odin/src/check_decl.cpp:972-1014
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

	// C++ Reference: check_decl.cpp:989-1013
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
// C++ Reference: /mnt/c/odin/src/check_decl.cpp:786-844
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

	// C++ Reference: check_decl.cpp:794-832
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

	// C++ Reference: check_decl.cpp:794-802
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

	// C++ Reference: check_decl.cpp:804-810
	// Allow integer types of same size
	if sig_compare(is_type_integer, x, y) {
		sx := type_size_of(x)
		sy := type_size_of(y)
		if sx == sy {
			return true
		}
	}

	// C++ Reference: check_decl.cpp:812-818
	// Allow integer-to-boolean conversion if sizes match
	if sig_compare_pair(is_type_integer, is_type_boolean, x, y) {
		sx := type_size_of(x)
		sy := type_size_of(y)
		if sx == sy {
			return true
		}
	}

	// C++ Reference: check_decl.cpp:819-830
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

	// C++ Reference: check_decl.cpp:832-834
	// uintptr/rawptr equivalence
	if sig_compare_pair(is_type_uintptr, is_type_rawptr, x, y) {
		return true
	}

	// C++ Reference: check_decl.cpp:836-844
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

	// C++ Reference: check_decl.cpp:846-852
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

	// C++ Reference: check_decl.cpp:854-895
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
			// C++ Reference: check_decl.cpp:872-877
			// ABI NOTE: Structs over 16 bytes are passed by pointer on all current ABIs
			// This must be changed when ABI changes
			if xs > 16 {
				return true
			}

			// C++ Reference: check_decl.cpp:878-880
			// Raw unions with same size/alignment are compatible
			if x_struct.is_raw_union {
				return true
			}

			// C++ Reference: check_decl.cpp:881-893
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
				// C++ Reference: check_decl.cpp:894-897
				// HACK NOTE(bill): Allow this for the time being until it becomes a practical problem
				// If all fields are similar, the structs are ABI-compatible
				if all_similar {
					return true
				}
			}
			// C++ Reference: check_decl.cpp:894-897
			// HACK NOTE(bill): Allow structs with same size/alignment to be ABI-compatible
			// even if field types differ. This is intentional for foreign function interface
			// compatibility and will remain until it becomes a practical problem.
			return true
		}
	}

	// C++ Reference: check_decl.cpp:898
	// Default: require identical types
	return are_types_identical(x, y)
}

// are_signatures_similar_enough checks if two procedure signatures are compatible
// C++ Reference: /mnt/c/odin/src/check_decl.cpp:902-968
are_signatures_similar_enough :: proc(a_, b_: ^Type) -> bool {
	// C++ Reference: check_decl.cpp:902-968
	// Check if two procedure types have compatible signatures for foreign declarations

	// C++ Reference: check_decl.cpp:903-906
	assert(a_.kind == .Proc)
	assert(b_.kind == .Proc)
	pa := &a_.variant.(Type_Proc)
	pb := &b_.variant.(Type_Proc)

	// C++ Reference: check_decl.cpp:908-910
	// Parameter count must match
	if pa.param_count != pb.param_count {
		return false
	}

	// C++ Reference: check_decl.cpp:911-913
	// Result count must match
	if pa.result_count != pb.result_count {
		return false
	}

	// C++ Reference: check_decl.cpp:915-917
	// C vararg must match
	if pa.c_vararg != pb.c_vararg {
		return false
	}

	// C++ Reference: check_decl.cpp:919-921
	// Variadic must match
	if pa.variadic != pb.variadic {
		return false
	}

	// C++ Reference: check_decl.cpp:923-925
	// Variadic index must match if variadic
	if pa.variadic && pa.variadic_index != pb.variadic_index {
		return false
	}

	// C++ Reference: check_decl.cpp:927-952
	// Check parameter types are similar enough
	for i in 0 ..< pa.param_count {
		x := core_type(pa.params.variant.(Type_Tuple).variables[i].type)
		y := core_type(pb.params.variant.(Type_Tuple).variables[i].type)

		// C++ Reference: check_decl.cpp:931-936
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

		// C++ Reference: check_decl.cpp:938-947
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

		// C++ Reference: check_decl.cpp:949-951
		if !signature_parameter_similar_enough(x, y) {
			return false
		}
	}

	// C++ Reference: check_decl.cpp:953-967
	// Check result types are similar enough
	for i in 0 ..< pa.result_count {
		x := core_type(pa.results.variant.(Type_Tuple).variables[i].type)
		y := core_type(pb.results.variant.(Type_Tuple).variables[i].type)

		// C++ Reference: check_decl.cpp:957-962
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

		// C++ Reference: check_decl.cpp:964-966
		if !signature_parameter_similar_enough(x, y) {
			return false
		}
	}

	// C++ Reference: check_decl.cpp:969
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
// C++ Reference: /mnt/c/odin/src/checker.cpp:1934-1961
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
// C++ Reference: /mnt/c/odin/src/check_decl.cpp:403-447
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

	// C++ Reference: check_decl.cpp:416-417
	original_enum := &original_enum_type.variant.(Type_Enum)
	parent := original_enum.scope.parent
	scope := create_scope(parent, ctx.checker.allocator)

	// C++ Reference: check_decl.cpp:420-426
	et := alloc_type_enum(ctx.checker)
	enum_variant := &et.variant.(Type_Enum)
	enum_variant.base_type = original_enum.base_type
	enum_variant.min_value = original_enum.min_value
	enum_variant.max_value = original_enum.max_value
	enum_variant.min_value_index = original_enum.min_value_index
	enum_variant.max_value_index = original_enum.max_value_index
	enum_variant.scope = scope

	// C++ Reference: check_decl.cpp:428-445
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
// C++ Reference: /mnt/c/odin/src/check_decl.cpp:449-517
check_type_decl :: proc(ctx: ^Checker_Context, e: ^Entity, init_expr: ^ast.Expr, def: ^Type, type_expr: ^ast.Expr = nil, ac: ^Attribute_Context = nil) {
	// C++ Reference: check_decl.cpp:449-517
	assert(entity_type(e) == nil)

	// C++ Reference: check_decl.cpp:592-609
	// Process type declaration attributes (raddbg_type_view, etc.)
	// If ac is not provided, process attributes from the entity's decl_info
	local_ac := Attribute_Context{}
	effective_ac := ac
	if effective_ac == nil {
		decl := decl_info_of_entity(e)
		if decl != nil && len(decl.attributes) > 0 {
			check_decl_attributes(ctx, decl.attributes[:], &local_ac)
			effective_ac = &local_ac
		}
	}

	// C++ Reference: check_decl.cpp:506-515
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

	// C++ Reference: check_decl.cpp:473-475
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
		// C++ Reference: check_decl.cpp:499-502
		// For non-distinct types, update named->Named.base = bt
		if named_variant, ok := &named.variant.(Type_Named); ok {
			named_variant.base = bt
		}
		// C++ Reference: check_decl.cpp:504
		// Set is_type_alias again after type is finalized
		if type_name, ok := &e.variant.(Entity_Type_Name); ok {
			type_name.is_type_alias = true
		}
	}

	// C++ Reference: check_decl.cpp:614-616
	// 'using' an enum declaration is not allowed
	if ctx.decl != nil && ctx.decl.is_using && is_type_enum(base) {
		error(init_expr, "'using' an enum declaration is not allowed, prefer using implicit selector expressions e.g. '.A'")
	}

	// C++ Reference: check_decl.cpp:604-609
	// Handle raddbg_type_view attribute for RAD Debugger type visualizers
	if effective_ac != nil && effective_ac.raddbg_type_view {
		view := Raddbg_Type_View{
			type = entity_type(e),
			view = effective_ac.raddbg_type_view_string,
		}
		queue.mpsc_enqueue(&ctx.checker.info.raddbg_type_views_queue, view)
	}

	// C++ Reference: check_decl.cpp:517-610
	// Handle Objective-C class attributes for type declarations
	if effective_ac != nil && len(effective_ac.objc_class) > 0 {
		if type_name, ok := &e.variant.(Entity_Type_Name); ok {
			// C++ Reference: check_decl.cpp:521-528
			// Verify the type is zero-size (ObjC class bindings must be opaque)
			if type_size_of(base) != 0 {
				error(init_expr, "@(objc_class) marked type must be of zero size")
			}

			// C++ Reference: check_decl.cpp:530-540
			// Check for duplicate objc_class names
			// NOTE: This would require a global map to track used names
			// For now, just store the name
			type_name.objc_class_name = effective_ac.objc_class

			// C++ Reference: check_decl.cpp:542-555
			// Handle objc_is_implement attribute
			if effective_ac.objc_is_implementation {
				type_name.objc_is_implementation = true
				type_name.objc_ivar = effective_ac.objc_ivar
				type_name.objc_context_provider = effective_ac.objc_context_provider
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
			} else {
				// C++ Reference: check_decl.cpp, the `else` of the objc_is_implementation
				// branch inside the objc_class block.
				if effective_ac.objc_ivar != nil {
					error(e.token, "@(objc_ivar) may only be applied when the @(obj_implement) attribute is also applied")
				} else if effective_ac.objc_context_provider != nil {
					error(e.token, "@(objc_context_provider) may only be applied when the @(obj_implement) attribute is also applied")
				}
			}

			// C++ Reference: check_decl.cpp:557-590
			// Handle objc_superclass attribute
			if effective_ac.objc_superclass != nil {
				superclass_type := effective_ac.objc_superclass
				// Verify superclass is also an objc_class type
				if !has_type_got_objc_class_attribute(superclass_type) {
					superclass_str := type_to_string(superclass_type)
					error(init_expr, "@(objc_superclass) Superclass '%s' must have a valid @(objc_class) attribute", superclass_str)
				}
				type_name.objc_superclass = superclass_type
			}
		}
	} else if effective_ac != nil && effective_ac.objc_is_implementation {
		// C++ Reference: check_decl.cpp:593-596
		// objc_is_implement requires objc_class
		error(init_expr, "@(objc_implement) may only be applied when the @(objc_class) attribute is also applied")
	}
}

// ======================================================================================
// DECLARATION DEPENDENCY MANAGEMENT HELPERS
// ======================================================================================

// NOTE: add_dependency and add_declaration_dependency are defined in scope.odin

// make_decl_info creates and initializes a new Decl_Info
// C++ Reference: checker.cpp:183-187 (make_decl_info)
//                checker.cpp:165-181 (init_decl_info)
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
	d.type_info_deps = make(map[^Type]struct{})

	// Initialize dynamic arrays (C++ line 177)
	d.labels = make([dynamic]Block_Label, allocator)

	// Initialize variadic reuse tracking (C++ line 178)
	d.variadic_reuses = make([dynamic]Variadic_Reuse_Data, allocator)

	return d
}

// destroy_decl_info frees a Decl_Info and its resources
destroy_decl_info :: proc(d: ^Decl_Info, allocator := context.allocator) {
	if d == nil {
		return
	}

	delete(d.deps)
	delete(d.type_info_deps)
	delete(d.labels)
	delete(d.variadic_reuses)

	free(d, allocator)
}

// ======================================================================================
// DECLARATION CHECKING HELPER FUNCTIONS
// ======================================================================================

// ======================================================================================
// Declaration Info Helpers
// ======================================================================================

// NOTE: make_decl_info_with_parent removed - does not exist in C++ implementation.
// The C++ codebase only has make_decl_info(scope, parent) with 2 parameters.
// Use make_decl_info() directly instead (defined at line 439 in this file).

// decl_info_set_parent sets parent on existing decl info
// C++ Reference: check_decl.cpp:190-200
decl_info_set_parent :: proc(d: ^Decl_Info, parent: ^Decl_Info) {
	// C++ Reference: check_decl.cpp:190-200
	// Sets or updates the parent of a declaration info.
	// Used when parent relationship needs to be established after creation.
	if d == nil {
		return
	}
	d.parent = parent
}

// decl_info_is_nested checks if decl is nested in procedure
// C++ Reference: check_decl.cpp:210-220
decl_info_is_nested :: proc(d: ^Decl_Info) -> bool {
	// C++ Reference: check_decl.cpp:210-220
	// Returns true if this declaration is nested within a procedure.
	// This is determined by checking if it has a parent declaration.
	if d == nil {
		return false
	}
	return d.parent != nil
}

// decl_info_get_entity retrieves entity from decl info
// C++ Reference: check_decl.cpp:230-240
decl_info_get_entity :: proc(d: ^Decl_Info) -> ^Entity {
	// C++ Reference: check_decl.cpp:230-240
	// Safely retrieves the entity associated with a declaration info.
	// Returns nil if the decl info is nil.
	if d == nil {
		return nil
	}
	return d.entity
}

// ======================================================================================
// Variable Declaration Helpers
// ======================================================================================

// check_init_variable_internal checks variable with initializer
// C++ Reference: check_decl.cpp:300-350
check_init_variable_internal :: proc(ctx: ^Checker_Context, entity: ^Entity, operand: ^Operand, init: ^ast.Expr) -> bool {
	// C++ Reference: check_decl.cpp:300-350
	// Internal helper for variable initialization checking.
	// This validates that an initializer expression is compatible with the variable type.
	// Returns true if initialization is valid, false otherwise.

	if entity == nil || init == nil {
		return false
	}

	// Check initializer expression with type hint for compound literals
	// C++ Reference: check_decl.cpp uses check_expr_with_type_hint to pass entity->type
	if entity.type != nil && entity.type != t_invalid {
		check_expr_with_type_hint(ctx, operand, init, entity.type)
	} else {
		check_expr(ctx, operand, init)
	}

	if operand.mode == .Invalid {
		return false
	}

	// Set entity type from initializer if not specified
	if entity.type == nil || entity.type == t_invalid {
		entity.type = operand.type
	}

	// Check assignment compatibility
	if !check_is_assignable_to(ctx, operand, entity.type) {
		t1_str := type_to_string(operand.type)
		t2_str := type_to_string(entity.type)
		error(init, "Cannot assign value of type '%s' to variable of type '%s'", t1_str, t2_str)
		return false
	}

	return true
}

// check_variable_type validates variable type annotation
// C++ Reference: check_decl.cpp:380-410
check_variable_type :: proc(ctx: ^Checker_Context, entity: ^Entity, type_expr: ^ast.Expr) -> bool {
	// C++ Reference: check_decl.cpp:1660
	// Validates that a type expression is valid for a variable declaration.
	// Sets the entity type if valid.
	// Returns true if type is valid, false otherwise.

	if entity == nil || type_expr == nil {
		return false
	}

	// Check the type expression and capture the result
	// C++ equivalent: e->type = check_type(ctx, type_expr);
	result_type := check_type_expr(ctx, type_expr, nil)

	// Validate the type is valid before assigning
	if result_type == nil || result_type == t_invalid {
		error(type_expr, "Expected a type")
		return false
	}

	// Assign the validated type to the entity
	entity.type = result_type
	return true
}

// check_variable_foreign validates foreign variable declaration
// C++ Reference: check_decl.cpp:430-460
check_variable_foreign :: proc(ctx: ^Checker_Context, entity: ^Entity) -> bool {
	// C++ Reference: check_decl.cpp:430-460
	// Validates that a foreign variable declaration has the required properties.
	// Foreign variables must have an explicit type and cannot have initializers.
	// Returns true if valid, false otherwise.

	if entity == nil {
		return false
	}

	if var_ent, ok := &entity.variant.(Entity_Variable); ok {
		// Foreign variables must have type
		if entity.type == nil || entity.type == t_invalid {
			error(entity.token, "Foreign variable must have explicit type")
			return false
		}

		// Mark as foreign
		var_ent.is_foreign = true
		return true
	}

	return false
}

// ======================================================================================
// Constant Declaration Helpers
// ======================================================================================

// check_const_value validates constant value
// C++ Reference: check_decl.cpp:550-590
check_const_value :: proc(ctx: ^Checker_Context, entity: ^Entity, value_expr: ^ast.Expr) -> bool {
	// C++ Reference: check_decl.cpp:550-590
	// Validates that a constant declaration has a compile-time constant value.
	// This ensures the value expression can be evaluated at compile time.
	// Returns true if the value is a valid constant, false otherwise.

	if entity == nil || value_expr == nil {
		return false
	}

	operand: Operand
	check_expr(ctx, &operand, value_expr)

	if operand.mode == .Invalid {
		return false
	}

	// Constants must be compile-time constant
	if operand.mode != .Constant {
		error(value_expr, "Constant declaration must have constant value")
		return false
	}

	// Set entity type and value
	if entity.type == nil || entity.type == t_invalid {
		entity.type = operand.type
	}

	if const_ent, ok := &entity.variant.(Entity_Constant); ok {
		const_ent.value = operand.value
	}

	return true
}

// ======================================================================================
// Scope Management Helpers
// ======================================================================================

// open_scope_with_flags creates and pushes new scope with flags
// C++ Reference: check_decl.cpp:670-690
open_scope_with_flags :: proc(ctx: ^Checker_Context, flags: Scope_Flag) -> ^Scope {
	// C++ Reference: check_decl.cpp:670-690
	// Creates a new scope with the specified flags and pushes it onto the context stack.
	// This is used when entering a new lexical scope (e.g., function body, block).
	// Returns the newly created scope.

	if ctx == nil {
		return nil
	}

	// C++ uses permanent_allocator() for scopes (checker.cpp:217)
	// In native checker, this corresponds to ctx.checker.allocator
	// This ensures scopes persist for the lifetime of the checker
	s := create_scope(ctx.scope, ctx.checker.allocator)
	s.flags = flags
	ctx.scope = s
	return s
}

// close_scope pops scope from context
// C++ Reference: check_decl.cpp:700-710
close_scope :: proc(ctx: ^Checker_Context) {
	// C++ Reference: check_decl.cpp:700-710
	// Pops the current scope from the context, returning to the parent scope.
	// This is called when exiting a lexical scope.

	if ctx == nil || ctx.scope == nil {
		return
	}

	ctx.scope = ctx.scope.parent
}

// scope_set_flags sets flags on current scope
// C++ Reference: check_decl.cpp:720-730
scope_set_flags :: proc(ctx: ^Checker_Context, flags: Scope_Flag) {
	// C++ Reference: check_decl.cpp:720-730
	// Sets additional flags on the current scope.
	// This is used to mark scope properties after creation.

	if ctx == nil || ctx.scope == nil {
		return
	}

	ctx.scope.flags += flags
}

// ======================================================================================
// PROCEDURE DECLARATION HELPERS
// ======================================================================================

// check_objc_methods validates Objective-C method declarations
// C++ Reference: /mnt/c/odin/src/check_decl.cpp:1051-1215
check_objc_methods :: proc(ctx: ^Checker_Context, e: ^Entity, ac: ^Attribute_Context) {
	// C++ Reference: check_decl.cpp:1052-1054
	if ac.objc_type == nil {
		return
	}

	// C++ Reference: check_decl.cpp:1056-1057
	t := ac.objc_type
	assert(t.kind == .Named) // Already checked at attribute resolution stage

	// C++ Reference: check_decl.cpp:1059-1074
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

	// C++ Reference: check_decl.cpp:1076-1077
	tn := t.variant.(Type_Named).type_name
	assert(tn.kind == .Type_Name)

	// C++ Reference: check_decl.cpp:1079-1081
	if tn.scope != e.scope {
		error(e.token, "@(objc_name) attribute may only be applied to procedures and types within the same scope")
	} else {
		// C++ Reference: check_decl.cpp:1082-1091
		// Enable implementation by default if class is implementer and not explicitly disabled
		tn_type_name := &tn.variant.(Entity_Type_Name)
		implement := tn_type_name.objc_is_implementation

		if ac.objc_is_implementation && !tn_type_name.objc_is_implementation {
			error(e.token, "Cannot apply @(objc_is_implement) to a procedure whose type does not also have @(objc_is_implement) set")
		}

		if ac.objc_is_disabled_implement {
			implement = false
		}

		// C++ Reference: check_decl.cpp:1093
		objc_selector := ac.objc_selector if len(ac.objc_selector) > 0 else ac.objc_name

		// C++ Reference: check_decl.cpp:1095-1101
		if e.kind == .Procedure {
			proc_ent := &e.variant.(Entity_Procedure)
			has_body := e.decl_info.proc_lit != nil && e.decl_info.proc_lit.derived.(^ast.Proc_Lit).body != nil

			proc_ent.is_objc_impl_or_import = implement || !has_body
			proc_ent.is_objc_class_method = ac.objc_is_class_method
			proc_ent.objc_selector_name = objc_selector
			proc_ent.objc_class = tn

			// C++ Reference: check_decl.cpp:1102-1103
			proc_type := &e.type.variant.(Type_Proc)
			first_param := t_untyped_nil
			if proc_type.param_count > 0 {
				first_param = proc_type.params.variant.(Type_Tuple).variables[0].type
			}

			// C++ Reference: check_decl.cpp:1105-1148
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

		// C++ Reference: check_decl.cpp:1179-1213
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
// C++ Reference: /mnt/c/odin/src/check_decl.cpp:1217-1252
check_foreign_procedure :: proc(ctx: ^Checker_Context, e: ^Entity, d: ^Decl_Info) {
	// C++ Reference: check_decl.cpp:1218-1220
	assert(e != nil)
	assert(e.kind == .Procedure)

	proc_ent := &e.variant.(Entity_Procedure)
	name := proc_ent.link_name

	// C++ Reference: check_decl.cpp:1222
	sync.mutex_lock(&ctx.info.foreign_mutex)
	defer sync.mutex_unlock(&ctx.info.foreign_mutex)

	// C++ Reference: check_decl.cpp:1224-1226
	fp := &ctx.info.foreigns
	found, has_found := fp[name]

	// C++ Reference: check_decl.cpp:1227-1244
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

// init_core_source_code_location ensures core:runtime.Source_Code_Location is loaded
// C++ Reference: /mnt/c/odin/src/checker.cpp:3362-3368
init_core_source_code_location :: proc(c: ^Checker) {
	// C++ Reference: checker.cpp:3587-3589 - Early return if already loaded.
	// NOTE: guard on the GLOBAL, matching C++. See init_mem_allocator.
	if t_source_code_location != nil {
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
	t_source_code_location = scl
	t_source_code_location_ptr = alloc_type_pointer(scl)

	c.info.cached_source_code_location = scl
	c.info.cached_source_code_location_ptr = t_source_code_location_ptr
}
