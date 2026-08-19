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
// C++ Reference: checker.cpp entity_of_node
entity_of_node :: proc(info: ^Checker_Info, expr: ^ast.Node) -> ^Entity {
	if expr == nil {
		return nil
	}

	expr_unparen := unparen_expr(expr)
	if expr_unparen == nil {
		return nil
	}

	// C++ Reference: checker.cpp entity_of_node
	#partial switch node in expr_unparen.derived {
	case ^ast.Ident:
		// C++ Reference: checker.cpp entity_of_node
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
		return get_ast_entity(info, expr_unparen)

	case ^ast.Selector_Expr:
		// C++ Reference: checker.cpp entity_of_node -- C++ uses unselector_expr (a LOOP over
		// nested SelectorExprs); the port strips one level here and re-enters, reaching the same node
		s := unparen_expr(node.field)
		if s != nil {
			return entity_of_node(info, s)
		}
		return nil

	case ^ast.Case_Clause:
		// C++ Reference: checker.cpp entity_of_node
		// In C++: return cc->implicit_entity
		// In Odin: retrieve from ast_entity_map
		return get_ast_entity(info, expr_unparen)

	case ^ast.Call_Expr:
		// C++ Reference: checker.cpp entity_of_node
		// In C++: return ce->entity_procedure_of
		// In Odin: retrieve from ast_entity_map
		return get_ast_entity(info, expr_unparen)

	case ^ast.Ternary_When_Expr:
		// C++ Reference: checker.cpp entity_of_node -- C++ uses `goto retry` after selecting
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

		// Check if condition is a compile-time boolean constant (C++ checker.cpp entity_of_node)
		if cond_bool, ok := tav.value.(bool); ok {
			// Recursively find entity in the selected branch (C++ checker.cpp entity_of_node)
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
	"require_results", "require_target_feature", "tag", "test",
}
@(rodata) attr_names_var := [?]string{
	"export", "link_name", "link_prefix", "link_section", "link_suffix", "linkage", "private",
	"require", "rodata", "static", "tag", "thread_local",
}
@(rodata) attr_names_const := [?]string{
	"link_name", "link_prefix", "link_suffix", "linkage", "private", "require", "rodata",
	"static", "tag", "thread_local",
}
@(rodata) attr_names_type := [?]string{
	"deprecated", "objc_class", "objc_context_provider", "objc_implement", "objc_ivar",
	"objc_superclass", "private", "raddbg_type_view", "tag",
}
@(rodata) attr_names_proc_group := [?]string{
	"objc_is_class_method", "objc_name", "objc_type", "private", "require_results", "tag",
}
@(rodata) attr_names_foreign_block := [?]string{
	"default_calling_convention", "link_prefix", "link_suffix", "private", "require_results", "tag",
}
@(rodata) attr_names_foreign_import := [?]string{
	"export", "extra_linker_flags", "force", "ignore_duplicates", "priority_index", "require", "tag",
}
@(rodata) attr_names_import := [?]string{"require", "tag"}

attribute_is_valid_for_kind :: proc(name: string, kind: Attribute_Decl_Kind) -> bool {
	// C++ handles `builtin` before the table is consulted (checker.cpp:4631), gated on the
	// declaration being in base:runtime, so it is never subject to the per-kind tables. That gate
	// now lives in check_decl_attributes; this function must NOT wave "builtin" through, or the
	// out-of-runtime case is accepted everywhere.
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
// string_is_valid_identifier is a FAITHFUL port of src/string.cpp:1238, INCLUDING ITS DEFECT.
//
// Do NOT replace this with is_string_an_identifier (entity_helpers.odin) or is_valid_identifier
// (check_decl.odin). Those are ports of DIFFERENT reference functions and they behave differently:
//   * is_string_an_identifier ports checker.cpp:4998-5020, which walks EVERY rune correctly.
//   * is_valid_identifier is ASCII-only and treats '_' as legal everywhere.
//   * THIS ports string.cpp:1238, whose loop never advances its decode pointer:
//         w = utf8_decode(str.text, str.len, &r);      // str.text, never str.text + offset
//     so it re-decodes the FIRST rune on every iteration. That rune has already satisfied the
//     rune_count==0 test, so the branch meant to validate characters 2..n can never fail. The net
//     behaviour is: reject empty, reject a leading invalid UTF-8 sequence, reject a non-letter
//     first character, ACCEPT ANYTHING AFTER THE FIRST CHARACTER.
//
// MEASURED on the reference via @(objc_name=...), which is its caller:
//     "foo" ok   "_foo" ok   "ábc" ok   "a1234" ok   "a b" OK   "a!@#$%^" OK
//     "1abc" rejected   "" rejected
// Filed upstream as
// COMPILER_ISSUES/UPSTREAM-UNFILED-string-is-valid-identifier-only-checks-the-first-rune.md,
// but it is not a crash, so per Jon's ruling the reference behaviour IS the contract and the port
// reproduces it. Using any of the correct validators here would reject `objc_name="a b"`, which the
// reference accepts.
string_is_valid_identifier :: proc(str: string) -> bool {
	// C++ line 1239: if (str.len <= 0) return false;
	if len(str) == 0 {
		return false
	}
	// C++ line 1247-1250: the single decode that this function ever really performs.
	r, _ := utf8.decode_rune_in_string(str)
	if r == utf8.RUNE_ERROR {
		return false
	}
	// C++ line 1252-1255: rune_count == 0 -> must be rune_is_letter. is_letter
	// (check_import_export.odin) is already the faithful port of unicode.cpp:15, '_' included.
	return is_letter(r)
}

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
// `subject_pos` is the position of the DECLARATION the attributes belong to, when the caller knows
// it. Only the `private`-on-a-local diagnostic needs it: C++ raises that one from
// check_collect_value_decl with the DECL node, not from the attribute handler with `elem`, so it
// points at the variable's name rather than at the attribute. #1000.
//
// `subject_node` (t204) is that same DECLARATION as a NODE, and is preferred over `subject_pos`
// whenever the caller has it. C++ checker.cpp:4923 is `error(decl, ...)` -- a NODE -- and a node
// carries an END, so the reference underlines the whole declaration:
//     @(private) X :: 1          oracle `^~~~~^`   (X :: 1)
//     @(private) T :: struct{}   oracle `^~~~~~~~~~^`  (T :: struct)
// Threading only a Pos threw the end away and the port drew a bare `^`. The second case also
// confirms ast_end_pos's Struct_Type arm: C++'s ast_end_token returns the last meaningful CHILD,
// so an empty struct ends at the `struct` keyword, not at the closing brace.
//
// subject_pos is KEPT as the fallback rather than replaced: not every caller has a decl node, and
// the pos path is still strictly better than falling all the way back to `elem`.
check_decl_attributes :: proc(ctx: ^Checker_Context, attributes: []^ast.Attribute, ac: ^Attribute_Context, kind: Attribute_Decl_Kind, subject_pos := tokenizer.Pos{}, subject_node: ^ast.Node = nil) {
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

	// C++ Reference: checker.cpp:4580-4581. A per-CALL set of element names, used for the
	// duplicate-attribute diagnostic below. The port had NO set, no map, and no such diagnostic
	// anywhere in this loop -- the check existed ONLY in the hand-rolled foreign-block copy in
	// check_stmt.odin, which is where an earlier fix landed instead of here.
	seen_attrs := make(map[string]bool, context.temp_allocator)
	defer delete(seen_attrs)

	// C++ Reference: checker.cpp:4583-4594. `@(builtin)` is legal ONLY inside base:runtime, and
	// the reference computes that with TWO branches: a file scope in the runtime package, or a
	// PROC scope whose parent is such a file scope.
	is_runtime := false
	if ctx.scope != nil {
		if .File in ctx.scope.flags && ctx.scope.file != nil && is_package_runtime(ctx.scope.file.pkg) {
			is_runtime = true
		} else if .Proc in ctx.scope.flags && ctx.scope.parent != nil &&
		   .File in ctx.scope.parent.flags && ctx.scope.parent.file != nil &&
		   is_package_runtime(ctx.scope.parent.file.pkg) {
			is_runtime = true
		}
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

			// C++ Reference: checker.cpp:4626-4629. DUPLICATE DETECTION, and note it `continue`s:
			// the handler never runs for the repeat, so the FIRST value wins. The port had no
			// duplicate check at all, which meant `@(cold, cold)` was silently accepted AND
			// `@(link_name="a") @(link_name="b")` silently took "b" where the reference keeps "a".
			if name in seen_attrs {
				error(elem, "Previous declaration of '%s'", name)
				continue
			}
			seen_attrs[name] = true

			// C++ Reference: checker.cpp:4631-4633. `@(builtin)` is exempt ONLY inside
			// base:runtime; everywhere else it must fall through to the unknown-attribute path.
			// The port instead special-cased "builtin" as unconditionally valid in
			// attribute_is_valid_for_kind (now removed), so `@(builtin) foo :: proc() {}` in ANY
			// package was accepted.
			if name == "builtin" && is_runtime {
				continue
			}

			// The user tag. C++ Reference: checker.cpp:3711 defines
			// `#define ATTRIBUTE_USER_TAG_NAME "tag"` and makes it the FIRST arm of ALL EIGHT
			// declaration-attribute handlers (3717, 3788, 3842, 4294, 4440, 4465, 5579, 5680),
			// each requiring a string value. The port had "tag" in NO table and only in a
			// local-variable exemption list, so `@(tag="anything")` was rejected as an unknown
			// attribute for every declaration kind.
			if name == "tag" {
				ev := check_decl_attribute_value(ctx, value)
				if _, is_str := ev.(string); !is_str {
					error(elem, "Expected a string value for '%s'", name)
				}
				continue
			}

			// C++ selects the attribute table by declaration kind; a name the table does not
			// name makes the handler return false, landing on the unknown-attribute path.
			// C++ Reference: checker.cpp var_decl_attribute --
			//
			//     if (c->curr_proc_decl != nullptr) {
			//         error(elem, "Only a variable at file scope can have a '%.*s'", LIT(name));
			//         return true;
			//     }
			//
			// #946: THE GUARD MUST PRECEDE THE NAME-TABLE CHECK. In C++ it lives INSIDE
			// var_decl_attribute and `return true`s, so a name that is not in the var table at all --
			// `cold`, `deprecated` -- still gets THIS error rather than falling through to
			// "Unknown attribute element name". #939 placed it after the table check and those two
			// cells reported the wrong diagnostic.
			//
			// #939: ABSENT FROM THE PORT. `@(export) v: int` inside a procedure body was accepted;
			// the oracle rejects it. 3 cells in `attributes` (export, link_name, private).
			//
			// The guard's POSITION in C++ is the whole rule. It sits after four names that each
			// `return true` before reaching it -- the user tag `"tag"`, `static`, `rodata` and
			// `thread_local` -- so those four remain legal on a LOCAL variable and everything else
			// in attr_names_var is file-scope-only. Reproducing that ordering as an explicit
			// exemption list is what keeps `@(static) v: int` and `@(rodata) v: int` accepted.
			//
			// Only .Var is guarded: C++ has no such test in proc_decl_attribute,
			// const_decl_attribute or type_decl_attribute, and a procedure or type declared inside
			// a procedure body keeps its attributes.
			// C++ Reference: checker.cpp const_decl_attribute --
			//
			//     } else if (name == "static" || name == "thread_local" || name == "require" ||
			//                name == "linkage" || name == "link_name" || name == "link_prefix" ||
			//                name == "link_suffix" || name == "rodata") {
			//         error(elem, "@(%.*s) is not supported for compile time constant value declarations", LIT(name));
			//         return true;
			//     }
			//
			// #999: the port performed these AFTER the dispatcher, from check_const_decl, using
			// `decl.attributes[0]` -- the `@(` node -- where C++ reports at `elem`, the element
			// inside it. Identical text, one column apart, 5 cells in `attributes`. Doing it here
			// puts the element node in scope and collapses eight hardcoded messages into C++'s one.
			if kind == .Const {
				switch name {
				case "static", "thread_local", "require", "linkage",
				     "link_name", "link_prefix", "link_suffix", "rodata":
					error(elem, "@(%s) is not supported for compile time constant value declarations", name)
					continue
				}
			}

			// C++ Reference: checker.cpp:4921-4923. The non-file-scope test for @(private) runs
			// during COLLECTION, for every value declaration check_collect_value_decl handles --
			// local constants, types and procedures included, not only variables. The port's only
			// copy of this message sits inside the `.Var` arm below, so `@(private) X :: 1`,
			// `@(private) T :: struct{}` and `@(private) f :: proc(){}` inside a procedure body
			// were all silently accepted.
			if kind != .Var && ctx.curr_proc_decl != nil && name == "private" {
				if subject_node != nil {
					error_node(subject_node, "Attribute 'private' is not allowed on a non file scope entity")
				} else if subject_pos.line != 0 {
					error(subject_pos, "Attribute 'private' is not allowed on a non file scope entity")
				} else {
					error(elem, "Attribute 'private' is not allowed on a non file scope entity")
				}
				continue
			}

			if kind == .Var && ctx.curr_proc_decl != nil {
				switch name {
				case "tag", "static", "rodata", "thread_local":
					// Handled by C++ before the guard; still legal on a local.
				case "private":
					// C++ Reference: checker.cpp check_collect_value_decl --
					//
					//     if (entity_visibility_kind != EntityVisiblity_Public && !(c->scope->flags&ScopeFlag_File)) {
					//         error(decl, "Attribute 'private' is not allowed on a non file scope entity");
					//     }
					//
					// #946: `private` DOES reach C++'s file-scope guard, but the oracle emits this
					// message instead -- MEASURED, one diagnostic, not two. The port has no
					// counterpart to that collection-phase site at all (the string appears nowhere
					// in core/odin/checker), so the message is emitted here.
					//
					// This is a PLACEMENT approximation and is stated as one: the TRIGGER is
					// equivalent -- inside a procedure body the scope is not a file scope, and
					// @(private) is by definition non-Public, so C++'s two conjuncts both hold
					// exactly when this arm is reached -- but C++ reaches it during collection
					// rather than during attribute checking. If the port ever grows the
					// visibility-kind machinery, this belongs there.
					// #1000: reported at the DECLARATION when the caller supplied its position,
					// which is what C++ does -- `error(decl, ...)` in check_collect_value_decl.
					// Falls back to `elem` when it was not supplied, so no caller is obliged to.
					if subject_node != nil {
						error_node(subject_node, "Attribute 'private' is not allowed on a non file scope entity")
					} else if subject_pos.line != 0 {
						error(subject_pos, "Attribute 'private' is not allowed on a non file scope entity")
					} else {
						error(elem, "Attribute 'private' is not allowed on a non file scope entity")
					}
					continue
				case:
					error(elem, "Only a variable at file scope can have a '%s'", name)
					continue
				}
			}

			if !attribute_is_valid_for_kind(name, kind) {
				report_unknown_attribute(elem, name)
				continue
			}

			// Process attributes based on name
			// C++ Reference: checker.cpp proc_decl_attribute

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
					// C++ Reference: checker.cpp:3861-3862 -- this arm `return false`s, and the
					// shared loop then ALSO reports the unknown-attribute error (4635-4641). So
					// the reference emits TWO diagnostics for `@(export=42)` and the port emitted
					// one. report_unknown_attribute already applies the
					// -ignore-unknown-attributes / -custom-attribute guards.
					report_unknown_attribute(elem, name)
				}
				// C++ Reference: checker.cpp:4366-4368 -- the VAR export arm re-tests
				// thread_local at its tail. Without it the check is ORDER-SENSITIVE: the port
				// caught `@(export, thread_local)` (thread_local arm runs second and tests
				// is_export) but NOT `@(thread_local, export)`. The reference catches both.
				if kind == .Var && len(ac.thread_local_model) != 0 {
					error(elem, "An exported variable cannot be thread local")
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
					// C++ Reference: checker.cpp:4051 (and 3737, 4406) guard on NON-EMPTY:
					// `ac->link_prefix.len != 0 && !is_foreign_name_valid(...)`.
					// is_foreign_name_valid("") is false on both sides, so without the length
					// term the port rejected `@(link_prefix="")`, which the reference allows.
					// The reference deliberately has NO such guard on link_name/link_section,
					// and the port matches there -- so this is the prefix/suffix pair only.
					if len(ac.link_prefix) != 0 && !is_foreign_name_valid(ac.link_prefix) {
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
					// C++ Reference: checker.cpp:4063 -- same non-empty guard as link_prefix.
					if len(ac.link_suffix) != 0 && !is_foreign_name_valid(ac.link_suffix) {
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

			if name == "require" {
				// TWO DIFFERENT CONTRACTS, one per declaration kind, and the port had only the
				// procedure one:
				//   * VAR  (checker.cpp:4350-4355): NO parameter is permitted, and
				//     require_declaration is forced TRUE regardless -- so `@(require=false)`
				//     is BOTH a diagnostic AND still requires the declaration. The port silently
				//     stored `false`, a wrong computed value as well as a missing error.
				//   * PROC (checker.cpp:3886-3895): an OPTIONAL boolean.
				// (.Const rejects "require" earlier via the unsupported-attribute list, and
				// .Import/.Foreign_Import use the wording "Expected no parameter for 'require'"
				// but are not reachable in this port -- see the dead-table note.)
				if kind == .Var {
					if value != nil {
						error(elem, "'require' does not have any parameters")
					}
					ac.require_declaration = true
					continue
				}
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
				// C++ Reference: checker.cpp:3865-3885. THREE divergences here, and note the two
				// failure paths differ in KIND:
				//   * non-string: the reference's wording is "Expected either a string 'linkage'"
				//     (awkward but exact) and it `return false`s, so the shared loop ALSO reports
				//     the unknown-attribute error -- two diagnostics, where the port gave one.
				//   * invalid kind: an ERROR_BLOCK header "Valid kinds:" followed by FOUR
				//     error_line continuations, then `return true` -- ONE diagnostic. The port had
				//     collapsed the four lines into a single comma-joined sentence.
				ev := check_decl_attribute_value(ctx, value)
				linkage, ok := ev.(string)
				if !ok {
					error(value, "Expected either a string 'linkage'")
					report_unknown_attribute(elem, name)
					continue
				}
				if linkage == "internal" || linkage == "strong" || linkage == "weak" || linkage == "link_once" {
					ac.linkage = linkage
				} else {
					begin_error_block()
					error(elem, "Invalid linkage '%s'. Valid kinds:", linkage)
					error_line("\tinternal\n")
					error_line("\tstrong\n")
					error_line("\tweak\n")
					error_line("\tlink_once\n")
					end_error_block()
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
					// C++ Reference: checker.cpp:4324-4328 lists FIVE models; "globaldynamic" was dropped.
					if model == "default" || model == "globaldynamic" || model == "localdynamic" || model == "initialexec" || model == "localexec" {
						ac.thread_local_model = model
					} else {
						// #1229. C++ Reference: checker.cpp:4331-4338. The message ENDS at
						// "Valid models:" and the five models follow as SEPARATE error_line
						// continuations inside an ERROR_BLOCK -- one per line. The port inlined
						// them into the message instead, and its inline list also OMITTED
						// "globaldynamic" (the accept-list above has it, so this was a text-only
						// defect -- witnesses n_tls_globaldynamic/default/localexec all match,
						// which is how I know the behaviour was right and only the text wrong).
						begin_error_block()
						defer end_error_block()
						error(elem, "Invalid thread local model '%s'. Valid models:", model)
						error_line("\tdefault\n")
						error_line("\tglobaldynamic\n")
						error_line("\tlocaldynamic\n")
						error_line("\tinitialexec\n")
						error_line("\tlocalexec\n")
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

			// The DEPRECATED bare `@(deferred=p)`. C++ Reference: checker.cpp:3908-3924. The port
			// listed "deferred" in attr_names_proc but the dispatch below matches only the seven
			// `deferred_*` names, so it passed the table check and fell all the way to
			// report_unknown_attribute -- giving "Unknown attribute element name 'deferred'" where
			// the reference gives the deprecation message AND still records the deferred procedure
			// with kind = .Out. A name accepted by a table with no handler to receive it.
			if name == "deferred" {
				if value != nil {
					o: Operand
					check_expr(ctx, &o, value)
					e := entity_of_node(&ctx.checker.info, o.expr)
					if e != nil && e.kind == .Procedure {
						error(elem, "'%s' is not allowed any more, please use one of the following instead: 'deferred_none', 'deferred_in', 'deferred_out'", name)
						if ac.deferred_procedure.entity != nil {
							error(elem, "Previous usage of a 'deferred_*' attribute")
						}
						ac.deferred_procedure.kind = .Out
						ac.deferred_procedure.entity = e
						continue
					}
				}
				error(elem, "Expected a procedure entity for '%s'", name)
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

				// Duplicate detection applies to the whole deferred family EXCEPT
				// "deferred_none". C++ Reference: the check is present at checker.cpp:3944-3946
				// (deferred_in), 3960, 3976, 3992, 4008, 4024 -- and DELIBERATELY ABSENT from
				// deferred_none's arm at 3925-3937, which assigns the kind and entity with no
				// prior-usage test. The port folded all seven names into one arm and applied the
				// check to every one, so `@(deferred_in=a, deferred_none=b)` was rejected where
				// the reference accepts it (ending with kind=none, entity=b).
				if name != "deferred_none" && ac.deferred_procedure.entity != nil {
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
				// #1220. C++ Reference: checker.cpp:4527-4541. THREE-WAY, not two-way:
				//   Invalid (no value at all) -> accept, `@(raddbg_type_view)` is legal;
				//   String                    -> accept, and reject an EMPTY one;
				//   anything else             -> "Expected a string or no value for '%s'".
				// The port had a two-way test with an invented message, so it BOTH
				// over-permitted (empty string silently accepted -- witness c_raddbg_e, where
				// the oracle rejects and the port said nothing) and mis-worded the other arm
				// (c_raddbg_n: "Expected a string value for" vs "a string or no value for").
				ev := check_decl_attribute_value(ctx, value)
				if ev == nil {
					ac.raddbg_type_view = true
				} else if v_str, ok := ev.(string); ok {
					ac.raddbg_type_view = true
					ac.raddbg_type_view_string = v_str

					if len(v_str) == 0 {
						error(elem, "Expected a non-empty string for '%s'", name)
					}
				} else {
					error(elem, "Expected a string or no value for '%s'", name)
				}
				continue
			}

			// Objective-C attributes - C++ check_decl.cpp check_type_decl
			// @(objc_class="ClassName") - ObjC class binding
			if name == "objc_class" {
				// C++ Reference: checker.cpp:4474-4480 -- the test is
				// `ev.kind != ExactValue_String || ev.value_string == ""`, and the message says
				// NON-EMPTY. The port tested only "is a string", so `@(objc_class="")` was
				// accepted, and for a non-string value the wording differed too.
				ev := check_decl_attribute_value(ctx, value)
				if v_str, ok := ev.(string); ok && v_str != "" {
					ac.objc_class = v_str
				} else {
					error(elem, "Expected a non-empty string value for '%s'", name)
				}
				continue
			}

			// @(objc_name="name") - ObjC method name
			// C++ Reference: checker.cpp:3794 (proc_group_attribute) and :4147
			// (proc_decl_attribute) -- both arms are IDENTICAL:
			//     if (ev.kind == ExactValue_String) {
			//         if (string_is_valid_identifier(ev.value_string)) { ac->objc_name = ...; }
			//         else { error(elem, "Invalid identifier for '%.*s', got '%.*s'", ...); }
			//     } else { error(elem, "Expected a string value for '%.*s'", LIT(name)); }
			// The port had NO validation at all -- it assigned any string. Witness
			// $S/phase2/wit_objcname/on_digit `@(objc_name="1abc")`: oracle rejects with
			// "Invalid identifier for 'objc_name', got '1abc'", the port accepted it silently.
			// See string_is_valid_identifier above for why that specific predicate is required
			// rather than either of the port's two correct identifier validators.
			if name == "objc_name" {
				ev := check_decl_attribute_value(ctx, value)
				if v_str, ok := ev.(string); ok {
					if string_is_valid_identifier(v_str) {
						ac.objc_name = v_str
					} else {
						error(elem, "Invalid identifier for '%s', got '%s'", name, v_str)
					}
				} else {
					error(elem, "Expected a string value for '%s'", name)
				}
				continue
			}

			// @(objc_selector="selector:name:") - ObjC selector
			// C++ Reference: checker.cpp:4198-4208 -- the THIRD caller of
			// string_is_valid_identifier in the checker, and identical in shape to objc_name:
			//     if (string_is_valid_identifier(ev.value_string)) { ac->objc_selector = ...; }
			//     else { error(elem, "Invalid identifier for '%.*s', got '%.*s'", ...); }
			// The port had no validation, exactly as objc_name did before #1190. Witnesses
			// $S/phase2/wit_objcsel/sel_bad `objc_selector="1bad"` and sel_empty `objc_selector=""`:
			// oracle emits "Invalid identifier for 'objc_selector', got '...'", the port emitted
			// only the LATER objc_name/objc_type diagnostic.
			// The buggy first-rune-only predicate is REQUIRED here rather than merely tolerated: a
			// real selector is `initWithFrame:` and a correct identifier check would REJECT the
			// colon. sel_colon is the control that pins that -- both compilers accept it.
			if name == "objc_selector" {
				ev := check_decl_attribute_value(ctx, value)
				if v_str, ok := ev.(string); ok {
					if string_is_valid_identifier(v_str) {
						ac.objc_selector = v_str
					} else {
						error(elem, "Invalid identifier for '%s', got '%s'", name, v_str)
					}
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
			// C++ Reference: checker.cpp:4491-4499 (type_decl_attribute):
			//     Type *objc_superclass = check_type(c, value);
			//     if (objc_superclass != nullptr) { ac->objc_superclass = objc_superclass; }
			//     else { error(value, "'%.*s' expected a named type", LIT(name)); }
			// The port assigned UNCONDITIONALLY and had no error arm at all.
			//
			// The `value != nil` guard is KEPT DELIBERATELY and is NOT in the reference here: the
			// reference calls check_type(c, nullptr) and DIES --
			//     src/checker.cpp(52): Assertion Failure: `expr != nullptr`
			// on `@(objc_superclass)` with no value, reproduced 3/3 alone, rc=132 (SIGILL). Filed
			// upstream. Jon's ruling stands: a reference quirk is the contract EXCEPT when it is a
			// crash, so the port diagnoses instead. The guard is the reference's OWN idiom for this
			// -- its objc_type arm (checker.cpp:3815) does exactly `if (value == nullptr) { error(
			// elem, "Expected a type for '%.*s'", ...); }` -- so this is its shape, applied to the
			// two neighbours where it forgot it.
			if name == "objc_superclass" {
				if value != nil {
					type_val := check_type(ctx, value)
					if type_val != nil {
						ac.objc_superclass = type_val
					} else {
						error(value, "'%s' expected a named type", name)
					}
				} else {
					error(elem, "Expected a type for '%s'", name)
				}
				continue
			}

			// @(objc_ivar=FieldType) - ObjC instance variable type
			// C++ Reference: checker.cpp:4501-4509:
			//     if (objc_ivar != nullptr && objc_ivar->kind == Type_Named) { ac->objc_ivar = ...; }
			//     else { error(value, "'%.*s' expected a named type", LIT(name)); }
			// The port had NEITHER half of that condition. Witness $S/phase2/wit_osc/oiv_basic,
			// `@(objc_ivar=int)`: oracle "'objc_ivar' expected a named type", port silently accepted
			// and then reported the LATER objc_implement error instead -- a different diagnostic for
			// the same program.
			// NOT is_type_named(): that port helper returns TRUE for Type_Basic (types.odin:4593),
			// which is the Odin sense of "named" and NOT the reference's test here. The reference
			// compares the KIND against Type_Named exactly, which is precisely why `int` -- a
			// Type_Basic -- is rejected. Testing the variant directly keeps that distinction.
			if name == "objc_ivar" {
				if value != nil {
					type_val := check_type(ctx, value)
					is_named := false
					if type_val != nil {
						_, is_named = type_val.variant.(Type_Named)
					}
					if is_named {
						ac.objc_ivar = type_val
					} else {
						error(value, "'%s' expected a named type", name)
					}
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
			// "builtin" was REMOVED from this list: it is handled by the is_runtime gate at the
			// top of the loop, and accepting it here defeated that gate.
			switch name {
			case "ignore_duplicates":
				continue
			}

			// C++ Reference: checker.cpp check_decl_attributes. Anything still unmatched is an error,
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

	// C++ Reference: checker.cpp check_decl_attributes. An INHERITED link_prefix/link_suffix is silently
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

	// C++ Reference: check_decl.cpp handle_link_name
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
				// C++ Reference: checker.cpp:3691 -- `if (!gb_char_is_alpha(cast(char)rune))`.
				// TWO things the port got wrong with unicode.is_alpha, and the SECOND is the reason
				// this is not simply "restrict to ASCII":
				//   1. gb_char_is_alpha (gb.h) is ASCII-ONLY: (c>='A'&&c<='Z')||(c>='a'&&c<='z').
				//      So `@(link_name="ábc")` is REJECTED by the reference and was ACCEPTED here.
				//   2. the rune is TRUNCATED to a single char first, so a non-ASCII leader whose LOW
				//      BYTE lands in ASCII alpha is ACCEPTED by the reference. `š` is U+0161, low byte
				//      0x61 = 'a', so `@(link_name="šbc")` is accepted -- and a naive
				//      `is_ascii_alpha(r)` rewrite would have REJECTED it and introduced a NEW
				//      divergence in the opposite direction.
				// Both cells are witnesses: wit_link/lk_nonascii_lead (was DIVERGENT) and
				// wit_link/lk_trunc_lead (must STAY matching). #1181, B3-b finding T1.8.
				b := u8(r)
				if !((b >= 'A' && b <= 'Z') || (b >= 'a' && b <= 'z')) {
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

	// C++ Reference: check_decl.cpp init_entity_foreign_library
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

	// C++ Reference: check_decl.cpp signature_parameter_similar_enough
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

	// C++ Reference: check_decl.cpp signature_parameter_similar_enough
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

	// C++ Reference: check_decl.cpp signature_parameter_similar_enough
	// Allow integer types of same size
	if sig_compare(is_type_integer, x, y) {
		sx := type_size_of(x)
		sy := type_size_of(y)
		if sx == sy {
			return true
		}
	}

	// C++ Reference: check_decl.cpp signature_parameter_similar_enough
	// Allow integer-to-boolean conversion if sizes match
	if sig_compare_pair(is_type_integer, is_type_boolean, x, y) {
		sx := type_size_of(x)
		sy := type_size_of(y)
		if sx == sy {
			return true
		}
	}

	// C++ Reference: check_decl.cpp signature_parameter_similar_enough
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

	// C++ Reference: check_decl.cpp signature_parameter_similar_enough
	// uintptr/rawptr equivalence
	if sig_compare_pair(is_type_uintptr, is_type_rawptr, x, y) {
		return true
	}

	// C++ Reference: check_decl.cpp signature_parameter_similar_enough
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

	// C++ Reference: check_decl.cpp signature_parameter_similar_enough
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

	// C++ Reference: check_decl.cpp signature_parameter_similar_enough
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
			// C++ Reference: check_decl.cpp signature_parameter_similar_enough
			// ABI NOTE: Structs over 16 bytes are passed by pointer on all current ABIs
			// This must be changed when ABI changes
			if xs > 16 {
				return true
			}

			// C++ Reference: check_decl.cpp signature_parameter_similar_enough
			// Raw unions with same size/alignment are compatible
			if x_struct.is_raw_union {
				return true
			}

			// C++ Reference: check_decl.cpp signature_parameter_similar_enough
			// Check field-by-field compatibility
			// C++ Reference: check_decl.cpp:884-901. The reference's inner loop does
			// `if (!similar) goto end;`, and `end:` is BELOW the HACK `return true` -- so a
			// dissimilar field escapes the whole struct arm and lands on are_types_identical.
			// The port used `break`, which leaves only the INNER LOOP, after which
			// `if all_similar` fails and control fell into the unconditional `return true`
			// below -- reporting two structurally different structs as ABI-compatible.
			// *** The port's old comment here CLAIMED that was intentional ("This is intentional
			// for foreign function interface compatibility"). The reference does not do it. ***
			// WITNESSED: two foreign procs under one @(link_name="sym"), params `struct{a: f32}`
			// vs `struct{b: i32}` (same size and align, one field each): oracle reports
			// "Redeclaration of foreign procedure 'sym' with different type signatures", port was
			// silent. A different-ARITY pair was caught by both, which is what proved the
			// surrounding path was live and localised the defect to this arm.
			if len(x_struct.fields) == len(y_struct.fields) {
				for i in 0 ..< len(x_struct.fields) {
					a := x_struct.fields[i]
					b := y_struct.fields[i]
					if !signature_parameter_similar_enough(a.type, b.type) {
						// C++ `goto end`: past the HACK return, to the identical-types test.
						return are_types_identical(x, y)
					}
				}
			}
			// HACK NOTE(bill), and it IS the reference's: reached when the field counts DIFFER, or
			// when every field was similar enough.
			return true
		}
	}

	// C++ Reference: check_decl.cpp signature_parameter_similar_enough
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

	// C++ Reference: check_decl.cpp are_signatures_similar_enough
	// Parameter count must match
	if pa.param_count != pb.param_count {
		return false
	}

	// C++ Reference: check_decl.cpp are_signatures_similar_enough
	// Result count must match
	if pa.result_count != pb.result_count {
		return false
	}

	// C++ Reference: check_decl.cpp are_signatures_similar_enough
	// C vararg must match
	if pa.c_vararg != pb.c_vararg {
		return false
	}

	// C++ Reference: check_decl.cpp are_signatures_similar_enough
	// Variadic must match
	if pa.variadic != pb.variadic {
		return false
	}

	// C++ Reference: check_decl.cpp are_signatures_similar_enough
	// Variadic index must match if variadic
	if pa.variadic && pa.variadic_index != pb.variadic_index {
		return false
	}

	// C++ Reference: check_decl.cpp are_signatures_similar_enough
	// Check parameter types are similar enough
	for i in 0 ..< pa.param_count {
		x := core_type(pa.params.variant.(Type_Tuple).variables[i].type)
		y := core_type(pb.params.variant.(Type_Tuple).variables[i].type)

		// C++ Reference: check_decl.cpp are_signatures_similar_enough
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

		// C++ Reference: check_decl.cpp are_signatures_similar_enough
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

		// C++ Reference: check_decl.cpp are_signatures_similar_enough
		if !signature_parameter_similar_enough(x, y) {
			return false
		}
	}

	// C++ Reference: check_decl.cpp are_signatures_similar_enough
	// Check result types are similar enough
	for i in 0 ..< pa.result_count {
		x := core_type(pa.results.variant.(Type_Tuple).variables[i].type)
		y := core_type(pb.results.variant.(Type_Tuple).variables[i].type)

		// C++ Reference: check_decl.cpp are_signatures_similar_enough
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

		// C++ Reference: check_decl.cpp are_signatures_similar_enough
		if !signature_parameter_similar_enough(x, y) {
			return false
		}
	}

	// C++ Reference: check_decl.cpp are_signatures_similar_enough
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

	// C++ Reference: check_decl.cpp clone_enum_type
	original_enum := &original_enum_type.variant.(Type_Enum)
	parent := original_enum.scope.parent
	scope := create_scope(parent, ctx.checker.allocator)

	// C++ Reference: check_decl.cpp clone_enum_type
	et := alloc_type_enum(ctx.checker)
	enum_variant := &et.variant.(Type_Enum)
	enum_variant.base_type = original_enum.base_type
	enum_variant.min_value = original_enum.min_value
	enum_variant.max_value = original_enum.max_value
	enum_variant.min_value_index = original_enum.min_value_index
	enum_variant.max_value_index = original_enum.max_value_index
	enum_variant.scope = scope

	// C++ Reference: check_decl.cpp clone_enum_type
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

	// C++ Reference: check_decl.cpp check_type_decl
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
	// **THAT EDGE HAS NOW BEEN MEASURED, AND IT WAS A REAL DEFECT -- see #1194.** This note used to
	// read "NOT INVESTIGATED: whether an attribute whose VALUE names the type being declared resolves
	// differently when the entity's type is still nil ... this is unlikely". It was not unlikely. The
	// supposition ("resolution goes through the SCOPE, where the entity exists either way") is correct
	// about finding the ENTITY and irrelevant to the failure: what the referenced procedure's
	// PARAMETER needs is the entity's TYPE, which was still t_invalid while the attributes ran.
	// `@(objc_context_provider=prov)` with `prov :: proc(self: ^P)` cached `proc(^invalid type)`.
	// FIXED by moving this whole block to C++'s position (after e->type = named AND after
	// named->Named.base = base); the enumeration above therefore no longer describes the port, and is
	// kept only as the record of how the order difference was reasoned about before it was measured.
	//
	// CITATION CORRECTED (#610): cited 592-609, the objc_superclass / zero-size region. C++ processes
	// type-decl attributes at `if (decl != nullptr) { AttributeContext ac = {};
	// check_decl_attributes(ctx, decl->attributes, type_decl_attribute, &ac); ... }` = 520-524.
	// This was the FIRST citation in the proc, so its too-high anchor inverted the four that follow (#52).

	// C++ Reference: check_decl.cpp check_type_decl
	// Process explicit type annotation if provided

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

	// C++ Reference: check_decl.cpp:476-478, verbatim --
	//     if (is_distinct && bt->kind == Type_Named && base->kind == Type_Enum) {
	//             base = clone_enum_type(ctx, base, named);
	//     }
	//
	// THE MIDDLE CONDITION WAS MISSING, and it is the one that decides whether the clone happens
	// at all in the common case. clone_enum_type exists for the `Y :: distinct X` edge case named
	// in its own comment -- X is already a NAMED enum, so Y needs its own copies of X's members
	// retyped to Y. A plain
	//     E :: enum { A, B, C }
	// is ALSO is_distinct (only `E :: X` over an existing type is an alias), but its `bt` is the
	// enum type itself, not a Named, so the reference does not clone: the entities check_enum_type
	// just built are the final ones. Without the guard the port cloned EVERY enum declaration in
	// every package -- a second scope, a second entity per member, and a second add_entity_use --
	// and then discarded the originals.
	//
	// The clone is not a faithful copy, which is how this surfaced. It carries token, type, value,
	// file, identifier, flags, docs and comment (check_decl.cpp:435-439 copies exactly those, and
	// the port matches) but NOT Entity_Constant.init_expr, the field upstream PR #7289 added for
	// enum members. So every explicitly-valued member lost its initialiser expression and the doc
	// writer fell through to exact_value_to_string.
	// MEASURED with docbin.sh: for `Greater = +1` / `Alias = Alias_Src` / `Expr = 2 + 3` the
	// oracle records init="+1" / "Alias_Src" / "2 + 3" and the port recorded "1" / "-1" / "5" --
	// the folded VALUES, which is a different thing from the source text and in the alias case
	// loses the referenced name entirely.
	//
	// FOUND BY POINTER: the entity check_enum_type built and the entity the doc writer read had
	// different addresses, which is what sent the search here rather than into the doc writer.
	if is_distinct && bt.kind == .Named && base.kind == .Enum {
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
		// C++ Reference: check_decl.cpp check_type_decl
		// For non-distinct types, update named->Named.base = bt
		if named_variant, ok := &named.variant.(Type_Named); ok {
			named_variant.base = bt
		}
		// C++ Reference: check_decl.cpp check_type_decl
		// Set is_type_alias again after type is finalized
		if type_name, ok := &e.variant.(Entity_Type_Name); ok {
			type_name.is_type_alias = true
		}
	}

	// C++ Reference: check_decl.cpp:509-518. The reference emits NO bespoke message here; it
	// builds an Addressing_Type operand and runs check_assignment against the annotation, giving
	// "Cannot assign 'Foo', a type, to a constant declaration" anchored at INIT_EXPR. The port's
	// "Expected 'typeid' for type declaration annotation" has 0 hits in src/ and anchored at
	// type_expr, so text AND position were both wrong.
	//
	// *** POSITION IN THE PROCEDURE IS PART OF THE FIX, AND IT TOOK TWO MOVES. *** The reference runs
	// this at 509, i.e. AFTER `e->type = bt` (504) and AFTER is_type_alias (507). Placed at the
	// port's original spot (before set_entity_type) the operand type was NIL and the message read
	// "Cannot assign '<no type>'". Placed after the FIRST set_entity_type(e, named) it read
	// "Cannot assign 'X'" -- the entity's own name -- because for an ALIAS the reference has already
	// re-pointed e->type at the aliased type by then. Only after the `!is_distinct` block, where
	// set_entity_type(e, bt) runs, does it print 'Foo' like the oracle. Each wrong position produced
	// a plausible message naming the wrong thing.
	if type_expr != nil {
		type_type := check_type(ctx, type_expr)
		if type_type != nil && !is_type_typeid(type_type) {
			operand := Operand{}
			operand.mode = .Type
			operand.type = entity_type(e)
			operand.expr = init_expr
			check_assignment(ctx, &operand, type_type, "constant declaration")
		}
	}

	// C++ Reference: check_decl.cpp check_type_decl
	//
	// #1194. MOVED HERE from the TOP of check_type_decl. C++'s order is
	//     465  e->type = named;
	//     479  named->Named.base = base;
	//     522  check_decl_attributes(ctx, decl->attributes, type_decl_attribute, &ac);
	//     524  e->deprecated_message = ac.deprecated_message;
	// so the attribute VALUES are resolved only once the declared type is BOTH assigned to the entity
	// AND has its base filled in. The port ran them first, before `named` even existed.
	//
	// #610 dispositioned that order difference as INERT by enumerating what the handler touches, and
	// recorded the single edge its enumeration did not cover:
	//     "**NOT INVESTIGATED:** whether an attribute whose VALUE names the type being declared
	//      ... resolves differently when the entity's type is still nil."
	// That edge is a real defect. MEASURED with
	//     @(objc_class="P", objc_implement, objc_context_provider=prov)
	//     P :: struct { using _: Foundation.Object }
	//     prov :: proc(self: ^P) -> runtime.Context { ... }
	// resolving the attribute value `prov` forces prov's signature, whose parameter names ^P, while
	// P's entity type was still t_invalid -- the port cached `proc(^invalid type)` where the reference
	// has `proc(^P)`, and then reported a spurious "must take as a parameter a single pointer".
	// Witnesses $S/phase2/wit_ocp/ocp_reveal_p and ocp_ok.
	//
	// POSITION MATTERS TWICE OVER: placing this immediately after set_entity_type(e, named) -- after
	// the entity has its type but BEFORE named.base is filled -- makes `^P` resolve to a Named type
	// with a nil base and produces "Invalid type usage 'P'" instead. Measured, not guessed. It has to
	// go after BOTH assignments, which is exactly where C++ has it.
	//
	// objc_context_provider is the ONLY type attribute whose value is a PROCEDURE, so it is the only
	// one that can form this TYPE -> PROC -> TYPE cycle; @(deferred_in=) and @(objc_ivar=) were both
	// measured and MATCH.
	// Process type declaration attributes (raddbg_type_view, etc.)
	// If ac is not provided, process attributes from the entity's decl_info
	local_ac := Attribute_Context{}
	effective_ac := ac
	if effective_ac == nil {
		decl := decl_info_of_entity(e)
		if decl != nil && len(decl.attributes) > 0 {
			check_decl_attributes(ctx, decl.attributes[:], &local_ac, .Type, e.token.pos, decl.decl_node)
			effective_ac = &local_ac
		}
	}

	// C++ Reference: check_decl.cpp check_type_decl
	// `e->deprecated_message = ac.deprecated_message;`
	// C++ guards this with `if (decl != nullptr)`, which is the condition under
	// which effective_ac is non-nil here.
	if effective_ac != nil {
		e.deprecated_message = effective_ac.deprecated_message
	}

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

	// C++ Reference: check_decl.cpp check_type_decl
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

	// C++ Reference: check_decl.cpp check_type_decl
	// CITATION CORRECTED (#610): cited 517-610; 517-518 are the CLOSING BRACES of the constant-decl
	// block above, and 520-524 is the attribute processing already cited at the top of this proc.
	// The objc block proper is `if (e->kind == Entity_TypeName && ac.objc_class != "") { ... }` = 526-607.
	// Handle Objective-C class attributes for type declarations
	if effective_ac != nil && len(effective_ac.objc_class) > 0 {
		if type_name, ok := &e.variant.(Entity_Type_Name); ok {
			// C++ Reference: check_decl.cpp check_type_decl
			// Verify the type is zero-size (ObjC class bindings must be opaque)
			// e.token, NOT init_expr. C++ anchors this on the ENTITY (check_decl.cpp check_type_decl,
			// `error(e->token, ...)`), i.e. the declared name, so `Foo :: struct {}` reports at
			// column 1. Anchoring on the initialising expression put us at column 8 -- the `struct`
			// keyword -- for every @(objc_class) type. Same class as #179 and #197: the message was
			// right and the anchor was not, which a count-only comparison cannot see.
			if type_size_of(base) != 0 {
				error_token(e.token, "@(objc_class) marked type must be of zero size")
			}

			// C++ Reference: check_decl.cpp check_type_decl
			type_name.objc_class_name = effective_ac.objc_class

			// C++ Reference: check_decl.cpp check_type_decl
			// Handle objc_is_implement attribute
			if effective_ac.objc_is_implementation {
				type_name.objc_is_implementation = true
				type_name.objc_ivar = effective_ac.objc_ivar
				type_name.objc_context_provider = effective_ac.objc_context_provider

				// C++ Reference: check_decl.cpp check_type_decl --
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

				// C++ Reference: check_decl.cpp check_type_decl and 557-592. Both the objc_superclass STORE
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
				// check_type_decl) as #691 and #693 did. Nothing iterates this set -- it is pure
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
					// C++ Reference: check_decl.cpp check_type_decl
					if super.kind != .Named {
						error(e.token, "@(objc_superclass) Referenced type must be a named struct")
						break
					}
					// C++ Reference: check_decl.cpp check_type_decl. C++'s type_set_update returns true
					// when the type was ALREADY present -- that is the cycle.
					if type_hash_canonical_type(super) in super_set {
						error(e.token, "@(objc_superclass) Superclass hierarchy cycle encountered")
						break
					}
					super_set[type_hash_canonical_type(super)] = super

					// C++ Reference: check_decl.cpp check_type_decl calls check_single_global_entity here to
					// force the superclass to resolve. OMITTED: C++ runs this block from
					// generate_minimum_dependency_set, a LATER pass, while the port runs it at
					// DECLARATION time, so re-entering global entity checking here is not safe.
					named_type := base_named_type(super)
					if named_type == nil || named_type.kind != .Named {
						break
					}
					nt := named_type.variant.(Type_Named)

					// C++ Reference: check_decl.cpp check_type_decl
					if !is_type_objc_object(ctx.checker, named_type) {
						error(e.token, "@(objc_superclass) Superclass '%s' must be an Objective-C class", nt.name)
						break
					}
					// C++ Reference: check_decl.cpp check_type_decl
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
		// C++ Reference: check_decl.cpp check_type_decl
		// objc_is_implement requires objc_class
		error(init_expr, "@(objc_implement) may only be applied when the @(objc_class) attribute is also applied")
	}
}

// ======================================================================================
// DECLARATION DEPENDENCY MANAGEMENT HELPERS
// ======================================================================================

// NOTE: add_dependency and add_declaration_dependency are defined in scope.odin

// make_decl_info creates and initializes a new Decl_Info
// C++ Reference: checker.cpp make_decl_info (make_decl_info)
//                checker.cpp init_decl_info
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

	// C++ Reference: check_decl.cpp check_objc_methods
	t := ac.objc_type
	assert(t.kind == .Named) // Already checked at attribute resolution stage

	// C++ Reference: check_decl.cpp check_objc_methods
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

	// C++ Reference: check_decl.cpp check_objc_methods
	tn := t.variant.(Type_Named).type_name
	assert(tn.kind == .Type_Name)

	// C++ Reference: check_decl.cpp check_objc_methods
	if tn.scope != e.scope {
		error(e.token, "@(objc_name) attribute may only be applied to procedures and types within the same scope")
	} else {
		// C++ Reference: check_decl.cpp check_objc_methods
		// Enable implementation by default if class is implementer and not explicitly disabled
		tn_type_name := &tn.variant.(Entity_Type_Name)
		implement := tn_type_name.objc_is_implementation

		if ac.objc_is_implementation && !tn_type_name.objc_is_implementation {
			error(e.token, "Cannot apply @(objc_is_implement) to a procedure whose type does not also have @(objc_is_implement) set")
		}

		if ac.objc_is_disabled_implement {
			implement = false
		}

		// C++ Reference: check_decl.cpp check_objc_methods
		objc_selector := ac.objc_selector if len(ac.objc_selector) > 0 else ac.objc_name

		// C++ Reference: check_decl.cpp check_objc_methods
		if e.kind == .Procedure {
			proc_ent := &e.variant.(Entity_Procedure)
			has_body := e.decl_info.proc_lit != nil && e.decl_info.proc_lit.derived.(^ast.Proc_Lit).body != nil

			proc_ent.is_objc_impl_or_import = implement || !has_body
			proc_ent.is_objc_class_method = ac.objc_is_class_method
			proc_ent.objc_selector_name = objc_selector
			proc_ent.objc_class = tn

			// C++ Reference: check_decl.cpp check_objc_methods
			proc_type := &e.type.variant.(Type_Proc)
			first_param := t_untyped_nil
			if proc_type.param_count > 0 {
				first_param = proc_type.params.variant.(Type_Tuple).variables[0].type
			}

			// C++ Reference: check_decl.cpp check_objc_methods
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
				// C++ Reference: check_decl.cpp:1154 --
				//     if (ac.objc_selector == "The @(objc_selector) attribute is required for imported Objective-C methods.") {
				//         return;
				//     } else if (proc.calling_convention != ProcCC_CDecl) { ... }
				// The reference COMPARES the selector against that literal STRING. It is not a
				// diagnostic there and the condition is effectively never true (nobody writes that
				// sentence as a selector), so the branch is a no-op and control falls through to the
				// calling-convention check. `grep -rn "attribute is required for imported" src/` finds
				// that ONE line and no error() call.
				// #1179: the port had turned it into a MEANINGFUL emptiness test AND an error, so it
				// rejected imported ObjC methods the reference accepts. B3-b finding T2.10, now
				// WITNESSED: on `@(objc_type=Foo, objc_name="bar") Foo_bar :: proc "c" (self: ^Foo) ---`
				// plus a misspelled selector, the oracle emits ONE error (the typo) and the port emitted
				// TWO. Reproduced verbatim rather than "repaired" -- and note objc_selector already
				// defaults to objc_name upstream (check_decl.cpp:1098), so emptiness is unlikely anyway.
				if ac.objc_selector == "The @(objc_selector) attribute is required for imported Objective-C methods." {
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

		// C++ Reference: check_decl.cpp check_objc_methods
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

	// C++ Reference: check_decl.cpp check_foreign_procedure
	sync.mutex_lock(&ctx.info.foreign_mutex)
	defer sync.mutex_unlock(&ctx.info.foreign_mutex)

	// C++ Reference: check_decl.cpp check_foreign_procedure
	fp := &ctx.info.foreigns
	found, has_found := fp[name]

	// C++ Reference: check_decl.cpp check_foreign_procedure
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
