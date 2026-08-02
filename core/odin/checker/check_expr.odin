package checker

/*
Expression checking.

This module implements expression type checking and validation,
following the logic in check_expr.cpp from the Odin compiler.
*/

import "core:fmt"
import "core:math/big"
import "core:odin/ast"
import "core:reflect"
import "core:odin/tokenizer"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:unicode/utf8"

// is_blank_ident and add_entity_use are defined in entity_helpers.odin

// unparen_expr strips parentheses from an expression, returning the innermost expression
// For example: (((x))) -> x
// Ported from parser.cpp:1879-1889
unparen_expr :: proc(node: ^ast.Node) -> ^ast.Node {
	current := node
	for current != nil {
		if paren, ok := current.derived.(^ast.Paren_Expr); ok {
			current = paren.expr
		} else {
			break
		}
	}
	return current
}

// ======================================================================================
// #LOAD DIRECTIVE HELPERS
// C++ Reference: check_expr.cpp:140-152, check_builtin.cpp:1820-1881
// ======================================================================================

// Load_Directive_Result represents the result of checking a #load directive
// C++ Reference: check_builtin.cpp:1820 (enum LoadDirectiveResult)
Load_Directive_Result :: enum {
	Success,    // File was loaded successfully
	Not_Found,  // File was not found
	Error,      // Error in directive arguments
}

// is_load_directive_call is defined in check_expr_helpers.odin

// check_load_directive checks a #load directive call
// C++ Reference: check_builtin.cpp:1820-1881
check_load_directive :: proc(ctx: ^Checker_Context, operand: ^Operand, call: ^ast.Node, type_hint: ^Type, err_on_not_found: bool) -> Load_Directive_Result {
	call_node := unparen_expr(call)
	ce, ok := call_node.derived.(^ast.Call_Expr)
	if !ok {
		return .Error
	}
	bd, bd_ok := ce.expr.derived.(^ast.Basic_Directive)
	if !bd_ok {
		return .Error
	}
	name := bd.name
	assert(name == "load")

	// Check argument count
	if len(ce.args) != 1 && len(ce.args) != 2 {
		if len(ce.args) == 0 {
			error_node(call_node, "'#%s' expects 1 or 2 arguments, got 0", name)
		} else {
			error_node(ce.args[0], "'#%s' expects 1 or 2 arguments, got %d", name, len(ce.args))
		}
		return .Error
	}

	// Check first argument is a constant string
	arg := ce.args[0]
	o: Operand
	check_expr(ctx, &o, arg)
	if o.mode != .Constant {
		error_node(arg, "'#%s' expected a constant string argument", name)
		return .Error
	}
	if !is_type_string(o.type) {
		error_node(arg, "'#%s' expected a constant string, got %s", name, type_to_string(o.type))
		return .Error
	}

	// Set operand type based on hint or default to []u8
	operand.type = t_u8_slice
	if len(ce.args) == 1 {
		if type_hint != nil && is_valid_type_for_load(type_hint) {
			operand.type = type_hint
		}
	} else if len(ce.args) == 2 {
		arg_type := ce.args[1]
		loaded_type := check_type(ctx, arg_type)
		if loaded_type != nil {
			if is_valid_type_for_load(loaded_type) {
				operand.type = loaded_type
			} else {
				error_node(arg_type, "'#%s' invalid type, expected a string, or slice of simple types, got %s", name, type_to_string(loaded_type))
			}
		}
	}
	operand.mode = .Constant

	// Get path string from constant value
	path_str: string
	if str, is_str := o.value.(string); is_str {
		path_str = str
	} else {
		if err_on_not_found {
			error_node(arg, "'#%s' could not extract path string from constant", name)
		}
		return .Not_Found
	}

	// Resolve path relative to source file
	// C++ Reference: check_builtin.cpp:1845-1860
	full_path := path_str
	if ctx.file != nil && ctx.file.fullpath != "" && !filepath.is_abs(path_str) {
		// Get directory of source file and join with relative path
		src_dir := filepath.dir(ctx.file.fullpath)
		joined, join_err := filepath.join({src_dir, path_str})
		if join_err != nil {
			if err_on_not_found {
				error_node(arg, "'#%s' could not resolve path for '%s'", name, path_str)
			}
			return .Not_Found
		}
		full_path = joined
	}

	// Try to read the file
	// C++ Reference: check_builtin.cpp:1862-1875
	// NOTE: the contents become a constant value on the operand, so they must be allocated
	// persistently rather than in the temporary allocator.
	data, read_err := os.read_entire_file(full_path, context.allocator)
	if read_err != nil {
		if err_on_not_found {
			error_node(arg, "'#%s' cannot load file '%s'", name, path_str)
		}
		return .Not_Found
	}

	// Convert to appropriate type and set as constant value
	// C++ Reference: check_builtin.cpp:1877-1880
	if is_type_string(operand.type) {
		operand.value = string(data)
	} else {
		// For []u8 or other slice types, store as raw bytes
		// Note: The exact value representation depends on how constants are stored
		operand.value = string(data)  // Store as string, will be reinterpreted at codegen
	}

	return .Success
}

// is_valid_type_for_load is defined in check_builtin.odin

// ======================================================================================
// INFERRED ARRAY HELPERS
// ======================================================================================

// is_expr_inferred_fixed_array checks if an expression is a [?]Type array syntax
// Used for inferred array count in compound literals
// C++ Reference: checker.cpp:9783-9797
is_expr_inferred_fixed_array :: proc(type_expr: ^ast.Expr) -> bool {
	type_expr := unparen_expr(cast(^ast.Node)type_expr)
	if type_expr == nil {
		return false
	}

	// Check for [?]Type syntax
	if array_type, ok := type_expr.derived.(^ast.Array_Type); ok {
		if count := array_type.len; count != nil {
			// Check for unary ? operator
			if unary, is_unary := count.derived.(^ast.Unary_Expr); is_unary {
				if unary.op.kind == .Question {
					return true
				}
			}
		}
	}
	return false
}

// check_array_range validates a range expression for indexed array initialization and extracts its bounds
// Returns true if the range is valid, false otherwise
// Fills x and y operands with the lower and upper bounds
// C++ Reference: check_expr.cpp:8657-8756
check_array_range :: proc(ctx: ^Checker_Context, node: ^ast.Expr, is_for_loop: bool, x: ^Operand, y: ^Operand, type_hint: ^Type = nil) -> bool {
	if !is_ast_range(node) {
		return false
	}

	binary := node.derived.(^ast.Binary_Expr)

	// Check left and right operands
	check_expr_with_type_hint(ctx, x, binary.left, type_hint)
	if x.mode == .Invalid {
		return false
	}
	check_expr_with_type_hint(ctx, y, binary.right, type_hint)
	if y.mode == .Invalid {
		return false
	}

	// Convert to common type
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

	// Ensure both sides have the same type
	if !are_types_identical(x.type, y.type) {
		if x.type != t_invalid && y.type != t_invalid {
			xt := type_to_string(x.type)
			yt := type_to_string(y.type)
			expr_str := expr_to_string(x.expr)
			defer delete(expr_str)
			error(binary.op, "Mismatched types in interval expression '%s' : '%s' vs '%s'", expr_str, xt, yt)
		}
		return false
	}

	type := x.type

	// Validate type is appropriate for ranges
	if is_for_loop {
		if !is_type_integer(type) && !is_type_float(type) && !is_type_enum(type) {
			error(binary.op, "Only numerical types are allowed within interval expressions")
			return false
		}
	} else {
		if !is_type_integer(type) && !is_type_float(type) && !is_type_pointer(type) && !is_type_enum(type) {
			error(binary.op, "Only numerical and pointer types are allowed within interval expressions")
			return false
		}
	}

	// Validate range bounds if both are constant
	if x.mode == .Constant && y.mode == .Constant {
		a := x.value
		b := y.value

		assert(are_types_identical(x.type, y.type), "Range operands must have identical types")

		// Determine comparison operator based on range type
		// C++ Reference: check_expr.cpp:8726-8732
		op: tokenizer.Token_Kind
		#partial switch binary.op.kind {
		case .Ellipsis:   op = .Lt_Eq  // .. (inclusive)
		case .Range_Full: op = .Lt_Eq  // ..= (inclusive)
		case .Range_Half: op = .Lt     // ..< (exclusive)
		case:
			error(binary.op, "Invalid range operator")
			return false
		}

		ok := compare_exact_values(op, a, b)
		if !ok {
			error(binary.op, "Invalid interval range")
			return false
		}
	}

	return true
}

// get_entity_type extracts the type from an entity
// Different entity kinds store their type in different fields
get_entity_type :: proc(entity: ^Entity) -> ^Type {
	if entity == nil {
		return nil
	}

	#partial switch entity.kind {
	case .Constant:
		constant := entity.variant.(Entity_Constant)
		return constant.type

	case .Variable:
		variable := entity.variant.(Entity_Variable)
		return variable.type

	case .Type_Name:
		type_name := entity.variant.(Entity_Type_Name)
		return type_name.type

	case .Procedure:
		// Note: For procedures, entity.type is the canonical source of truth
		// Entity_Procedure.type may not be set consistently
		return entity.type

	case .Builtin:
		// Builtins don't have a conventional type
		return nil

	case .Proc_Group:
		// Proc groups don't have a single type
		return nil

	case .Label:
		// Labels don't have a type
		return nil

	case .Package_Name, .Import_Name, .Library_Name:
		// These don't have types
		return nil

	case .Invalid:
		return t_invalid
	}

	return nil
}

// check_ident resolves an identifier and sets the operand
// Ported from check_ident in check_expr.cpp:1743-1923
check_ident :: proc(ctx: ^Checker_Context, o: ^Operand, node: ^ast.Node, named_type: ^Type, type_hint: ^Type, allow_import_name: bool) -> ^Entity {
	// Initialize operand to invalid state
	o.mode = .Invalid
	o.expr = node

	// Extract identifier information
	ident, ok := node.derived.(^ast.Ident)
	if !ok {
		// This should not happen - caller should verify node is an identifier
		assert(false, "check_ident called with non-identifier node")
		o.type = t_invalid
		return nil
	}

	name := ident.name

	// Perform scope lookup
	found_scope, entity := scope_lookup_parent(ctx.scope, name)
	_ = found_scope // May be used for additional diagnostics

	if entity == nil {
		// Identifier not found
		if is_blank_ident(name) {
			error(node, "'_' cannot be used as a value")
		} else {
			error(node, "Undeclared name: %s", name)
		}
		o.type = t_invalid
		o.mode = .Invalid
		if named_type != nil {
			set_base_type(named_type, t_invalid)
		}
		return nil
	}

	// Check for nested procedure variable capture
	// In Odin, nested procedures do not capture parent variables unless marked static
	if entity.kind == .Variable || entity.kind == .Label {
		// Nested procedure capture checking
		if entity.parent_proc_decl != nil && ctx.curr_proc_decl != nil && entity.parent_proc_decl != ctx.curr_proc_decl {
			if entity.kind == .Variable {
				variable := &entity.variant.(Entity_Variable)
				if !variable.is_static {
					error(node, "Nested procedures do not capture its parent's variables: %s", name)
					return nil
				}
			} else if entity.kind == .Label {
				error(node, "Nested procedures do not capture its parent's labels: %s", name)
				return nil
			}
		}
	}

	// Handle procedure groups with type hints
	if entity.kind == .Proc_Group {
		// Check entity declaration to ensure it's resolved
		check_entity_decl(ctx, entity, nil, nil)

		// If we have a type hint that's a procedure type, try to resolve the overload
		if type_hint != nil && is_type_proc(type_hint) {
			proc_group := entity.variant.(Entity_Proc_Group)

			// Try to find a matching procedure in the group
			for proc_entity in proc_group.procs {
				if proc_entity.kind != .Procedure {
					continue
				}

				proc_variant := proc_entity.variant.(Entity_Procedure)
				proc_type := base_type(proc_variant.type)
				if proc_type == t_invalid {
					continue
				}

				// Check if this procedure is assignable to the type hint
				test_operand: Operand
				test_operand.mode = .Value
				test_operand.type = proc_type
				if check_is_assignable_to(ctx, &test_operand, type_hint) {
					entity = proc_entity
					add_entity_use(ctx, node, entity)
					// Skip the proc group return below
					break
				}
			}

			// If we didn't resolve to a single procedure, return proc group mode
			if entity.kind == .Proc_Group {
				o.mode = .Proc_Group
				o.type = t_invalid
				o.proc_group = entity
				return nil
			}
		} else {
			// No type hint - return as proc group
			o.mode = .Proc_Group
			o.type = t_invalid
			o.proc_group = entity
			return nil
		}
	}

	// Track entity usage
	add_entity_use(ctx, node, entity)

	// Resolve BEFORE dispatching on entity.kind.
	//
	// C++ Reference: check_expr.cpp:1956-1960 — add_entity_use, then
	// `if (e->state == EntityState_Unresolved) check_entity_decl(...)`, and only
	// THEN `switch (e->kind)`.
	//
	// The kind can CHANGE during resolution: `log2 :: intrinsics.constant_log2`
	// starts as a Constant and check_const_decl rewrites it in place into an
	// Entity_Builtin (check_decl.odin, mirroring check_decl.cpp:690-698). Testing
	// `entity.kind == .Builtin` before resolving meant an alias that had not been
	// resolved yet missed the builtin arm entirely, so `A :: log2(V)` under a
	// file-scope `#assert` - which forces A to resolve early - never reached the
	// builtin call dispatch and came back Invalid.
	if entity.state == .Unresolved {
		check_entity_decl(ctx, entity, nil, named_type)
	}

	// Handle builtin entities specially - they don't have types
	// Must be handled before the type check below
	if entity.kind == .Builtin {
		builtin := entity.variant.(Entity_Builtin)
		o.builtin_id = builtin.id
		o.mode = .Builtin
		// C++ sets `o->type = e->type` immediately before its entity-kind switch
		// (check_expr.cpp, just above `case Entity_Builtin:`), and the Builtin arm does not
		// overwrite it -- so a builtin operand carries t_invalid, NOT nil. VERIFIED
		// BEHAVIOURALLY rather than by reading the entity constructor: the oracle diagnoses
		// `g := len` cleanly, which is only reachable if check_init_variable's prologue guard
		// (`operand->type == t_invalid`, check_decl.cpp:5-7) fires.
		//
		// The port used nil with the comment "Builtins don't have types". The guard then never
		// matched, the prologue was skipped, and execution reached `assert(is_type_typed(t))`
		// in check_init_variable -- CRASHING the checker on a three-line program that C++
		// diagnoses cleanly (LEDGER task 246).
		o.type = t_invalid
		// Store type_and_value so is_diverging_expr can detect diverging builtins
		add_type_and_value(ctx, node, .Builtin, nil, nil)
		return entity
	}

	// Handle label entities specially - they don't have types
	// Must be handled before the type check below
	// Labels are looked up from break/continue statements
	if entity.kind == .Label {
		o.mode = .Invalid // Labels aren't values
		o.type = nil
		return entity
	}


	// C++ Reference: check_expr.cpp:1957-1968
	// Report an illegal declaration cycle before the `type == nil` bail-out below: an
	// entity caught mid-cycle has no type yet, so leaving this until the .Type_Name case
	// further down means the cycle is never reported and resolution keeps recursing.
	#partial switch entity.kind {
	case .Constant, .Variable, .Type_Name:
		if check_cycle(ctx, entity, true) {
			o.type = t_invalid
			return entity
		}
	}

	// C++ Reference: check_expr.cpp:2047-2056. Import and library names carry no type, and C++
	// handles them in its kind switch by reporting the not-in-selector-form error (when not allowed)
	// and RETURNING THE ENTITY.
	//
	// This port extracted the type first and bailed on nil, and get_entity_type returns nil for
	// exactly these kinds - so the .Import_Name and .Library_Name arms further down were
	// UNREACHABLE and check_ident always returned nil for them. That broke `_ :: intrinsics`, the
	// standard idiom for marking an import used: check_const_decl never saw the entity, so its
	// override-aliased-entity switch could not fire and it reported
	// "Invalid declaration value 'intrinsics'" instead.
	#partial switch entity.kind {
	case .Import_Name:
		if !allow_import_name {
			error(node, "Use of import name '%s' not in selector form 'x.y'", name)
		}
		return entity
	case .Library_Name:
		if !allow_import_name {
			error(node, "Use of library '%s' not in foreign block", name)
		}
		return entity
	}

	// Extract type from entity - different variants store it differently
	entity_type := get_entity_type(entity)
	if entity_type == nil {
		// Entity has no type - this can happen during resolution
		return nil
	}

	// Set operand type
	o.type = entity_type

	// Set addressing mode and value based on entity kind
	#partial switch entity.kind {
	case .Constant:
		if entity_type == t_invalid {
			o.type = t_invalid
			return entity
		}

		constant := entity.variant.(Entity_Constant)
		o.value = constant.value

		// C++ Reference: check_expr.cpp:1846-1853
		// Check for procedure constant - unwrap to get actual procedure entity
		if proc_value, is_proc := o.value.(Exact_Value_Procedure); is_proc {
			proc_entity := strip_entity_wrapping(ctx, proc_value.expr)
			if proc_entity != nil {
				o.mode = .Value
				o.type = proc_entity.type
				return proc_entity
			}
		}

		// Set mode to Constant - this includes the nil constant which has nil as its value
		// The nil constant has type t_untyped_nil and a nil Exact_Value, which is valid
		o.mode = .Constant

	case .Variable:
		if entity_type == t_invalid {
			o.type = t_invalid
			return entity
		}

		o.mode = .Variable

		// Check if variable should be treated as a value
		// EntityFlag_Value indicates value semantics (e.g., procedure parameters by value)
		if .Value in entity.flags {
			o.mode = .Value
		}

	case .Procedure:
		o.mode = .Value
		// C++ Reference: check_expr.cpp:1871
		// Set exact value for procedure reference
		o.value = exact_value_procedure(cast(^ast.Expr)node)

	case .Builtin:
		// Note: Builtins are now handled earlier in check_ident
		// This case should not be reached, but is kept for completeness
		builtin := entity.variant.(Entity_Builtin)
		o.builtin_id = builtin.id
		o.mode = .Builtin

	case .Type_Name:
		o.mode = .Type

		// C++ Reference: check_expr.cpp:1881-1883
		// Check for type cycles during type resolution
		if check_cycle(ctx, entity, true) {
			o.type = t_invalid
		}

		// NO ALIAS UNWRAPPING HERE. C++ Reference: check_expr.cpp:1963-1968 — the
		// Entity_TypeName arm only runs the cycle check; o->type stays e->type.
		//
		// This previously did `if type_name.is_type_alias { o.type = base_type(o.type) }`,
		// which is wrong at the root: for `N :: E`, check_type_decl already sets N's entity
		// type to E itself (the non-distinct branch, mirroring check_decl.cpp:499-504). An
		// alias IS the aliased type; stripping to base_type threw away E's identity and
		// yielded the underlying unnamed enum, so `x: N = .A`, `y: E = x` and
		// `bit_set[N]{.A}` all failed while the identical `E` forms worked. base/runtime
		// reaches this through `Odin_Arch_Type :: type_of(ODIN_ARCH)`.

	case .Import_Name:
		if !allow_import_name {
			error(node, "Use of import name '%s' not in selector form 'x.y'", name)
		}
		return entity

	case .Library_Name:
		if !allow_import_name {
			error(node, "Use of library '%s' not in foreign block", name)
		}
		return entity

	case .Label:
		o.mode = .No_Value

	case .Package_Name:
		// Package names should only be used in selectors
		if !allow_import_name {
			error(node, "Use of package name '%s' not in selector form 'x.y'", name)
		}
		return entity

	case .Invalid:
		o.type = t_invalid
		o.mode = .Invalid

	case .Proc_Group:
		// Should have been handled above
		o.mode = .Proc_Group
		o.proc_group = entity
		return nil
	}

	return entity
}


// parse_exact_value_from_token extracts the exact value from a literal token
// This is our implementation of exact_value_from_token / exact_value_from_basic_literal
// Reference: /mnt/c/odin/src/parser.cpp:768-797 and exact_value.cpp
parse_exact_value_from_token :: proc(tok: tokenizer.Token) -> Exact_Value {
	text := tok.text

	#partial switch tok.kind {
	case .Integer:
		// C++ Reference: exact_value_integer_from_string -- C++ parses EVERY integer literal
		// straight into arbitrary precision, and so does this now.
		//
		// It used to go through strconv. First parse_i64_maybe_prefixed, which reports ok=true
		// for values above max(i64) and wraps them negative; that was replaced by
		// parse_u64_maybe_prefixed, which has THE SAME FLAW one bit further out:
		//
		//     18446744073709551616  -> ok=true, value=0
		//     100000000000000000000 -> ok=true, value=7766279631452241920
		//
		// So a literal wider than u64 was not merely accepted, it was silently replaced by a
		// different number, and the range check downstream then honestly approved the
		// substitute. `x: int = 100000000000000000000` compiled as 7766279631452241920.
		// Fixing the i64 case by switching to the u64 helper repeated the bug at a larger
		// bound; parsing into a BigInt removes the bound entirely. LEDGER #167.
		{
			body := text
			radix := i8(10)
			if len(body) > 2 && body[0] == '0' {
				switch body[1] {
				case 'b', 'B':
					radix = 2
					body = body[2:]
				case 'o', 'O':
					radix = 8
					body = body[2:]
				case 'd', 'D':
					radix = 10
					body = body[2:]
				case 'x', 'X', 'h', 'H':
					radix = 16
					body = body[2:]
				}
			}
			// Odin permits digit separators in literals; big.int_atoi does not.
			cleaned := body
			if strings.contains(body, "_") {
				cleaned, _ = strings.replace_all(body, "_", "", context.temp_allocator)
			}
			v: big.Int
			if big.int_atoi(&v, cleaned, radix) == nil {
				return v
			}
		}
		return nil

	case .Float:
		// C++ Reference: exact_value.cpp:363-365.
		//
		//     if (!string_contains_char(string, '.') && !string_contains_char(string, '-')) {
		//         // NOTE(bill): treat as integer
		//         return exact_value_integer_from_string(string);
		//     }
		//
		// Both tokenizers classify `1e20` as a FLOAT token -- C++'s scan_number sets
		// Token_Float the moment it sees an 'e'. The difference is here: C++ then looks at
		// the TEXT, and a float token carrying neither '.' nor '-' becomes an INTEGER exact
		// value. That is why the oracle reports `1e20` as an 'untyped integer' and calls a
		// malformed `1e400` an "Invalid INTEGER literal". The port ran every float token
		// through parse_f64, so `x: int = 1e20` was reported as a truncated float instead.
		// C++ Reference: exact_value.cpp:335-361 -- the `0h` hexadecimal FLOAT bit-pattern
		// form is handled BEFORE the integer treatment below and stays a float. It contains
		// neither '.' nor '-', so without this guard `0h7ff00000_00000000` fell into the
		// integer branch, failed to parse as base-10, and produced "Invalid float literal"
		// for every such constant in core/strconv.
		is_hex_float := len(text) > 2 && text[0] == '0' && (text[1] == 'h' || text[1] == 'H')
		if !is_hex_float && !strings.contains(text, ".") && !strings.contains(text, "-") {
			mantissa := text
			exponent := 0
			if idx := strings.index_any(text, "eE"); idx >= 0 {
				mantissa = text[:idx]
				exp_text := text[idx + 1:]
				if len(exp_text) > 0 && exp_text[0] == '+' {
					exp_text = exp_text[1:]
				}
				n, ok := strconv.parse_int(exp_text)
				if !ok || n < 0 {
					return nil
				}
				exponent = n
			}
			cleaned := mantissa
			if strings.contains(mantissa, "_") {
				cleaned, _ = strings.replace_all(mantissa, "_", "", context.temp_allocator)
			}
			v: big.Int
			if big.int_atoi(&v, cleaned, 10) != nil {
				return nil
			}
			if exponent > 0 {
				ten: big.Int
				scale: big.Int
				if big.int_atoi(&ten, "10", 10) != nil {
					return nil
				}
				if big.int_pow(&scale, &ten, exponent) != nil {
					return nil
				}
				if big.int_mul(&v, &v, &scale) != nil {
					return nil
				}
			}
			return v
		}

		value, ok := strconv.parse_f64(text)
		if ok {
			return value
		}
		// Invalid float
		return nil

	case .String:
		// Unquote string literal
		// Odin strings can be raw (backtick) or interpreted (double quote)
		if len(text) >= 2 {
			if text[0] == '`' && text[len(text) - 1] == '`' {
				// Raw string - no escape processing
				return text[1:len(text) - 1]
			} else if text[0] == '"' && text[len(text) - 1] == '"' {
				// Interpreted string - process escapes
				return unquote_string(text)
			}
		}
		// Invalid string
		return nil

	case .Rune:
		// Parse rune literal
		// C++ Reference: string.cpp:1111-1118 (unquote_string with quote == '\'')
		if len(text) >= 3 && text[0] == '\'' && text[len(text) - 1] == '\'' {
			inner := text[1:len(text) - 1]

			// Use unquote_char to parse the rune (handles escapes and multi-byte UTF-8)
			r, _, tail, ok := unquote_char(inner, '\'')
			if !ok {
				return nil  // Invalid escape or character
			}

			// For rune literals, there must be exactly one character
			if len(tail) != 0 {
				return nil  // More than one character in rune literal
			}

			return exact_value_i64(i64(r))
		}
		// Invalid rune
		return nil

	case .Imag:
		// Parse imaginary/quaternion literal (e.g., 2i, 3.14j, 4k)
		// The text ends with 'i', 'j', or 'k' - strip it and parse the numeric part
		if len(text) >= 2 {
			last := text[len(text) - 1]
			if last == 'i' || last == 'j' || last == 'k' {
				num_part := text[:len(text) - 1]
				// Try parsing as float first
				value, ok := strconv.parse_f64(num_part)
				if ok {
					return value
				}
				// Try parsing as integer
				ivalue, iok := strconv.parse_i64_maybe_prefixed(num_part)
				if iok {
					return f64(ivalue)
				}
			}
		}
		// Invalid imaginary literal
		return nil

	case .Ident:
		// Check for boolean keywords
		if text == "true" {
			return true
		} else if text == "false" {
			return false
		} else if text == "nil" {
			// nil has no value - it's represented by the type
			return nil
		}
	}

	// Unsupported or invalid
	return nil
}

// hex_digit_to_int converts a hex character to its integer value
// Returns -1 if not a valid hex digit
// C++ Reference: string.cpp uses gb_hex_digit_to_int
hex_digit_to_int :: proc(c: u8) -> i32 {
	switch c {
	case '0' ..= '9':
		return i32(c - '0')
	case 'a' ..= 'f':
		return i32(c - 'a' + 10)
	case 'A' ..= 'F':
		return i32(c - 'A' + 10)
	case:
		return -1
	}
}

// digit_to_int converts a digit character to its integer value
// Returns -1 if not a valid digit
// C++ Reference: string.cpp uses gb_digit_to_int
digit_to_int :: proc(c: u8) -> i32 {
	if c >= '0' && c <= '9' {
		return i32(c - '0')
	}
	return -1
}

// unquote_char parses a single character or escape sequence from a string
// Returns the rune value, whether it spans multiple bytes, the remaining string, and success status
// C++ Reference: string.cpp:945-1051
unquote_char :: proc(s: string, quote: u8) -> (r: rune, multiple_bytes: bool, tail: string, ok: bool) {
	if len(s) == 0 {
		return 0, false, "", false
	}

	// Check for quote character (invalid in string/rune literals)
	if s[0] == quote && (quote == '\'' || quote == '"') {
		return 0, false, "", false
	}

	// Handle multi-byte UTF-8 sequences
	if s[0] >= 0x80 {
		decoded, size := utf8.decode_rune_in_string(s)
		return decoded, true, s[size:], true
	}

	// Handle non-escape character
	if s[0] != '\\' {
		return rune(s[0]), false, s[1:], true
	}

	// Must have at least 2 characters for an escape sequence
	if len(s) <= 1 {
		return 0, false, "", false
	}

	c := s[1]
	remaining := s[2:]

	switch c {
	case 'a':
		return '\a', false, remaining, true
	case 'b':
		return '\b', false, remaining, true
	case 'e':
		return rune(0x1b), false, remaining, true  // ESC character
	case 'f':
		return '\f', false, remaining, true
	case 'n':
		return '\n', false, remaining, true
	case 'r':
		return '\r', false, remaining, true
	case 't':
		return '\t', false, remaining, true
	case 'v':
		return '\v', false, remaining, true
	case '\\':
		return '\\', false, remaining, true
	case '\'', '"':
		return rune(c), false, remaining, true

	// Octal escape: \0-\7 followed by exactly 2 more octal digits
	case '0', '1', '2', '3', '4', '5', '6', '7':
		result := digit_to_int(c)
		if len(remaining) < 2 {
			return 0, false, "", false
		}
		for i := 0; i < 2; i += 1 {
			d := digit_to_int(remaining[i])
			if d < 0 || d > 7 {
				return 0, false, "", false
			}
			result = (result << 3) | d
		}
		remaining = remaining[2:]
		if result > 0xff {
			return 0, false, "", false
		}
		return rune(result), false, remaining, true

	// Hex escapes: \x (2 digits), \u (4 digits), \U (8 digits)
	case 'x', 'u', 'U':
		count: int
		switch c {
		case 'x':
			count = 2
		case 'u':
			count = 4
		case 'U':
			count = 8
		}

		if len(remaining) < count {
			return 0, false, "", false
		}

		result: rune = 0
		for i := 0; i < count; i += 1 {
			d := hex_digit_to_int(remaining[i])
			if d < 0 {
				return 0, false, "", false
			}
			result = (result << 4) | rune(d)
		}
		remaining = remaining[count:]

		if c == 'x' {
			// \x produces a byte value, not a multi-byte rune
			return result, false, remaining, true
		}

		// \u and \U produce Unicode code points
		if result > utf8.MAX_RUNE {
			return 0, false, "", false
		}
		return result, true, remaining, true

	case:
		// Unknown escape sequence
		return 0, false, "", false
	}
}

// unquote_string processes escape sequences in a quoted string
// Returns the unquoted string, or the original if unquoting fails
// C++ Reference: string.cpp:1072-1154
unquote_string :: proc(s: string) -> string {
	n := len(s)
	if n < 2 {
		return s
	}

	quote := s[0]
	if quote != s[n - 1] {
		return s  // Mismatched quotes
	}

	inner := s[1:n - 1]

	// Raw string (backtick) - no escape processing
	if quote == '`' {
		if strings.contains(inner, "`") {
			return s  // Invalid - raw string cannot contain backtick
		}
		return inner
	}

	// Must be double quote for strings
	if quote != '"' {
		return s
	}

	// Check for newlines (invalid in non-raw strings)
	if strings.contains(inner, "\n") {
		return s
	}

	// Fast path: no escapes needed
	if !strings.contains(inner, "\\") && !strings.contains_rune(inner, rune(quote)) {
		return inner
	}

	// Process escapes using unquote_char
	// Allocate buffer with some extra space for multi-byte runes
	buf := make([dynamic]u8, 0, 3 * len(inner) / 2, context.temp_allocator)

	remaining := inner
	for len(remaining) > 0 {
		r, multiple_bytes, tail, ok := unquote_char(remaining, quote)
		if !ok {
			return s  // Invalid escape sequence - return original
		}
		remaining = tail

		if r < 0x80 || !multiple_bytes {
			append(&buf, u8(r))
		} else {
			// Encode multi-byte rune
			rune_bytes, size := utf8.encode_rune(r)
			for i := 0; i < size; i += 1 {
				append(&buf, rune_bytes[i])
			}
		}
	}

	return string(buf[:])
}

// parse_escape_rune parses an escape sequence in a rune literal
// Uses unquote_char for full escape sequence support
// C++ Reference: string.cpp:945-1051 (via unquote_char)
parse_escape_rune :: proc(s: string) -> rune {
	if len(s) == 0 {
		return 0
	}

	// Use unquote_char with single-quote context
	r, _, _, ok := unquote_char(s, '\'')
	if !ok {
		return 0
	}
	return r
}

// check_literal handles basic literal expressions
// Reference: /mnt/c/odin/src/check_expr.cpp:11422-11444
//
// This function checks basic literal nodes and sets the operand to the
// appropriate untyped constant type with the literal's exact value.
check_literal :: proc(ctx: ^Checker_Context, o: ^Operand, node: ^ast.Node, type_hint: ^Type) {
	// Extract Basic_Lit from node
	lit, ok := node.derived.(^ast.Basic_Lit)
	if !ok {
		// Not a basic literal
		o.mode = .Invalid
		o.type = t_invalid
		o.expr = node
		error(node, "Internal error: check_literal called with non-literal node")
		return
	}

	o.expr = node
	o.mode = .Constant

	// Determine type and value based on token kind
	tok := lit.tok

	#partial switch tok.kind {
	case .Integer:
		// Integer literal -> untyped integer
		o.type = t_untyped_integer
		o.value = parse_exact_value_from_token(tok)

		if o.value == nil {
			error(node, "Invalid integer literal: %s", tok.text)
			o.mode = .Invalid
			o.type = t_invalid
		}

	case .Rune:
		// Rune literal -> untyped rune
		o.type = t_untyped_rune
		o.value = parse_exact_value_from_token(tok)

		if o.value == nil {
			error(node, "Invalid rune literal: %s", tok.text)
			o.mode = .Invalid
			o.type = t_invalid
		}

	case .Float:
		o.value = parse_exact_value_from_token(tok)

		// C++ Reference: check_expr.cpp:12318-12325 -- the literal's type comes from the
		// EXACT VALUE's kind, not the token's:
		//     switch (node->tav.value.kind) {
		//     case ExactValue_Float:   t = t_untyped_float;   break;
		//     case ExactValue_Integer: t = t_untyped_integer; break;
		// A float TOKEN can carry an integer VALUE, because exact_value_float_from_string
		// treats text with no '.' and no '-' as an integer (see parse_exact_value_from_token).
		// `1e20` is such a case: C++ reports it as an 'untyped integer', the port reported it
		// as a truncated float. Switching on the token kind here is what made the two
		// disagree even once the value was parsed correctly.
		o.type = t_untyped_float
		if _, is_integer := o.value.(big.Int); is_integer {
			o.type = t_untyped_integer
		}

		if o.value == nil {
			error(node, "Invalid float literal: %s", tok.text)
			o.mode = .Invalid
			o.type = t_invalid
		}

	case .Imag:
		// Imaginary literal (e.g., 2i, 3.14i) -> untyped complex
		// The imaginary value is stored as the coefficient (e.g., 2i -> 2.0)
		o.type = t_untyped_complex
		o.value = parse_exact_value_from_token(tok)

		if o.value == nil {
			error(node, "Invalid imaginary literal: %s", tok.text)
			o.mode = .Invalid
			o.type = t_invalid
		}

	case .String:
		// String literal -> untyped string
		o.type = t_untyped_string
		o.value = parse_exact_value_from_token(tok)

		if o.value == nil {
			error(node, "Invalid string literal: %s", tok.text)
			o.mode = .Invalid
			o.type = t_invalid
		}

	case .Ident:
		// Check for special identifier literals (true, false, nil)
		text := tok.text

		if text == "true" || text == "false" {
			// Boolean literal
			o.type = t_untyped_bool
			o.value = (text == "true")
		} else if text == "nil" {
			// nil literal
			o.type = t_untyped_nil
			o.value = nil
		} else {
			// Not a literal - this shouldn't happen
			error(node, "Internal error: check_literal called with identifier '%s'", text)
			o.mode = .Invalid
			o.type = t_invalid
		}

	case:
		// Unsupported literal type
		error(node, "Unsupported literal type: %v", tok.kind)
		o.mode = .Invalid
		o.type = t_invalid
	}
}

// check_binary_op validates that an operator is valid for the given operand type
// Reference: /mnt/c/odin/src/check_expr.cpp:1997-2104
check_binary_op :: proc(ctx: ^Checker_Context, o: ^Operand, op: tokenizer.Token) -> bool {
	// C++ Reference: check_expr.cpp:2149, `Type *type = base_type(core_array_type(main_type))`.
	// The core_array_type step is what lets array programming through: `[4]int % n`
	// must be judged on the ELEMENT type, not on the array.
	type := base_type(core_array_type(o.type))
	// C++ Reference: check_expr.cpp:2150, `Type *ct = core_type(type)`. The bitwise
	// arms below test `ct`, not `type`: core_type strips an enum down to its backing
	// integer, which is what makes the standard idiom of defining an enum member from
	// earlier members legal —
	//
	//     E :: enum u32 { R = 1, W = 2, RW = R | W }
	//
	// Here `R` and `W` have the ENUM type, so `R | W` is `E | E`; only after core_type
	// is it `u32 | u32`. Testing base_type rejected it as "not an integer, boolean or
	// bit_set", and the enum member then failed as "Enumeration value must be a
	// constant" — the second diagnostic being purely a consequence of the first.
	//
	// Note it is `core_type(type)`, NOT `core_type(o.type)`: `type` has already had
	// core_array_type applied, so `ct` inherits the array unwrapping. Passing `o.type`
	// here meant the bitwise arms saw the ARRAY rather than its element type, and every
	// `&`, `|`, `~` and `&~` on an integer array was rejected -- core/math/noise's
	// `[3]i64{...} & {PRIME_X, PRIME_Y, PRIME_Z}` -- even though `+` and `-` worked,
	// because those arms test `type`.
	ct := core_type(type)

	#partial switch op.kind {
	case .Sub:
		// C++ Reference: check_expr.cpp:2001-2002
		// bit_set subtraction is set difference
		if is_type_bit_set(type) {
			return true
		} else if !is_type_numeric(type) {
			error(op.pos, "Operator '%s' is only allowed with numeric expressions or bit_sets", op.text)
			return false
		}

	case .Quo:
		// C++ Reference: check_expr.cpp:2011-2017
		// Division not allowed on matrix or SIMD integer types
		if is_type_matrix(o.type) {
			error(op.pos, "Operator '%s' is not allowed with matrix types", op.text)
			return false
		} else if is_type_simd_vector(o.type) && is_type_integer(type) {
			error(op.pos, "Operator '%s' is not allowed with #simd types with integer elements", op.text)
			return false
		}
		if !is_type_numeric(type) {
			error(op.pos, "Operator '%s' is only allowed with numeric expressions", op.text)
			return false
		}

	case .Mul:
		// C++ Reference: check_expr.cpp:2022-2023
		// bit_set multiplication is intersection (&)
		if is_type_bit_set(type) {
			return true
		} else if !is_type_numeric(type) {
			error(op.pos, "Operator '%s' is only allowed with numeric expressions or bit_sets", op.text)
			return false
		}

	case .Add:
		// C++ Reference: check_expr.cpp:2037-2038
		// bit_set addition is union (|)
		if is_type_bit_set(type) {
			return true
		} else if is_type_string(type) {
			if o.mode == .Constant {
				return true
			}
			error(op.pos, "String concatenation is only allowed with constant strings")
			return false
		} else if !is_type_numeric(type) {
			error(op.pos, "Operator '%s' is only allowed with numeric expressions or bit_sets", op.text)
			return false
		}

	case .Mod, .Mod_Mod:
		// C++ Reference: check_expr.cpp:2061-2071
		// Modulo not allowed on matrix or SIMD types
		if is_type_matrix(o.type) {
			error(op.pos, "Operator '%s' is not allowed with matrix types", op.text)
			return false
		}
		if !is_type_integer(type) {
			error(op.pos, "Operator '%s' is only allowed with integers", op.text)
			return false
		}
		if is_type_simd_vector(o.type) {
			error(op.pos, "Operator '%s' is not allowed with #simd types with integer elements", op.text)
			return false
		}

	case .And, .Or, .Xor:
		// C++ Reference: check_expr.cpp:2203-2212
		if !is_type_integer(ct) && !is_type_boolean(ct) && !is_type_bit_set(ct) {
			error(op.pos, "Operator '%s' is only allowed with integers, booleans, or bit sets", op.text)
			return false
		}

	case .And_Not:
		// C++ Reference: check_expr.cpp:2231-2237. `&~` is its own arm: unlike the
		// other bitwise operators it does NOT accept booleans. The port had merged it
		// into the arm above, so `bool &~ bool` was wrongly accepted.
		if !is_type_integer(ct) && !is_type_bit_set(ct) {
			error(op.pos, "Operator '%s' is only allowed with integers and bit sets", op.text)
			return false
		}

	case .Cmp_And, .Cmp_Or:
		if !is_type_boolean(type) {
			error(op.pos, "Operator '%s' is only allowed with boolean expressions", op.text)
			return false
		}

	case:
		error(op.pos, "Unknown operator '%s'", op.text)
		return false
	}

	return true
}

// check_binary_matrix handles binary operations on matrix types
// Reference: /mnt/c/odin/src/check_expr.cpp:3853-3971 (~118 lines)
//
// Matrix operations:
// - Matrix + Matrix: element-wise addition (same dimensions required)
// - Matrix - Matrix: element-wise subtraction (same dimensions required)
// - Matrix * Matrix: matrix multiplication (inner dimensions must match)
// - Matrix * Scalar or Scalar * Matrix: scaling
// - Matrix / Scalar: element-wise division by scalar
check_binary_matrix :: proc(ctx: ^Checker_Context, node: ^ast.Node, x: ^Operand, y: ^Operand, op: tokenizer.Token) -> bool {
	x_type := base_type(x.type)
	y_type := base_type(y.type)

	x_is_matrix := is_type_matrix(x_type)
	y_is_matrix := is_type_matrix(y_type)

	// At least one must be a matrix for this function to be called
	if !x_is_matrix && !y_is_matrix {
		return false
	}

	// Get element types for checking
	x_elem: ^Type = nil
	y_elem: ^Type = nil
	x_rows, x_cols: i64 = 0, 0
	y_rows, y_cols: i64 = 0, 0

	if x_is_matrix {
		mat := x_type.variant.(Type_Matrix)
		x_elem = mat.elem
		x_rows = mat.row_count
		x_cols = mat.column_count
	}
	if y_is_matrix {
		mat := y_type.variant.(Type_Matrix)
		y_elem = mat.elem
		y_rows = mat.row_count
		y_cols = mat.column_count
	}

	#partial switch op.kind {
	case .Add, .Sub:
		// Element-wise operations require both operands to be matrices with same dimensions
		if !x_is_matrix || !y_is_matrix {
			error(op.pos, "Operator '%s' on matrices requires both operands to be matrices", op.text)
			return false
		}

		if x_rows != y_rows || x_cols != y_cols {
			error(op.pos, "Matrix dimensions must match for '%s': matrix[%d, %d] vs matrix[%d, %d]",
				op.text, x_rows, x_cols, y_rows, y_cols)
			return false
		}

		// Element types must be identical
		if !are_types_identical(x_elem, y_elem) {
			error(op.pos, "Matrix element types must match: '%s' vs '%s'",
				type_to_string(x_elem), type_to_string(y_elem))
			return false
		}

		// Result is same matrix type
		x.type = x.type
		x.mode = .Value

	case .Mul:
		if x_is_matrix && y_is_matrix {
			// Matrix multiplication: (M x N) * (N x P) = (M x P)
			if x_cols != y_rows {
				error(op.pos, "Matrix multiplication dimension mismatch: matrix[%d, %d] * matrix[%d, %d] - inner dimensions must match",
					x_rows, x_cols, y_rows, y_cols)
				return false
			}

			// Element types must match
			if !are_types_identical(x_elem, y_elem) {
				error(op.pos, "Matrix element types must match: '%s' vs '%s'",
					type_to_string(x_elem), type_to_string(y_elem))
				return false
			}

			// Result type is matrix[x_rows, y_cols]
			if x_rows == y_cols && x_cols == y_rows {
				// Square result, can use either type
				x.type = x.type
			} else {
				// Need to create new matrix type with result dimensions
				x.type = alloc_type_matrix(x_elem, x_rows, y_cols, nil, nil, false)
			}
			x.mode = .Value
		} else if x_is_matrix && !y_is_matrix {
			// Matrix * Scalar
			if !is_type_numeric(y_type) {
				error(op.pos, "Cannot multiply matrix by non-numeric type '%s'", type_to_string(y.type))
				return false
			}
			// Result is same matrix type
			x.type = x.type
			x.mode = .Value
		} else {
			// Scalar * Matrix
			if !is_type_numeric(x_type) {
				error(op.pos, "Cannot multiply non-numeric type '%s' by matrix", type_to_string(x.type))
				return false
			}
			// Result is the matrix type
			x.type = y.type
			x.mode = .Value
		}

	case .Quo:
		// Matrix / Scalar only (no matrix / matrix)
		if !x_is_matrix {
			error(op.pos, "Division with matrix requires matrix as left operand")
			return false
		}
		if y_is_matrix {
			error(op.pos, "Cannot divide matrix by matrix; use element-wise operations or multiply by inverse")
			return false
		}
		if !is_type_numeric(y_type) {
			error(op.pos, "Cannot divide matrix by non-numeric type '%s'", type_to_string(y.type))
			return false
		}
		// Result is same matrix type
		x.type = x.type
		x.mode = .Value

	case:
		error(op.pos, "Operator '%s' is not valid for matrix types", op.text)
		return false
	}

	x.expr = node
	return true
}

// check_binary_array_expr handles binary operations on array types
// Reference: /mnt/c/odin/src/check_expr.cpp:3786-3852 (~66 lines)
//
// Array operations are element-wise:
// - Array + Array, Array - Array, Array * Array, Array / Array
// - All require same array type (same length and element type)
check_binary_array_expr :: proc(ctx: ^Checker_Context, x: ^Operand, y: ^Operand, op: tokenizer.Token) -> bool {
	// C++ Reference: /mnt/c/odin/src/check_expr.cpp:4134-4155
	//
	// This is "array programming": an ARRAY combined with a NON-array, where the
	// scalar is broadcast across the elements. The port previously required BOTH
	// operands to be arrays - the opposite of this procedure's purpose - and its
	// single call site was guarded the same way, so `v * s` never reached it and
	// fell through to the identical-types check as a mismatch.
	//
	// The both-arrays case needs nothing here: identical array types pass the
	// `are_types_identical` test at the caller and are validated by check_binary_op.
	if is_type_array_like(x.type) || is_type_array_like(y.type) {
		if op.kind == .Cmp_And || op.kind == .Cmp_Or {
			error(op.pos, "Array programming is not allowed with the operator '%s'", op.text)
		}
	}

	if is_type_array(x.type) && !is_type_array(y.type) {
		if check_is_assignable_to(ctx, y, x.type) {
			if check_binary_op(ctx, x, op) {
				return true
			}
		}
	}

	if is_type_simd_vector(x.type) && !is_type_simd_vector(y.type) {
		if check_is_assignable_to(ctx, y, x.type) {
			if check_binary_op(ctx, x, op) {
				return true
			}
		}
	}

	return false
}

// check_shift handles shift operators (<< and >>)
// Reference: /mnt/c/odin/src/check_expr.cpp:3142-3245 (~103 lines)
//
// Shift operations:
// - x << n: Left shift
// - x >> n: Right shift
// - LHS must be integer type
// - RHS must be unsigned integer (shift amount)
// - Result type is same as LHS type (or type_hint for untyped constants)
check_shift :: proc(ctx: ^Checker_Context, node: ^ast.Node, x: ^Operand, y: ^Operand, op: tokenizer.Token, type_hint: ^Type = nil) -> bool {
	#partial switch op.kind {
	case .Shl, .Shr:
		// Valid shift operator
	case:
		return false // Not a shift operator
	}

	x_type := base_type(x.type)
	y_type := base_type(y.type)

	// LHS must be an integer
	if !is_type_integer(x_type) {
		error(x.expr, "Shift operand must be an integer type, got '%s'", type_to_string(x.type))
		return false
	}

	// RHS must be an unsigned integer
	// C++ Reference: check_expr.cpp:3145-3151
	if !is_type_integer(y_type) {
		error(y.expr, "Shift amount must be an integer type, got '%s'", type_to_string(y.type))
		return false
	}
	if !is_type_unsigned(y_type) && !is_type_untyped(y_type) {
		error(y.expr, "Shift amount '%s' must be an unsigned integer", type_to_string(y.type))
		return false
	}

	// For constant shift amounts, validate the value
	// C++ Reference: check_expr.cpp:3171-3180
	MAX_BIG_INT_SHIFT :: 128 // Maximum shift for untyped big integers
	if y.mode == .Constant {
		shift_val := exact_value_to_i64(y.value)
		if shift_val < 0 {
			error(y.expr, "Shift amount cannot be negative: %d", shift_val)
			return false
		}

		// For untyped constants (big integers), limit the shift amount
		if is_type_untyped(x_type) && shift_val > MAX_BIG_INT_SHIFT {
			error(y.expr, "Shift amount %d is too large for untyped constant (maximum %d)", shift_val, MAX_BIG_INT_SHIFT)
			return false
		}

		// Get bit size of LHS type for typed integers
		if !is_type_untyped(x_type) {
			lhs_bits := i64(8 * type_size_of(x_type))
			if shift_val >= lhs_bits {
				// Warning: shifting by more than type width is undefined
				// In Odin, this is allowed but produces 0 for left shift
				// For right shift, it produces 0 for unsigned, -1 for signed
			}
		}
	}

	// Constant folding for shifts.
	//
	// C++ Reference: check_expr.cpp:3480-3500 — a fully constant shift RETURNS
	// here. An untyped constant result becomes `untyped integer`, NEVER the
	// caller's type_hint; the type_hint branch below is reached only when the
	// shifted value is not constant (C++ 3511-3527).
	//
	// The hint belongs to the enclosing expression, not the shift: in
	// `i32((1<<31) - 1 - (1<<31)%u32(n))` (core/math/rand/rand.odin:273) typing
	// `1<<31` as i32 collides with the u32 operand beside it, where leaving it
	// untyped lets it unify with either.
	if x.mode == .Constant && y.mode == .Constant {
		shift_val := exact_value_to_i64(y.value)
		if shift_val >= 0 {
			x.value = exact_binary_operator_value(op.kind, x.value, y.value)
		}

		if is_type_untyped(x_type) {
			convert_to_typed(ctx, x, t_untyped_integer)
			if x.mode == .Invalid {
				return true
			}
		}

		x.expr = node
		check_is_expressible(ctx, x, x.type)
		return true
	}

	x.mode = .Value

	// Result type handling for a non-constant shifted value.
	// C++ Reference: check_expr.cpp:3511-3527
	if is_type_untyped(x_type) && type_hint != nil && is_type_integer(type_hint) {
		x.type = type_hint
	}
	x.expr = node

	return true
}

// check_tautological_comparison warns about comparisons that are always true/false
// C++ Reference: check_stmt.cpp:2720-2745
// Examples:
//   unsigned_val >= 0  -> always true (warning)
//   unsigned_val <= 0  -> equivalent to == 0 (warning)
//   0 <= unsigned_val  -> always true (warning)
//   0 >= unsigned_val  -> equivalent to == 0 (warning)
check_tautological_comparison :: proc(ctx: ^Checker_Context, node: ^ast.Node, x: ^Operand, y: ^Operand, op: tokenizer.Token_Kind) {
	// Only check ordered comparisons
	#partial switch op {
	case .Lt, .Gt, .Lt_Eq, .Gt_Eq:
		// Continue with check
	case:
		return
	}

	// Helper to check if a value is constant zero
	is_constant_zero :: proc(operand: ^Operand) -> bool {
		if operand.mode != .Constant || operand.value == nil {
			return false
		}
		return is_exact_value_zero(operand.value)
	}

	// Helper to check if type is unsigned integer
	is_unsigned_integer :: proc(t: ^Type) -> bool {
		if t == nil {
			return false
		}
		bt := base_type(t)
		if bt == nil || bt.kind != .Basic {
			return false
		}
		basic := bt.variant.(Type_Basic)
		#partial switch basic.kind {
		case .U8, .U16, .U32, .U64, .U128, .Uint, .Uintptr, .U16le, .U32le, .U64le, .U128le, .U16be, .U32be, .U64be, .U128be:
			return true
		case:
			return false
		}
	}

	// C++ has NO tautological-comparison warning in comparison checking. The six warnings
	// that were here ("Comparison of unsigned value >= 0 is always true" and friends) were
	// INVENTED: grep src/*.cpp for "is always true"/"is always false" and the only hits are
	// two in check_stmt.cpp, both inside `for`-statement condition handling, both emitting a
	// single differently-worded message. So the port warned on every comparison anywhere in
	// the program where C++ warns only on a loop condition. See check_for_loop_tautological_comparison.

}

// check_comparison handles comparison operators
// Reference: /mnt/c/odin/src/check_expr.cpp:2915-3022
check_comparison :: proc(ctx: ^Checker_Context, node: ^ast.Node, x: ^Operand, y: ^Operand, op: tokenizer.Token_Kind) {
	// C++ Reference: check_expr.cpp:2908-2917
	// Handle Type vs Type comparison (compile-time type equality)
	if x.mode == .Type && y.mode == .Type {
		comp := are_types_identical(x.type, y.type)
		x.mode = .Constant
		x.type = t_untyped_bool
		if op == .Cmp_Eq {
			x.value = exact_value_bool(comp)
		} else {
			x.value = exact_value_bool(!comp)
		}
		return
	}

	// C++ Reference: check_expr.cpp:2920-2936
	// Handle Type vs Typeid comparison
	if x.mode == .Type && is_type_typeid(y.type) {
		add_type_info_type(ctx, x.type)
		x.mode = .Value
		x.type = t_untyped_bool
		return
	}
	if y.mode == .Type && is_type_typeid(x.type) {
		add_type_info_type(ctx, y.type)
		x.mode = .Value
		x.type = t_untyped_bool
		return
	}

	defined := false
	mutually_assignable := true // C++'s outer gate; see the comment where it is computed

	// Check for nil comparisons
	// C++ Reference: check_expr.cpp:2920-2960
	x_is_nil := are_types_identical(x.type, t_untyped_nil)
	y_is_nil := are_types_identical(y.type, t_untyped_nil)

	if x_is_nil && y_is_nil {
		// nil == nil is always allowed
		defined = true
	} else if x_is_nil || y_is_nil {
		// One side is nil. C++ (check_expr.cpp:3233-3235) asks `type_has_nil` about
		// the other side rather than enumerating nillable kinds, and only for the
		// equality operators. The hand-written list here was missing enum, bit_set,
		// rawptr, typeid, #soa pointers and #soa slice/dynamic structs, so idioms
		// like `err != nil` on an Allocator_Error were rejected outright.
		other_type := x_is_nil ? y.type : x.type
		#partial switch op {
		case .Cmp_Eq, .Not_Eq:
			defined = type_has_nil(other_type)
		case .Lt, .Gt, .Lt_Eq, .Gt_Eq:
			defined = is_type_ordered(x.type) && is_type_ordered(y.type)
		}
	} else {
		#partial switch op {
		case .Cmp_Eq, .Not_Eq:
			// Equality operators work on comparable types
			defined = is_type_comparable(x.type) && is_type_comparable(y.type)

		case .Lt, .Gt, .Lt_Eq, .Gt_Eq:
			// C++ Reference: check_expr.cpp:3196-3201. Ordered comparison of two IDENTICAL
			// bit_set types is always defined — in Odin these are the subset/superset
			// operators, not an ordering on the underlying integer. The port tested only
			// is_type_ordered, which is false for a bit_set, so `x >= y` on two bit_sets
			// reported "Cannot compare 'S' and 'S'" — the same type on both sides, which
			// cannot be a legitimate diagnostic. core/io's Stream_Mode_Set alone accounted
			// for 830 instances.
			if are_types_identical(x.type, y.type) && is_type_bit_set(x.type) {
				defined = true
			} else {
				defined = is_type_ordered(x.type) && is_type_ordered(y.type)
			}
		}

		// C++ Reference: check_expr.cpp:3221 -- mutual assignability is the OUTER gate that
		// selects which FAMILY of message to emit, not an extra condition folded into
		// `defined`:
		//
		//     if (check_is_assignable_to(c, x, y->type) || check_is_assignable_to(c, y, x->type)) {
		//         ... "not simply comparable" / "operator not defined between"
		//     } else {
		//         ... "Mismatched types '%s' and '%s'"
		//     }
		//
		// Folding it in meant two unrelated types reported "Operator '==' not defined
		// between the types '[8]u8' and '[3]u8'" where C++ says "Mismatched types". The
		// operator is perfectly well defined for those types; they simply are not the
		// same type. LEDGER task 270.
		if !are_types_identical(x.type, y.type) {
			mutually_assignable = check_is_assignable_to(ctx, x, y.type) || check_is_assignable_to(ctx, y, x.type)
		}
	}

	if !mutually_assignable || !defined {
		// C++ Reference: check_expr.cpp:3255-3267, 3277-3288 and 3292. FOUR messages, all
		// wrapped as "Cannot compare expression. %s." -- three for types that ARE mutually
		// assignable but whose comparison is undefined, and one for types that are not
		// mutually assignable at all. The port collapsed everything into one invented
		// sentence naming the two types.
		op_str := tokenizer.to_string(op)
		err_str: string
		if !mutually_assignable {
			// C++ names a procedure-group operand as "procedure group" rather than printing
			// its type. C++ Reference: check_expr.cpp:3277-3286.
			xt := x.mode == .Proc_Group ? "procedure group" : type_to_string(x.type)
			yt := y.mode == .Proc_Group ? "procedure group" : type_to_string(y.type)
			err_str = fmt.tprintf("Mismatched types '%s' and '%s'", xt, yt)
		} else {
			xs := type_to_string(x.type)
			ys := type_to_string(y.type)
			if !is_type_comparable(x.type) {
				err_str = fmt.tprintf("Type '%s' is not simply comparable, so operator '%s' is not defined for it", xs, op_str)
			} else if !is_type_comparable(y.type) {
				err_str = fmt.tprintf("Type '%s' is not simply comparable, so operator '%s' is not defined for it", ys, op_str)
			} else {
				err_str = fmt.tprintf("Operator '%s' not defined between the types '%s' and '%s'", op_str, xs, ys)
			}
		}
		error(node, "Cannot compare expression. %s.", err_str)
		x.type = t_untyped_bool
		x.mode = .Invalid
		return
	}

	// Check for tautological unsigned comparisons
	// C++ Reference: check_stmt.cpp:2720-2745
	check_tautological_comparison(ctx, node, x, y, op)

	// Constant folding for comparisons
	if x.mode == .Constant && y.mode == .Constant && x.value != nil && y.value != nil {
		// C++ Reference: check_expr.cpp:3011-3043
		// Special handling for bit_set comparisons (subset/superset)
		if is_type_bit_set(x.type) && is_type_bit_set(y.type) {
			x_int := exact_value_to_u64(x.value)
			y_int := exact_value_to_u64(y.value)
			result_bool: bool
			#partial switch op {
			case .Cmp_Eq:
				result_bool = x_int == y_int
			case .Not_Eq:
				result_bool = x_int != y_int
			case .Lt:
				// x < y means x is proper subset of y: (x & y) == x && x != y
				result_bool = (x_int & y_int) == x_int && x_int != y_int
			case .Gt:
				// x > y means x is proper superset of y: (x & y) == y && x != y
				result_bool = (x_int & y_int) == y_int && x_int != y_int
			case .Lt_Eq:
				// x <= y means x is subset of y: (x & y) == x
				result_bool = (x_int & y_int) == x_int
			case .Gt_Eq:
				// x >= y means x is superset of y: (x & y) == y
				result_bool = (x_int & y_int) == y_int
			}
			x.mode = .Constant
			x.type = t_untyped_bool
			x.value = exact_value_bool(result_bool)
		} else {
			result := compare_exact_values(op, x.value, y.value)
			x.mode = .Constant
			x.type = t_untyped_bool
			x.value = result
		}
	} else {
		x.mode = .Value
		x.type = t_untyped_bool

		// C++ Reference: check_expr.cpp:3053-3125
		// Add runtime dependencies for complex type comparisons
		cmp_type := base_type(x.type)
		if cmp_type != nil && cmp_type.kind == .Basic {
			basic := cmp_type.variant.(Type_Basic)
			#partial switch basic.kind {
			case .String:
				#partial switch op {
				case .Cmp_Eq:
					add_package_dependency(ctx, "runtime", "string_eq")
				case .Not_Eq:
					add_package_dependency(ctx, "runtime", "string_ne")
				case .Lt:
					add_package_dependency(ctx, "runtime", "string_lt")
				case .Gt:
					add_package_dependency(ctx, "runtime", "string_gt")
				case .Lt_Eq:
					add_package_dependency(ctx, "runtime", "string_le")
				case .Gt_Eq:
					add_package_dependency(ctx, "runtime", "string_ge")
				}
			case .Cstring:
				#partial switch op {
				case .Cmp_Eq:
					add_package_dependency(ctx, "runtime", "cstring_eq")
				case .Not_Eq:
					add_package_dependency(ctx, "runtime", "cstring_ne")
				case .Lt:
					add_package_dependency(ctx, "runtime", "cstring_lt")
				case .Gt:
					add_package_dependency(ctx, "runtime", "cstring_gt")
				case .Lt_Eq:
					add_package_dependency(ctx, "runtime", "cstring_le")
				case .Gt_Eq:
					add_package_dependency(ctx, "runtime", "cstring_ge")
				}
			case .Complex64:
				add_package_dependency(ctx, "runtime", "complex64_eq")
			case .Complex128:
				add_package_dependency(ctx, "runtime", "complex128_eq")
			case .Quaternion128:
				add_package_dependency(ctx, "runtime", "quaternion128_eq")
			case .Quaternion256:
				add_package_dependency(ctx, "runtime", "quaternion256_eq")
			}
		}
	}
}

// check_binary_expr handles binary operator expressions
// Reference: /mnt/c/odin/src/check_expr.cpp:4026-4464
// token_is_comparison reports whether an operator yields a boolean regardless of
// its operand types, so the surrounding type hint must not reach the operands.
token_is_comparison :: proc(kind: tokenizer.Token_Kind) -> bool {
	#partial switch kind {
	case .Cmp_Eq, .Not_Eq, .Lt, .Gt, .Lt_Eq, .Gt_Eq:
		return true
	}
	return false
}

// NOTE: can_use_other_type_as_type_hint lives in check_expr_helpers.odin.
check_binary_expr :: proc(ctx: ^Checker_Context, x: ^Operand, node: ^ast.Node, type_hint: ^Type, use_lhs_as_type_hint := false) {
	be, ok := node.derived.(^ast.Binary_Expr)
	if !ok {
		error(node, "Internal error: check_binary_expr called with non-binary expression")
		x.mode = .Invalid
		x.type = t_invalid
		return
	}

	// Viral flags propagate upward out of BOTH operands, on every exit path.
	// C++ Reference: check_expr.cpp:4375-4378 (a `defer` at the top of check_binary_expr).
	// Without this a `x or_break` or a deferred-procedure call nested inside a binary
	// expression is invisible to check_has_break_expr and contains_deferred_call.
	defer {
		node.viral_state_flags |= be.left.viral_state_flags
		node.viral_state_flags |= be.right.viral_state_flags
	}

	y: Operand
	op := be.op

	// Check operands - for most operators, check left then right
	// Special cases like == and != allow type checking
	#partial switch op.kind {
	case .Cmp_Eq, .Not_Eq:
		// NOTE(bill) in C++: allow comparisons between types.
		// C++ Reference: check_expr.cpp:4382-4410
		//
		// Each side is checked with the *other* side's type as its hint, which is the only
		// thing that gives an implicit selector something to resolve against:
		// `ODIN_ENDIAN == .Little` has to learn `.Little`'s type from ODIN_ENDIAN. When the
		// implicit selector is on the left instead, the order is reversed.
		if is_ise_expr(be.left) {
			// Evaluate the right before the left for an '.X' expression
			check_expr_or_type(ctx, &y, be.right, nil)
			check_expr_or_type(ctx, x, be.left, y.type)
		} else {
			check_expr_or_type(ctx, x, be.left, nil)
			check_expr_or_type(ctx, &y, be.right, x.type)
		}

		// If exactly one side is a type, that is an error unless the other is a typeid.
		// C++ Reference: check_expr.cpp:4394-4409
		{
			x_is_type := x.mode == .Type
			y_is_type := y.mode == .Type
			if x_is_type != y_is_type {
				if x_is_type && !is_type_typeid(y.type) {
					error_operand_not_expression(x)
				}
				if y_is_type && !is_type_typeid(x.type) {
					error_operand_not_expression(&y)
				}
			}
		}

	case .In, .Not_In:
		// C++ Reference: check_expr.cpp:4065-4156
		// For 'in' and 'not_in', check right side first to get type hint for left side
		check_expr(ctx, &y, be.right)
		rhs_type := type_deref(y.type)
		if rhs_type == nil {
			error(y.expr, "Cannot use '%s' on an expression with no value", op.text)
			x.mode = .Invalid
			x.expr = node
			return
		}

		// Use element type as hint for left side
		if is_type_bit_set(rhs_type) {
			bt := base_type(rhs_type).variant.(Type_Bit_Set)
			check_expr_with_type_hint(ctx, x, be.left, bt.elem)
		} else if is_type_map(rhs_type) {
			mt := base_type(rhs_type).variant.(Type_Map)
			check_expr_with_type_hint(ctx, x, be.left, mt.key)
		} else {
			check_expr(ctx, x, be.left)
		}

		if x.mode == .Invalid {
			return
		}
		if y.mode == .Invalid {
			x.mode = .Invalid
			x.expr = y.expr
			return
		}

		// Now validate the 'in' operation itself
		if is_type_map(rhs_type) {
			mt := base_type(rhs_type).variant.(Type_Map)
			if op.kind == .In {
				check_assignment(ctx, x, mt.key, "map 'in'")
			} else {
				check_assignment(ctx, x, mt.key, "map 'not_in'")
			}
			// C++ Reference: check_expr.cpp:315-323
			add_map_get_dependencies(ctx, rhs_type)
		} else if is_type_bit_set(rhs_type) {
			bt := base_type(rhs_type).variant.(Type_Bit_Set)
			if op.kind == .In {
				check_assignment(ctx, x, bt.elem, "bit_set 'in'")
			} else {
				check_assignment(ctx, x, bt.elem, "bit_set 'not_in'")
			}
			// Constant folding for bit_set 'in'
			if x.mode == .Constant && y.mode == .Constant {
				key_int := exact_value_to_i64(x.value)
				bits_int := exact_value_to_i64(y.value)
				lower := bt.lower
				upper := bt.upper
				if lower <= key_int && key_int <= upper {
					bit := i64(1) << u64(key_int)
					x.mode = .Constant
					x.type = t_untyped_bool
					if op.kind == .In {
						x.value = exact_value_bool((bit & bits_int) != 0)
					} else {
						x.value = exact_value_bool((bit & bits_int) == 0)
					}
					x.expr = node
					return
				} else {
					error(x.expr, "Key '%d' out of range of bit set, %d..%d", key_int, lower, upper)
					x.mode = .Invalid
				}
			}
		} else {
			error(x.expr, "Expected either a map or bit_set for '%s', got %s", op.text, type_to_string(y.type))
			x.mode = .Invalid
			x.expr = node
			return
		}

		if x.mode != .Invalid {
			x.mode = .Value
			x.type = t_untyped_bool
		}
		x.expr = node
		return

	case:
		// C++ Reference: check_expr.cpp:4510-4528. The enclosing type_hint must
		// reach the operands: an untyped compound literal like
		// `open(name, {.Read} + extra, perm)` has no other way to learn its type.
		is_cmp := token_is_comparison(op.kind)
		if is_ise_expr(be.left) {
			check_expr_or_type(ctx, &y, be.right, nil if is_cmp else type_hint)
			if can_use_other_type_as_type_hint(use_lhs_as_type_hint, y.type) {
				check_expr_or_type(ctx, x, be.left, y.type)
			} else {
				check_expr_or_type(ctx, x, be.left, type_hint)
			}
		} else {
			check_expr_or_type(ctx, x, be.left, type_hint)
			if x.mode == .Invalid {
				return
			}
			if can_use_other_type_as_type_hint(use_lhs_as_type_hint, x.type) {
				check_expr_or_type(ctx, &y, be.right, x.type)
			} else {
				check_expr_or_type(ctx, &y, be.right, nil if is_cmp else type_hint)
			}
		}
	}

	if x.mode == .Invalid {
		return
	}
	if y.mode == .Invalid {
		x.mode = .Invalid
		x.expr = y.expr
		return
	}

	// Check for invalid operand modes
	if x.mode == .Builtin {
		x.mode = .Invalid
		error(x.expr, "built-in expression in binary expression")
		return
	}
	if y.mode == .Builtin {
		x.mode = .Invalid
		error(y.expr, "built-in expression in binary expression")
		return
	}
	if x.mode == .Proc_Group {
		x.mode = .Invalid
		error(x.expr, "procedure group used in binary expression")
		return
	}
	if y.mode == .Proc_Group {
		x.mode = .Invalid
		error(y.expr, "procedure group used in binary expression")
		return
	}


	// Shifts are dispatched BEFORE EITHER operand-unification block below, and ALWAYS
	// return. C++ Reference: check_expr.cpp:4574-4577
	//     if (token_is_shift(op.kind)) { check_shift(c, x, y, node, type_hint); return; }
	//
	// A shift's operands are independent: the amount is NOT unified with the shifted
	// value. C++ never unifies them; check_shift converts an untyped amount to
	// untyped_integer itself. Unifying first turns `rune(x) << 31` into a rune shift
	// amount, which is then rejected as "Shift amount 'rune' must be an unsigned integer".
	//
	// NOTE there are TWO unification blocks in this function — `convert_to_typed(x, y.type)`
	// / `convert_to_typed(&y, x.type)` immediately below, and a second `default_type(...)`
	// pair further down. An earlier attempt placed this dispatch between them and still
	// saw the amount arrive as rune. It must precede BOTH.
	//
	// The dispatch also must not be conditional on check_shift's return value: that is
	// false both for "not a shift" and for "shift failed", so a failed shift used to fall
	// through to the generic binary path and emit a bogus "Unknown operator '<<'".
	#partial switch op.kind {
	case .Shl, .Shr:
		check_shift(ctx, node, x, &y, op, type_hint)
		return
	}

	// Convert untyped constants to typed
	convert_to_typed(ctx, x, y.type)
	if x.mode == .Invalid {
		return
	}
	convert_to_typed(ctx, &y, x.type)
	if y.mode == .Invalid {
		x.mode = .Invalid
		return
	}

	// Comparisons dispatch AFTER both operands are unified, as C++ does
	// (check_expr.cpp:4616, following the convert_to_typed pair at :4602-4610).
	if is_comparison_operator(op.kind) {
		check_comparison(ctx, node, x, &y, op.kind)
		return
	}

	// Apply default types only if one operand is typed and the other is untyped
	// If both are untyped, keep them untyped to allow proper type inference later
	// Reference: check_expr.cpp - untyped values propagate through binary ops
	x_is_untyped := is_type_untyped(x.type)
	y_is_untyped := is_type_untyped(y.type)
	if !x_is_untyped || !y_is_untyped {
		convert_to_typed(ctx, x, default_type(y.type))
		if x.mode == .Invalid {
			return
		}
		convert_to_typed(ctx, &y, default_type(x.type))
		if y.mode == .Invalid {
			x.mode = .Invalid
			return
		}
	}

	// Check for matrix binary operations (before types must match check)
	// Matrix operations allow mixed types like scalar * matrix
	if is_type_matrix(base_type(x.type)) || is_type_matrix(base_type(y.type)) {
		if check_binary_matrix(ctx, node, x, &y, op) {
			return
		}
		// If check_binary_matrix returns false, fall through to report type mismatch
	}

	// Array programming, in BOTH operand orders.
	// C++ Reference: check_expr.cpp:4620-4629
	if check_binary_array_expr(ctx, x, &y, op) {
		x.mode = .Value
		x.expr = node
		return
	}
	if check_binary_array_expr(ctx, &y, x, op) {
		x.mode = .Value
		x.type = y.type
		x.expr = node
		return
	}


	// Types must match
	// C++ Reference: check_expr.cpp:4284-4290
	// Exception: && and || allow any boolean types to be mixed
	if (op.kind == .Cmp_And || op.kind == .Cmp_Or) && is_type_boolean(x.type) && is_type_boolean(y.type) {
		// NOTE(bill): Allow any boolean types within `&&` and `||`
	} else if !are_types_identical(x.type, y.type) {
		if x.type != t_invalid && y.type != t_invalid {
			// C++ Reference: check_expr.cpp:4649 -- the EXPRESSION text comes first:
			//   "Mismatched types in binary expression '%s' : '%s' vs '%s'"
			expr_str := expr_to_string(node)
			defer delete(expr_str)
			error(op.pos, "Mismatched types in binary expression '%s' : '%s' vs '%s'", expr_str, type_to_string(x.type), type_to_string(y.type))
		}
		x.mode = .Invalid
		return
	}

	// Validate operator for the type
	if !check_binary_op(ctx, x, op) {
		x.mode = .Invalid
		return
	}

	// Division by zero check for constants
	#partial switch op.kind {
	case .Quo, .Mod, .Mod_Mod:
		// C++ Reference: check_expr.cpp:4227-4248
		// Warning: dividing untyped float by typed integer performs integer division
		if op.kind == .Quo {
			if is_type_integer(y.type) && !is_type_untyped(y.type) &&
			   is_type_float(x.type) && is_type_untyped(x.type) {
				warning(node, "Dividing an untyped float by a typed integer will perform integer division; convert the divisor to a float type explicitly")
			}
		}

		if y.mode == .Constant {
			is_zero := false

			// Check if divisor is zero
			#partial switch &v in y.value {
			case big.Int:
				is_zero, _ = big.is_zero(&v)
			case f64:
				is_zero = v == 0.0
			}

			if is_zero {
				// C++ Reference: check_expr.cpp:4396-4441
				// Handle target-specific division by zero behavior
				div_by_zero_kind := check_for_integer_division_by_zero(ctx, node)
				#partial switch div_by_zero_kind {
				case .Trap:
					// Default: error on division by zero
					error(y.expr, "Division by zero not allowed")
					x.mode = .Invalid
					return
				case .Zero:
					// Result is zero - allow for runtime handling
				case .Self:
					// Result is dividend - allow for runtime handling
				case .All_Bits:
					// Result is all bits set - allow for runtime handling
				}
			}
		}

	case .Cmp_And, .Cmp_Or:
		// '&&' and '||' short-circuit, so a deferred procedure attached to a call in
		// either operand may or may not run. C++ rejects it outright.
		// C++ Reference: check_expr.cpp:4711-4720
		if .Contains_Deferred_Procedure in be.left.viral_state_flags {
			error(be.left, "Procedure calls that have an associated deferred procedure are not allowed within logical binary expressions")
		}
		if .Contains_Deferred_Procedure in be.right.viral_state_flags {
			error(be.right, "Procedure calls that have an associated deferred procedure are not allowed within logical binary expressions")
		}
	}

	// Constant folding
	if x.mode == .Constant && y.mode == .Constant {
		if !is_type_constant_type(x.type) {
			x.mode = .Value
			return
		}

		// Two operator rewrites C++ performs before folding (check_expr.cpp:4734-4743).
		//
		// `/` on integers is INTEGER division, but exact_binary_operator_value's `.Quo`
		// arm is float division; C++ gets truncating division by rewriting the token to
		// `.Quo_Eq` first ("Hack to get division of integers"). Without this the port
		// folded `7 / 2` to 3.500 and `max(i64) / 1e9` to 9223372036.855, which then
		// failed to be representable as the very type it came from.
		//
		// A bit_set's `+`/`-` are set union/difference, not arithmetic.
		fold_op := op.kind
		if fold_op == .Quo && is_type_integer(x.type) {
			fold_op = .Quo_Eq
		}
		if is_type_bit_set(x.type) {
			#partial switch fold_op {
			case .Add:
				fold_op = .Or
			case .Sub:
				fold_op = .And_Not
			}
		}

		// Perform constant operation
		x.value = exact_binary_operator_value(fold_op, x.value, y.value)
		x.expr = node

		// Validate constant is expressible in its type
		if x.type != nil && !is_type_untyped(x.type) {
			check_is_expressible(ctx, x, x.type)
		}
		return
	}

	// For string concatenation, must be constant
	if is_type_string(x.type) && op.kind == .Add {
		error(node, "String concatenation is only allowed with constant strings")
		x.mode = .Invalid
		return
	}

	x.mode = .Value
	x.expr = node
}

// check_unary_expr handles unary operator expressions
// Reference: /mnt/c/odin/src/check_expr.cpp:2697-2851
check_unary_expr :: proc(ctx: ^Checker_Context, o: ^Operand, node: ^ast.Node, type_hint: ^Type = nil) {
	ue, ok := node.derived.(^ast.Unary_Expr)
	if !ok {
		error(node, "Internal error: check_unary_expr called with non-unary expression")
		o.mode = .Invalid
		o.type = t_invalid
		return
	}

	op := ue.op

	// C++ Reference: check_expr.cpp:12486-12491 - the hint is passed down,
	// dereferenced for '&' so `takes_ptr(&{})` gives the literal the pointee type.
	operand_hint := type_hint
	if op.kind == .And {
		operand_hint = type_deref(operand_hint)
	}
	check_expr_base(ctx, o, ue.expr, operand_hint)
	if o.mode == .Invalid {
		return
	}

	// '**x' is the expand_values operator: **x == expand_values(x)
	// C++ Reference: check_expr.cpp:2995-3035 (case Token_MulMul), handled before check_unary_op.
	if op.kind == .Mul_Mul {
		if o.type == nil {
			return
		}
		if o.mode == .Type {
			type_str := type_to_string(o.type)
			error(node, "Cannot apply '**' to a type '%s', the operand must be a value of struct or array type", type_str)
		}
		result, ok2 := expand_values_tuple_type(ctx, o.type)
		if !ok2 {
			type_str := type_to_string(o.type)
			error(node, "Expected a struct or array type to 'expand_values', got '%s'", type_str)
			o.mode = .Invalid
			o.type = t_invalid
			return
		}
		o.type = result
		o.mode = .Value
		return
	}

	// Handle address-of operator specially
	if op.kind == .And {
		// Address-of operator: check addressability
		// Reference: check_expr.cpp:1996-2020, 2691-2746
		if check_is_not_addressable(ctx, o) {
			// C++ Reference: check_expr.cpp:2910-2960.
			//
			// The port used one generic message plus two INVENTED suggestions
			// ("Cannot take address of constant. Assign it to a variable first.") which appear
			// nowhere in C++, and emitted them OUTSIDE an error block so they printed before
			// the error. C++ instead selects a SPECIFIC message naming the expression and the
			// reason, and only the default arm carries continuations.
			str := expr_to_string(o.expr)
			defer delete(str)

			e: ^Entity
			if o.expr != nil {
				if ident, is_ident := unparen_expr(o.expr).derived.(^ast.Ident); is_ident {
					e = ident.entity
				}
			}

			if e != nil && .Param in e.flags {
				error(op.pos, "Cannot take the pointer address of '%s' which is a procedure parameter", str)
			} else if e != nil && .Bit_Field_Field in e.flags {
				error(op.pos, "Cannot take the pointer address of '%s' which is a bit_field's field", str)
			} else {
				#partial switch o.mode {
				case .Constant:
					error(op.pos, "Cannot take the pointer address of '%s' which is a constant", str)
				case .Swizzle_Value, .Swizzle_Variable:
					error(op.pos, "Cannot take the pointer address of '%s' which is a swizzle intermediate array value", str)
				case:
					// C++ Reference: check_expr.cpp:2930-2957 -- the ONLY arm with continuations.
					begin_error_block()
					defer end_error_block()
					error(op.pos, "Cannot take the pointer address of '%s'", str)
					if e != nil {
						if .For_Value in e.flags {
							// C++ reads e->Variable.for_loop_parent_type; here it lives on the
							// Entity_Variable variant, so guard the assertion.
							parent_raw: ^Type
							if ev, ev_ok := e.variant.(Entity_Variable); ev_ok {
								parent_raw = ev.for_loop_parent_type
							}
							parent := type_deref(parent_raw)
							if parent != nil && is_type_string(parent) {
								error_line("\tSuggestion: Iterating over a string produces an intermediate 'rune' value which cannot be addressed.\n")
							} else if parent != nil && is_type_tuple(parent) {
								error_line("\tSuggestion: Iterating over a procedure does not produce values which are addressable.\n")
							} else {
								error_line("\tSuggestion: Did you want to pass the iterable value to the for statement by pointer to get addressable semantics?\n")
							}
							if parent != nil && is_type_map(parent) {
								error_line("\t            Prefer doing 'for key, &%s in ...'\n", e.token.text)
							} else {
								error_line("\t            Prefer doing 'for &%s in ...'\n", e.token.text)
							}
						}
						if .Switch_Value in e.flags {
							error_line("\tSuggestion: Did you want to pass the value to the switch statement by pointer to get addressable semantics?\n")
						}
					}
				}
			}

			o.mode = .Invalid
			return
		}

		// C++ Reference: check_expr.cpp:2750-2759
		// For SOA variables, create an SOA pointer type instead of regular pointer
		if o.mode == .Soa_Variable {
			// Create SOA pointer type
			o.type = alloc_type_soa_pointer(o.type)
			o.mode = .Value
			o.expr = node
			return
		}

		// Create pointer type
		o.type = alloc_type_pointer(o.type)

		// C++ Reference: check_expr.cpp:2764-2771
		// Convert Optional_Ok/Map_Index to Optional_Ok_Ptr when taking address
		if o.mode == .Optional_Ok || o.mode == .Map_Index {
			o.mode = .Optional_Ok_Ptr
		} else {
			o.mode = .Value
		}
		o.expr = node
		return
	}

	// Validate operator for the type
	if !check_unary_op(ctx, o, op) {
		o.mode = .Invalid
		return
	}

	// Constant folding for unary operators
	if o.mode == .Constant {
		bt := base_type(o.type)
		if !is_type_constant_type(o.type) {
			o.mode = .Value
			return
		}

		// C++ Reference: check_expr.cpp:2802-2808
		// Bitwise NOT cannot be applied to untyped constants
		if op.kind == .Xor && is_type_untyped(o.type) {
			err_str := type_to_string(o.type)
			error(op.pos, "Bitwise not cannot be applied to untyped constants '%s'", err_str)
			o.mode = .Invalid
			return
		}

		// C++ Reference: check_expr.cpp:2809-2815
		// Unsigned constants cannot be negated
		if op.kind == .Sub && is_type_unsigned(o.type) {
			err_str := type_to_string(o.type)
			error(op.pos, "An unsigned constant cannot be negated '%s'", err_str)
			o.mode = .Invalid
			return
		}

		// For bitwise NOT (~), we need the actual precision and signedness
		// C++ Reference: check_expr.cpp uses type info for bit operations
		precision := 0
		is_unsigned := false
		if op.kind == .Xor && bt != nil {
			// C++ Reference: check_expr.cpp:2828-2831
			// For bit_set, use the underlying type's bit size for the mask
			if is_type_bit_set(bt) {
				bs := bt.variant.(Type_Bit_Set)
				if bs.underlying != nil {
					precision = type_size_of(bs.underlying) * 8
				} else {
					precision = type_size_of(bt) * 8
				}
				is_unsigned = true // bit_set underlying is always treated as unsigned
			} else {
				precision = type_size_of(bt) * 8 // Convert bytes to bits
				is_unsigned = is_type_unsigned(o.type)
			}
		}

		// Perform constant operation
		o.value = exact_unary_operator_value(op.kind, o.value, i32(precision), is_unsigned)
		o.expr = node

		// Validate constant is expressible in its type
		if o.type != nil && !is_type_untyped(o.type) {
			check_is_expressible(ctx, o, o.type)
		}
		return
	}

	o.mode = .Value
	o.expr = node
}

// check_unary_op validates a unary operator for the given operand
// Reference: /mnt/c/odin/src/check_expr.cpp (inlined in check_unary_expr)
check_unary_op :: proc(ctx: ^Checker_Context, o: ^Operand, op: tokenizer.Token) -> bool {
	type := base_type(o.type)

	#partial switch op.kind {
	case .Sub, .Add:
		// C++ Reference: check_expr.cpp:2092-2098 -- names the EXPRESSION, not the category:
		//   "Operator '-' is not allowed with 'p'"
		if !is_type_numeric(type) {
			str := expr_to_string(o.expr)
			defer delete(str)
			error(op.pos, "Operator '%s' is not allowed with '%s'", op.text, str)
			return false
		}

	case .Not:
		// Logical not works on booleans
		if !is_type_boolean(type) {
			error(op.pos, "Operator '%s' is only allowed with boolean expressions", op.text)
			return false
		}
		// C++ Reference: check_expr.cpp:1965
		// Logical NOT produces untyped bool
		o.type = t_untyped_bool

	case .Xor:
		// C++ Reference: check_expr.cpp:1948
		// Bitwise not works on integers, booleans, and bit_sets
		if !is_type_integer(type) && !is_type_boolean(type) && !is_type_bit_set(type) {
			error(op.pos, "Operator '%s' is only allowed with integers, booleans, or bit_sets", op.text)
			return false
		}

	case .Pointer:
		// Dereference operator - check for pointer type
		// C++ Reference: check_expr.cpp:12569 - the deref path tests `t->kind == Type_Pointer`
		// directly rather than is_type_pointer, because `rawptr` cannot be dereferenced.
		if type.kind != .Pointer {
			error(op.pos, "Cannot dereference non-pointer type '%s'", type_to_string(o.type))
			return false
		}

		// Get element type
		ptr := type.variant.(Type_Pointer)
		o.type = ptr.elem
		o.mode = .Variable

	case .Mul:
		// C++ Reference: check_expr.cpp:1969-1983
		// C-style dereference (*ptr) - not valid in Odin, suggest ptr^
		error(op.pos, "Operator '*' is not a valid unary operator in Odin")
		if is_type_pointer(type) {
			error_line("\tSuggestion: Did you mean '%s^'?\n", type_to_string(o.type))
		}
		return false

	case:
		error(op.pos, "Unknown unary operator '%s'", op.text)
		return false
	}

	return true
}

// is_comparison_operator checks if a token is a comparison operator
is_comparison_operator :: proc(kind: tokenizer.Token_Kind) -> bool {
	#partial switch kind {
	case .Cmp_Eq, .Not_Eq, .Lt, .Gt, .Lt_Eq, .Gt_Eq:
		return true
	}
	return false
}

// exact_binary_operator_value performs constant folding for binary operators
// Reference: /mnt/c/odin/src/exact_value.cpp:755-923
//
// exact_binary_operator_value and exact_unary_operator_value are defined in exact_value.odin


// compare_exact_values is defined in check_equivalence.odin

// is_type_cstring checks if a type is cstring
// Ported from is_type_cstring in types.cpp:1323-1330
is_type_cstring :: proc(t: ^Type) -> bool {
	bt := base_type(t)
	if bt == nil {
		return false
	}
	if bt.kind != .Basic {
		return false
	}
	basic := bt.variant.(Type_Basic)
	return basic.kind == .Cstring
}

// is_type_any checks if a type is any
is_type_any :: proc(t: ^Type) -> bool {
	bt := base_type(t)
	if bt == nil {
		return false
	}
	if bt.kind != .Basic {
		return false
	}
	basic := bt.variant.(Type_Basic)
	return basic.kind == .Any
}

// is_type_union checks if a type is a union
// Ported from is_type_union in types.cpp:1856
is_type_union :: proc(t: ^Type) -> bool {
	bt := base_type(t)
	// C++ nil-guards after reducing (types.cpp, e.g. is_type_enum:
	//     t = base_type(t); if (t == nullptr) { return false; }
	// base_type(nil) returns nil here, so the deref below would fault.
	if bt == nil {
		return false
	}

	return t != nil && bt.kind == .Union
}


// base_array_type is defined in check_builtin_simd.odin

// is_operand_nil checks if an operand is nil
is_operand_nil :: proc(o: Operand) -> bool {
	if o.mode == .Constant && o.value == nil {
		return true
	}
	if o.type != nil && o.type == t_untyped_nil {
		return true
	}
	return false
}

// is_operand_uninit checks if an operand is uninit
is_operand_uninit :: proc(o: Operand) -> bool {
	return o.type != nil && is_type_untyped_uninit(o.type)
}

// check_get_expr_info retrieves expression info from temporary untyped map
// C++ Reference: checker.cpp check_get_expr_info (lines ~100)
// This accesses the temporary ExprInfo map used during untyped expression processing.
// Falls back to global_untyped if local untyped map is not set.
check_get_expr_info :: proc(ctx: ^Checker_Context, expr: ^ast.Expr) -> ^Expr_Info {
	if expr == nil {
		return nil
	}

	// Try local untyped map first (if set)
	if ctx.untyped != nil {
		if info, found := ctx.untyped[expr]; found {
			return info
		}
		return nil
	}

	// Fall back to global untyped map with mutex protection
	// C++ Reference: checker.cpp uses mutex for thread safety
	//
	// NOTE: the unlock must be deferred from THIS scope, not from inside the `if`. Odin's `defer`
	// is scope-scoped, so a `defer` written inside the `if` fires at that block's closing brace -
	// releasing the lock before the map access below and leaving the critical section empty.
	locked := !in_single_threaded_checker_stage()
	if locked {
		sync.shared_lock(&ctx.info.global_untyped_mutex)
	}
	defer if locked {
		sync.shared_unlock(&ctx.info.global_untyped_mutex)
	}
	if info, found := ctx.info.global_untyped[expr]; found {
		return info
	}
	return nil
}

// check_set_expr_info stores expression info in temporary untyped map
// C++ Reference: checker.cpp check_set_expr_info
// This stores temporary ExprInfo during untyped expression processing.
// The info is later removed when the expression is finalized.
check_set_expr_info :: proc(ctx: ^Checker_Context, expr: ^ast.Expr, mode: Addressing_Mode, type: ^Type, value: Exact_Value, is_lhs := false) {
	if expr == nil {
		return
	}

	// Create ExprInfo
	info := new(Expr_Info, ctx.checker.allocator)
	info.mode = mode
	info.type = type
	info.value = value
	info.is_lhs = is_lhs

	// Store in appropriate map
	if ctx.untyped != nil {
		ctx.untyped[expr] = info
	} else {
		// Use mutex protection for global untyped map
		// C++ Reference: checker.cpp uses mutex for thread safety
		// NOTE: see check_get_expr_info - the unlock must be deferred from this scope, not from
		// inside the `if`, or the critical section is empty.
		locked := !in_single_threaded_checker_stage()
		if locked {
			sync.lock(&ctx.info.global_untyped_mutex)
		}
		defer if locked {
			sync.unlock(&ctx.info.global_untyped_mutex)
		}
		ctx.info.global_untyped[expr] = info
	}
}

// check_remove_expr_info removes expression info from temporary untyped map
// C++ Reference: checker.cpp check_remove_expr_info
// Called when finalizing an untyped expression to clean up temporary info.
check_remove_expr_info :: proc(ctx: ^Checker_Context, expr: ^ast.Expr) {
	if expr == nil {
		return
	}

	// Remove from appropriate map
	if ctx.untyped != nil {
		delete_key(ctx.untyped, expr)
	} else {
		// Use mutex protection for global untyped map
		// C++ Reference: checker.cpp uses mutex for thread safety
		// NOTE: see check_get_expr_info - the unlock must be deferred from this scope, not from
		// inside the `if`, or the critical section is empty.
		locked := !in_single_threaded_checker_stage()
		if locked {
			sync.lock(&ctx.info.global_untyped_mutex)
		}
		defer if locked {
			sync.unlock(&ctx.info.global_untyped_mutex)
		}
		delete_key(&ctx.info.global_untyped, expr)
	}
}

// add_type_and_value stores type and value information for an expression node
// C++ Reference: checker.cpp:1773-1817
// In C++, this stores in expr->tav. In Odin, we use an external map since core:odin/ast
// doesn't have a tav field. The C++ version also handles parenthesized expressions by
// propagating the information through the paren chain.
//
// Thread-safe: Uses mutex protection for type_and_value_map access
// C++ Reference: checker.cpp:1784-1791, 1791, 1816 (mutex usage)
add_type_and_value :: proc(ctx: ^Checker_Context, expr: ^ast.Node, mode: Addressing_Mode, type: ^Type, value: Exact_Value, is_bit_field := false) {
	if expr == nil {
		return
	}
	if mode == .Invalid {
		return
	}
	// C++ checker validates constant mode has valid type
	if mode == .Constant && type == nil {
		return
	}

	// C++ Reference: checker.cpp:1784-1815. C++ stores this ON THE NODE (`expr->tav`), and
	// so do we now. There is no map and therefore no mutex: a plain field write cannot race
	// a rehash, and a reader can never find the entry "missing".
	//
	// The previous implementation kept a `map[rawptr]Type_And_Value` on the shared
	// Checker_Info, which forced every read and write through an RW mutex and still left a
	// failure mode C++ does not have - see tav_lookup below.

	// Handle special case: when type is 'any' and we already have an untyped type stored,
	// preserve the untyped type (C++ lines 1796-1799)
	final_type := type
	if prev := expr.tav; prev.mode != .Invalid {
		if type != nil && prev.type != nil && is_type_any(type) && is_type_untyped(prev.type) {
			// Keep the existing untyped type, don't overwrite with 'any'
			final_type = prev.type
		}
	}

	// Determine which value to store based on mode and type
	// C++ Reference: checker.cpp:1803-1809
	// Store value if:
	//   1. Mode is Constant or Invalid, OR
	//   2. Mode is Value AND type is typeid, OR
	//   3. Mode is Value AND type is proc
	stored_value := value
	if mode != .Constant && mode != .Invalid {
		// For non-constant, non-invalid modes:
		// Only store value if mode is Value AND type is typeid or proc
		if mode != .Value || (final_type != nil && !is_type_typeid(final_type) && !is_type_proc(final_type)) {
			stored_value = {} // Clear value
		}
	}

	expr.tav = Type_And_Value {
		type         = final_type,
		mode         = mode,
		is_lhs       = false, // Will be set appropriately by callers
		is_bit_field = is_bit_field,
		value        = stored_value,
	}

	// Propagate type/value through ALL parenthesis levels
	// C++ Reference: checker.cpp:1792-1815
	//
	// CRITICAL: We must peel ONE paren level at a time and assign to each level.
	// The old implementation used unparen_expr() which strips ALL parens at once,
	// causing intermediate paren nodes to miss type/value assignments.
	//
	// Example: (((x))) has 4 nodes to assign: (((x))), ((x)), (x), x
	current := expr
	prev_expr: ^ast.Node = nil
	for prev_expr != current {
		prev_expr = current

		// Peel ONE parenthesis level (not all at once!)
		// C++ Reference: checker.cpp:1811
		#partial switch node in current.derived {
		case ^ast.Paren_Expr:
			current = node.expr // Go to next level
		case:
			break // Not a paren, stop peeling
		}

		if current == nil {
			break
		}

		// Store type/value for this intermediate level
		// C++ Reference: checker.cpp:1795-1809

		// Apply same type resolution as for the outermost expression
		current_final_type := type
		if prev := current.tav; prev.mode != .Invalid {
			if type != nil && prev.type != nil && is_type_any(type) && is_type_untyped(prev.type) {
				current_final_type = prev.type
			}
		}

		current.tav = Type_And_Value {
			type         = current_final_type,
			mode         = mode,
			is_lhs       = false, // Will be set appropriately by callers
			is_bit_field = is_bit_field, // Propagate bit field flag through parens
			value        = stored_value, // Use same conditional value as outer
		}
	}
}

// type_and_value_of_expr retrieves stored type and value for an expression
// C++ Reference: checker.cpp:1600-1606
// In C++, this returns expr->tav. In Odin, we look it up in the map.
type_and_value_of_expr :: proc(ctx: ^Checker_Context, expr: ^ast.Node) -> (type: ^Type, value: Exact_Value, mode: Addressing_Mode) {
	if expr == nil {
		return nil, {}, .Invalid
	}

	// C++ Reference: checker.cpp:1600-1606 - this is `expr->tav`, a plain field read.
	tv := expr.tav
	if tv.mode != .Invalid {
		return tv.type, tv.value, tv.mode
	}
	return nil, {}, .Invalid
}

// tav_lookup returns the Type_And_Value recorded for `node`.
//
// C++ has no side table: it stores the Type_And_Value on the AST node itself (`expr->tav`) and
// tests `tav.mode != Addressing_Invalid` to decide whether the node has been checked
// (e.g. check_stmt.cpp:534). This now does the same, so `found` means exactly that.
//
// It previously read a `map[rawptr]Type_And_Value` on the shared Checker_Info under an RW mutex.
// That had two costs C++ does not pay. The mutex was mandatory - an unsynchronised lookup landing
// during map_grow_dynamic reads through the freed bucket array and segfaults, which is what
// checking any core package used to do roughly two runs in three. And "entry absent" was
// representable at all, so callers asserting presence (check_stmt.odin's .Map_Index path) could
// abort on a state C++ cannot reach; that assertion is what blocked the conversion type-hint fix.
//
// It takes ^Checker_Info rather than ^Checker_Context because some callers (type_of_expr) only
// have the info. The parameter is now unused but kept so the 14 call sites need not change.
tav_lookup :: proc(info: ^Checker_Info, node: ^ast.Node) -> (tv: Type_And_Value, found: bool) {
	if node == nil {
		return {}, false
	}
	tv = node.tav
	found = tv.mode != .Invalid
	return
}

// update_untyped_expr_type updates the type for an untyped expression
// C++ Reference: check_expr.cpp:4479-4601
// This function is used during type inference to propagate concrete types
// to untyped expressions (literals, untyped operations, etc.).
//
// CRITICAL: Uses ExprInfo map (temporary storage), NOT type_and_value_map (permanent)
update_untyped_expr_type :: proc(ctx: ^Checker_Context, expr: ^ast.Node, type: ^Type, final: bool) {
	if expr == nil {
		return
	}

	// Get expr info from TEMPORARY storage (not permanent tav map)
	// C++ Reference: check_expr.cpp:4481-4493
	// NOTE: check_get_expr_info requires ^ast.Expr, but we have ^ast.Node.
	// Since Expr embeds Node, we can cast if this is an expression node.
	expr_node := cast(^ast.Expr)expr
	old := check_get_expr_info(ctx, expr_node)
	if old == nil {
		// No expr info found - try updating tav directly as fallback
		// C++ Reference: check_expr.cpp:4483-4492
		if type != nil && type != t_invalid {
			if tv, found := tav_lookup(ctx.info, expr); found {
				if tv.type == nil || tv.type == t_invalid {
					// Update permanent storage
					add_type_and_value(ctx, expr, tv.mode, type, tv.value)
					// Special case for ternary if expressions
					#partial switch e in expr.derived {
					case ^ast.Ternary_If_Expr:
						update_untyped_expr_type(ctx, e.x, type, final)
						update_untyped_expr_type(ctx, e.y, type, final)
					}
				}
			}
		}
		return
	}

	// Handle recursive propagation for different expression types
	// C++ Reference: check_expr.cpp:4495-4581
	// NOTE: We skip constant expressions (old.value != Invalid) as they'll be
	// updated later during the general checking stage

	#partial switch e in expr.derived {
	case ^ast.Paren_Expr:
		// C++ Reference: check_expr.cpp:4578-4580
		update_untyped_expr_type(ctx, e.expr, type, final)

	case ^ast.Unary_Expr:
		// C++ Reference: check_expr.cpp:4496-4504
		if old.value == nil {
			// Non-constant unary - propagate to operand
			update_untyped_expr_type(ctx, e.expr, type, final)
		}

	case ^ast.Binary_Expr:
		// C++ Reference: check_expr.cpp:4506-4519
		if old.value == nil {
			// Non-constant binary - propagate to operands

			// Check if comparison operator
			is_comparison := false
			#partial switch e.op.kind {
			case .Cmp_Eq, .Not_Eq, .Lt, .Lt_Eq, .Gt, .Gt_Eq:
				is_comparison = true
			}

			// Check if shift operator
			is_shift := false
			#partial switch e.op.kind {
			case .Shl, .Shr:
				is_shift = true
			}

			if is_comparison {
				// Comparison operators - don't update operand types
				// (they keep their own types)
			} else if is_shift {
				// Shift operators - only update LHS
				update_untyped_expr_type(ctx, e.left, type, final)
			} else {
				// Normal binary operators - update both operands
				update_untyped_expr_type(ctx, e.left, type, final)
				update_untyped_expr_type(ctx, e.right, type, final)
			}
		}

	case ^ast.Ternary_If_Expr:
		// C++ Reference: check_expr.cpp:4521-4537
		if old.value == nil {
			// Check expressibility of branches before updating
			// If a branch has a constant value, verify it can be represented in the target type
			x_info := check_get_expr_info(ctx, e.x)
			y_info := check_get_expr_info(ctx, e.y)

			x_ok := x_info == nil || x_info.value == nil || check_representable_as_constant(ctx, x_info.value, type, nil)
			y_ok := y_info == nil || y_info.value == nil || check_representable_as_constant(ctx, y_info.value, type, nil)

			if x_ok {
				update_untyped_expr_type(ctx, e.x, type, final)
			}
			if y_ok {
				update_untyped_expr_type(ctx, e.y, type, final)
			}
		}

	case ^ast.Ternary_When_Expr:
		// C++ Reference: check_expr.cpp:4540-4548
		if old.value == nil {
			update_untyped_expr_type(ctx, e.x, type, final)
			update_untyped_expr_type(ctx, e.y, type, final)
		}

	case ^ast.Or_Return_Expr:
		// C++ Reference: check_expr.cpp:4550-4557
		if old.value == nil {
			update_untyped_expr_type(ctx, e.expr, type, final)
		}

	case ^ast.Or_Branch_Expr:
		// C++ Reference: check_expr.cpp:4559-4566
		if old.value == nil {
			update_untyped_expr_type(ctx, e.expr, type, final)
		}

	case ^ast.Or_Else_Expr:
		// C++ Reference: check_expr.cpp:4568-4576
		if old.value == nil {
			update_untyped_expr_type(ctx, e.x, type, final)
			update_untyped_expr_type(ctx, e.y, type, final)
		}
	}

	// Final processing
	// C++ Reference: check_expr.cpp:4583-4601
	if !final && is_type_untyped(type) {
		old.type = base_type(type)
		return
	}

	// Remove from temporary map and re-add to permanent storage
	check_remove_expr_info(ctx, expr_node)

	// Check if shift LHS must be integer
	if old.is_lhs && !is_type_integer(type) {
		error_node(expr, "Shifted operand must be an integer, got '%s'", type_to_string(type))
		return
	}

	// Add to permanent storage with final type
	add_type_and_value(ctx, expr, old.mode, type, old.value)
}

// update_untyped_expr_value updates the value for an untyped expression
// C++ Reference: check_expr.cpp:4603-4609
// This function is used to propagate constant values through untyped expressions.
//
// CRITICAL: Uses ExprInfo map (temporary storage), NOT type_and_value_map (permanent)
update_untyped_expr_value :: proc(ctx: ^Checker_Context, expr: ^ast.Node, value: Exact_Value) {
	if expr == nil {
		return
	}

	// Simple: lookup in ExprInfo map and update value
	// C++ Reference: check_expr.cpp:4605-4608
	// NOTE: check_get_expr_info requires ^ast.Expr. Since Expr embeds Node,
	// we cast (all call sites pass expression nodes).
	expr_node := cast(^ast.Expr)expr
	if found := check_get_expr_info(ctx, expr_node); found != nil {
		found.value = value
	}
}

// Integer range constants for representability checking
// C++ Reference: common.cpp:279-311
SIGNED_INTEGER_MINS := [9]i64 {
	0, // [0] unused
	-128, // [1] i8
	-32768, // [2] i16
	0, // [3] unused
	-2147483648, // [4] i32
	0, // [5] unused
	0, // [6] unused
	0, // [7] unused
	min(i64), // [8] i64 (-9223372036854775808)
}

SIGNED_INTEGER_MAXS := [9]i64 {
	0, // [0] unused
	127, // [1] i8
	32767, // [2] i16
	0, // [3] unused
	2147483647, // [4] i32
	0, // [5] unused
	0, // [6] unused
	0, // [7] unused
	max(i64), // [8] i64 (9223372036854775807)
}

UNSIGNED_INTEGER_MAXS := [9]u64 {
	0, // [0] unused
	255, // [1] u8
	65535, // [2] u16
	0, // [3] unused
	4294967295, // [4] u32
	0, // [5] unused
	0, // [6] unused
	0, // [7] unused
	max(u64), // [8] u64 (18446744073709551615)
}

// check_representable_as_constant validates if a constant value can be represented in a target type
// Returns true if the value fits, false otherwise
// C++ Reference: check_expr.cpp:2107-2361
check_representable_as_constant :: proc(ctx: ^Checker_Context, in_value: Exact_Value, type: ^Type, out_value: ^Exact_Value = nil) -> bool {
	// Invalid values already had an error
	if in_value == nil {
		return true
	}

	// C++ Reference: check_expr.cpp:2295 - `type = core_type(type);`
	// Unwraps Named, Enum (to its backing integer) and Bit_Field (to its backing type)
	// so the rules below dispatch on the underlying basic kind.
	ct := core_type(type)

	if ct == nil || ct == t_invalid {
		return false
	}

	// Check based on the type category
	if is_type_boolean(ct) {
		// Boolean values can only be represented as booleans
		_, ok := in_value.(bool)
		return ok

	} else if is_type_string(ct) {
		// String values
		// C++ Reference: check_expr.cpp:2301-2306
		// A UTF-16 string value is only representable in the UTF-16 string types.
		if _, is_string16 := in_value.(Exact_Value_String16); is_string16 {
			return is_type_string16(ct) || is_type_cstring16(ct)
		}
		s, ok := in_value.(string)
		if !ok {
			return false
		}
		if out_value != nil {
			out_value^ = s
		}
		return true

	} else if is_type_integer(ct) {
		// Convert value to integer
		// For i128/u128 we work with BigInt directly
		value_i64: i64
		value_u64: u64
		is_signed := false
		use_bigint := false
		bigint_value: big.Int
		// Whether the magnitude is representable in 64 bits at all. Defaults TRUE and is
		// cleared only by the big.Int branch below, because every other exact-value kind
		// that reaches the range check (notably f64) already produced a 64-bit value.
		// Defaulting it false instead made every float-derived constant fail the guard --
		// `1e12` cast to i64 in base/runtime stopped checking.
		fits_64 := true

		#partial switch v in in_value {
		case bool:
			// Booleans cannot convert to integers in constants
			return false
		case big.Int:
			// Store the BigInt value for range checking
			bigint_value = v
			use_bigint = true

			// Also try to extract i64/u64 for smaller types
			temp_v := v
			temp_i64, err_i64 := big.int_get_i64(&temp_v)
			temp_u64, err_u64 := big.int_get_u64(&temp_v)
			if err_i64 == nil {
				value_i64 = temp_i64
				is_signed = true
			} else if err_u64 == nil {
				value_u64 = temp_u64
				is_signed = false
			}
			// C++ Reference: big_int.cpp:298 --
			//     big_int_can_be_represented_in_64_bits(x) { return mp_count_bits(x) <= 64; }
			// Ask the magnitude directly rather than inferring from a failed extraction:
			// big.int_get_u64 TRUNCATES silently for values wider than 64 bits instead of
			// erroring, so "extraction failed" is not the same question and answered it
			// wrongly for everything >= 2^64.
			if bits, bits_err := big.count_bits(&temp_v); bits_err == nil {
				fits_64 = bits <= 64
			}
			// If NEITHER succeeded, fits_64 stays false and value_i64/value_u64 stay 0.
			// That zero used to be treated as a real value by the signed range check below,
			// so a constant too large for 64 bits was accepted AND silently rewritten to 0.
			// Note: If neither fits, we still proceed with BigInt for i128/u128
		case f64:
			// Floats can convert if they're whole numbers
			if v != f64(i64(v)) {
				return false
			}
			value_i64 = i64(v)
			is_signed = true
		case complex128:
			// Complex cannot convert to integer
			return false
		case string:
			// Strings cannot convert to integer
			return false
		case quaternion256:
			// Quaternions cannot convert to integer
			return false
		case Exact_Value_Pointer:
			// Pointers can convert to integers (as addresses)
			value_i64 = v.address
			is_signed = true
		case Exact_Value_Compound:
			// Compound literals cannot convert to integer
			return false
		case Exact_Value_Procedure:
			// Procedures cannot convert to integer
			return false
		case Exact_Value_Typeid:
			// Typeids cannot convert to integer
			return false
		case:
			return false
		}

		// Check if untyped - untyped integers accept any value
		if is_type_untyped(ct) {
			if out_value != nil {
				// A value wider than 64 bits has no i64/u64 extraction: both
				// big.int_get_i64 and big.int_get_u64 failed above, leaving
				// value_i64/value_u64 at zero. Rebuilding from them silently
				// replaced e.g. `1<<127` with 0. An untyped integer is arbitrary
				// precision, so pass the BigInt straight through.
				if use_bigint {
					out_value^ = bigint_value
				} else {
					result: big.Int
					if is_signed {
						big.internal_int_set_from_integer(&result, value_i64, false)
					} else {
						big.internal_int_set_from_integer(&result, value_u64, false)
					}
					out_value^ = result
				}
			}
			return true
		}

		// Get type size for range checking
		bt := base_type(ct)
		if bt == nil || bt.kind != .Basic {
			return false
		}
		basic := bt.variant.(Type_Basic)
		byte_size := basic.size

		// Handle i128/u128 sizes using BigInt range checking
		// C++ Reference: check_expr.cpp:2162-2179
		if byte_size > 8 {
			if !use_bigint {
				// Need BigInt value for i128/u128 range checking
				return false
			}

			// Compute 128-bit limits
			// umax = (1 << 128) - 1
			// imin = -(1 << 127)
			// imax = (1 << 127) - 1
			one: big.Int
			umax: big.Int
			imin: big.Int
			imax: big.Int

			big.internal_int_set_from_integer(&one, i64(1), false)
			big.internal_int_set_from_integer(&umax, i64(1), false)
			big.internal_int_set_from_integer(&imin, i64(1), false)
			big.internal_int_set_from_integer(&imax, i64(1), false)

			// umax = 1 << 128
			big.int_shl(&umax, &one, 128)
			// umax = (1 << 128) - 1
			big.int_sub(&umax, &umax, &one)

			// imin = 1 << 127
			big.int_shl(&imin, &one, 127)
			// imin = -(1 << 127)
			big.int_neg(&imin, &imin)

			// imax = 1 << 127
			big.int_shl(&imax, &one, 127)
			// imax = (1 << 127) - 1
			big.int_sub(&imax, &imax, &one)

			// Check based on signed/unsigned type
			#partial switch basic.kind {
			case .I128, .I128le, .I128be:
				// Signed 128-bit: imin <= value <= imax
				cmp_min, _ := big.int_cmp(&imin, &bigint_value)
				cmp_max, _ := big.int_cmp(&bigint_value, &imax)
				if cmp_min > 0 || cmp_max > 0 {
					return false
				}
				if out_value != nil {
					out_value^ = bigint_value
				}
				return true

			case .U128, .U128le, .U128be:
				// Unsigned 128-bit: 0 <= value <= umax (must be non-negative)
				cmp_max, _ := big.int_cmp(&bigint_value, &umax)
				if bigint_value.sign == .Negative || cmp_max > 0 {
					return false
				}
				if out_value != nil {
					out_value^ = bigint_value
				}
				return true
			}
			// C++ Reference: check_expr.cpp:2445 - GB_PANIC("Compiler error: Unknown integer type!")
			// No integer basic kind is wider than 8 bytes except the i128/u128 families above.
			panic(fmt.tprintf("check_representable_as_constant: Compiler error: Unknown integer type: %v", basic.kind))
		}

		// Check range based on signedness
		// C++ Reference: check_expr.cpp:2375-2446
		#partial switch basic.kind {
		case .I8, .I16, .I32, .I64, .Int, .Rune,
		     .I16le, .I32le, .I64le,
		     .I16be, .I32be, .I64be:
			// Signed integer types
			// Note: Rune is treated as i32 for representability
			// Note: Untyped_Rune handled by is_type_untyped check above
			// C++ Reference: check_expr.cpp:2376-2388 (Basic_rune, Basic_i*, Basic_i*le, Basic_i*be)
			if byte_size < 9 && byte_size > 0 {
				min_val := SIGNED_INTEGER_MINS[byte_size]
				max_val := SIGNED_INTEGER_MAXS[byte_size]

				// C++ Reference: check_expr.cpp:2389-2397:
				//     if (!big_int_can_be_represented_in_64_bits(&i)) return false;
				//     i64 val64 = big_int_to_i64(&i);
				//     return imin_64 <= val64 && val64 <= imax_64;
				//
				// That conversion WRAPS, so C++ accepts anything in [2^63, 2^64-1] for a
				// signed 64-bit type: it wraps to a negative i64 and lands back in range.
				// `x: int = 18446744073709551615` compiles and becomes -1. That is an
				// upstream bug (LEDGER 264, task #166), reproduced here because the port's
				// job is to agree with the compiler, and diverging silently would be worse
				// than agreeing visibly. If it is fixed upstream, fix it here in the same
				// change.
				//
				// The port previously got this wrong in BOTH directions: it rejected
				// 2^63..2^64-1 (which C++ accepts) because big.int_get_i64 fails there, and
				// it accepted anything >= 2^64 (which C++ rejects) because both extractions
				// fail and the leftover zero passed the range test.
				if !fits_64 {
					return false
				}
				val64 := value_i64
				if !is_signed {
					val64 = i64(value_u64) // wrapping, matching big_int_to_i64
				}
				if val64 < min_val || val64 > max_val {
					return false
				}
				if out_value != nil {
					// C++ assigns *out_value from the ORIGINAL exact value near the top of
					// the function (check_expr.cpp:2312), before any range test, so the
					// stored constant is the value as written, not the wrapped one.
					if use_bigint {
						out_value^ = bigint_value
					} else {
						result: big.Int
						big.internal_int_set_from_integer(&result, val64, false)
						out_value^ = result
					}
				}
				return true
			}
			return false

		case .U8, .U16, .U32, .U64, .Uint, .Uintptr,
		     .U16le, .U32le, .U64le,
		     .U16be, .U32be, .U64be:
			// Unsigned integer types
			// C++ Reference: check_expr.cpp:2408-2421 (Basic_u*, Basic_uint, Basic_uintptr, Basic_u*le, Basic_u*be)
			if byte_size < 9 && byte_size > 0 {
				max_val := UNSIGNED_INTEGER_MAXS[byte_size]

				if is_signed {
					// Check if signed value is non-negative and fits
					if value_i64 < 0 || u64(value_i64) > max_val {
						return false
					}
					if out_value != nil {
						result: big.Int
						big.internal_int_set_from_integer(&result, u64(value_i64), false)
						out_value^ = result
					}
				} else {
					if value_u64 > max_val {
						return false
					}
					if out_value != nil {
						result: big.Int
						big.internal_int_set_from_integer(&result, value_u64, false)
						out_value^ = result
					}
				}
				return true
			}
			return false

		case .Untyped_Integer:
			// Untyped integers accept any integer value
			// C++ Reference: check_expr.cpp:2443-2444
			if out_value != nil {
				// Convert to big.Int since Exact_Value uses big.Int for integers
				result: big.Int
				if is_signed {
					big.internal_int_set_from_integer(&result, value_i64, false)
				} else {
					big.internal_int_set_from_integer(&result, i64(value_u64), value_u64 > max(u64) / 2)
				}
				out_value^ = result
			}
			return true

		case:
			// C++ Reference: check_expr.cpp:2446 - GB_PANIC("Compiler error: Unknown integer type!")
			// Every Basic_Kind carrying Basic_Flag.Integer is covered above; the untyped
			// integer kinds (Untyped_Integer, Untyped_Rune) return early via is_type_untyped.
			panic(fmt.tprintf("check_representable_as_constant: Compiler error: Unknown integer type: %v", basic.kind))
		}

	} else if is_type_float(ct) {
		// Convert value to float
		value_f64: f64
		local_value := in_value

		#partial switch &v in &local_value {
		case bool:
			return false
		case big.Int:
			// Convert big.Int to f64
			temp_f64, err := big.int_get_float(&v)
			if err != nil {
				return false
			}
			value_f64 = temp_f64
		case f64:
			value_f64 = v
		case complex128:
			// Complex cannot directly convert to float
			return false
		case string:
			return false
		case quaternion256:
			// Quaternions cannot convert to float
			return false
		case Exact_Value_Pointer:
			// Pointers cannot convert to float
			return false
		case Exact_Value_Compound:
			// Compound literals cannot convert to float
			return false
		case Exact_Value_Procedure:
			// Procedures cannot convert to float
			return false
		case Exact_Value_Typeid:
			// Typeids cannot convert to float
			return false
		case:
			return false
		}

		// Check if untyped
		if is_type_untyped(ct) {
			if out_value != nil {
				out_value^ = value_f64
			}
			return true
		}

		// C++ Reference: check_expr.cpp:2240-2255
		// Check for float overflow on conversion to smaller types
		bt := base_type(ct)
		if bt == nil || bt.kind != .Basic {
			return false
		}
		basic := bt.variant.(Type_Basic)

		// Float limits
		F16_MAX :: 65504.0 // Maximum value representable in f16
		F32_MAX :: 3.40282346e+38 // Maximum value representable in f32

		// Infinity constant for comparison
		INF_F64 :: 0h7FF0_0000_0000_0000

		#partial switch basic.kind {
		case .F16, .F16le, .F16be:
			// Check f16 overflow (only if not already infinity)
			abs_val := abs(value_f64)
			is_inf := abs_val == INF_F64
			if abs_val > F16_MAX && !is_inf {
				return false
			}
			if out_value != nil {
				out_value^ = value_f64
			}
			return true

		case .F32, .F32le, .F32be:
			// Check f32 overflow (only if not already infinity)
			abs_val := abs(value_f64)
			is_inf := abs_val == INF_F64
			if abs_val > F32_MAX && !is_inf {
				return false
			}
			if out_value != nil {
				out_value^ = value_f64
			}
			return true

		case .F64, .F64le, .F64be, .Untyped_Float:
			// f64 is the native type, no overflow check needed
			if out_value != nil {
				out_value^ = value_f64
			}
			return true

		case:
			// C++ Reference: check_expr.cpp:2472 - GB_PANIC("Compiler error: Unknown float type!")
			// Every Basic_Kind carrying Basic_Flag.Float is covered above.
			panic(fmt.tprintf("check_representable_as_constant: Compiler error: Unknown float type: %v", basic.kind))
		}

	} else if is_type_complex(ct) {
		// Convert value to complex
		value_complex: complex128
		local_value := in_value

		#partial switch &v in &local_value {
		case bool:
			return false
		case big.Int:
			// Convert big.Int to complex
			temp_f64, err := big.int_get_float(&v)
			if err != nil {
				return false
			}
			value_complex = complex(temp_f64, 0)
		case f64:
			value_complex = complex(v, 0)
		case complex128:
			value_complex = v
		case string:
			return false
		case quaternion256:
			// Quaternions cannot convert to complex
			return false
		case Exact_Value_Pointer:
			// Pointers cannot convert to complex
			return false
		case Exact_Value_Compound:
			// Compound literals cannot convert to complex
			return false
		case Exact_Value_Procedure:
			// Procedures cannot convert to complex
			return false
		case Exact_Value_Typeid:
			// Typeids cannot convert to complex
			return false
		case:
			return false
		}

		// Check if untyped
		if is_type_untyped(ct) {
			if out_value != nil {
				out_value^ = value_complex
			}
			return true
		}

		// Range checking for complex types
		// Reference: check_expr.cpp:2266-2278
		bt := base_type(ct)
		if bt == nil || bt.kind != .Basic {
			return false
		}
		basic := bt.variant.(Type_Basic)

		#partial switch basic.kind {
		case .Complex32, .Complex64, .Complex128:
			// Convert components to f64 for typed complex
			real := exact_value_real(value_complex)
			imag := exact_value_imag(value_complex)
			if real != nil && imag != nil {
				real_f64 := exact_value_to_f64(real)
				imag_f64 := exact_value_to_f64(imag)
				if out_value != nil {
					out_value^ = exact_value_complex(real_f64, imag_f64)
				}
				return true
			}
			// C++ Reference: check_expr.cpp:2489 - `break` out of the switch, then `return false`
			return false

		case .Untyped_Complex:
			if out_value != nil {
				out_value^ = value_complex
			}
			return true

		case:
			// C++ Reference: check_expr.cpp:2495 - GB_PANIC("Compiler error: Unknown complex type!")
			// Every Basic_Kind carrying Basic_Flag.Complex is covered above.
			panic(fmt.tprintf("check_representable_as_constant: Compiler error: Unknown complex type: %v", basic.kind))
		}

	} else if is_type_quaternion(ct) {
		// Quaternion constant checking
		// Reference: check_expr.cpp:2286-2314
		value_quat := exact_value_to_quaternion(in_value)
		if value_quat == nil {
			return false
		}

		// Check if untyped
		if is_type_untyped(ct) {
			if out_value != nil {
				out_value^ = value_quat
			}
			return true
		}

		bt := base_type(ct)
		if bt == nil || bt.kind != .Basic {
			return false
		}
		basic := bt.variant.(Type_Basic)

		#partial switch basic.kind {
		case .Quaternion64, .Quaternion128, .Quaternion256:
			// Convert components to f64 for typed quaternion
			real := exact_value_real(value_quat)
			imag := exact_value_imag(value_quat)
			jmag := exact_value_jmag(value_quat)
			kmag := exact_value_kmag(value_quat)
			if real != nil && imag != nil {
				real_f64 := exact_value_to_f64(real)
				imag_f64 := exact_value_to_f64(imag)
				jmag_f64 := exact_value_to_f64(jmag)
				kmag_f64 := exact_value_to_f64(kmag)
				if out_value != nil {
					out_value^ = exact_value_quaternion(real_f64, imag_f64, jmag_f64, kmag_f64)
				}
				return true
			}
			// C++ Reference: check_expr.cpp:2523 - `break` out of the switch, then `return false`
			return false

		case .Untyped_Quaternion:
			if out_value != nil {
				out_value^ = value_quat
			}
			return true

		case:
			// C++ Reference: check_expr.cpp:2531 - GB_PANIC (quaternion switch default)
			// Every Basic_Kind carrying Basic_Flag.Quaternion is covered above.
			panic(fmt.tprintf("check_representable_as_constant: Compiler error: Unknown quaternion type: %v", basic.kind))
		}

	} else if is_type_pointer(ct) {
		// Pointer constants (nil, pointer literals). Covers both Type_Pointer and
		// the `rawptr` basic type, which carries Basic_Flag.Pointer.
		// C++ Reference: check_expr.cpp:2535-2549
		#partial switch v in in_value {
		case Exact_Value_Pointer:
			// C++ Reference: check_expr.cpp:2536-2538
			return true
		case big.Int:
			// Integer to pointer rejected at constant level
			// (May be allowed at runtime via cast/transmute)
			// C++ Reference: check_expr.cpp:2539-2542
			return false
		case string:
			// String to pointer rejected
			// C++ Reference: check_expr.cpp:2543-2545
			return false
		case Exact_Value_String16:
			// C++ Reference: check_expr.cpp:2546-2548
			return false
		case:
			// C++ Reference: check_expr.cpp:2549 - writes the value through but does NOT
			// return true; control falls out to the trailing `return false`.
			if out_value != nil {
				out_value^ = in_value
			}
		}

	} else if is_type_bit_set(ct) {
		// Bit set constants can be initialized from integers
		// C++ Reference: check_expr.cpp:2340-2343
		#partial switch v in in_value {
		case big.Int:
			// Accept integer values for bit set initialization
			if out_value != nil {
				out_value^ = in_value
			}
			return true
		case:
			return false
		}

	} else if is_type_typeid(ct) {
		// Typeid constants
		// C++ Reference: check_expr.cpp:2336-2349
		// Handle typeid{} compound literals
		result_value := in_value
		if compound, is_compound := in_value.(Exact_Value_Compound); is_compound {
			if cl, ok := compound.expr.derived.(^ast.Comp_Lit); ok {
				if len(cl.elems) == 0 {
					// Empty compound literal - convert to nil typeid
					result_value = exact_value_typeid(nil)
				} else {
					return false
				}
			}
		}
		if _, is_typeid := result_value.(Exact_Value_Typeid); is_typeid {
			if out_value != nil {
				out_value^ = result_value
			}
			return true
		}
	} else if is_type_proc(ct) {
		// Procedure constants
		// C++ Reference: check_expr.cpp:2363-2365
		#partial switch v in in_value {
		case Exact_Value_Procedure:
			if out_value != nil {
				out_value^ = in_value
			}
			return true
		}
	}

	// Compound literal constants (struct{}, array{})
	// C++ Reference: check_expr.cpp:2350-2362
	if _, is_compound := in_value.(Exact_Value_Compound); is_compound {
		if is_type_struct(ct) || is_type_array(ct) || is_type_enumerated_array(ct) {
			// Compound literals can be assigned to struct/array types
			// The compound literal itself has already been type-checked
			if out_value != nil {
				out_value^ = in_value
			}
			return true
		}
	}

	// C++ Reference: check_expr.cpp:2569 - the function simply returns false for anything
	// that matched none of the categories above. There is NO panic here in C++; the four
	// GB_PANICs live inside the integer/float/complex/quaternion switches, which is where
	// they now live here too. Basic kinds that legitimately reach this point and are not
	// representable as constants: Any, Untyped_Nil, Untyped_Uninit, and Invalid.
	return false
}

// check_is_expressible checks if a constant operand's value can be represented in the target type
// Reports an error if the value doesn't fit
// C++ Reference: check_expr.cpp:2536-2582
check_is_expressible :: proc(ctx: ^Checker_Context, operand: ^Operand, target_type: ^Type) -> bool {
	assert(operand.mode == .Constant, "check_is_expressible called on non-constant operand")

	out_value := operand.value
	if is_type_constant_type(target_type) && check_representable_as_constant(ctx, operand.value, target_type, &out_value) {
		operand.value = out_value
		return true
	} else {
		operand.value = out_value

		// Error reporting for expressibility failures
		// C++ Reference: check_expr.cpp:2545-2578
		// C++ Reference: check_expr.cpp:2754-2757 binds FOUR strings, and every message in
		// this family uses the EXPRESSION text, not the source type:
		//     a = expr_to_string(o->expr)        the expression
		//     b = type_to_string(type)           the TARGET type
		//     c = type_to_string(o->type)        the SOURCE type
		//     s = exact_value_to_string(o->value)
		// The port bound only three and passed the source TYPE wherever C++ passes `a`, so
		// every one of these four diagnostics named a type where C++ names the expression,
		// and the general arm dropped the "from '<source>'" clause entirely.
		expr_str := expr_to_string(operand.expr)
		defer delete(expr_str)
		src_type_str := type_to_string(operand.type)
		dst_type_str := type_to_string(target_type)
		value_str := exact_value_to_string(operand.value)
		defer delete(value_str)

		// C++ Reference: check_expr.cpp:2766 -- the whole reporting tail is one error block,
		// and every arm except the truncation one follows its message with
		// check_assignment_error_suggestion. The port emitted the messages and none of the
		// suggestions, so an out-of-range constant never said what the bound actually was.
		begin_error_block()
		defer end_error_block()

		if is_type_numeric(operand.type) && is_type_numeric(target_type) {
			if !is_type_integer(operand.type) && is_type_integer(target_type) {
				// C++ check_expr.cpp:2771. NOTE: no suggestion on this arm.
				error(operand.expr, "'%s' truncated to '%s', got %s", expr_str, dst_type_str, value_str)
			} else {
				// C++ check_expr.cpp:2773-2776: the bit_field width in scope, when there is
				// one, narrows the bound the suggestion reports.
				max_bit_size: i64 = 0
				if ctx.bit_field_bit_size != 0 {
					max_bit_size = ctx.bit_field_bit_size
				}

				if are_types_identical(operand.type, target_type) {
					// C++ check_expr.cpp:2779
					error(operand.expr, "Numeric value '%s' from '%s' cannot be represented by '%s'", value_str, expr_str, dst_type_str)
				} else {
					// C++ check_expr.cpp:2781
					error(operand.expr, "Cannot convert numeric value '%s' from '%s' to '%s' from '%s'", value_str, expr_str, dst_type_str, src_type_str)
				}

				check_assignment_error_suggestion(ctx, operand, target_type, operand.expr, max_bit_size)
			}
		} else {
			// C++ check_expr.cpp:2787
			error(operand.expr, "Cannot convert '%s' to '%s' from '%s', got %s", expr_str, dst_type_str, src_type_str, value_str)
			check_assignment_error_suggestion(ctx, operand, target_type, operand.expr)
		}

		operand.mode = .Invalid
		return false
	}
}

// check_is_assignable_to determines if an operand can be assigned to a target type
// This is the core assignability check used throughout the checker
// Ported from check_expr.cpp:1037-1040 (wrapper) and check_expr.cpp:1005-1034 (with_score version)
//
// The full implementation requires check_distance_between_types (check_expr.cpp:667-1003)
// which handles:
// - Exact type matches (distance 0)
// - Untyped constant conversions with range checking
// - Untyped nil assignments to nullable types
// - Interface satisfaction
// - Pointer conversions
// - Slice/array conversions
// - Any type assignments
// - Array programming (SIMD operations)
//
// check_is_assignable_to is defined in check_equivalence.odin

// convert_untyped_error reports a failed untyped-constant conversion.
//
// C++ Reference: check_expr.cpp:4960-4997.
//
// The port previously emitted "Cannot convert '%s' to '%s' from '%s'" -- C++'s message is
// "Cannot convert UNTYPED VALUE '%s' ...", which distinguishes it from the typed-conversion
// error at check_expr.cpp:2787 that really does read "Cannot convert '%s' to ...". Two
// distinct C++ messages had collapsed onto one string, so the diagnostic no longer said
// which of the two checks had failed.
//
// The port also dropped the "Did you want 'nil'?" hint and the enum did-you-mean suggestion,
// and set operand.mode = .Invalid on entry -- which is why the hint could not have worked
// even if it had been written: it is guarded on mode == .Constant, and the guard ran after
// the field it reads had already been cleared. C++ invalidates at the END. Same shape as
// LEDGER #153: the check was ported, the state it reads was not.
convert_untyped_error :: proc(ctx: ^Checker_Context, operand: ^Operand, target_type: ^Type, ignore_error_block := false) {
	expr_str := expr_to_string(operand.expr)
	defer delete(expr_str)
	type_str := type_to_string(target_type)
	from_type_str := type_to_string(operand.type)

	extra_text := ""
	if operand.mode == .Constant {
		// C++ tests big_int_is_zero(&operand->value.value_integer) whatever the value's
		// actual kind is, deliberately reading the integer member of the union
		// ("NOTE(bill): Doesn't matter what the type is as it's still zero in the union").
		// Odin's Exact_Value is type-safe, so that reinterpretation is not expressible;
		// is_exact_value_zero tests each kind on its own terms and agrees with C++ on the
		// kinds that reach here (integer, float, and string, where C++ ends up reading the
		// string's length field and so treats only "" as zero).
		if is_exact_value_zero(operand.value) {
			if expr_str != "nil" { 	// HACK NOTE(bill): Just in case
				extra_text = " - Did you want 'nil'?"
			}
		}
	}

	if !ignore_error_block {
		begin_error_block()
	}
	error(operand.expr, "Cannot convert untyped value '%s' to '%s' from '%s'%s", expr_str, type_str, from_type_str, extra_text)
	if key, is_string := operand.value.(string); is_string {
		if is_type_string(operand.type) && is_type_enum(target_type) {
			et := base_type(target_type)
			if et != nil {
				if enum_variant, ok := &et.variant.(Type_Enum); ok {
					check_did_you_mean_type(key, enum_variant.fields[:], ".")
				}
			}
		}
	}
	operand.mode = .Invalid
	if !ignore_error_block {
		end_error_block()
	}
}

// convert_to_typed converts an untyped constant/value to a typed value
// Ported from convert_to_typed in check_expr.cpp:4667-4964
//
// This is the critical function for untyped constant conversion.
// It handles:
// - Untyped to untyped conversion (numeric promotion)
// - Untyped to typed conversion with range checking
// - Special cases for nil, arrays, unions, etc.
convert_to_typed :: proc(ctx: ^Checker_Context, operand: ^Operand, target_type: ^Type) {
	// Early exit conditions
	if target_type == nil || operand.mode == .Invalid || operand.mode == .Type || is_type_typed(operand.type) || target_type == t_invalid {
		return
	}

	// Handle untyped to untyped conversion (numeric promotion)
	if is_type_untyped(target_type) {
		assert(operand.type.kind == .Basic)
		assert(target_type.kind == .Basic)

		x_basic := operand.type.variant.(Type_Basic)
		y_basic := target_type.variant.(Type_Basic)
		x_kind := x_basic.kind
		y_kind := y_basic.kind

		if is_type_numeric(operand.type) && is_type_numeric(target_type) {
			// Promote to higher precision untyped numeric type
			if x_kind < y_kind {
				operand.type = target_type
				update_untyped_expr_type(ctx, operand.expr, target_type, false)
			}
		} else if x_kind != y_kind {
			// Incompatible untyped types
			operand.mode = .Invalid
			convert_untyped_error(ctx, operand, target_type)
			return
		}
		return
	}

	// Get base type (unwrap named types)
	// When in enum type context, use core_type to get the underlying type
	// This allows enum values to convert to their base integer type
	t := ctx.in_enum_type ? core_type(target_type) : base_type(target_type)

	// An untyped `nil` keeps its type. This has to happen BEFORE the switch on the
	// target's kind: the equivalent branch used to live inside `case .Basic:`, so it
	// only ran for basic targets and a union target retyped the nil.
	//
	// `is_operand_nil` is `mode == Value && type == t_untyped_nil` (C++ checker.cpp:32),
	// and check_comparison's equality arm relies on it because `is_type_comparable` is
	// FALSE for `any` and for unions (types.cpp:2781). A retyped nil satisfies neither
	// arm, so `x == nil` is rejected for exactly the types the nil arm exists to serve.
	// C++ marks the intent with the commented-out `// target_type = t_untyped_nil;`.
	// NOTE: `is_type_untyped_nil` answers true for `---` as well as `nil` (deliberately,
	// "to improve the error handling"), so it must NOT be used here -- `---` has its own
	// handling further down and hoisting it too breaks `a: u128 = ---`.
	is_nil_operand := false
	if ob := base_type(operand.type); ob != nil && ob.kind == .Basic {
		is_nil_operand = ob.variant.(Type_Basic).kind == .Untyped_Nil
	}
	if is_nil_operand {
		if !is_type_any(target_type) && !is_type_cstring(target_type) && !type_has_nil(target_type) {
			operand.mode = .Invalid
			convert_untyped_error(ctx, operand, target_type)
			return
		}
		operand.mode = .Value
		return
	}

	#partial switch t.kind {
	case .Basic:
		// `---` (explicit uninitialized) converts to ANY type. C++ Reference:
		// check_expr.cpp:711-713, where check_distance_between_types returns distance 1 for
		// an untyped-uninit source before any other test, and the default arm of
		// convert_to_typed (check_expr.cpp:5306) accepts it too.
		//
		// The port had the distance guard (check_equivalence.odin:550) and the default arm,
		// but NOT this one — so a target whose base type is Basic never reached either. `---`
		// then fell into the untyped-nil branch below and was rejected by type_has_nil, which
		// is false for int/u128/i64/complex128 and friends:
		//     a: u128 = ---   ->  Cannot convert '---' to 'u128' from 'untyped uninitialized'
		if is_type_untyped_uninit(operand.type) {
			break
		}

		// Convert to basic typed type
		// Handle untyped nil specially - it's a constant but needs nil-compatibility check
		if is_type_untyped_nil(operand.type) {
			// nil can convert to specific types
			if is_type_any(target_type) {
				// any accepts nil
			} else if is_type_cstring(target_type) {
				// cstring accepts nil
			} else if !type_has_nil(target_type) {
				operand.mode = .Invalid
				convert_untyped_error(ctx, operand, target_type)
				return
			}
		} else if operand.mode == .Constant {
			// Check if constant is representable in target type
			check_is_expressible(ctx, operand, t)
			if operand.mode == .Invalid {
				return
			}
			update_untyped_expr_value(ctx, operand.expr, operand.value)
		} else {
			// Non-constant untyped value - validate type compatibility
			if operand.type.kind == .Basic {
				x_basic := operand.type.variant.(Type_Basic)

				#partial switch x_basic.kind {
				case .Untyped_Bool:
					if !is_type_boolean(target_type) {
						operand.mode = .Invalid
						convert_untyped_error(ctx, operand, target_type)
						return
					}

				case .Untyped_Integer, .Untyped_Float, .Untyped_Complex, .Untyped_Rune:
					if !is_type_numeric(target_type) {
						operand.mode = .Invalid
						convert_untyped_error(ctx, operand, target_type)
						return
					}

				// C++ Reference: check_expr.cpp:4716
				// Untyped quaternion can convert to quaternion types
				case .Untyped_Quaternion:
					if !is_type_quaternion(target_type) {
						operand.mode = .Invalid
						convert_untyped_error(ctx, operand, target_type)
						return
					}
				}
			}
		}

	case .Array:
		// Arrays can accept untyped string constants or element-assignable values
		elem := base_array_type(t)
		if check_is_assignable_to(ctx, operand, elem) {
			operand.mode = .Value
		} else if operand.mode == .Constant && operand.value != nil {
			// Handle string to array conversion
			// C++ Reference: check_expr.cpp:4858-4878
			// C++ Reference: check_expr.cpp:5110-5133. The COUNT must match, and which
			// count depends on the element type: bytes for [N]u8, rune count for
			// [N]rune, and UTF-16 code units for [N]u16. The port previously accepted
			// any [N]u8 or [N]rune regardless of length -- it discarded the string value
			// outright (`_ = str_val`) -- so `[4]u8 == "abc"` passed. It also had no
			// plain-string -> [N]u16 path at all, only String16 -> [N]u16, so
			// `[3]u16 == "abc"` was rejected.
			if str_val, is_string := operand.value.(string); is_string {
				arr := t.variant.(Type_Array)
				matched := false
				if is_type_u8(arr.elem) {
					matched = i64(len(str_val)) == arr.count
				} else if is_type_rune(arr.elem) {
					matched = i64(utf8.rune_count_in_string(str_val)) == arr.count
				} else if is_type_u16(arr.elem) {
					// C++ converts via string_to_string16 and compares its length; the
					// UTF-16 length is one unit per rune below U+10000 and two above.
					units := i64(0)
					for r in str_val {
						units += 1 if r < 0x1_0000 else 2
					}
					matched = units == arr.count
				}
				if !matched {
					operand.mode = .Invalid
					convert_untyped_error(ctx, operand, target_type)
					return
				}
				operand.mode = .Value
			// String16 constant can convert to [N]u16 of the same length.
			} else if s16_val, is_string16 := operand.value.(Exact_Value_String16); is_string16 {
				arr := t.variant.(Type_Array)
				if !is_type_u16(arr.elem) || i64(s16_val.len) != arr.count {
					operand.mode = .Invalid
					convert_untyped_error(ctx, operand, target_type)
					return
				}
				operand.mode = .Value
			} else {
				operand.mode = .Invalid
				convert_untyped_error(ctx, operand, target_type)
				return
			}
		} else {
			operand.mode = .Invalid
			convert_untyped_error(ctx, operand, target_type)
			return
		}

	case .Simd_Vector:
		// SIMD vectors can be initialized with scalar values
		elem := base_array_type(t)
		if check_is_assignable_to(ctx, operand, elem) {
			operand.mode = .Value
		} else {
			operand.mode = .Invalid
			convert_untyped_error(ctx, operand, target_type)
			return
		}

	case .Matrix:
		// Matrices can be initialized with scalar values (square matrices only)
		elem := base_array_type(t)
		if check_is_assignable_to(ctx, operand, elem) {
			mat := t.variant.(Type_Matrix)
			if mat.row_count != mat.column_count {
				operand.mode = .Invalid
				convert_untyped_error(ctx, operand, target_type)
				error(operand.expr, "Note: Only square matrix types can be initialized with a scalar value")
				return
			}
			operand.mode = .Value
		} else {
			operand.mode = .Invalid
			convert_untyped_error(ctx, operand, target_type)
			return
		}

	case .Union:
		// Union conversion: find matching variant
		// C++ Reference: check_expr.cpp:4812-4937

		if !is_operand_nil(operand^) && !is_operand_uninit(operand^) {
			// Get union type info
			union_type := t.variant.(Type_Union)
			variant_count := len(union_type.variants)

			// Track valid matching variants with their scores
			Valid_Index_And_Score :: struct {
				index: int,
				score: i64,
			}
			valids := make([dynamic]Valid_Index_And_Score, context.temp_allocator)
			first_success_index := -1

			// Check each variant for assignability
			// C++ Reference: check_expr.cpp:4839-4850
			for vt, i in union_type.variants {
				score: i64 = 0
				if check_is_assignable_to_with_score(ctx, operand, vt, &score) {
					append(&valids, Valid_Index_And_Score{index = i, score = score})
					if first_success_index < 0 {
						first_success_index = i
					}
				}
			}
			valid_count := len(valids)

			// Sort by score (higher is better) and trim to best matches
			// C++ Reference: check_expr.cpp:4852-4864
			if valid_count > 1 {
				// Sort by score descending
				slice.sort_by(valids[:], proc(a, b: Valid_Index_And_Score) -> bool {
					return a.score > b.score
				})
				best_score := valids[0].score
				for i := 1; i < valid_count; i += 1 {
					if best_score > valids[i].score {
						valid_count = i
						break
					}
					best_score = valids[i].score
				}
				first_success_index = valids[0].index
			}

			type_str := type_to_string(target_type)

			if valid_count == 1 {
				// Exactly one matching variant
				// C++ Reference: check_expr.cpp:4869-4881
				new_type := union_type.variants[first_success_index]
				t = new_type

				if is_type_union(new_type) {
					// Nested union - recursive convert
					convert_to_typed(ctx, operand, new_type)
					return
				}

				operand.type = new_type
				if operand.mode != .Constant || !elem_type_can_be_constant(operand.type) {
					operand.mode = .Value
				}
				// Break out of switch, fall through to final type update
			} else if valid_count > 1 {
				// Ambiguous - multiple variants match equally well
				// C++ Reference: check_expr.cpp:4882-4905
				assert(first_success_index >= 0)
				operand.mode = .Invalid
				convert_untyped_error(ctx, operand, target_type)

				// Build error message with ambiguous variants
				sb := strings.builder_make(context.temp_allocator)
				strings.write_string(&sb, "Ambiguous type conversion to '")
				strings.write_string(&sb, type_str)
				strings.write_string(&sb, "', which variant did you mean:\n\t")
				for i := 0; i < valid_count; i += 1 {
					if i > 0 && valid_count > 2 {
						strings.write_string(&sb, ", ")
					}
					if i == valid_count - 1 {
						if valid_count == 2 {
							strings.write_string(&sb, " ")
						}
						strings.write_string(&sb, "or ")
					}
					var_str := type_to_string(union_type.variants[valids[i].index])
					strings.write_string(&sb, "'")
					strings.write_string(&sb, var_str)
					strings.write_string(&sb, "'")
				}
				error(operand.expr, "%s", strings.to_string(sb))
				return
			} else if is_type_untyped_uninit(operand.type) {
				// uninit can convert to union
				t = t_untyped_uninit
			} else if !is_type_untyped_nil(operand.type) || !type_has_nil(target_type) {
				// No matching variant found
				// C++ Reference: check_expr.cpp:4908-4933
				operand.mode = .Invalid
				convert_untyped_error(ctx, operand, target_type)

				if variant_count > 0 {
					// List valid variants
					sb := strings.builder_make(context.temp_allocator)
					strings.write_string(&sb, "'")
					strings.write_string(&sb, type_str)
					strings.write_string(&sb, "' is a union which only accepts the following types:\n\t")
					for v, i in union_type.variants {
						if i > 0 && variant_count > 2 {
							strings.write_string(&sb, ", ")
						}
						if i == variant_count - 1 {
							if variant_count == 2 {
								strings.write_string(&sb, " ")
							}
							if variant_count > 1 {
								strings.write_string(&sb, "or ")
							}
						}
						var_str := type_to_string(v)
						strings.write_string(&sb, "'")
						strings.write_string(&sb, var_str)
						strings.write_string(&sb, "'")
					}
					error(operand.expr, "%s", strings.to_string(sb))
				}
				return
			}
		}
		// nil and uninit can convert to unions - fall through

	case:
		// Default case: handle nil/uninit special values
		if is_type_untyped_uninit(operand.type) {
			t = t_untyped_uninit
		} else if o_type := operand.type; o_type != nil && o_type == t_untyped_nil && type_has_nil(target_type) {
			t = t_untyped_nil
		} else {
			operand.mode = .Invalid
			convert_untyped_error(ctx, operand, target_type)
			return
		}
	}

	// Determine final target type
	final_type := target_type

	// Special case: any type with untyped values
	if is_type_any(target_type) && is_type_untyped(operand.type) {
		if !is_type_untyped_uninit(operand.type) && operand.type != t_untyped_nil {
			// Convert to default typed version before wrapping in any
			final_type = default_type(operand.type)
		}
	} else if t == t_untyped_uninit || t == t_untyped_nil {
		// Only use the modified t for nil/uninit special cases in the default switch case
		final_type = t
	}

	// Update the operand's type and expression metadata
	update_untyped_expr_type(ctx, operand.expr, final_type, true)
	operand.type = final_type
}

// check_expr is a wrapper that calls check_expr_base
// Reference: /mnt/c/odin/src/check_expr.cpp:11767-11779
check_expr :: proc(ctx: ^Checker_Context, o: ^Operand, node: ^ast.Node) {
	check_expr_base(ctx, o, node, nil)
}

// check_expr_with_type_hint checks an expression with an optional type hint
// and ensures it's a valid value (not a type, builtin, or no-value)
// Reference: /mnt/c/odin/src/check_expr.cpp:8421-8443
check_expr_with_type_hint :: proc(ctx: ^Checker_Context, o: ^Operand, node: ^ast.Node, type_hint: ^Type) {
	check_expr_base(ctx, o, node, type_hint)
	check_not_tuple(ctx, o)

	// Check for invalid operand modes
	err_str: string = ""
	#partial switch o.mode {
	case .No_Value:
		err_str = "used as a value"
	case .Type:
		// Types are only allowed if type_hint is typeid
		if type_hint == nil || !is_type_typeid(type_hint) {
			err_str = "is not an expression but a type, in this context it is ambiguous"
		}
	case .Builtin:
		err_str = "must be called"
	}

	if err_str != "" {
		expr_str := expr_to_string(node)
		defer delete(expr_str)
		error(node, "'%s' %s", expr_str, err_str)
		o.mode = .Invalid
	}
}

// check_expr_or_type checks an expression that could be either a value or a type
// Reference: /mnt/c/odin/src/check_expr.cpp:11848-11852
check_expr_or_type :: proc(ctx: ^Checker_Context, o: ^Operand, node: ^ast.Node, type_hint: ^Type = nil) {
	check_expr_base(ctx, o, node, type_hint)
	check_not_tuple(ctx, o)
	error_operand_no_value(o)
}

// check_multi_expr_or_type checks an expression that can yield multiple values
// Unlike check_expr_or_type, this does NOT call check_not_tuple because
// multi-value returns (tuples) are allowed in this context
// C++ Reference: check_expr.cpp (various locations)
check_multi_expr_or_type :: proc(ctx: ^Checker_Context, o: ^Operand, node: ^ast.Node, type_hint: ^Type = nil) {
	check_expr_base(ctx, o, node, type_hint)
	// Note: we intentionally skip check_not_tuple to allow multi-value returns
	error_operand_no_value(o)
}

// check_not_tuple ensures an operand is not a tuple value
// Tuples are not first-class values in Odin
// C++ Reference: check_expr.cpp:11789-11800
check_not_tuple :: proc(ctx: ^Checker_Context, o: ^Operand) {
	if o.mode == .Value && o.type != nil && o.type.kind == .Tuple {
		tuple := o.type.variant.(Type_Tuple)
		count := len(tuple.variables)
		error(o.expr, "%d-valued expression found where single value expected", count)
		o.mode = .Invalid
	}
}

// error_operand_not_expression checks if operand is a type instead of expression
// C++ Reference: check_expr.cpp:280-287
error_operand_not_expression :: proc(o: ^Operand) {
	if o.mode == .Type {
		expr_str := expr_to_string(o.expr)
		defer delete(expr_str)
		error(o.expr, "'%s' is not an expression but a type", expr_str)
		o.mode = .Invalid
	}
}

// error_operand_no_value checks if an operand has no value and reports an error
// Some expressions like panic/assert are allowed to have no value
// Reference: /mnt/c/odin/src/check_expr.cpp:289-311
error_operand_no_value :: proc(o: ^Operand) {
	if o.mode == .No_Value {
		x := unparen_expr(o.expr)

		// Check if this is a panic or assert directive - these are allowed to have no value
		if x != nil {
			if call, ok := x.derived.(^ast.Call_Expr); ok {
				if proc_expr := unparen_expr(call.expr); proc_expr != nil {
					if directive, is_directive := proc_expr.derived.(^ast.Basic_Directive); is_directive {
						tag := directive.name
						if tag == "panic" || tag == "assert" {
							return
						}
					}
				}
			}
		}

		// Report appropriate error message
		if x != nil {
			if _, is_call := x.derived.(^ast.Call_Expr); is_call {
				// C++ Reference: check_expr.cpp:312 -- names the call expression.
				nv_call := expr_to_string(o.expr)
				defer delete(nv_call)
				error(o.expr, "'%s' call does not return a value and cannot be used as a value", nv_call)
			} else {
				error(o.expr, "Expression used as a value but has no value")
			}
		} else {
			// C++ Reference: check_expr.cpp:2078
			nv_str := expr_to_string(o.expr)
			defer delete(nv_str)
			error(o.expr, "Expression has no value '%s'", nv_str)
		}
		o.mode = .Invalid
	}
}

// check_multi_expr_with_type_hint checks a multi-valued expression with type hint
// Reference: /mnt/c/odin/src/check_expr.cpp:11814-11827
check_multi_expr_with_type_hint :: proc(ctx: ^Checker_Context, o: ^Operand, node: ^ast.Node, type_hint: ^Type) {
	check_expr_base(ctx, o, node, type_hint)
	#partial switch o.mode {
	case .No_Value:
		error_operand_no_value(o)
	case .Type:
		error_operand_not_expression(o)
	case:
		// Valid - all other modes allowed
		return
	}
}

// get_constant_field_value extracts a field value from a constant compound literal
// C++ Reference: check_expr.cpp:5810-5830
// Returns the value and true if one was found and is constant.
//
// NOTE: this used to return ^Exact_Value, taken as `&tv.value` from a Type_And_Value that a map
// lookup had already copied onto this frame - i.e. a pointer to a dead stack slot, dereferenced
// by every caller. It returns by value now; there is nothing in the map worth aliasing.
get_constant_field_value :: proc(ctx: ^Checker_Context, comp_lit: ^ast.Comp_Lit, field_idx: int, struct_type: ^Type) -> (value: Exact_Value, ok: bool) {
	if comp_lit == nil || field_idx < 0 {
		return {}, false
	}

	elems := comp_lit.elems
	if len(elems) == 0 {
		return {}, false
	}

	// Get struct field info to understand the layout
	bt := base_type(struct_type)
	if bt == nil || bt.kind != .Struct {
		return {}, false
	}
	struct_info := bt.variant.(Type_Struct)

	// Check if elements are named (Field_Value) or positional
	first_elem := elems[0]
	if first_elem == nil {
		return {}, false
	}

	target_elem: ^ast.Expr = nil

	if _, is_field_value := first_elem.derived.(^ast.Field_Value); is_field_value {
		// Named elements - find the one matching our field
		if field_idx < len(struct_info.fields) {
			field_entity := struct_info.fields[field_idx]
			field_name := field_entity.token.text

			for elem in elems {
				if fv, is_fv := elem.derived.(^ast.Field_Value); is_fv {
					if ident, is_ident := fv.field.derived.(^ast.Ident); is_ident {
						if ident.name == field_name {
							target_elem = fv.value
							break
						}
					}
				}
			}
		}
	} else {
		// Positional elements - use index directly
		if field_idx < len(elems) {
			target_elem = elems[field_idx]
		}
	}

	if target_elem == nil {
		return {}, false
	}

	// Get the type_and_value of the target element
	if tv, found := tav_lookup(ctx.info, target_elem); found {
		if tv.mode == .Constant {
			return tv.value, true
		}
	}

	return {}, false
}

// get_constant_array_element_value extracts an element value from a constant array compound literal
// C++ Reference: check_expr.cpp:11110-11128
// Returns the value and true if one was found and is constant. See get_constant_field_value for
// why this returns by value rather than by pointer.
get_constant_array_element_value :: proc(ctx: ^Checker_Context, comp_lit: ^ast.Comp_Lit, elem_idx: i64) -> (value: Exact_Value, ok: bool) {
	if comp_lit == nil || elem_idx < 0 {
		return {}, false
	}

	elems := comp_lit.elems
	if len(elems) == 0 || elem_idx >= i64(len(elems)) {
		return {}, false
	}

	// Array elements are always positional (unlike struct fields which can be named)
	target_elem := elems[elem_idx]
	if target_elem == nil {
		return {}, false
	}

	// Get the type_and_value of the target element
	if tv, found := tav_lookup(ctx.info, target_elem); found {
		if tv.mode == .Constant {
			return tv.value, true
		}
	}

	return {}, false
}

// get_constant_field_single extracts a single element from a constant value by index
// C++ Reference: check_expr.cpp:2319-2325
// Works with constant strings (returns rune) and arrays (returns element value)
// Returns the extracted value, or nil if not extractable
get_constant_field_single :: proc(ctx: ^Checker_Context, value: Exact_Value, type: ^Type, index: i64) -> Exact_Value {
	if value == nil {
		return nil
	}

	bt := base_type(type)
	if bt == nil {
		return nil
	}

	// Handle string constants - return the rune at index
	if is_type_string(bt) {
		if str, is_str := value.(string); is_str {
			// Get rune at index (rune-based indexing)
			rune_idx: i64 = 0
			for r in str {
				if rune_idx == index {
					// Return the rune value as an integer
					result: big.Int
					big.internal_int_set_from_integer(&result, i64(r), false)
					return result
				}
				rune_idx += 1
			}
		}
		return nil
	}

	// Handle array constants from compound literals
	if is_type_array(bt) || is_type_enumerated_array(bt) {
		// For compound literal values, we need the expression context
		// This case is handled by get_constant_array_element_value
		// Here we handle the case where we have a direct Exact_Value_Compound
		if compound, is_compound := value.(Exact_Value_Compound); is_compound {
			if compound.expr != nil {
				if comp_lit, ok := compound.expr.derived.(^ast.Comp_Lit); ok {
					if elem, has_elem := get_constant_array_element_value(ctx, comp_lit, index); has_elem {
						return elem
					}
				}
			}
		}
		return nil
	}

	return nil
}

// parse_swizzle_name parses a swizzle selector name (e.g., "xyz", "rgb")
// Returns: (valid, packed_indices, count)
// - valid: true if the name is a valid swizzle pattern
// - packed_indices: 2 bits per component (0=x/r, 1=y/g, 2=z/b, 3=w/a)
// - count: number of swizzle components (1-4)
// Reference: /mnt/c/odin/src/check_expr.cpp:5680-5720
parse_swizzle_name :: proc(name: string, max_count: i64) -> (valid: bool, indices: u8, count: u8) {
	if len(name) == 0 || len(name) > 4 {
		return false, 0, 0
	}

	// Determine which swizzle set is being used (xyzw or rgba)
	// All letters must be from the same set
	use_xyzw := false
	use_rgba := false

	for c in name {
		switch c {
		case 'x', 'y', 'z', 'w':
			use_xyzw = true
		case 'r', 'g', 'b', 'a':
			use_rgba = true
		case:
			return false, 0, 0 // Invalid character
		}
	}

	// Can't mix xyzw and rgba
	if use_xyzw && use_rgba {
		return false, 0, 0
	}

	// Parse each character into an index
	packed: u8 = 0
	for c, i in name {
		idx: u8 = 0
		switch c {
		case 'x', 'r':
			idx = 0
		case 'y', 'g':
			idx = 1
		case 'z', 'b':
			idx = 2
		case 'w', 'a':
			idx = 3
		}

		// Check index is within bounds
		if i64(idx) >= max_count {
			return false, 0, 0
		}

		// Pack the index (2 bits per component)
		packed |= idx << (u8(i) * 2)
	}

	return true, packed, u8(len(name))
}

// check_selector handles selector expressions (x.y)
// Ported from check_expr.cpp:5474-5873
//
// Implemented:
// - Import name access (package.symbol)
// - Basic struct field access (struct.field)
// - Enum value access (Enum.Value)
// - Pointer-to-struct automatic dereferencing
// - Error reporting for missing fields
//
// Implemented: SOA access, array swizzle (.xyzw, .rgba), bit field flag propagation, field suggestions
// -> operator validated (error outside call context), field did-you-mean suggestions
check_selector :: proc(ctx: ^Checker_Context, operand: ^Operand, node: ^ast.Node, type_hint: ^Type) -> ^Entity {
	se, ok := node.derived.(^ast.Selector_Expr)
	if !ok {
		operand.mode = .Invalid
		operand.expr = node
		return nil
	}

	check_op_expr := true
	expr_entity: ^Entity = nil
	entity: ^Entity = nil
	sel: Selection = {} // Not used if it's an import name

	// Arrow operator (->) validation
	// Reference: check_expr.cpp:5480-5493
	if !ctx.allow_arrow_right_selector_expr && se.op.kind == .Arrow_Right {
		error_node(node, "Illegal use of -> selector shorthand outside of a call")
		x_str := expr_to_string(se.expr)
		defer delete(x_str)
		y_str := se.field.name if se.field != nil else "<unknown>"
		error_line("\tSuggestion: Did you mean '%s.%s'?", x_str, y_str)
		// Continue checking to gather more diagnostics
	}

	operand.expr = node

	op_expr := se.expr
	selector := unparen_expr(se.field)
	if selector == nil {
		operand.mode = .Invalid
		operand.expr = node
		return nil
	}

	if _, ok2 := selector.derived.(^ast.Ident); !ok2 {
		error(selector, "Illegal selector kind - must be an identifier")
		operand.mode = .Invalid
		operand.expr = node
		return nil
	}

	// Special handling for import name access (package.symbol)
	if op_ident, is_ident := op_expr.derived.(^ast.Ident); is_ident {
		op_name := op_ident.name
		e := scope_lookup(ctx.scope, op_name)
		add_entity_use(ctx, op_expr, e)
		expr_entity = e

		// Check if this is a procedure/proc group (error case)
		if e != nil && (e.kind == .Procedure || e.kind == .Proc_Group) {
			if selector_ident, ok2 := selector.derived.(^ast.Ident); ok2 {
				error(node, "'%s' is not declared by '%s'", selector_ident.name, e.token.text)
			}
			operand.mode = .Invalid
			operand.expr = node
			return nil
		}

		// Check if this is an import name
		if e != nil && e.kind == .Import_Name {
			if selector_ident, ok2 := selector.derived.(^ast.Ident); ok2 {
				import_name := op_name
				import_entity := e.variant.(Entity_Import_Name)
				import_scope := import_entity.scope
				entity_name := selector_ident.name

				if import_scope == nil {
					error(node, "'%s' is not imported in this file, '%s' is unavailable", import_name, entity_name)
					operand.mode = .Invalid
					operand.expr = node
					return nil
				}

				check_op_expr = false
				entity = scope_lookup_current(import_scope, entity_name)

				// Validate entity is declared and exported
				allow_builtin := false
				if entity != nil && !is_entity_declared_for_selector(entity, import_scope, &allow_builtin) {
					entity = nil
				}

				// C++ Reference: check_expr.cpp:5554-5561
				// Check if the entity is exported from its package
				if entity != nil && !allow_builtin && !is_entity_exported(entity, false) {
					error(node, "'%s' is not exported by '%s'", entity_name, import_name)
					operand.mode = .Invalid
					operand.expr = node
					return nil
				}

				if entity == nil {
					// C++ check_expr.cpp:5927-5935. check_did_you_mean_scope was ported
					// (error.odin:1801) but never called from anywhere; C++ has exactly one
					// call site and it is this one, so the suggestion block never appeared
					// for a misspelled package member.
					begin_error_block()
					defer end_error_block()

					error(node, "'%s' is not declared by '%s'", entity_name, import_name)
					operand.mode = .Invalid
					operand.expr = node

					check_did_you_mean_scope(entity_name, import_scope)
					return nil
				}

				check_entity_decl(ctx, entity, nil, nil)

				if entity.kind == .Proc_Group {
					operand.mode = .Proc_Group
					operand.proc_group = entity
					add_type_and_value(ctx, operand.expr, operand.mode, operand.type, operand.value)
					return entity
				}

				// Handle builtin entities (e.g., intrinsics.trap)
				// Builtins have t_invalid type but are valid - let later code handle them
				if entity.kind == .Builtin {
					builtin := entity.variant.(Entity_Builtin)
					operand.mode = .Builtin
					operand.builtin_id = builtin.id
					operand.type = t_invalid
					operand.expr = node
					add_entity_use(ctx, selector, entity)
					// Set entity on the selector field so entity_of_node can find it
					set_entity_for_node(&ctx.checker.info, selector, entity)
					add_type_and_value(ctx, operand.expr, operand.mode, operand.type, operand.value)
					return entity
				}

				// Set operand for imported entity
				entity_type := get_entity_type(entity)
				if entity_type == nil {
					error(node, "Imported entity '%s' has no type", entity_name)
					operand.mode = .Invalid
					operand.expr = node
					return nil
				}
			}
		}
	}

	// Check the operand expression if not an import name
	if check_op_expr {
		check_expr_base(ctx, operand, op_expr, nil)
		if operand.mode == .Invalid {
			operand.mode = .Invalid
			operand.expr = node
			return nil
		}
	}

	// SOA type completion - ensure fields are generated before access
	// Reference: check_expr.cpp:7620-7625
	if operand.type != nil {
		deref_t := type_deref(operand.type)
		if deref_t != nil && is_type_soa_struct(deref_t) {
			complete_soa_type(ctx.checker, deref_t, true)
		}
	}

	// Perform field lookup
	if entity == nil {
		if selector_ident, ok2 := selector.derived.(^ast.Ident); ok2 {
			field_name := selector_ident.name
			t := type_deref(operand.type)

			if t == nil {
				error(operand.expr, "Cannot use a selector expression on nil-value expression")
				operand.mode = .Invalid
				operand.expr = node
				return nil
			}

			// Initialize allocator type if accessing dynamic array fields (e.g., .allocator)
			// C++ Reference: check_expr.cpp:7636-7638
			if is_type_dynamic_array(type_deref(operand.type)) {
				init_mem_allocator(ctx.checker)
			}

			sel = lookup_field(operand.type, field_name, operand.mode == .Type)
			entity = sel.entity

			if entity != nil && .Type_Field in entity.flags {
				add_type_info_type(ctx, operand.type)
			}

			if is_type_enum(operand.type) {
				add_type_info_type(ctx, operand.type)
			}
		}
	}

	// Array/SIMD swizzle operations (.xyzw, .rgba)
	// Reference: /mnt/c/odin/src/check_expr.cpp:5680-5780
	if entity == nil && operand.type != nil {
		if selector_ident, ok_swizzle := selector.derived.(^ast.Ident); ok_swizzle {
			deref_type := type_deref(operand.type)
			base := base_type(deref_type)

			is_array := base != nil && base.kind == .Array
			is_simd := base != nil && base.kind == .Simd_Vector

			if is_array || is_simd {
				swizzle_name := selector_ident.name
				max_count: i64 = 0
				elem_type: ^Type = nil

				if is_array {
					arr := base.variant.(Type_Array)
					max_count = arr.count
					elem_type = arr.elem
				} else {
					simd := base.variant.(Type_Simd_Vector)
					max_count = simd.count
					elem_type = simd.elem
				}

				// Parse swizzle letters and validate
				swizzle_valid, swizzle_indices, swizzle_count := parse_swizzle_name(swizzle_name, max_count)

				if swizzle_valid && swizzle_count > 0 {
					// SIMD vectors have restrictions
					if is_simd {
						// SIMD swizzle count must be power of two
						if !is_power_of_two(i64(swizzle_count)) {
							error_node(selector, "Swizzle of #simd vector must select a power of two elements, got %d", swizzle_count)
							operand.mode = .Invalid
							operand.expr = node
							return nil
						}
						// Single element SIMD swizzle not allowed via selector
						if swizzle_count == 1 {
							error_node(selector, "A single element swizzle is not allowed on a #simd type, use indexing")
							operand.mode = .Invalid
							operand.expr = node
							return nil
						}
					}

					// Set selection swizzle info
					sel.swizzle_count = swizzle_count
					sel.swizzle_indices = swizzle_indices

					// Determine result type
					if swizzle_count == 1 {
						// Single element swizzle returns the element type
						operand.type = elem_type
						if operand.mode == .Variable {
							operand.mode = .Swizzle_Variable
						} else {
							operand.mode = .Swizzle_Value
						}
					} else {
						// Multi-element swizzle returns array/simd type
						operand.type = determine_swizzle_array_type(deref_type, type_hint, i64(swizzle_count))
						if is_array {
							if operand.mode == .Variable {
								operand.mode = .Swizzle_Variable
							} else {
								operand.mode = .Swizzle_Value
							}
						} else {
							operand.mode = .Value // SIMD swizzle is always a value
						}
					}

					operand.expr = node
					add_type_and_value(ctx, operand.expr, operand.mode, operand.type, operand.value, sel.is_bit_field)
					return nil // No entity for swizzle
				}
			}
		}
	}

	// Entity not found - report error
	if entity == nil {
		op_str := expr_to_string(op_expr)
		defer delete(op_str)
		type_str := type_to_string_shorthand(operand.type)
		// NOTE: defer delete removed - type_to_string uses temp_allocator internally
		// defer delete(type_str)

		// Extract selector name from identifier
		sel_str := "<unknown>"
		if selector_ident, ok_ident := selector.derived.(^ast.Ident); ok_ident {
			sel_str = selector_ident.name
		}

		if operand.mode == .Type {
			error_node(op_expr, "'%s' of type '%s' has no field '%s'", op_str, type_str, sel_str)
		} else {
			// Use error block to keep error value alive for did-you-mean suggestions
			begin_error_block()
			error_node(op_expr, "'%s' of type '%s' has no field '%s'", op_str, type_str, sel_str)

			// Add did-you-mean suggestions for struct fields
			if operand.type != nil && sel_str != "<unknown>" {
				bt := base_type(operand.type)
				if bt != nil && bt.kind == .Struct {
					st := bt.variant.(Type_Struct)
					check_did_you_mean_type(sel_str, st.fields[:])
				}
			}
			end_error_block()
		}
		operand.mode = .Invalid
		operand.type = t_invalid  // Set type to invalid to prevent garbage access
		operand.expr = node
		return nil
	}

	// Constant field access from constant structs
	// C++ Reference: check_expr.cpp:5810-5830
	// If the operand is a constant struct/array, extract the field value
	if operand.mode == .Constant && entity != nil && len(sel.index) > 0 {
		if compound, is_compound := operand.value.(Exact_Value_Compound); is_compound {
			if compound.expr != nil {
				if comp_lit, is_comp := compound.expr.derived.(^ast.Comp_Lit); is_comp {
					field_idx := sel.index[0]
					field_value, has_field_value := get_constant_field_value(ctx, comp_lit, int(field_idx), operand.type)
					if has_field_value {
						operand.value = field_value
						// Mode stays Constant, type will be set below from entity
					}
				}
			}
		}
	}

	if expr_entity != nil && is_type_polymorphic(expr_entity.type) {
		error(op_expr, "Cannot access field from non-specialized polymorphic type")
		operand.mode = .Invalid
		return nil
	}

	add_entity_use(ctx, selector, entity)

	operand.type = get_entity_type(entity)
	operand.expr = node

	// Add runtime dependencies for bit field access
	// C++ Reference: check_expr.cpp:5833-5836
	if .Bit_Field_Field in entity.flags {
		add_package_dependency(ctx, "runtime", "__write_bits")
		add_package_dependency(ctx, "runtime", "__read_bits")
	}

	// Set operand mode based on entity kind
	#partial switch entity.kind {
	case .Constant:
		constant := entity.variant.(Entity_Constant)
		operand.value = constant.value

		// C++ Reference: check_expr.cpp:5840-5845
		// Check for procedure constant - unwrap to get actual procedure entity
		if proc_value, is_proc := operand.value.(Exact_Value_Procedure); is_proc {
			proc_entity := strip_entity_wrapping(ctx, proc_value.expr)
			if proc_entity != nil {
				operand.mode = .Value
				operand.type = proc_entity.type
			}
		} else {
			operand.mode = .Constant
		}

	case .Variable:
		// Determine addressing mode based on selection properties
		if sel.indirect {
			operand.mode = .Variable
		} else if operand.mode == .Context {
			// Keep mode as Context
		} else if operand.mode == .Map_Index {
			operand.mode = .Value
		} else if operand.mode == .Optional_Ok {
			operand.mode = .Value
		} else if operand.mode == .Soa_Variable {
			operand.mode = .Variable
		} else if operand.mode != .Value {
			operand.mode = .Variable
		} else {
			operand.mode = .Value
		}

	// SOA pointer field handling
	// Reference: check_expr.cpp:5800-5803
	if .Soa_Ptr_Field in entity.flags {
		operand.mode = .Soa_Variable
	}

	// NOTE: Bit field flag is propagated via add_type_and_value at the end of this function
	// using sel.is_bit_field - this allows check_is_not_addressable to detect nested
	// bit field accesses even when the final entity isn't itself a bit field.

	case .Builtin:
		// Builtins accessed through type
		operand.mode = .Builtin
		operand.builtin_id = entity.variant.(Entity_Builtin).id

	case .Type_Name:
		operand.mode = .Type

	case .Proc_Group:
		operand.mode = .Proc_Group
		operand.proc_group = entity

	case .Procedure:
		// Procedure accessed through import (e.g., runtime.some_proc)
		operand.mode = .Value

	case:
		error(node, "Unexpected entity kind in selector expression: %v", entity.kind)
		operand.mode = .Invalid
		operand.expr = node
		return nil
	}

	add_type_and_value(ctx, operand.expr, operand.mode, operand.type, operand.value, sel.is_bit_field)

	return entity
}

// Index Expression Support
// These functions implement array/slice/map indexing (x[i])
// Reference: /mnt/c/odin/src/check_expr.cpp:8446-8562, 4966-5070, 11009-11136

// check_set_index_data sets the operand mode and type after indexing
// For each indexable type, it determines:
// - The element type (operand.type)
// - The addressing mode (operand.mode)
// - The max_count for bounds checking (if applicable)
// Ported from check_expr.cpp:8446-8562
// NOTE: SOA indexing and Matrix indexing are implemented
check_set_index_data :: proc(operand: ^Operand, t: ^Type, indirection: bool, max_count: ^i64, original_type: ^Type) -> bool {
	#partial switch t.kind {
	case .Basic:
		basic := t.variant.(Type_Basic)
		if basic.kind == .String {
			if operand.mode == .Constant {
				// For constant strings, we know the length at compile time
				if str, ok := operand.value.(string); ok {
					max_count^ = i64(len(str))
				}
			}
			if operand.mode != .Constant {
				operand.mode = .Value
			}
			operand.type = t_u8
			return true
		} else if basic.kind == .String16 {
			// C++ Reference: check_expr.cpp:9054-9063. `string16` indexes to u16.
			//
			// This arm EXISTED but was nested inside the `.Untyped_String` branch below,
			// guarded by `basic.kind == .String16` — a condition that can never hold once
			// `basic.kind == .Untyped_String` has already matched. It was dead code, so
			// every `s[i]` on a string16 reported "Cannot index 's' of type 'string16'".
			if operand.mode == .Constant {
				if s16_val, ok := operand.value.(Exact_Value_String16); ok {
					max_count^ = i64(s16_val.len)
				}
			}
			if operand.mode != .Constant {
				operand.mode = .Value
			}
			operand.type = t_u16
			return true
		} else if basic.kind == .Untyped_String {
			// C++ Reference: check_expr.cpp:9064-9071 — indexable only when constant.
			if operand.mode == .Constant {
				if str, ok := operand.value.(string); ok {
					max_count^ = i64(len(str))
				}
				operand.type = t_u8
				return true
			}
			return false
		}

	case .Multi_Pointer:
		mp := t.variant.(Type_Multi_Pointer)
		operand.type = mp.elem
		if operand.mode != .Constant {
			operand.mode = .Variable
		}
		return true

	case .Array:
		arr := t.variant.(Type_Array)
		max_count^ = arr.count
		if indirection {
			operand.mode = .Variable
		} else if operand.mode != .Variable && operand.mode != .Constant {
			operand.mode = .Value
		}
		operand.type = arr.elem
		return true

	case .Enumerated_Array:
		earr := t.variant.(Type_Enumerated_Array)
		max_count^ = earr.count
		if indirection {
			operand.mode = .Variable
		} else if operand.mode != .Variable && operand.mode != .Constant {
			operand.mode = .Value
		}
		operand.type = earr.elem
		return true

	case .Matrix:
		// Matrix indexing returns an array (vector)
		// Reference: check_expr.cpp:8572-8585
		mat := t.variant.(Type_Matrix)
		if indirection {
			operand.mode = .Variable
		} else if operand.mode != .Variable {
			operand.mode = .Value
		}
		// For row major: index by row, returns column_count-element array
		// For column major: index by column, returns row_count-element array
		if mat.is_row_major {
			max_count^ = mat.row_count
			operand.type = alloc_type_array(mat.elem, mat.column_count)
		} else {
			max_count^ = mat.column_count
			operand.type = alloc_type_array(mat.elem, mat.row_count)
		}
		return true

	case .Slice:
		slice := t.variant.(Type_Slice)
		operand.type = slice.elem
		if operand.mode != .Constant {
			operand.mode = .Variable
		}
		return true

	case .Dynamic_Array:
		dyn := t.variant.(Type_Dynamic_Array)
		operand.type = dyn.elem
		if operand.mode != .Constant {
			operand.mode = .Variable
		}
		return true

	case .Fixed_Capacity_Dynamic_Array:
		// C++ Reference: check_expr.cpp:9132-9133 — indexes exactly like [dynamic]T.
		fc := t.variant.(Type_Fixed_Capacity_Dynamic_Array)
		operand.type = fc.elem
		if operand.mode != .Constant {
			operand.mode = .Variable
		}
		return true

	case .Struct:
		strct := &t.variant.(Type_Struct)
		// SOA (Structure-of-Arrays) indexing
		// Reference: check_expr.cpp:8537-8548
		// Indexing a SOA struct returns the element type (original struct)
		if strct.soa_kind != .None {
			// For #soa[N]T, indexing returns T
			operand.type = strct.soa_elem
			operand.mode = .Soa_Variable
			// C++ lines 8544-8546: Set max_count for bounds checking
			if max_count != nil {
				if strct.soa_kind == .Fixed {
					max_count^ = strct.soa_count
				} else {
					max_count^ = -1 // Slice/Dynamic: no compile-time bound
				}
			}
			return true
		}
		return false
	}

	// Special case: SOA pointer with multi-pointer indirection
	// Reference: check_expr.cpp:8552-8559
	if is_type_pointer(original_type) && indirection {
		// Check if the dereferenced type is a SOA struct
		ptr_type := base_type(original_type)
		if ptr, ok := ptr_type.variant.(Type_Pointer); ok {
			pointed := base_type(ptr.elem)
			if pointed != nil && pointed.kind == .Struct {
				strct := &pointed.variant.(Type_Struct)
				if strct.soa_kind != .None {
					operand.type = strct.soa_elem
					operand.mode = .Soa_Variable
					if max_count != nil {
						if strct.soa_kind == .Fixed {
							max_count^ = strct.soa_count
						} else {
							max_count^ = -1
						}
					}
					return true
				}
			}
		}
	}

	return false
}

// check_index_value validates an index expression and performs bounds checking
// Returns true if the index is valid, false otherwise
// If value is not nil, it's set to the constant index value (if applicable)
// Ported from check_expr.cpp:4966-5082
check_index_value :: proc(ctx: ^Checker_Context, main_type: ^Type, open_range: bool, index_value: ^ast.Node, max_count: i64, value: ^i64, type_hint: ^Type = nil) -> bool {
	operand: Operand
	check_expr_or_type(ctx, &operand, index_value, type_hint)

	if operand.mode == .Invalid {
		if value != nil {
			value^ = 0
		}
		// NOTE: return true here to propagate the errors better
		return true
	}

	index_type := t_int
	if type_hint != nil {
		index_type = type_hint
	}
	convert_to_typed(ctx, &operand, index_type)

	if operand.mode == .Invalid {
		if value != nil {
			value^ = 0
		}
		return false
	}

	// Check type constraints
	if type_hint != nil {
		// For enumerated arrays, index must match the enum type
		if !check_is_assignable_to(ctx, &operand, type_hint) {
			// C++ Reference: check_expr.cpp:4987-4993
			expr_str := expr_to_string(operand.expr)
			defer delete(expr_str)
			got_type_str := type_to_string(operand.type)
			want_type_str := type_to_string(type_hint)
			error(operand.expr, "Expected index of type '%s' for '%s', got '%s'", want_type_str, expr_str, got_type_str)
			if value != nil {
				value^ = 0
			}
			return false
		}
	} else if !is_type_integer(operand.type) && !is_type_enum(operand.type) {
		// C++ Reference: check_expr.cpp:4996-5002
		expr_str := expr_to_string(operand.expr)
		defer delete(expr_str)
		type_str := type_to_string(operand.type)
		error(operand.expr, "Index '%s' must be an integer, got '%s'", expr_str, type_str)
		if value != nil {
			value^ = 0
		}
		return false
	}

	// Bounds checking for constant indices
	if operand.mode == .Constant && .No_Bounds_Check not_in ctx.state_flags {
		// Reference: check_expr.cpp:5005-5006

		// Extract integer value from Exact_Value
		// Note: Exact_Value uses big.Int for all integers, not i64/u64
		idx: i64 = -1
		if int_val, ok := operand.value.(big.Int); ok {
			// Convert big.Int to i64 with overflow check
			// Reference: check_expr.cpp:4995-5005
			idx_i128, err := big.int_get_i128(&int_val)
			if err != nil {
				error(operand.expr, "Index value too large")
				if value != nil {
					value^ = 0
				}
				return false
			}
			// Check if value fits in i64
			if idx_i128 > i128(max(i64)) || idx_i128 < i128(min(i64)) {
				error(operand.expr, "Index value out of range for i64")
				if value != nil {
					value^ = 0
				}
				return false
			}
			idx = i64(idx_i128)
		}

		// Check for negative indices (not allowed except for multi-pointers and enums)
		// C++ Reference: check_expr.cpp:5008-5015
		if idx < 0 && !is_type_multi_pointer(main_type) && !is_type_enum(operand.type) {
			error(operand.expr, "Index cannot be a negative value")
			if value != nil {
				value^ = 0
			}
			return false
		}

		// Array bounds checking
		if max_count >= 0 {
			// Check if index is enum type - use enum range checking
			// C++ Reference: check_expr.cpp:5016-5053
			if is_type_enum(operand.type) {
				bt := base_type(operand.type)
				assert(bt.kind == .Enum)
				en := bt.variant.(Type_Enum)

				lo := en.min_value
				hi := en.max_value

				// Get field names for better error messages
				lo_str := ""
				hi_str := ""
				if len(en.fields) > 0 {
					lo_idx := clamp(en.min_value_index, 0, i64(len(en.fields) - 1))
					hi_idx := clamp(en.max_value_index, 0, i64(len(en.fields) - 1))
					lo_str = en.fields[lo_idx].token.text
					hi_str = en.fields[hi_idx].token.text
				}

				out_of_bounds := false
				if compare_exact_values(.Lt, operand.value, lo) || compare_exact_values(.Gt, operand.value, hi) {
					out_of_bounds = true
				}

				if out_of_bounds {
					expr_str := expr_to_string(operand.expr)
					defer delete(expr_str)
					if len(lo_str) > 0 {
						error(operand.expr, "Index '%s' is out of bounds range %s ..= %s", expr_str, lo_str, hi_str)
					} else {
						type_str := type_to_string(operand.type)
						error(operand.expr, "Index '%s' is out of bounds range of enum type %s", expr_str, type_str)
					}
					return false
				}

				// Return adjusted value (index - min_value)
				if value != nil {
					diff := exact_value_sub(operand.value, lo)
					value^ = exact_value_to_i64(diff)
				}
				return true
			}

			// Basic array bounds checking
			// C++ Reference: check_expr.cpp:5054-5079
			if value != nil {
				value^ = idx
			}

			out_of_bounds := false
			if idx < 0 {
				out_of_bounds = true
			} else if open_range {
				out_of_bounds = idx > max_count
			} else {
				out_of_bounds = idx >= max_count
			}

			if out_of_bounds {
				expr_str := expr_to_string(operand.expr)
				defer delete(expr_str)
				error(operand.expr, "Index '%s' is out of bounds range 0..<%d", expr_str, max_count)
				return false
			}

			return true
		}
	}

	// Non-constant index or no bounds to check
	if value != nil {
		value^ = -1
	}
	return true
}

// check_index checks index expressions (x[i])
// Handles: arrays, slices, dynamic arrays, maps, strings, multi-pointers, SOA structs
// Ported from check_expr.cpp:11009-11136
//
// Implemented: Arrays, slices, dynamic arrays, maps, strings, multi-pointers, SOA, matrices, constant indexing
// Map runtime dependencies handled in entity_helpers.odin:add_map_dependencies
check_index :: proc(ctx: ^Checker_Context, operand: ^Operand, node: ^ast.Node, type_hint: ^Type) -> Expr_Kind {
	kind := Expr_Kind.Expr

	ie, ok := node.derived.(^ast.Index_Expr)
	if !ok {
		operand.mode = .Invalid
		operand.expr = node
		return kind
	}

	// Check the indexed expression
	check_expr(ctx, operand, ie.expr)

	if operand.mode == .Invalid {
		operand.expr = node
		return kind
	}

	t := base_type(type_deref(operand.type))
	is_ptr := is_type_pointer(operand.type)
	is_const := operand.mode == .Constant

	// Special case: Map indexing
	if is_type_map(t) {
		map_type := t.variant.(Type_Map)

		key: Operand
		if is_type_typeid(map_type.key) {
			check_expr_or_type(ctx, &key, ie.index, map_type.key)
		} else {
			check_expr_or_type(ctx, &key, ie.index, map_type.key)
		}

		check_assignment(ctx, &key, map_type.key, "map index")
		if key.mode == .Invalid {
			operand.mode = .Invalid
			operand.expr = node
			return kind
		}

		operand.mode = .Map_Index
		operand.type = map_type.value
		operand.expr = node

		// Add runtime dependencies for map access
		// Reference: check_expr.cpp:11040-11041
		add_map_get_dependencies(ctx, t)

		return .Expr
	}

	// Set up indexing data (element type, addressing mode, max_count)
	max_count: i64 = -1
	valid := check_set_index_data(operand, t, is_ptr, &max_count, operand.type)

	// Additional validation for constant indexing
	if is_const {
		if is_type_array(t) || is_type_slice(t) || is_type_enumerated_array(t) || is_type_string(t) {
			// These types can be indexed when constant
		} else if is_type_matrix(t) {
			// Matrix constants can be indexed
			// Reference: check_expr.cpp:11057-11058
		} else {
			valid = false
		}
	}

	if !valid {
		// C++ Reference: check_expr.cpp:11065-11073
		expr_str := expr_to_string(operand.expr)
		defer delete(expr_str)
		type_str := type_to_string(operand.type)
		if is_const {
			error(operand.expr, "Cannot index constant '%s' of type '%s'", expr_str, type_str)
		} else {
			error(operand.expr, "Cannot index '%s' of type '%s'", expr_str, type_str)
		}
		operand.mode = .Invalid
		operand.expr = node
		return kind
	}

	// Check for missing index
	if ie.index == nil {
		// C++ Reference: check_expr.cpp:11080-11082
		expr_str := expr_to_string(operand.expr)
		defer delete(expr_str)
		error(operand.expr, "Missing index for '%s'", expr_str)
		operand.mode = .Invalid
		operand.expr = node
		return kind
	}

	// Determine index type hint (for enumerated arrays)
	index_type_hint: ^Type = nil
	if is_type_enumerated_array(t) {
		bt := base_type(t)
		earr := bt.variant.(Type_Enumerated_Array)
		index_type_hint = earr.index
	}

	// Validate the index expression
	index: i64 = 0
	index_ok := check_index_value(ctx, t, false, ie.index, max_count, &index, index_type_hint)

	// If index validation failed (wrong type, out of bounds, etc.), mark as invalid
	if !index_ok {
		operand.mode = .Invalid
		operand.expr = node
		return kind
	}

	// Handle constant array/string indexing
	if is_const {
		if index < 0 {
			// Negative index into constant - not allowed
			// C++ Reference: check_expr.cpp:11100-11108
			expr_str := expr_to_string(operand.expr)
			defer delete(expr_str)
			error(operand.expr, "Cannot index constant '%s' with a variable index", expr_str)
			operand.mode = .Invalid
			operand.expr = node
			return kind
		} else if index_ok && !is_type_matrix(t) {
			// Extract constant value from indexed constant
			// Reference: check_expr.cpp:11110-11128
			if operand.value != nil {
				str_val, is_string := operand.value.(string)
				if is_string && index >= 0 && index < i64(len(str_val)) {
					// Constant string indexing - extract byte value
					byte_val := str_val[index]
					result: big.Int
					big.int_set_from_integer(&result, i64(byte_val))
					operand.mode = .Constant
					operand.value = result
					operand.type = t_u8
				}

				// Handle constant array indexing from compound literals
				// C++ Reference: check_expr.cpp:11110-11128
				if compound, is_compound := operand.value.(Exact_Value_Compound); is_compound {
					if compound.expr != nil {
						if comp_lit, is_comp := compound.expr.derived.(^ast.Comp_Lit); is_comp {
							elem_value, has_elem := get_constant_array_element_value(ctx, comp_lit, index)
							if has_elem {
								operand.value = elem_value
								operand.mode = .Constant
							}
						}
					}
				}
			}
		}
	}

	// Matrix type hint handling
	// Reference: check_expr.cpp:11131-11134
	if type_hint != nil && is_type_matrix(t) {
		operand.type = check_matrix_type_hint(operand.type, type_hint)
	}

	operand.expr = node
	return kind
}

// check_matrix_index_expr checks matrix indexing (mat[row, col])
// Reference: /mnt/c/odin/src/check_expr.cpp:11212-11261
//
// Matrix indexing extracts a single element from a matrix using row and column indices.
// Both indices must be integers within the bounds of the matrix dimensions.
check_matrix_index_expr :: proc(ctx: ^Checker_Context, operand: ^Operand, node: ^ast.Node, type_hint: ^Type) -> Expr_Kind {
	kind := Expr_Kind.Expr

	me, ok := node.derived.(^ast.Matrix_Index_Expr)
	if !ok {
		operand.mode = .Invalid
		operand.expr = node
		return kind
	}

	// Check the matrix expression
	check_expr(ctx, operand, me.expr)
	node.viral_state_flags |= me.expr.viral_state_flags

	if operand.mode == .Invalid {
		operand.expr = node
		return kind
	}

	// Get the base type (deref if pointer)
	t := base_type(type_deref(operand.type))
	is_ptr := is_type_pointer(operand.type)

	// Verify it's a matrix type
	if t.kind != .Matrix {
		type_str := type_to_string(operand.type)
		error(me.expr, "Cannot index non-matrix type '%s' with matrix indexing syntax", type_str)
		operand.mode = .Invalid
		operand.expr = node
		return kind
	}

	mat := t.variant.(Type_Matrix)

	// Check row index
	row_operand := Operand{}
	check_expr(ctx, &row_operand, me.row_index)
	node.viral_state_flags |= me.row_index.viral_state_flags

	if row_operand.mode == .Invalid {
		operand.mode = .Invalid
		operand.expr = node
		return kind
	}

	if !is_type_integer(core_type(row_operand.type)) {
		error(me.row_index, "Matrix row index must be an integer")
		operand.mode = .Invalid
		operand.expr = node
		return kind
	}

	// Check column index
	col_operand := Operand{}
	check_expr(ctx, &col_operand, me.column_index)
	node.viral_state_flags |= me.column_index.viral_state_flags

	if col_operand.mode == .Invalid {
		operand.mode = .Invalid
		operand.expr = node
		return kind
	}

	if !is_type_integer(core_type(col_operand.type)) {
		error(me.column_index, "Matrix column index must be an integer")
		operand.mode = .Invalid
		operand.expr = node
		return kind
	}

	// Bounds checking for constant indices
	if row_operand.mode == .Constant {
		row_val := exact_value_to_i64(row_operand.value)
		if row_val < 0 || row_val >= mat.row_count {
			error(me.row_index, "Matrix row index %d is out of bounds (0..<%d)", row_val, mat.row_count)
		}
	}

	if col_operand.mode == .Constant {
		col_val := exact_value_to_i64(col_operand.value)
		if col_val < 0 || col_val >= mat.column_count {
			error(me.column_index, "Matrix column index %d is out of bounds (0..<%d)", col_val, mat.column_count)
		}
	}

	// Set result type to the matrix element type
	operand.type = mat.elem
	operand.mode = .Variable
	if is_ptr {
		operand.mode = .Variable
	}
	operand.expr = node

	return kind
}

// check_slice checks slice expressions (x[low:high])
// Reference: /mnt/c/odin/src/check_expr.cpp:11138-11340
//
// Slice expressions create sub-slices from sliceable types:
// - Arrays: [N]T -> []T (requires addressability)
// - Slices: []T -> []T (sub-slicing)
// - Strings: string -> string (constant strings with constant indices)
// - Dynamic arrays: [dynamic]T -> []T
// - Multi-pointers: [^]T -> [^]T or []T depending on bounds
//
// Implemented: Arrays, slices, strings (including constant substring extraction), dynamic arrays,
// pointers, multi-pointers, SOA structs, String16
check_slice :: proc(ctx: ^Checker_Context, operand: ^Operand, node: ^ast.Node, type_hint: ^Type) -> Expr_Kind {
	kind := Expr_Kind.Stmt

	// Extract Slice_Expr from node
	se, ok := node.derived.(^ast.Slice_Expr)
	if !ok {
		error(node, "Expected slice expression")
		operand.mode = .Invalid
		operand.expr = node
		return kind
	}

	// Check the base expression being sliced
	check_expr(ctx, operand, se.expr)

	// Propagate viral state flags from sub-expression
	node.viral_state_flags |= se.expr.viral_state_flags

	// Early return on invalid operand
	if operand.mode == .Invalid {
		operand.expr = node
		return kind
	}

	// Determine sliceability and result type
	valid := false
	max_count: i64 = -1
	t := base_type(type_deref(operand.type))

	#partial switch t.kind {
	case .Basic:
		// String slicing
		// Reference: check_expr.cpp:11154-11169
		basic := t.variant.(Type_Basic)
		if basic.kind == .String || basic.kind == .Untyped_String {
			valid = true
			// Extract length from constant strings
			if operand.mode == .Constant && operand.value != nil {
				if str_val, is_string := operand.value.(string); is_string {
					max_count = i64(len(str_val))
				}
			}
			operand.type = type_deref(operand.type)
		} else if basic.kind == .String16 {
			// String16 slicing support (check_expr.cpp:11162-11168)
			valid = true
			// Extract length from constant String16 values
			if operand.mode == .Constant && operand.value != nil {
				if s16_val, is_string16 := operand.value.(Exact_Value_String16); is_string16 {
					max_count = i64(s16_val.len)
				}
			}
			operand.type = type_deref(operand.type)
		}

	case .Array:
		// Array slicing: [N]T -> []T
		// Reference: check_expr.cpp:11172-11184
		valid = true
		array_type := t.variant.(Type_Array)
		max_count = array_type.count

		// Arrays require addressability to be sliced
		if operand.mode != .Variable && !is_type_pointer(operand.type) {
			// C++ Reference: check_expr.cpp:11172-11184
			expr_str := expr_to_string(operand.expr)
			defer delete(expr_str)
			error(node, "Cannot slice array '%s', value is not addressable", expr_str)
			operand.mode = .Invalid
			operand.expr = node
			return kind
		}

		// Convert array to slice type
		operand.type = alloc_type_slice(array_type.elem)

	case .Multi_Pointer:
		// Multi-pointer slicing
		// Reference: check_expr.cpp:11186-11189
		valid = true
		operand.type = type_deref(operand.type)

	case .Slice:
		// Slice sub-slicing: []T -> []T
		// Reference: check_expr.cpp:11191-11194
		valid = true
		operand.type = type_deref(operand.type)

	case .Dynamic_Array:
		// Dynamic array slicing: [dynamic]T -> []T
		// Reference: check_expr.cpp:11196-11199
		valid = true
		da_type := t.variant.(Type_Dynamic_Array)
		operand.type = alloc_type_slice(da_type.elem)

	case .Fixed_Capacity_Dynamic_Array:
		// `[dynamic; N]T` slices to []T, as [dynamic]T does.
		// C++ Reference: check_expr.cpp:12060-12070.
		valid = true
		fc_type := t.variant.(Type_Fixed_Capacity_Dynamic_Array)
		operand.type = alloc_type_slice(fc_type.elem)

	case .Struct:
		// SOA struct slicing
		// Reference: check_expr.cpp:11201-11217
		strct := &t.variant.(Type_Struct)
		if strct.soa_kind != .None {
			// SOA struct slicing - result is a SOA slice
			// C++ lines 11204-11217
			if strct.soa_kind == .Fixed {
				// Fixed SOA: needs addressability check
				// C++ lines 11205-11213
				if operand.mode != .Variable && operand.mode != .Soa_Variable {
					error(operand.expr, "Cannot slice non-addressable SOA array")
				} else {
					valid = true
					// Create a SOA slice type from the fixed SOA
					operand.type = make_soa_struct_slice(ctx, node, se.expr, strct.soa_elem)
				}
			} else {
				// Slice/Dynamic SOA: already sliceable
				// C++ lines 11214-11216
				valid = true
				operand.type = make_soa_struct_slice(ctx, node, se.expr, strct.soa_elem)
			}
		}

	case .Enumerated_Array:
		// Enumerated arrays explicitly cannot be sliced
		// C++ Reference: check_expr.cpp:11219-11230
		expr_str := expr_to_string(operand.expr)
		defer delete(expr_str)
		type_str := type_to_string(operand.type)
		error(node, "Cannot slice enumerated array '%s' of type '%s'", expr_str, type_str)
		operand.mode = .Invalid
		operand.expr = node
		return kind
	}

	// Validate that type is sliceable
	if !valid {
		// C++ Reference: check_expr.cpp:11233-11242
		expr_str := expr_to_string(operand.expr)
		defer delete(expr_str)
		type_str := type_to_string(operand.type)
		error(operand.expr, "Cannot slice '%s' of type '%s'", expr_str, type_str)
		operand.mode = .Invalid
		operand.expr = node
		return kind
	}

	// Validate slice indices
	// Reference: check_expr.cpp:11244-11277

	// Handle nil low index (defaults to 0)
	// Reference: check_expr.cpp:11244-11246

	indices: [2]i64
	nodes := [2]^ast.Expr{se.low, se.high}

	// Validate and extract both indices
	for i in 0 ..< len(nodes) {
		index := max_count

		if nodes[i] != nil {
			// Validate the index expression
			capacity: i64 = -1
			if max_count >= 0 {
				capacity = max_count
			}

			j: i64 = 0
			// open_range = true for slice bounds (allows index == length)
			if check_index_value(ctx, t, true, nodes[i], capacity, &j) {
				index = j
			}

			// Propagate viral state flags from index expression
			node.viral_state_flags |= nodes[i].viral_state_flags
		} else if i == 0 {
			// nil low bound defaults to 0
			index = 0
		}

		indices[i] = index
	}

	// Validate that low <= high
	// Reference: check_expr.cpp:11269-11277
	for i in 0 ..< len(indices) {
		a := indices[i]
		for j in i + 1 ..< len(indices) {
			b := indices[j]
			if a > b && b >= 0 {
				error(se.close, "Invalid slice indices: low index greater than high index")
			}
		}
	}

	// Check for slicing constants without known bounds
	// C++ Reference: check_expr.cpp:11279-11285
	if max_count < 0 {
		if operand.mode == .Constant {
			expr_str := expr_to_string(se.expr)
			defer delete(expr_str)
			error(se.expr, "Cannot slice constant '%s'", expr_str)
		}
	}

	// Multi-pointer special semantics
	// Reference: check_expr.cpp:11287-11295
	// x[:]   -> [^]T (multi-pointer)
	// x[i:]  -> [^]T (multi-pointer)
	// x[:n]  -> []T  (slice)
	// x[i:n] -> []T  (slice)
	if t.kind == .Multi_Pointer && se.high != nil {
		mp_type := t.variant.(Type_Multi_Pointer)
		operand.type = alloc_type_slice(mp_type.elem)
	}

	// Default mode is Value
	operand.mode = .Value

	// Constant string slicing
	// Reference: check_expr.cpp:11300-11338
	if is_type_string(t) && max_count >= 0 && operand.value != nil {
		// Check if we have a constant string with constant indices
		str_val, is_string := operand.value.(string)
		if is_string {
			// Check if both indices are constant
			low_const := true
			high_const := true

			if se.low != nil {
				_, low_val, low_mode := type_and_value_of_expr(ctx, se.low)
				low_const = low_mode == .Constant && low_val != nil
			}

			if se.high != nil {
				_, high_val, high_mode := type_and_value_of_expr(ctx, se.high)
				high_const = high_mode == .Constant && high_val != nil
			}

			if low_const && high_const {
				// Both indices are constant - extract substring at compile time
				// indices[0] is low, indices[1] is high
				low_idx := indices[0]
				high_idx := indices[1]

				// Default high to string length if not specified
				if high_idx < 0 {
					high_idx = i64(len(str_val))
				}

				// Validate indices are in bounds (should already be validated by check_index_value)
				if low_idx >= 0 && high_idx >= 0 && low_idx <= high_idx && high_idx <= i64(len(str_val)) {
					// Extract the substring
					substring := str_val[low_idx:high_idx]
					operand.mode = .Constant
					operand.value = substring
				}
			}
		}
	}

	operand.expr = node
	return kind
}

// ternary_compare_types checks if two types are compatible in a ternary expression context
// Reference: /mnt/c/odin/src/check_expr.cpp:8564-8575
//
// This is more lenient than exact type equality, allowing:
// - untyped_uninit is compatible with anything
// - untyped_nil is compatible with any type that can hold nil
ternary_compare_types :: proc(x, y: ^Type) -> bool {
	if is_type_untyped_uninit(x) {
		return true
	} else if is_type_untyped_nil(x) && type_has_nil(y) {
		return true
	} else if is_type_untyped_uninit(y) {
		return true
	} else if is_type_untyped_nil(y) && type_has_nil(x) {
		return true
	}
	return are_types_identical(x, y)
}

// check_ternary_if_expr checks a ternary if expression: x if cond else y
// Reference: /mnt/c/odin/src/check_expr.cpp:9124-9206
//
// This is a runtime conditional expression where:
// - cond must be a boolean expression
// - x and y must have compatible types
// - The result type is the common type of x and y
check_ternary_if_expr :: proc(ctx: ^Checker_Context, o: ^Operand, node: ^ast.Node, type_hint: ^Type) -> Expr_Kind {
	kind := Expr_Kind.Expr
	cond := Operand{}
	te := node.derived.(^ast.Ternary_If_Expr)

	// Check condition - must be boolean
	check_expr(ctx, &cond, te.cond)
	node.viral_state_flags |= te.cond.viral_state_flags

	if cond.mode != .Invalid && !is_type_boolean(cond.type) {
		error(te.cond, "Non-boolean condition in ternary if expression")
	}

	// Check true branch (x)
	x := Operand{}
	check_expr_or_type(ctx, &x, te.x, type_hint)
	node.viral_state_flags |= te.x.viral_state_flags

	// Check false branch (y)
	y := Operand{}
	if te.y != nil {
		th := type_hint
		if type_hint == nil && is_type_typed(x.type) {
			th = x.type
		}
		check_expr_or_type(ctx, &y, te.y, th)
		node.viral_state_flags |= te.y.viral_state_flags
	} else {
		error(node, "A ternary expression must have an else clause")
		return kind
	}

	// Reject if either operand is a type (not expression)
	if x.mode == .Type || y.mode == .Type {
		type_expr := x.mode == .Type ? x.expr : y.expr
		type_str := expr_to_string(type_expr)
		defer delete(type_str)
		error(node, "Type %s is invalid operand for ternary if expression", type_str)
		return kind
	}

	// Handle untyped nil/uninit special case
	use_type_hint := type_hint != nil && (is_operand_nil(x) || is_operand_nil(y))

	// Convert both operands to compatible types
	convert_to_typed(ctx, &x, use_type_hint ? type_hint : y.type)
	if x.mode == .Invalid {
		return kind
	}
	convert_to_typed(ctx, &y, use_type_hint ? type_hint : x.type)
	if y.mode == .Invalid {
		x.mode = .Invalid
		return kind
	}

	// Allow expressions like: x: union{f32} = f32(123) if cond else nil
	if type_hint != nil && !is_type_any(type_hint) {
		if check_is_assignable_to(ctx, &x, type_hint) && check_is_assignable_to(ctx, &y, type_hint) {
			check_cast(ctx, &x, type_hint)
			check_cast(ctx, &y, type_hint)
		}
	}

	// Validate types are compatible
	if !ternary_compare_types(x.type, y.type) {
		its := type_to_string(x.type)
		ets := type_to_string(y.type)
		error(node, "Mismatched types in ternary if expression, %s vs %s", its, ets)
		return kind
	}

	// Set result type (prefer typed over untyped)
	o.type = x.type
	if is_type_untyped_nil(o.type) || is_type_untyped_uninit(o.type) {
		o.type = y.type
	}

	o.mode = .Value
	o.expr = node

	// Apply type hint if present and types are untyped
	if type_hint != nil && is_type_untyped(o.type) && !is_type_any(type_hint) {
		if check_cast_internal(ctx, &x, type_hint) && check_cast_internal(ctx, &y, type_hint) {
			convert_to_typed(ctx, o, type_hint)
			update_untyped_expr_type(ctx, node, type_hint, !is_type_untyped(type_hint))
			o.type = type_hint
		}
	}

	return kind
}

// check_ternary_when_expr checks a ternary when expression: x when cond else y
// Reference: /mnt/c/odin/src/check_expr.cpp:9208-9232
//
// This is a compile-time conditional expression where:
// - cond must be a constant boolean expression
// - Only one branch is evaluated based on the condition
// - This is compile-time selection, not runtime
check_ternary_when_expr :: proc(ctx: ^Checker_Context, o: ^Operand, node: ^ast.Node, type_hint: ^Type) -> Expr_Kind {
	kind := Expr_Kind.Expr
	cond := Operand{}
	te := node.derived.(^ast.Ternary_When_Expr)

	// Check condition - must be constant boolean
	check_expr(ctx, &cond, te.cond)
	node.viral_state_flags |= te.cond.viral_state_flags

	if cond.mode != .Constant || !is_type_boolean(cond.type) {
		error(te.cond, "Expected a constant boolean condition in ternary when expression")
		return kind
	}

	// Evaluate only the selected branch based on constant condition
	// C++ Reference: check_expr.cpp:7965-7975
	if cond.value != nil {
		cond_bool := false
		if bool_val, is_bool := cond.value.(bool); is_bool {
			cond_bool = bool_val
		}

		if cond_bool {
			check_expr_or_type(ctx, o, te.x, type_hint)
		} else {
			check_expr_or_type(ctx, o, te.y, type_hint)
		}
	}

	o.expr = node
	return kind
}

// check_type_assertion checks a type assertion expression: value.(Type)
// Reference: /mnt/c/odin/src/check_expr.cpp:10733-10860
//
// Type assertions allow runtime type checking for unions and 'any' types:
// - For unions: checks if value is one of the union variants
// - For any: can assert to any typed type
// - Returns (value, ok) pair for safe checking
//
// Syntax variants:
// - value.(Type)       - asserts and panics if wrong type
// - value.(Type?)      - optional assertion for single-variant unions
// - value, ok := x.(Type) - safe assertion with boolean result
check_type_assertion :: proc(ctx: ^Checker_Context, o: ^Operand, node: ^ast.Node, type_hint: ^Type) -> Expr_Kind {
	kind := Expr_Kind.Expr
	ta := node.derived.(^ast.Type_Assertion)

	// Check the expression being asserted
	check_expr(ctx, o, ta.expr)
	node.viral_state_flags |= ta.expr.viral_state_flags

	// If expression is invalid, bail out
	if o.mode == .Invalid {
		o.expr = node
		return kind
	}

	// Cannot assert constants
	if o.mode == .Constant {
		// C++ Reference: check_expr.cpp:11584
		tac_str := expr_to_string(o.expr)
		defer delete(tac_str)
		error(o.expr, "A type assertion cannot be applied to a constant expression: '%s'", tac_str)
		o.mode = .Invalid
		o.expr = node
		return kind
	}

	// Cannot assert untyped expressions
	if is_type_untyped(o.type) {
		// C++ Reference: check_expr.cpp:11593
		ta_str := expr_to_string(o.expr)
		defer delete(ta_str)
		error(o.expr, "A type assertion cannot be applied to an untyped expression: '%s'", ta_str)
		o.mode = .Invalid
		o.expr = node
		return kind
	}

	// Get the source type (potentially dereferenced)
	src := type_deref(o.type)
	bsrc := base_type(src)

	// Handle optional type assertion: x.(T?)
	// This is for single-variant unions where we want to extract the variant
	if ta.type != nil {
		if unary, ok := ta.type.derived.(^ast.Unary_Expr); ok && unary.op.kind == .Question {
			// This is a .? assertion (optional type assertion)
			if !is_type_union(src) {
				// C++ check_expr.cpp:11607 names the type, and names o->type -- the
				// UNDEREFERENCED one -- not the type_deref'd `src` it just tested.
				error(o.expr, "Type assertions with .? can only operate on unions, got %s", type_to_string(o.type))
				o.mode = .Invalid
				o.expr = node
				return kind
			}

			// Check if union has single variant (or can be inferred from type_hint)
			union_type := bsrc.variant.(Type_Union)
			variant_count := len(union_type.variants)

			if variant_count != 1 && type_hint != nil {
				// Try to match type_hint with a union variant
				allowed := false
				for vt in union_type.variants {
					if are_types_identical(vt, type_hint) {
						allowed = true
						add_type_info_type(ctx, vt)
						break
					}
				}

				if allowed {
					add_type_info_type(ctx, o.type)
					o.type = type_hint
					o.mode = .Optional_Ok
					o.expr = node
					return kind
				}
			}

			if variant_count != 1 {
				error(o.expr, "Type assertions with .? can only operate on unions with 1 variant, got %d", variant_count)
				o.mode = .Invalid
				o.expr = node
				return kind
			}

			add_type_info_type(ctx, o.type)
			add_type_info_type(ctx, union_type.variants[0])

			o.type = union_type.variants[0]
			o.mode = .Optional_Ok
			o.expr = node
			return kind
		}
	}

	// Normal type assertion: x.(Type)
	if ta.type == nil {
		error(node, "Type assertion requires a target type")
		o.mode = .Invalid
		o.expr = node
		return kind
	}

	// Check the target type
	target := check_type(ctx, ta.type)

	if is_type_union(src) {
		// Type assertion on union - check if target is a valid variant
		union_type := bsrc.variant.(Type_Union)
		ok := false

		for vt in union_type.variants {
			if are_types_identical(vt, target) {
				ok = true
				break
			}
		}

		if !ok {
			// C++ check_expr.cpp:11657-11665. Two divergences here, not one: the port
			// dropped the EXPRESSION from the message entirely ("Cannot type assert to"
			// rather than "Cannot type assert '%s' to"), and passed the ^Type to a "%v",
			// dumping the Type struct where a name belongs. LEDGER 287.
			assert_expr_str := expr_to_string(o.expr)
			defer delete(assert_expr_str)
			dst_type_str := type_to_string(target)
			if len(union_type.variants) == 0 {
				error(o.expr, "Cannot type assert '%s' to '%s' as this is an empty union", assert_expr_str, dst_type_str)
			} else {
				error(o.expr, "Cannot type assert '%s' to '%s' as it is not a variant of that union", assert_expr_str, dst_type_str)
			}
			o.mode = .Invalid
			o.expr = node
			return kind
		}

		add_type_info_type(ctx, o.type)
		add_type_info_type(ctx, target)

		o.type = target
		o.mode = .Optional_Ok
		o.expr = node

	} else if is_type_any(src) {
		// Type assertion on 'any' - can assert to any typed type
		add_type_info_type(ctx, o.type)
		add_type_info_type(ctx, target)

		o.type = target
		o.mode = .Optional_Ok
		o.expr = node

	} else {
		// Invalid source type for type assertion
		// C++ Reference: check_expr.cpp:11684 -- reports the actual type.
		ta_got := type_to_string(o.type)
		error(o.expr, "Type assertions can only operate on unions and 'any', got %s", ta_got)
		o.mode = .Invalid
		o.expr = node
		return kind
	}

	// Add runtime dependency tracking for type assertions
	// Only if type assertions are not disabled via #no_type_assert
	if .No_Type_Assert not_in node.state_flags {
		add_package_dependency(ctx, "runtime", "type_assertion_check")
		add_package_dependency(ctx, "runtime", "type_assertion_check2")
	}

	return kind
}

// attempt_implicit_selector_expr attempts to resolve an implicit selector for a given type
// Reference: /mnt/c/odin/src/check_expr.cpp:8704-8741
//
// This helper tries to resolve .field against a specific type:
// - For enums: looks up the enum value in the enum's scope
// - For unions: recursively tries each variant and returns if exactly one matches
// Returns true if successful, false otherwise
attempt_implicit_selector_expr :: proc(ctx: ^Checker_Context, o: ^Operand, ise: ^ast.Implicit_Selector_Expr, th: ^Type) -> bool {
	// Handle enum types
	if is_type_enum(th) {
		enum_type := base_type(th).variant.(Type_Enum)
		name := ise.field.name

		// Look up the enum value in the enum's fields array
		// Note: enum fields are stored in the fields array, not in a scope
		entity: ^Entity = nil
		for field in enum_type.fields {
			if field.token.text == name {
				entity = field
				break
			}
		}
		if entity == nil {
			return false
		}

		// Verify it's a constant and has the right type
		entity_type := get_entity_type(entity)
		assert(are_types_identical(base_type(entity_type), base_type(th)))
		assert(entity.kind == .Constant)

		// Set operand to the enum constant
		o.value = entity.variant.(Entity_Constant).value
		o.mode = .Constant
		o.type = entity_type
		return true
	}

	// Handle union types - try each variant
	if is_type_union(th) {
		union_type := base_type(th).variant.(Type_Union)
		operands: [dynamic]Operand
		defer delete(operands)

		// Try implicit selector against each variant
		for vt in union_type.variants {
			x := Operand{}
			if attempt_implicit_selector_expr(ctx, &x, ise, vt) {
				append(&operands, x)
			}
		}

		// Only succeed if exactly one variant matched
		if len(operands) == 1 {
			o^ = operands[0]
			return true
		}
	}

	return false
}

// check_implicit_selector_expr checks an implicit selector expression: .field
// Reference: /mnt/c/odin/src/check_expr.cpp:8743-8795
//
// Implicit selectors require a type hint from context to resolve:
// - .Red for enum values (where enum type is inferred from context)
// - .field for struct fields (where struct type is inferred from context)
//
// Example:
//   Color :: enum { Red, Green, Blue }
//   x: Color = .Red  // implicit selector, type inferred from Color
check_implicit_selector_expr :: proc(ctx: ^Checker_Context, o: ^Operand, node: ^ast.Node, type_hint: ^Type) -> Expr_Kind {
	ise := node.derived.(^ast.Implicit_Selector_Expr)

	// Initialize to invalid
	o.type = t_invalid
	o.expr = node
	o.mode = .Invalid

	th := type_hint

	// Type hint is required for implicit selectors
	if th == nil {
		// C++ Reference: check_expr.cpp:9375 -- names the expression.
		ise_str := expr_to_string(node)
		defer delete(ise_str)
		error(node, "Cannot determine type for implicit selector expression '%s'", ise_str)
		return .Expr
	}

	o.type = th

	// Attempt to resolve the selector
	ok := attempt_implicit_selector_expr(ctx, o, ise, th)

	if !ok {
		name := ise.field.name

		if is_type_enum(th) {
			// Error for undeclared enum value
			error(node, "Undeclared name '%s' for enum type", name)
			// C++ Reference: check_expr.cpp:8838 - suggest similar enum field names
			suggest_bt := base_type(th)
			if suggest_bt != nil && suggest_bt.kind == .Enum {
				en := suggest_bt.variant.(Type_Enum)
				check_did_you_mean_type(name, en.fields[:], ".")
			}

		} else if is_type_bit_set(th) {
			bt := base_type(th).variant.(Type_Bit_Set)
			if is_type_enum(bt.elem) {
				// Bit set with enum base - suggest using { .field } syntax
				// C++ Reference: check_expr.cpp:8839-8841
				error(node, "Cannot convert enum value to bit_set; did you mean '{ .%s }'?", name)
			} else {
				// C++ Reference: check_expr.cpp:9408 -- names the TYPE and the expression.
				ise_typ := type_to_string(type_hint)
				ise_str := expr_to_string(node)
				defer delete(ise_str)
				error(node, "Invalid type '%s' for implicit selector expression '%s'", ise_typ, ise_str)
			}

		} else {
			// Generic error for unsupported type
			error(node, "Invalid type for implicit selector expression")
		}
	}

	o.expr = node
	return .Expr
}

// Helper functions for or_return and or_branch expressions
// Reference: /mnt/c/odin/src/check_builtin.cpp:66-155

// check_or_else_right_type validates the right side of an or_else-like expression
// Reference: /mnt/c/odin/src/check_builtin.cpp:66-75
check_or_else_right_type :: proc(ctx: ^Checker_Context, expr: ^ast.Node, name: string, right_type: ^Type) {
	if right_type == nil {
		return
	}
	if !is_type_boolean(right_type) && !type_has_nil(right_type) {
		str := type_to_string(right_type)
		error(expr, "'%s' expects an \"optional ok\" like value, or an n-valued expression where the last value is either a boolean or can be compared against 'nil', got %s", name, str)
	}
}

// check_promote_optional_ok promotes an optional-ok expression to its tuple form
// Reference: /mnt/c/odin/src/check_expr.cpp:8862-8902
check_promote_optional_ok :: proc(ctx: ^Checker_Context, x: ^Operand, val_type_: ^^Type, ok_type_: ^^Type, change_operand := true) {
	// Handle special addressing modes
	#partial switch x.mode {
	case .Map_Index, .Optional_Ok, .Optional_Ok_Ptr:
		if val_type_ != nil {
			val_type_^ = x.type
		}
	case:
		if ok_type_ != nil {
			ok_type_^ = x.type
		}
		return
	}

	expr := unparen_expr(x.expr)
	if expr == nil {
		return
	}

	// Handle call expressions with optional-ok returns
	if call, is_call := expr.derived.(^ast.Call_Expr); is_call {
		pt := base_type(type_of_expr(call.expr, ctx.info))
		if is_type_proc(pt) {
			proc_type := &pt.variant.(Type_Proc)
			tuple := proc_type.results

			if proc_type.result_count >= 2 && tuple != nil && tuple.kind == .Tuple {
				tuple_var := &tuple.variant.(Type_Tuple)
				if ok_type_ != nil && len(tuple_var.variables) >= 2 {
					ok_type_^ = get_entity_type(tuple_var.variables[1])
				}
				if change_operand {
					x.type = tuple
					add_type_and_value(ctx, x.expr, x.mode, tuple, x.value)
				}
				return
			}
		}
	}

	// Create optional-ok tuple type
	tuple := make_optional_ok_type(x.type)
	if tuple != nil && tuple.kind == .Tuple {
		tuple_var := &tuple.variant.(Type_Tuple)
		if ok_type_ != nil && len(tuple_var.variables) >= 2 {
			ok_type_^ = get_entity_type(tuple_var.variables[1])
		}

		if change_operand {
			add_type_and_value(ctx, x.expr, x.mode, tuple, x.value)
			x.type = tuple
		}
	}
}

// check_or_else_split_types splits an expression into value and ok types
// Reference: /mnt/c/odin/src/check_builtin.cpp:77-100
check_or_else_split_types :: proc(ctx: ^Checker_Context, x: ^Operand, name: string, left_type_: ^^Type, right_type_: ^^Type) {
	left_type: ^Type = nil
	right_type: ^Type = nil

	if x.type != nil && x.type.kind == .Tuple {
		tuple := &x.type.variant.(Type_Tuple)
		vars := tuple.variables[:]
		vars_count := len(vars)

		if vars_count >= 2 {
			// Split into left (all but last) and right (last)
			if vars_count == 2 {
				// Simple case: (value, ok)
				left_type = get_entity_type(vars[0])
			} else if vars_count > 2 {
				// Multiple values: (v1, v2, ..., ok)
				// Create a tuple from all but the last variable
				left_vars := vars[:vars_count - 1]
				left_type = alloc_type_tuple(left_vars)
			}

			// Last element is always the ok/error type
			right_type = get_entity_type(vars[vars_count - 1])
		}
	} else {
		// Not a tuple - try to promote optional-ok
		check_promote_optional_ok(ctx, x, &left_type, &right_type)
	}

	if left_type_ != nil do left_type_^ = left_type
	if right_type_ != nil do right_type_^ = right_type

	check_or_else_right_type(ctx, x.expr, name, right_type)
}

// check_or_return_split_types is identical to check_or_else_split_types
// Kept as separate function for clarity (matches C++ design)
// Reference: /mnt/c/odin/src/check_builtin.cpp:132-155
check_or_return_split_types :: proc(ctx: ^Checker_Context, x: ^Operand, name: string, left_type_: ^^Type, right_type_: ^^Type) {
	check_or_else_split_types(ctx, x, name, left_type_, right_type_)
}

// check_or_else_expr_no_value_error reports error when expression doesn't return optional value
// Reference: /mnt/c/odin/src/check_builtin.cpp:103-129
check_or_else_expr_no_value_error :: proc(ctx: ^Checker_Context, name: string, x: Operand, type_hint: ^Type) {
	t := type_to_string(x.type)
	error(x.expr, "'%s' does not return a value, value is of type %s", name, t)

	// Union type assertion suggestions
	if is_type_union(type_deref(x.type)) {
		expr_str := expr_to_string(x.expr)
		defer delete(expr_str)
		error_line("Suggestion: was a type assertion such as %s.(T) or %s.? wanted?", expr_str, expr_str)
	}
}

// check_basic_directive_expr handles directive expressions (#file, #line, #procedure, etc.)
// Reference: /mnt/c/odin/src/check_expr.cpp:9058-9188
check_basic_directive_expr :: proc(ctx: ^Checker_Context, o: ^Operand, node: ^ast.Node, type_hint: ^Type) -> Expr_Kind {
	bd := node.derived.(^ast.Basic_Directive)
	name := bd.name

	switch name {
	case "file":
		// #file - returns the current file path as a string
		// C++ Reference: check_expr.cpp:9065-9075
		o.mode = .Constant
		o.type = t_untyped_string
		// Get file path from the node's position
		if len(bd.tok.pos.file) > 0 {
			o.value = bd.tok.pos.file
		} else {
			o.value = "<unknown>"
		}
		o.expr = node
		return .Expr

	case "directory":
		// #directory - returns the directory containing the current file
		// C++ Reference: check_expr.cpp:9076-9086 (similar to #file)
		o.mode = .Constant
		o.type = t_untyped_string
		if len(bd.tok.pos.file) > 0 {
			// C++ Reference: dir_from_path (parser.cpp). It walks back from the end shrinking the
			// length and BREAKS on the separator without consuming it, so the result KEEPS its
			// trailing separator: "/a/b/c.odin" -> "/a/b/".
			//
			// filepath.dir would return "/a/b" instead - a one-character divergence that is
			// user-visible for anything concatenating #directory with a filename. Sliced directly
			// so the value stays a substring of the token's file path and therefore outlives this
			// constant (it must not come from the temp allocator, which can be reset while the
			// constant is still referenced).
			file := bd.tok.pos.file
			dir := file
			for i := len(file) - 1; i >= 0; i -= 1 {
				if file[i] == '/' || file[i] == '\\' {
					dir = file[:i + 1]
					break
				}
				if i == 0 {
					// No separator at all - C++ shrinks to length 0.
					dir = file[:0]
				}
			}
			o.value = dir
		} else {
			o.value = "."
		}
		o.expr = node
		return .Expr

	case "line":
		// #line - returns the current line number
		// C++ Reference: check_expr.cpp:9076-9086
		o.mode = .Constant
		o.type = t_untyped_integer
		result: big.Int
		big.int_set_from_integer(&result, i64(bd.tok.pos.line))
		o.value = result
		o.expr = node
		return .Expr

	case "column":
		// #column - returns the current column number
		// C++ Reference: check_expr.cpp:9087-9097
		o.mode = .Constant
		o.type = t_untyped_integer
		result: big.Int
		big.int_set_from_integer(&result, i64(bd.tok.pos.column))
		o.value = result
		o.expr = node
		return .Expr

	case "procedure":
		// #procedure - returns the current procedure name as a string
		// C++ Reference: check_expr.cpp:9098-9118
		// Find enclosing procedure name
		if ctx.curr_proc_decl != nil && ctx.curr_proc_decl.entity != nil {
			o.mode = .Constant
			o.type = t_untyped_string
			o.value = ctx.curr_proc_decl.entity.token.text
		} else {
			error(node, "'#procedure' can only be used within a procedure")
			o.mode = .Invalid
		}
		o.expr = node
		return .Expr

	case "defined":
		// #defined - checks if an identifier is defined
		// C++ Reference: check_expr.cpp:9119-9135
		// This is handled as a call expression, not a bare directive
		// NOTE: C++ has no such message. A bare `#defined` reaches here only when the
		// directive is NOT the callee of a call, and C++ simply falls through to its
		// generic handling; emitting this meant `#defined(1)` produced TWO errors, this
		// invented one plus the real one from the builtin path.
		o.mode = .Invalid
		o.mode = .Invalid
		o.expr = node
		return .Expr

	case "config":
		// #config - compile-time configuration values
		// C++ Reference: check_expr.cpp:9136-9165
		// This is handled as a call expression, not a bare directive
		error(node, "'#config' must be called as '#config(name, default_value)'")
		o.mode = .Invalid
		o.expr = node
		return .Expr

	case "load":
		// #load - loads a file at compile time
		// C++ Reference: check_expr.cpp:9166-9188
		// This is handled as a call expression, not a bare directive
		error(node, "'#load' must be called as '#load(path)' or '#load(path, type)'")
		o.mode = .Invalid
		o.expr = node
		return .Expr

	case "load_directory":
		// #load_directory - loads directory listing
		// Must be called as a function
		error(node, "'#load_directory' must be called as '#load_directory(path)'")
		o.mode = .Invalid
		o.expr = node
		return .Expr

	case "assert":
		// #assert - compile-time assertion
		// Must be called as a function
		error(node, "'#assert' must be called as '#assert(condition)'")
		o.mode = .Invalid
		o.expr = node
		return .Expr

	case "panic":
		// #panic - compile-time panic
		// Must be called as a function
		error(node, "'#panic' must be called as '#panic(message)'")
		o.mode = .Invalid
		o.expr = node
		return .Expr

	case "caller_location":
		// #caller_location - returns Source_Code_Location of caller
		// C++ Reference: check_expr.cpp:9109-9118
		// Used as default parameter value
		// Ensure Source_Code_Location type is initialized
		init_core_source_code_location(ctx.checker)
		loc_type := ctx.info.cached_source_code_location
		if loc_type != nil {
			o.mode = .Value
			o.type = loc_type
			o.expr = node
			return .Expr
		}
		// Fallback if type not loaded
		error(node, "'#caller_location' requires base:runtime to be imported")
		o.mode = .Invalid
		o.expr = node
		return .Expr

	case:
		// Unknown directive
		error(node, "Unknown directive '#%s'", name)
		o.mode = .Invalid
		o.expr = node
		return .Expr
	}
}

// check_or_else_expr checks or_else expressions
// Reference: /mnt/c/odin/src/check_expr.cpp:9235-9360
check_or_else_expr :: proc(ctx: ^Checker_Context, o: ^Operand, node: ^ast.Node, type_hint: ^Type) -> Expr_Kind {
	oe := node.derived.(^ast.Or_Else_Expr)

	name := oe.token.text
	arg := oe.x
	default_value := oe.y
	x: Operand
	y: Operand

	// Handle #load directive edge case
	// C++ Reference: check_expr.cpp:9369-9420
	// NOTE(bill, 2022-08-11): edge case to handle #load(path) or_else default
	if is_load_directive_call(arg) {
		res := check_load_directive(ctx, &x, arg, type_hint, false)

		// Allow for chaining of '#load(path) or_else #load(path)'
		if !(is_load_directive_call(default_value) && res == .Success) {
			y_is_diverging := false
			check_expr_base(ctx, &y, default_value, x.type)

			#partial switch y.mode {
			case .No_Value:
				if is_diverging_expr(ctx, default_value) {
					// Allow diverging expressions
					y.mode = .Value
					y_is_diverging = true
				} else {
					error_operand_no_value(&y)
					y.mode = .Invalid
				}
			case .Type:
				error_operand_not_expression(&y)
				y.mode = .Invalid
			}

			if y.mode == .Invalid {
				o.mode = .Value
				o.type = t_invalid
				o.expr = node
				return .Expr
			}

			if !y_is_diverging {
				check_assignment(ctx, &y, x.type, name)
				if y.mode != .Constant {
					error(y.expr, "expected a constant expression on the right-hand side of 'or_else' in conjunction with '#load'")
				}
			}
		}

		if res == .Success {
			o^ = x
		} else {
			o^ = y
		}
		o.expr = node
		return .Expr
	}

	// Check LHS expression - may return tuple (value, ok)
	check_multi_expr_with_type_hint(ctx, &x, arg, type_hint)
	if x.mode == .Invalid {
		o.mode = .Value
		o.type = t_invalid
		o.expr = node
		return .Expr
	}

	// Split tuple into value type and ok type
	left_type: ^Type = nil
	right_type: ^Type = nil
	check_or_else_split_types(ctx, &x, name, &left_type, &right_type)

	add_type_and_value(ctx, arg, x.mode, x.type, x.value)

	// Check RHS expression with value type as hint
	y_is_diverging := false
	check_expr_base(ctx, &y, default_value, left_type)

	// Handle special addressing modes
	#partial switch y.mode {
	case .No_Value:
		// Check for diverging expressions (like panic())
		// Reference: check_expr.cpp:9320-9330
		if is_diverging_expr(ctx, default_value) {
			y_is_diverging = true
		} else {
			error_operand_no_value(&y)
			y.mode = .Invalid
		}

	case .Type:
		error_operand_not_expression(&y)
		y.mode = .Invalid
	}

	if y.mode == .Invalid {
		o.mode = .Value
		o.type = t_invalid
		o.expr = node
		return .Expr
	}

	// Validate default value matches extracted value type
	if left_type != nil {
		if !y_is_diverging {
			// Check if left_type is a tuple - needs special handling
			if left_type.kind == .Tuple {
				tuple := &left_type.variant.(Type_Tuple)
				tuple_count := len(tuple.variables)

				if y.type.kind != .Tuple {
					error(y.expr, "Found a single value where a %d-valued expression was expected", tuple_count)
				} else if !are_types_identical(left_type, y.type) {
					xt := type_to_string(left_type)
					yt := type_to_string(y.type)
					error(y.expr, "Mismatched types, expected (%s), got (%s)", xt, yt)
				}
			} else {
				// Single value - check assignment compatibility
				check_assignment(ctx, &y, left_type, name)
			}
		}
	} else {
		// No value type extracted - report error
		check_or_else_expr_no_value_error(ctx, name, x, type_hint)
	}

	// Set result to value type (non-optional)
	if left_type == nil {
		left_type = t_invalid
	}
	o.mode = .Value
	o.type = left_type
	o.expr = node
	return .Expr
}

// check_or_return_expr checks or_return expressions
// Reference: /mnt/c/odin/src/check_expr.cpp:9362-9442
check_or_return_expr :: proc(ctx: ^Checker_Context, o: ^Operand, node: ^ast.Node, type_hint: ^Type) -> Expr_Kind {
	re := node.derived.(^ast.Or_Return_Expr)

	name := re.token.text
	x: Operand
	check_expr_base(ctx, &x, re.expr, type_hint)

	if x.mode == .Invalid {
		o.mode = .Value
		o.type = t_invalid
		o.expr = node
		return .Expr
	}

	left_type: ^Type = nil
	right_type: ^Type = nil
	check_or_return_split_types(ctx, &x, name, &left_type, &right_type)

	add_type_and_value(ctx, re.expr, x.mode, x.type, x.value)

	if right_type == nil {
		check_or_else_expr_no_value_error(ctx, name, x, type_hint)
	} else {
		proc_type := base_type(ctx.curr_proc_sig)
		if proc_type == nil || proc_type.kind != .Proc {
			// Will be caught by the check below
		} else {
			pt := &proc_type.variant.(Type_Proc)
			result_type := pt.results

			if result_type == nil {
				error(node, "'%s' requires the current procedure to have at least one return value", name)
			} else if result_type.kind == .Tuple {
				rt := &result_type.variant.(Type_Tuple)
				vars := rt.variables[:]
				vars_count := len(vars)

				if vars_count == 0 {
					error(node, "'%s' requires the current procedure to have at least one return value", name)
				} else {
					// Get the last return value type
					end_type := get_entity_type(vars[vars_count - 1])

					if vars_count > 1 {
						if !pt.has_named_results {
							error(node, "'%s' within a procedure with more than 1 return value requires that the return values are named, allowing for early return", name)
						}
					}

					// Create operand for type checking
					rhs: Operand
					rhs.type = right_type
					rhs.mode = .Value

					// Allow implicit conversion between boolean types
					if is_type_boolean(right_type) && is_type_boolean(end_type) {
						// Allow - improves experience with third-party code
					} else if is_type_boolean(right_type) && type_has_nil(end_type) {
						// Allow boolean from type assertion (.?) with nil-able return type
						// On failure, or_return returns nil for the type
					} else if !check_is_assignable_to(ctx, &rhs, end_type) {
						// C++ Reference: check_builtin.cpp:139-145
						rhs_str := type_to_string(right_type)
						end_str := type_to_string(end_type)
						error(node, "Cannot assign end value '%s' of or_return to return type '%s'", rhs_str, end_str)
					}
				}
			}
		}
	}

	o.expr = node
	o.type = left_type
	if left_type != nil {
		o.mode = .Value
	} else {
		o.mode = .No_Value
	}

	if ctx.curr_proc_sig == nil {
		error(node, "'%s' can only be used within a procedure", name)
	}

	if ctx.in_defer {
		error(node, "'or_return' cannot be used within a defer statement")
	}

	return .Expr
}

// check_or_branch_expr checks or_break and or_continue expressions
// Reference: /mnt/c/odin/src/check_expr.cpp:9445-9545
check_or_branch_expr :: proc(ctx: ^Checker_Context, o: ^Operand, node: ^ast.Node, type_hint: ^Type) -> Expr_Kind {
	be := node.derived.(^ast.Or_Branch_Expr)

	name := be.token.text
	x: Operand
	check_expr_base(ctx, &x, be.expr, type_hint)

	if x.mode == .Invalid {
		o.mode = .Value
		o.type = t_invalid
		o.expr = node
		return .Expr
	}

	left_type: ^Type = nil
	right_type: ^Type = nil
	check_or_return_split_types(ctx, &x, name, &left_type, &right_type)

	add_type_and_value(ctx, be.expr, x.mode, x.type, x.value)

	if right_type == nil {
		check_or_else_expr_no_value_error(ctx, name, x, type_hint)
	} else {
		if is_type_boolean(right_type) || type_has_nil(right_type) {
			// okay
		} else {
			str := type_to_string(right_type)
			error(node, "'%s' requires a boolean or nil-able type, got %s", name, str)
		}
	}

	o.expr = node
	o.type = left_type
	if left_type != nil {
		o.mode = .Value
	} else {
		o.mode = .No_Value
	}

	if ctx.curr_proc_sig == nil {
		error(node, "'%s' can only be used within a procedure", name)
	}

	label := be.label

	// Check context based on token kind
	#partial switch be.token.kind {
	case .Or_Break:
		node.viral_state_flags |= {.Contains_Or_Break}
		if !(.Break_Allowed in ctx.stmt_flags) && label == nil {
			error(node, "'%s' only allowed in non-inline loops or 'switch' statements", name)
		}
	case .Or_Continue:
		if !(.Continue_Allowed in ctx.stmt_flags) && label == nil {
			error(node, "'%s' only allowed in non-inline loops", name)
		}
	}

	// Label handling
	if label != nil {
		if ctx.in_defer {
			error(label, "A labelled '%s' cannot be used within a 'defer'", name)
			return .Expr
		}

		// Validate label is an identifier
		if _, ok := label.derived.(^ast.Ident); !ok {
			error(label, "A branch statement's label name must be an identifier")
			return .Expr
		}

		// Look up the label entity
		label_op: Operand
		e := check_ident(ctx, &label_op, label, nil, nil, false)
		if e == nil {
			label_name := label.derived.(^ast.Ident).name
			error(label, "Undeclared label name: %s", label_name)
			return .Expr
		}

		add_entity_use(ctx, label, e)

		if e.kind != .Label {
			label_name := label.derived.(^ast.Ident).name
			error(label, "'%s' is not a label", label_name)
			return .Expr
		}

		// Validate label's parent statement matches the branch kind
		label_entity := &e.variant.(Entity_Label)
		parent := label_entity.parent
		if parent == nil {
			error(label, "Label has no parent statement")
			return .Expr
		}

		// Validate parent statement type matches token kind
		#partial switch _ in parent.derived_stmt {
		case ^ast.Block_Stmt, ^ast.If_Stmt, ^ast.Switch_Stmt:
			if be.token.kind == .Or_Continue {
				error(label, "Label '%s' can only be used with 'or_break' here, not 'or_continue'", e.token.text)
			}
		case ^ast.Range_Stmt, ^ast.For_Stmt:
			// Both or_break and or_continue are valid for loops
		case:
			error(label, "Label '%s' targets an invalid statement type", e.token.text)
		}
	}

	return .Expr
}

// check_expr_base is the main expression checking dispatcher
// Reference: /mnt/c/odin/src/check_expr.cpp:11342-11765
//
// This implementation now handles:
// - Identifiers (via check_ident)
// - Basic literals (via check_literal)
// - Binary expressions (via check_binary_expr)
// - Unary expressions (via check_unary_expr)
// check_expr_base checks an expression and RECORDS its type-and-value on the node.
//
// C++ Reference: check_expr.cpp:12670-12690. C++ splits this in two: check_expr_base_internal
// does the dispatch, and check_expr_base wraps it and calls add_type_and_value(c, node, ...)
// UNCONDITIONALLY for every expression it checks. That single call is what guarantees any
// checked node has a type-and-value.
//
// The port had no such wrapper — the dispatch WAS check_expr_base, and type-and-value was only
// recorded at ~24 scattered special-case sites. So most expressions never got one, and any
// consumer that expects a checked node to have a type-and-value would find nothing. The visible
// symptom was that `m[k] = v` — ANY map assignment — aborted on check_stmt.odin's `has_tav`
// assertion for the map expression, because a plain identifier was never recorded.
check_expr_base :: proc(ctx: ^Checker_Context, o: ^Operand, node: ^ast.Node, type_hint: ^Type) -> Expr_Kind {
	kind := check_expr_base_internal(ctx, o, node, type_hint)
	// C++ line 12688 — every expression, no exceptions. add_type_and_value itself skips
	// .Invalid modes and nil nodes, matching C++'s own guards.
	add_type_and_value(ctx, node, o.mode, o.type, o.value)
	return kind
}

// make_deref_expr and make_address_expr build the two AST nodes the arrow-call desugaring
// needs when the receiver does not directly match the callee's first parameter.
//
// C++ Reference: check_expr.cpp:11805 (ast_deref_expr) and 11815 (ast_unary_expr with
// Token_And) - bill's own comment there calls it an "AST GENERATION HACK", but it is load
// bearing: `v->method()` where method takes ^T and v is a variable only type-checks because
// the receiver is rewritten to `&v`.
make_deref_expr :: proc(x: ^ast.Expr) -> ^ast.Expr {
	d := new(ast.Deref_Expr)
	d.pos = x.pos
	d.end = x.end
	d.expr = x
	d.op = tokenizer.Token{kind = .Pointer, text = "^", pos = x.pos}
	d.derived = d
	d.derived_expr = d
	return d
}

make_address_expr :: proc(x: ^ast.Expr) -> ^ast.Expr {
	u := new(ast.Unary_Expr)
	u.pos = x.pos
	u.end = x.end
	u.expr = x
	u.op = tokenizer.Token{kind = .And, text = "&", pos = x.pos}
	u.derived = u
	u.derived_expr = u
	return u
}

check_expr_base_internal :: proc(ctx: ^Checker_Context, o: ^Operand, node: ^ast.Node, type_hint: ^Type) -> Expr_Kind {
	// Initialize operand to invalid state
	o.mode = .Invalid
	o.type = t_invalid
	o.value = nil
	o.expr = node

	if node == nil {
		return .Stmt
	}

	// Dispatch based on node kind
	// Note: ast.Node has a derived field that contains the concrete node type
	#partial switch derived in node.derived {
	case ^ast.Ident:
		// Identifier expression
		check_ident(ctx, o, node, nil, type_hint, false)
		return .Expr

	case ^ast.Basic_Lit:
		// Literal expression
		check_literal(ctx, o, node, type_hint)
		return .Expr

	case ^ast.Binary_Expr:
		// Binary operator expression
		check_binary_expr(ctx, o, node, type_hint, true)
		return .Expr

	case ^ast.Unary_Expr:
		// Unary operator expression
		check_unary_expr(ctx, o, node, type_hint)
		return .Expr

	case ^ast.Type_Cast:
		// Type cast expression: cast(T)expr or transmute(T)expr
		// Reference: /mnt/c/odin/src/check_expr.cpp:11544-11575
		tc := node.derived.(^ast.Type_Cast)

		// First, check the type expression
		check_expr_or_type(ctx, o, tc.type)
		if o.mode != .Type {
			error(tc.type, "Expected a type, got %v", o.mode)
			o.mode = .Invalid
		}
		if o.mode == .Invalid {
			o.expr = node
			return .Expr
		}

		target_type := o.type

		// Now check the value expression
		check_expr_base(ctx, o, tc.expr, target_type)

		// Propagate viral state flags from cast expression
		node.viral_state_flags |= tc.expr.viral_state_flags

		if o.mode != .Invalid {
			// Dispatch based on token kind (cast vs transmute)
			#partial switch tc.tok.kind {
			case .Transmute:
				check_transmute(ctx, node, o, target_type, true)
			case .Cast:
				check_cast(ctx, o, target_type, true)
			case:
				error(node, "Invalid AST: Invalid casting expression")
				o.mode = .Invalid
			}
		}
		return .Expr

	case ^ast.Auto_Cast:
		// Auto cast expression: auto_cast expr
		// Reference: /mnt/c/odin/src/check_expr.cpp:11577-11590
		ac := node.derived.(^ast.Auto_Cast)

		check_expr_base(ctx, o, ac.expr, type_hint)

		// Propagate viral state flags from auto cast expression
		node.viral_state_flags |= ac.expr.viral_state_flags

		if o.mode == .Invalid {
			o.expr = node
			return .Expr
		}

		// Auto cast uses type_hint if available
		if type_hint != nil {
			check_cast(ctx, o, type_hint)
		}

		o.expr = node
		return .Expr

	case ^ast.Index_Expr:
		// Index expression: x[i]
		// Reference: /mnt/c/odin/src/check_expr.cpp:11623-11625
		return check_index(ctx, o, node, type_hint)

	case ^ast.Matrix_Index_Expr:
		// Matrix index expression: mat[row, col]
		// Reference: /mnt/c/odin/src/check_expr.cpp:11212-11261
		return check_matrix_index_expr(ctx, o, node, type_hint)

	case ^ast.Slice_Expr:
		// Slice expression: x[low:high]
		// Reference: /mnt/c/odin/src/check_expr.cpp:11626-11628
		return check_slice(ctx, o, node, type_hint)

	case ^ast.Selector_Expr:
		// Selector expression: x.y
		// Reference: /mnt/c/odin/src/check_expr.cpp:11617-11620
		check_selector(ctx, o, node, type_hint)
		return .Expr

	case ^ast.Selector_Call_Expr:
		// Arrow call: `x->y(123)` desugars to `x.y(x, 123)`.
		//
		// C++ Reference: check_expr.cpp:11714-11845. C++ REWRITES THE AST - it prepends the
		// receiver to the call's argument list and latches se->modified_call so the rewrite
		// happens exactly once. The port did neither: it checked sc.call verbatim, so the
		// receiver was never passed and every arrow call was short one argument. `o->bare()`
		// reported "Missing argument for parameter 'o'"; `o->setup(allocator)` put allocator
		// in slot 0 and reported "Missing argument for parameter 'allocator'". core/time's
		// Benchmark_Options and core/io's stream vtable are written entirely in this style.
		sc := node.derived.(^ast.Selector_Call_Expr)

		// C++ 11729-11736: the modified_call latch. This matters more here than in C++
		// because the port checks procedure bodies more than once (see task 127); without it
		// the receiver would be prepended again on every pass.
		if !sc.modified_call {
			if sel, sel_ok := sc.expr.derived.(^ast.Selector_Expr); sel_ok && sel.expr != nil {
				first_arg := sel.expr

				// C++ 11797-11818: adjust the receiver to the first parameter's type -
				// dereference a pointer, or take the address of an addressable value.
				// Skipped when the callee is a proc GROUP, exactly as C++ does (11774),
				// because the group has no single first parameter to adjust against.
				// C++ 11738-11743 brackets this probe with
				// allow_arrow_right_selector_expr = true; without it the Selector_Expr's own
				// guard (check_expr.odin:4254) rejects the `->` as being outside a call.
				callee: Operand
				prev_allow_arrow := ctx.allow_arrow_right_selector_expr
				ctx.allow_arrow_right_selector_expr = true
				check_expr_base(ctx, &callee, sc.expr, nil)
				ctx.allow_arrow_right_selector_expr = prev_allow_arrow
				if callee.mode != .Proc_Group {
					if pt := base_type(callee.type); pt != nil && pt.kind == .Proc {
						proc_info := pt.variant.(Type_Proc)
						if proc_info.params != nil && proc_info.params.kind == .Tuple {
							vars := proc_info.params.variant.(Type_Tuple).variables
							if len(vars) > 0 && vars[0] != nil {
								first_type := entity_type(vars[0])
								recv: Operand
								check_expr_base(ctx, &recv, first_arg, nil)
								if !check_is_assignable_to(ctx, &recv, first_type) {
									deref := recv
									deref.type = type_deref(recv.type)
									if check_is_assignable_to(ctx, &deref, first_type) {
										first_arg = make_deref_expr(first_arg)
									} else if recv.mode == .Variable {
										addr := recv
										addr.type = alloc_type_pointer(recv.type)
										if check_is_assignable_to(ctx, &addr, first_type) {
											first_arg = make_address_expr(first_arg)
										}
									}
								}
							}
						}
					}
				}

				// C++ 11843-11846: prepend and latch.
				new_args := make([]^ast.Expr, len(sc.call.args) + 1, ctx.checker.allocator)
				new_args[0] = first_arg
				copy(new_args[1:], sc.call.args)
				sc.call.args = new_args
			}
			sc.modified_call = true
		}

		kind := check_call_expr(ctx, o, sc.call, type_hint)
		node.viral_state_flags |= sc.call.viral_state_flags
		o.expr = node
		return kind

	case ^ast.Call_Expr:
		// Call expression: f(x, y, z)
		// Reference: /mnt/c/odin/src/check_expr.cpp:8155-8418
		return check_call_expr(ctx, o, node, type_hint)

	case ^ast.Comp_Lit:
		// Compound literal: T{...}
		// Reference: /mnt/c/odin/src/check_expr.cpp:9763-10728
		return check_compound_literal(ctx, o, node, type_hint)

	case ^ast.Ternary_If_Expr:
		// Ternary if expression: x if cond else y
		// Reference: /mnt/c/odin/src/check_expr.cpp:11499-11501
		return check_ternary_if_expr(ctx, o, node, type_hint)

	case ^ast.Ternary_When_Expr:
		// Ternary when expression: x when cond else y
		// Reference: /mnt/c/odin/src/check_expr.cpp:11503-11505
		return check_ternary_when_expr(ctx, o, node, type_hint)

	case ^ast.Type_Assertion:
		// Type assertion expression: value.(Type)
		// Reference: /mnt/c/odin/src/check_expr.cpp:11541-11543
		return check_type_assertion(ctx, o, node, type_hint)

	case ^ast.Implicit_Selector_Expr:
		// Implicit selector expression: .field
		// Reference: /mnt/c/odin/src/check_expr.cpp:11625-11627
		return check_implicit_selector_expr(ctx, o, node, type_hint)

	case ^ast.Or_Else_Expr:
		// Or else expression: value or_else default_value
		// Reference: /mnt/c/odin/src/check_expr.cpp:9235-9360
		return check_or_else_expr(ctx, o, node, type_hint)

	case ^ast.Or_Return_Expr:
		// Or return expression: value or_return
		// Reference: /mnt/c/odin/src/check_expr.cpp:12405-12407
		// NOTE: C++ sets this flag here but never reads it anywhere; kept for parity.
		node.viral_state_flags |= {.Contains_Or_Return}
		return check_or_return_expr(ctx, o, node, type_hint)

	case ^ast.Or_Branch_Expr:
		// Or branch expression: value or_break label, value or_continue label
		// Reference: /mnt/c/odin/src/check_expr.cpp:9445-9545
		return check_or_branch_expr(ctx, o, node, type_hint)

	case ^ast.Paren_Expr:
		// Parenthesized expression: (expr)
		// Reference: /mnt/c/odin/src/check_expr.cpp:11524-11528
		pe := node.derived.(^ast.Paren_Expr)
		kind := check_expr_base(ctx, o, pe.expr, type_hint)
		node.viral_state_flags |= pe.expr.viral_state_flags
		o.expr = node
		return kind

	case ^ast.Tag_Expr:
		// Tag expression: #tag expr
		// Reference: /mnt/c/odin/src/check_expr.cpp:11530-11538
		te := node.derived.(^ast.Tag_Expr)
		name := te.name
		error(node, "Unknown tag expression, #%s", name)
		kind := Expr_Kind.Expr
		if te.expr != nil {
			kind = check_expr_base(ctx, o, te.expr, type_hint)
			node.viral_state_flags |= te.expr.viral_state_flags
		}
		o.expr = node
		return kind

	case ^ast.Implicit:
		// Implicit values like 'context'
		// Reference: /mnt/c/odin/src/check_expr.cpp:11382-11409
		impl := node.derived.(^ast.Implicit)

		// Check if this is the context implicit value
		if impl.tok.text == "context" {
			// The 'context' keyword - special implicit variable
			if ctx.curr_proc_sig == nil {
				error(node, "'context' is only allowed within procedures")
				return .Stmt
			}

			// C++ Reference: check_expr.cpp:12277-12279. Assigning TO `context` is what
			// defines it for the rest of the scope — this is how a "c" or "contextless"
			// procedure bootstraps one:
			//
			//     main :: proc "c" (argc: i32, argv: [^]cstring) -> i32 {
			//         context = default_context()
			//         ...                       // context is now available here
			//     }
			//
			// The port had no `assignment_lhs_hint` at all, so the assignment was checked
			// as a READ, reported "'context' has not been defined", and left the flag
			// clear — making every subsequent context use and every Odin-convention call
			// in the same body fail too. That is both halves of this pair of classes.
			if ctx.assignment_lhs_hint != nil && unparen_expr(ctx.assignment_lhs_hint) == node {
				ctx.scope.flags += {.Context_Defined}
			}

			// Check if context has been defined in scope
			if .Context_Defined not_in ctx.scope.flags {
				error(node, "'context' has not been defined within this scope")
			}

			// C++ Reference: check_expr.cpp:12285 - init_core_context(c->checker) is called HERE,
			// immediately before assigning t_context, not only from init_preload.
			//
			// The previous comment here claimed "core context initialization is handled during
			// global entity checking". That is exactly backwards: init_preload runs AFTER
			// check_all_global_entities (check_files.odin, matching checker.cpp:7695-7698), and
			// procedure signatures with `allocator := context.allocator` are checked inside that
			// earlier window - so t_context was still nil for them and every such default
			// parameter reported "Cannot use a selector expression on nil-value expression".
			init_core_context(ctx.checker)
			o.mode = .Context
			o.type = t_context
			return .Expr
		} else {
			error(node, "Illegal implicit name '%s'", impl.tok.text)
			return .Stmt
		}

	case ^ast.Undef:
		// Uninitialized literal (---)
		// Reference: /mnt/c/odin/src/check_expr.cpp:11415-11419
		// Note: ast.Uninit doesn't exist, it's ast.Undef
		o.mode = .Value
		o.type = t_untyped_uninit
		error(node, "Global variables will always be zeroed if left unassigned, --- is disallowed")
		return .Expr

	case ^ast.Basic_Directive:
		// Directive expression: #file, #line, #procedure, #column, #load, etc.
		// Reference: /mnt/c/odin/src/check_expr.cpp:9058-9188, 11446-11448
		return check_basic_directive_expr(ctx, o, node, type_hint)

	case ^ast.Proc_Group:
		// Procedure group - illegal in expression context
		// Reference: /mnt/c/odin/src/check_expr.cpp:11450-11453
		error(node, "Illegal use of a procedure group")
		o.mode = .Invalid
		return .Stmt

	case ^ast.Proc_Lit:
		// Procedure literal (inline procedure)
		// C++ Reference: check_expr.cpp:11630-11672
		pl := node.derived.(^ast.Proc_Lit)

		// Create a new context for the procedure literal
		proc_ctx := ctx^

		// Allocate the procedure type
		// C++ Reference: check_decl.cpp:1225-1230
		proc_type := alloc_type_proc(
			scope = proc_ctx.scope,
			params = nil,
			results = nil,
			param_count = 0,
			result_count = 0,
			variadic = false,
			calling_convention = default_calling_convention(),
		)

		// Open a scope for the procedure
		check_open_scope(&proc_ctx, pl.type)

		// Create declaration info for the procedure
		decl := make_decl_info(proc_ctx.scope, proc_ctx.decl)
		decl.proc_lit = pl
		proc_ctx.decl = decl

		// Procedure literals cannot have tags
		// C++ Reference: check_expr.cpp:11642-11645
		if pl.tags != {} {
			error(node, "A procedure literal cannot have tags")
			pl.tags = {}
		}

		// Check the procedure type
		check_procedure_type(&proc_ctx, proc_type, pl.type)
		if proc_type.kind != .Proc {
			expr_str := expr_to_string(node)
			defer delete(expr_str)
			error(node, "Invalid procedure literal '%s'", expr_str)
			check_close_scope(&proc_ctx)
			return .Stmt
		}

		// Procedure literals must have a body
		// C++ Reference: check_expr.cpp:11656-11659
		if pl.body == nil {
			error(node, "A procedure literal must have a body")
			check_close_scope(&proc_ctx)
			return .Stmt
		}

		// Store the declaration info in the AST node
		pl.decl = decl

		// Queue the procedure body for later checking
		// C++ Reference: check_expr.cpp:11662
		empty_token: tokenizer.Token
		check_procedure_later_from_params(
			proc_ctx.checker,
			proc_ctx.file,
			empty_token,
			decl,
			proc_type,
			pl.body.derived.(^ast.Block_Stmt),
			u64(transmute(u32)pl.tags),
		)

		// Track nested procedure literals
		// C++ Reference: check_expr.cpp:11663-11665
		append(&proc_ctx.checker.nested_proc_lits, decl)

		check_close_scope(&proc_ctx)

		o.mode = .Value
		o.type = proc_type
		o.value = exact_value_procedure(cast(^ast.Expr)pl)
		return .Expr

	case ^ast.Deref_Expr:
		// Explicit dereference: ^ptr
		// Reference: /mnt/c/odin/src/check_expr.cpp:11647-11689
		de := node.derived.(^ast.Deref_Expr)

		check_expr_or_type(ctx, o, de.expr)
		node.viral_state_flags |= de.expr.viral_state_flags

		if o.mode == .Invalid {
			o.expr = node
			return .Stmt
		} else if o.mode == .Type {
			error(o.expr, "Cannot dereference a type")
			o.mode = .Invalid
			o.expr = node
			return .Stmt
		}

		t := base_type(o.type)
		if t.kind == .Pointer && !is_type_empty_union(t.variant.(Type_Pointer).elem) {
			o.mode = .Variable
			o.type = t.variant.(Type_Pointer).elem
		} else if t.kind == .Soa_Pointer {
			o.mode = .Soa_Variable
			o.type = type_deref(t)
		} else {
			// C++ Reference: check_expr.cpp:12576-12586. Names the expression, and the
			// multi-pointer hint is C++'s wording inside an ERROR_BLOCK. The port's
			// "Suggestion: Multi-pointer types cannot be dereferenced..." was invented, and
			// being unblocked it printed BEFORE the error.
			str := expr_to_string(o.expr)
			defer delete(str)
			begin_error_block()
			error(o.expr, "Cannot dereference '%s' of type '%s'", str, type_to_string(o.type))
			if is_type_multi_pointer(o.type) {
				error_line("\tDid you mean '%s[0]'?\n", str)
			}
			end_error_block()
			o.mode = .Invalid
			o.expr = node
			return .Stmt
		}
		o.expr = node
		return .Expr

	case ^ast.Inline_Asm_Expr:
		// Inline assembly expression
		// Reference: /mnt/c/odin/src/check_expr.cpp:11720-11736
		// Inline assembly is validated but produces a procedure-like type
		asm_expr := node.derived.(^ast.Inline_Asm_Expr)

		// Check that asm string is a constant string
		if asm_expr.asm_string != nil {
			asm_op := Operand{}
			check_expr(ctx, &asm_op, asm_expr.asm_string)
			if asm_op.mode != .Constant || !is_type_string(asm_op.type) {
				error(asm_expr.asm_string, "Inline assembly string must be a constant string")
			}
		}

		// Check constraints string if present
		if asm_expr.constraints_string != nil {
			constraint_op := Operand{}
			check_expr(ctx, &constraint_op, asm_expr.constraints_string)
			if constraint_op.mode != .Constant || !is_type_string(constraint_op.type) {
				error(asm_expr.constraints_string, "Inline assembly constraints must be a constant string")
			}
		}

		// Build return type from return_type expression
		return_type: ^Type = nil
		if asm_expr.return_type != nil {
			return_type = check_type(ctx, asm_expr.return_type)
		}

		// The result is the return type of the inline assembly
		if return_type != nil {
			o.type = return_type
			o.mode = .Value
		} else {
			o.type = nil
			o.mode = .No_Value
		}
		o.expr = node
		return .Expr

	// Type expression nodes - these are all types, not expressions
	case ^ast.Distinct_Type, ^ast.Typeid_Type, ^ast.Poly_Type, ^ast.Proc_Type, ^ast.Pointer_Type, ^ast.Multi_Pointer_Type, ^ast.Array_Type, ^ast.Dynamic_Array_Type, ^ast.Fixed_Capacity_Dynamic_Array_Type, ^ast.Struct_Type, ^ast.Union_Type, ^ast.Enum_Type, ^ast.Map_Type, ^ast.Bit_Set_Type, ^ast.Matrix_Type:
		// Reference: /mnt/c/odin/src/check_expr.cpp:11738-11756
		o.mode = .Type
		o.type = check_type(ctx, node)
		return .Expr

	case ^ast.Bad_Expr:
		// Error node - already reported by parser
		return .Stmt

	case:
		// Unsupported expression type - report error
		// NOTE: `derived` is an ast.Any_Node here (this is the default arm of the type switch),
		// so "%T" printed the union's own name - every one of these read "Any_Node", which says
		// nothing about what is actually unhandled. Report the variant instead.
		error(node, "Expression type not yet supported: %v", reflect.union_variant_typeid(node.derived))
		o.mode = .Invalid
		o.type = t_invalid
		return .Stmt
	}
}

// check_assignment validates that an operand can be assigned to a target type
// This is the main entry point for type checking assignments, parameters, returns, etc.
// Ported from check_expr.cpp:1081-1267
//
// Key responsibilities:
// 1. Reject tuple expressions (must be single values)
// 2. Handle untyped constant/value conversion via convert_to_typed
// 3. Special handling for untyped nil and uninit
// 4. Resolve procedure groups to specific procedures
// 5. Check assignability and report detailed errors
//
// Returns: false if assignment is invalid (after reporting error), true otherwise
check_assignment :: proc(ctx: ^Checker_Context, operand: ^Operand, target_type: ^Type, context_name: string) -> bool {
	// Step 1: Ensure operand is not a tuple (must be single value)
	check_not_tuple(ctx, operand)
	if operand.mode == .Invalid {
		return false
	}

	// Get appropriate article for error messages
	article := error_article(context_name)

	// Step 2: Handle untyped operands (constants and untyped values)
	if is_type_untyped(operand.type) {
		actual_target_type := target_type

		// If no target type or target is 'any', use default type for the untyped value
		if target_type == nil || is_type_any(target_type) {
			// Special error cases: untyped nil and uninit need explicit types
			if target_type == nil && is_type_untyped_uninit(operand.type) {
				error(operand.expr, "Use of --- in %s%s", article, context_name)
				operand.mode = .Invalid
				return false
			}

			if target_type == nil && operand.type == t_untyped_nil {
				error(operand.expr, "Use of untyped nil in %s%s", article, context_name)
				operand.mode = .Invalid
				return false
			}

			// Get default type (e.g., int for untyped integer)
			actual_target_type = default_type(operand.type)
			if target_type != nil && !is_type_any(target_type) {
				assert(is_type_typed(actual_target_type))
			}

			// Add type info for runtime type info tracking
			add_type_info_type(ctx, target_type)
			add_type_info_type(ctx, actual_target_type)
		}

		// Convert untyped operand to typed target type
		convert_to_typed(ctx, operand, actual_target_type)
		if operand.mode == .Invalid {
			return false
		}
	}

	// Step 3: If no target type, assignment is vacuously valid (for type inference)
	if target_type == nil {
		return true
	}

	// Step 4: Handle procedure groups - resolve to specific procedure matching target type
	// C++ Reference: check_expr.cpp:2478-2520
	if operand.mode == .Proc_Group {
		good := false
		matched_entity: ^Entity = nil

		// Only try to resolve if target is a procedure type
		if is_type_proc(target_type) {
			// C++ line 2480-2481: Get procedures from the group
			procs := proc_group_entities(ctx, operand)

			// C++ lines 2483-2510: Find best matching procedure
			for entity in procs {
				if entity == nil {
					continue
				}

				entity_type := entity_type(entity)
				if entity_type == nil {
					continue
				}

				// C++ lines 2489-2502: Check if this procedure type is assignable to target
				temp_operand := Operand {
					mode = .Value,
					type = entity_type,
				}

				if check_is_assignable_to(ctx, &temp_operand, target_type) {
					if matched_entity != nil {
						// C++ lines 2493-2497: Ambiguous - multiple matches
						error(operand.expr, "Ambiguous procedure group resolution - multiple procedures match '%s' in %s%s", type_to_string(target_type), article, context_name)
						operand.mode = .Invalid
						return false
					}
					matched_entity = entity
					good = true
				}
			}
		}

		if !good {
			// Failed to resolve procedure group
			error(operand.expr, "Cannot assign overloaded procedure group to '%s' in %s%s", type_to_string(target_type), article, context_name)
			operand.mode = .Invalid
			return false
		}

		// C++ line 2513-2515: Mark entity usage and update operand
		if matched_entity != nil {
			add_entity_use(ctx, operand.expr, matched_entity)
			operand.type = entity_type(matched_entity)
			operand.mode = .Value
		}

		// Convert resolved procedure to typed
		convert_to_typed(ctx, operand, target_type)
		return true
	}

	// Step 5: Check if assignment is valid via assignability rules
	if check_is_assignable_to(ctx, operand, target_type) {
		// Special case: Type mode assigning to typeid
		if operand.mode == .Type && is_type_typeid(target_type) {
			add_type_info_type(ctx, operand.type)
			add_type_and_value(ctx, operand.expr, .Value, target_type, exact_value_typeid(operand.type))
		}
		return true
	}

	// Step 6: Assignment failed - report detailed error with context

	// Special error for builtin procedures
	if operand.mode == .Builtin {
		error(operand.expr, "Cannot assign built-in procedure to %s%s", article, context_name)
		return false
	}

	// Special error for type expressions
	if operand.mode == .Type {
		type_str := type_to_string(operand.type)

		if is_type_polymorphic(operand.type) {
			// C++ Reference: check_expr.cpp:9320-9325
			error(operand.expr, "Cannot assign '%s', a polymorphic type, to %s%s", type_str, article, context_name)
		} else {
			error(operand.expr, "Cannot assign '%s', a type, to %s%s", type_str, article, context_name)

			// Helpful suggestion for 'any' type
			// C++ Reference: check_expr.cpp:9326-9328
			if target_type != nil && is_type_any(target_type) {
				expr_str := expr_to_string(operand.expr)
				defer delete(expr_str)
				error_line("\tSuggestion: 'typeid_of(%s)'", expr_str)
			}
		}
		return false
	}

	// General assignment error with detailed type information
	op_type_str := type_to_string(operand.type)
	target_type_str := type_to_string(target_type)

	// C++ Reference: check_expr.cpp:1300-1308. Two divergences fixed here:
	//   - C++ names the EXPRESSION: "Cannot assign value 'arr' of type '[3]int' to '[]int'".
	//     The port omitted it, the same shape as the Cannot-convert family (LEDGER task 232).
	//   - C++ then calls check_assignment_error_suggestion, which the port implemented and
	//     never called, so none of its suggestions were ever emitted:
	//         Suggestion: The array expression may be sliced with arr[:]
	//         Suggestion: Did you mean `&v`
	//         Suggestion: A string may be transmuted to []u8
	//     A previous note here dismissed these as "quality improvements". C++ emits them, so
	//     they are parity, not polish.
	//
	// ERROR_BLOCK equivalent: the suggestion is an error_line continuation, and without the
	// block the buffered error and the immediate continuation come out in the wrong order.
	//
	// STILL NOT reproduced: C++'s "(package X)" disambiguation when both type names render
	// identically (check_expr.cpp:1286-1297), and the variadic/calling-convention hints below
	// it. Recorded rather than silently skipped.
	begin_error_block()
	expr_str := expr_to_string(operand.expr)
	defer delete(expr_str)
	error(operand.expr, "Cannot assign value '%s' of type '%s' to '%s' in %s%s", expr_str, op_type_str, target_type_str, article, context_name)
	check_assignment_error_suggestion(ctx, operand, target_type, operand.expr)
	end_error_block()

	return false
}

// type_to_string_shorthand provides a concise string representation of a type
// NOTE: Currently delegates to type_to_string - shorthand formatting is a quality improvement
// C++ Reference: checker.cpp (various locations)
type_to_string_shorthand :: proc(t: ^Type) -> string {
	return type_to_string(t)
}

type_to_string :: proc(t: ^Type, shorthand := true) -> string {
	if t == nil {
		return "<no type>"
	}

	// NOTE: C++ has NO special case for t_invalid. t_invalid is basic_types[Basic_Invalid]
	// (types.cpp:581) whose name string is "invalid type" (types.cpp:484), so it renders
	// through the ordinary Basic path. The port had an invented early return here producing
	// "<invalid>", which preempted basic_kind_to_string -- which already returns the correct
	// "invalid type". Every diagnostic naming an invalid type was therefore wrong.
	// The nil case above IS faithful: C++ prints "<no type>" at types.cpp:5368. LEDGER 286.

	builder := strings.builder_make(context.temp_allocator)
	write_type_to_string(&builder, t, shorthand)
	return strings.to_string(builder)
}

// write_type_to_string recursively writes a type to a string builder
// C++ Reference: types.cpp:4970-5314 (write_type_to_string)
write_type_to_string :: proc(b: ^strings.Builder, t: ^Type, shorthand := true) {
	if t == nil {
		strings.write_string(b, "<no type>")
		return
	}

	#partial switch t.kind {
	case .Basic:
		basic := t.variant.(Type_Basic)
		strings.write_string(b, basic_kind_to_string(basic.kind))

	case .Named:
		named := t.variant.(Type_Named)
		if named.name != "" {
			strings.write_string(b, named.name)
		} else {
			strings.write_string(b, "<named type>")
		}

	case .Generic:
		generic := t.variant.(Type_Generic)
		strings.write_rune(b, '$')
		if generic.name != "" {
			strings.write_string(b, generic.name)
		} else if generic.entity != nil {
			strings.write_string(b, generic.entity.token.text)
		} else {
			strings.write_string(b, "type")
		}
		if generic.specialized != nil {
			strings.write_rune(b, '/')
			write_type_to_string(b, generic.specialized, shorthand)
		}

	case .Pointer:
		ptr := t.variant.(Type_Pointer)
		strings.write_rune(b, '^')
		write_type_to_string(b, ptr.elem, shorthand)

	case .Multi_Pointer:
		mp := t.variant.(Type_Multi_Pointer)
		strings.write_string(b, "[^]")
		write_type_to_string(b, mp.elem, shorthand)

	case .Soa_Pointer:
		soa := t.variant.(Type_Soa_Pointer)
		strings.write_string(b, "#soa ^")
		write_type_to_string(b, soa.elem, shorthand)

	case .Array:
		arr := t.variant.(Type_Array)
		fmt.sbprintf(b, "[%d]", arr.count)
		write_type_to_string(b, arr.elem, shorthand)

	case .Enumerated_Array:
		ea := t.variant.(Type_Enumerated_Array)
		if ea.is_sparse {
			strings.write_string(b, "#sparse")
		}
		strings.write_rune(b, '[')
		write_type_to_string(b, ea.index, shorthand)
		strings.write_rune(b, ']')
		write_type_to_string(b, ea.elem, shorthand)

	case .Slice:
		sl := t.variant.(Type_Slice)
		strings.write_string(b, "[]")
		write_type_to_string(b, sl.elem, shorthand)

	case .Dynamic_Array:
		da := t.variant.(Type_Dynamic_Array)
		strings.write_string(b, "[dynamic]")
		write_type_to_string(b, da.elem, shorthand)

	case .Fixed_Capacity_Dynamic_Array:
		// C++ Reference: types.cpp:4691-4694. Without this arm every diagnostic
		// mentioning the type read "<unknown type>".
		fc := t.variant.(Type_Fixed_Capacity_Dynamic_Array)
		strings.write_string(b, "[dynamic; ")
		if fc.generic_capacity != nil {
			write_type_to_string(b, fc.generic_capacity, shorthand)
		} else {
			strings.write_i64(b, fc.capacity)
		}
		strings.write_string(b, "]")
		write_type_to_string(b, fc.elem, shorthand)

	case .Map:
		m := t.variant.(Type_Map)
		strings.write_string(b, "map[")
		write_type_to_string(b, m.key, shorthand)
		strings.write_rune(b, ']')
		write_type_to_string(b, m.value, shorthand)

	case .Struct:
		st := t.variant.(Type_Struct)
		// Handle SOA struct variants
		if st.soa_kind != .None {
			switch st.soa_kind {
			case .Fixed:
				fmt.sbprintf(b, "#soa[%d]", st.soa_count)
			case .Slice:
				strings.write_string(b, "#soa[]")
			case .Dynamic:
				strings.write_string(b, "#soa[dynamic]")
			case .None:
			}
			write_type_to_string(b, st.soa_elem, shorthand)
			return
		}
		strings.write_string(b, "struct")
		if st.is_packed {
			strings.write_string(b, " #packed")
		}
		if st.is_raw_union {
			strings.write_string(b, " #raw_union")
		}
		strings.write_string(b, " {")
		if shorthand && len(st.fields) > 16 {
			fmt.sbprintf(b, "%d fields...", len(st.fields))
		} else {
			for field, i in st.fields {
				if i > 0 {
					strings.write_string(b, ", ")
				}
				if field != nil {
					strings.write_string(b, field.token.text)
					strings.write_string(b, ": ")
					write_type_to_string(b, field.type, shorthand)
				}
			}
		}
		strings.write_rune(b, '}')

	case .Union:
		un := t.variant.(Type_Union)
		strings.write_string(b, "union")
		#partial switch un.kind {
		case .No_Nil:
			strings.write_string(b, " #no_nil")
		case .Shared_Nil:
			strings.write_string(b, " #shared_nil")
		}
		strings.write_string(b, " {")
		for variant, i in un.variants {
			if i > 0 {
				strings.write_string(b, ", ")
			}
			write_type_to_string(b, variant, shorthand)
		}
		strings.write_rune(b, '}')

	case .Enum:
		en := t.variant.(Type_Enum)
		strings.write_string(b, "enum")
		if en.base_type != nil {
			strings.write_rune(b, ' ')
			write_type_to_string(b, en.base_type, shorthand)
		}
		strings.write_string(b, " {")
		for field, i in en.fields {
			if i > 0 {
				strings.write_string(b, ", ")
			}
			if field != nil {
				strings.write_string(b, field.token.text)
			}
		}
		strings.write_rune(b, '}')

	case .Proc:
		pr := t.variant.(Type_Proc)
		strings.write_string(b, "proc")
		// Write calling convention if not default
		#partial switch pr.calling_convention {
		case .C:
			strings.write_string(b, " \"c\" ")
		case .Std:
			strings.write_string(b, " \"std\" ")
		case .Fast:
			strings.write_string(b, " \"fast\" ")
		case .None:
			strings.write_string(b, " \"none\" ")
		case .Naked:
			strings.write_string(b, " \"naked\" ")
		case .Contextless:
			if default_calling_convention() != .Contextless {
				strings.write_string(b, " \"contextless\" ")
			}
		case .Odin:
			// Default, don't write
		}
		strings.write_rune(b, '(')
		if pr.params != nil {
			write_type_to_string(b, pr.params, shorthand)
		}
		strings.write_rune(b, ')')
		if pr.results != nil {
			strings.write_string(b, " -> ")
			results := pr.results.variant.(Type_Tuple)
			if len(results.variables) > 1 {
				strings.write_rune(b, '(')
			}
			write_type_to_string(b, pr.results, shorthand)
			if len(results.variables) > 1 {
				strings.write_rune(b, ')')
			}
		}

	case .Tuple:
		tu := t.variant.(Type_Tuple)
		comma_index := 0
		for v in tu.variables {
			if v == nil {
				continue
			}
			if comma_index > 0 {
				strings.write_string(b, ", ")
			}
			comma_index += 1
			// Handle ellipsis (variadic)
			if .Ellipsis in v.flags {
				strings.write_string(b, "..")
				if v.type != nil {
					bt := base_type(v.type)
					if sl, ok := bt.variant.(Type_Slice); ok {
						write_type_to_string(b, sl.elem, shorthand)
						continue
					}
				}
			}
			write_type_to_string(b, v.type, shorthand)
		}

	case .Bit_Set:
		bs := t.variant.(Type_Bit_Set)
		strings.write_string(b, "bit_set[")
		if bs.elem == nil {
			strings.write_string(b, "<unresolved>")
		} else if is_type_enum(bs.elem) {
			write_type_to_string(b, bs.elem, shorthand)
		} else {
			fmt.sbprintf(b, "%d..=%d", bs.lower, bs.upper)
		}
		if bs.underlying != nil {
			strings.write_string(b, "; ")
			write_type_to_string(b, bs.underlying, shorthand)
		}
		strings.write_rune(b, ']')

	case .Simd_Vector:
		sv := t.variant.(Type_Simd_Vector)
		fmt.sbprintf(b, "#simd[%d]", sv.count)
		write_type_to_string(b, sv.elem, shorthand)

	case .Matrix:
		mx := t.variant.(Type_Matrix)
		if mx.is_row_major {
			strings.write_string(b, "#row_major ")
		}
		fmt.sbprintf(b, "matrix[%d, %d]", mx.row_count, mx.column_count)
		write_type_to_string(b, mx.elem, shorthand)

	case .Bit_Field:
		bf := t.variant.(Type_Bit_Field)
		strings.write_string(b, "bit_field ")
		write_type_to_string(b, bf.backing_type, shorthand)
		strings.write_string(b, " {...}")

	case:
		strings.write_string(b, "<unknown type>")
	}
}

// basic_kind_to_string returns the canonical name of a basic type
// C++ Reference: /mnt/c/odin/src/types.cpp:470-561
// Matches the exact string representation used in the C++ basic_types array
basic_kind_to_string :: proc(kind: Basic_Kind) -> string {
	switch kind {
	case .Invalid:
		return "invalid type"

	// Boolean variants
	case .Llvm_Bool:
		return "llvm bool"
	case .Bool:
		return "bool"
	case .B8:
		return "b8"
	case .B16:
		return "b16"
	case .B32:
		return "b32"
	case .B64:
		return "b64"

	// Integer types
	case .I8:
		return "i8"
	case .U8:
		return "u8"
	case .I16:
		return "i16"
	case .U16:
		return "u16"
	case .I32:
		return "i32"
	case .U32:
		return "u32"
	case .I64:
		return "i64"
	case .U64:
		return "u64"
	case .I128:
		return "i128"
	case .U128:
		return "u128"
	case .Rune:
		return "rune"

	// Float types
	case .F16:
		return "f16"
	case .F32:
		return "f32"
	case .F64:
		return "f64"

	// Complex types
	case .Complex32:
		return "complex32"
	case .Complex64:
		return "complex64"
	case .Complex128:
		return "complex128"

	// Quaternion types
	case .Quaternion64:
		return "quaternion64"
	case .Quaternion128:
		return "quaternion128"
	case .Quaternion256:
		return "quaternion256"

	// Platform-dependent integer types
	case .Int:
		return "int"
	case .Uint:
		return "uint"
	case .Uintptr:
		return "uintptr"
	case .Rawptr:
		return "rawptr"

	// String types
	case .String:
		return "string"
	case .Cstring:
		return "cstring"
	case .String16:
		return "string16"
	case .Cstring16:
		return "cstring16"

	// Special types
	case .Any:
		return "any"
	case .Typeid:
		return "typeid"

	// Endian-specific integer types (little-endian)
	case .I16le:
		return "i16le"
	case .U16le:
		return "u16le"
	case .I32le:
		return "i32le"
	case .U32le:
		return "u32le"
	case .I64le:
		return "i64le"
	case .U64le:
		return "u64le"
	case .I128le:
		return "i128le"
	case .U128le:
		return "u128le"

	// Endian-specific integer types (big-endian)
	case .I16be:
		return "i16be"
	case .U16be:
		return "u16be"
	case .I32be:
		return "i32be"
	case .U32be:
		return "u32be"
	case .I64be:
		return "i64be"
	case .U64be:
		return "u64be"
	case .I128be:
		return "i128be"
	case .U128be:
		return "u128be"

	// Endian-specific float types (little-endian)
	case .F16le:
		return "f16le"
	case .F32le:
		return "f32le"
	case .F64le:
		return "f64le"

	// Endian-specific float types (big-endian)
	case .F16be:
		return "f16be"
	case .F32be:
		return "f32be"
	case .F64be:
		return "f64be"

	// Untyped variants
	case .Untyped_Bool:
		return "untyped bool"
	case .Untyped_Integer:
		return "untyped integer"
	case .Untyped_Float:
		return "untyped float"
	case .Untyped_Complex:
		return "untyped complex"
	case .Untyped_Quaternion:
		return "untyped quaternion"
	case .Untyped_String:
		return "untyped string"
	case .Untyped_Rune:
		return "untyped rune"
	case .Untyped_Nil:
		return "untyped nil"
	case .Untyped_Uninit:
		return "untyped uninitialized"
	}

	return "unknown"
}

// ===========================================================================
// Type Casting and Conversion
// ===========================================================================
// Reference: /mnt/c/odin/src/check_expr.cpp:3246-3789

// check_is_castable_to checks if an operand can be cast to a target type
// This implements the type casting rules for Odin's cast() operator
// Reference: /mnt/c/odin/src/check_expr.cpp:3246-3523
check_is_castable_to :: proc(ctx: ^Checker_Context, operand: ^Operand, target: ^Type) -> bool {
	// If assignable, it's definitely castable
	if check_is_assignable_to(ctx, operand, target) {
		return true
	}

	is_constant := operand.mode == .Constant

	src := core_type(operand.type)
	dst := core_type(target)

	// Identical core types are always castable
	if are_types_identical(src, dst) {
		return true
	}

	// Special handling for untyped string constants to byte/rune arrays
	// Reference: check_expr.cpp:3275-3284
	if is_constant && is_type_untyped(src) && is_type_string(src) {
		if str_val, is_str := operand.value.(string); is_str {
			// Check if casting to [N]u8
			if is_type_u8_array(dst) {
				arr := base_type(dst).variant.(Type_Array)
				return i64(len(str_val)) == arr.count
			}
			// Check if casting to [N]rune
			if is_type_rune_array(dst) {
				arr := base_type(dst).variant.(Type_Array)
				rune_count := utf8.rune_count_in_string(str_val)
				return i64(rune_count) == arr.count
			}
		}
	}

	// Array to array (same element type, different count)
	if src_arr, src_ok := src.variant.(Type_Array); src_ok {
		if dst_arr, dst_ok := dst.variant.(Type_Array); dst_ok {
			if are_types_identical(dst_arr.elem, src_arr.elem) {
				return dst_arr.count == src_arr.count
			}
		}
	}

	// Slice to slice (same element type)
	if src_slice, src_ok := src.variant.(Type_Slice); src_ok {
		if dst_slice, dst_ok := dst.variant.(Type_Slice); dst_ok {
			return are_types_identical(dst_slice.elem, src_slice.elem)
		}
	}

	// Cast between booleans and integers
	if is_type_boolean(src) || is_type_integer(src) {
		if is_type_boolean(dst) || is_type_integer(dst) {
			return true
		}
	}

	// Cast between numbers (integers and floats)
	if is_type_integer(src) || is_type_float(src) {
		if is_type_integer(dst) || is_type_float(dst) {
			return true
		}
	}

	// Bit field type casting - can cast to/from backing type
	// Reference: check_expr.cpp:7455-7464
	if is_type_bit_field(src) {
		bf := base_type(src).variant.(Type_Bit_Field)
		if are_types_identical(core_type(bf.backing_type), dst) {
			return true
		}
	}
	if is_type_bit_field(dst) {
		bf := base_type(dst).variant.(Type_Bit_Field)
		if are_types_identical(src, core_type(bf.backing_type)) {
			return true
		}
	}

	// Integer <-> rune
	if is_type_integer(src) && is_type_rune(dst) {
		return true
	}
	if is_type_rune(src) && is_type_integer(dst) {
		return true
	}

	// Complex <-> complex
	if is_type_complex(src) && is_type_complex(dst) {
		return true
	}

	// Float -> complex
	if is_type_float(src) && is_type_complex(dst) {
		return true
	}

	// Quaternion type casting
	if is_type_float(src) && is_type_quaternion(dst) {
		return true
	}
	if is_type_complex(src) && is_type_quaternion(dst) {
		return true
	}
	if is_type_quaternion(src) && is_type_quaternion(dst) {
		return true
	}

	// Matrix type casting
	if is_type_matrix(src) && is_type_matrix(dst) {
		return true
	}

	// Cast between pointers
	if is_type_pointer(src) && is_type_pointer(dst) {
		return true
	}

	// rawptr <-> typed pointer
	if are_types_identical(src, t_rawptr) && is_type_pointer(dst) {
		return true
	}
	if is_type_pointer(src) && are_types_identical(dst, t_rawptr) {
		return true
	}

	// rawptr <-> multi-pointer
	if are_types_identical(src, t_rawptr) && is_type_multi_pointer(dst) {
		return true
	}
	if is_type_multi_pointer(src) && are_types_identical(dst, t_rawptr) {
		return true
	}

	// Multi-pointer casting
	if is_type_multi_pointer(src) && is_type_multi_pointer(dst) {
		return true
	}
	if is_type_multi_pointer(src) && is_type_pointer(dst) {
		return true
	}
	if is_type_pointer(src) && is_type_multi_pointer(dst) {
		return true
	}

	// uintptr <-> pointer
	if is_type_uintptr(src) && is_type_pointer(dst) {
		return true
	}
	if is_type_pointer(src) && is_type_uintptr(dst) {
		return true
	}
	// uintptr <-> multi-pointer casting
	if is_type_uintptr(src) && is_type_multi_pointer(dst) {
		return true
	}
	if is_type_multi_pointer(src) && is_type_uintptr(dst) {
		return true
	}

	// []u8 <-> string (not cstring)
	if is_type_u8_slice(src) && (is_type_string(dst) && !is_type_cstring(dst)) {
		return true
	}

	// []u16 <-> string16 (not cstring16)
	// C++ Reference: check_expr.cpp:3713-3716 - the exact UTF-16 counterpart of the rule
	// above, which the port had but its u16 twin was absent.
	if is_type_u16_slice(src) && (is_type_string16(dst) && !is_type_cstring16(dst)) {
		return true
	}

	// cstring casting rules
	// cstring <-> ^u8
	if is_type_cstring(src) && is_type_u8_ptr(dst) {
		return true
	}
	if is_type_u8_ptr(src) && is_type_cstring(dst) {
		return true
	}
	// cstring <-> [^]u8
	if is_type_cstring(src) && is_type_u8_multi_ptr(dst) {
		return true
	}
	if is_type_u8_multi_ptr(src) && is_type_cstring(dst) {
		return true
	}
	// cstring <-> rawptr
	if is_type_cstring(src) && are_types_identical(dst, t_rawptr) {
		return true
	}
	if are_types_identical(src, t_rawptr) && is_type_cstring(dst) {
		return true
	}
	// cstring16 casting rules — the UTF-16 counterparts of the block above.
	// C++ Reference: check_expr.cpp:3759-3785. These six were simply absent, so every
	// `([^]u16)(s)` / `(^u16)(s)` on a cstring16 was rejected. base:runtime's UTF-16
	// string handling is built on exactly these casts (internal.odin:581/603/651,
	// core_builtin.odin:483), and it is imported by everything.
	//
	// `is_type_u16_ptr` / `is_type_u16_multi_ptr` already existed in the port and were
	// used by check_decl_helpers' signature comparison — only the cast rules were missing.
	if are_types_identical(src, t_cstring16) && is_type_u16_ptr(dst) {
		return true
	}
	if are_types_identical(src, t_cstring16) && is_type_u16_multi_ptr(dst) {
		return true
	}
	if are_types_identical(src, t_cstring16) && are_types_identical(dst, t_rawptr) {
		return true
	}
	if is_type_u16_ptr(src) && are_types_identical(dst, t_cstring16) {
		return true
	}
	if is_type_u16_multi_ptr(src) && are_types_identical(dst, t_cstring16) {
		return true
	}
	if are_types_identical(src, t_rawptr) && are_types_identical(dst, t_cstring16) {
		return true
	}

	// cstring -> string (view conversion)
	// Reference: spec/conversions.md line 171
	if is_type_cstring(src) && is_type_string(dst) && !is_type_cstring(dst) {
		return true
	}

	// cstring16 -> string16
	// C++ Reference: check_expr.cpp:3725-3731. Task 114 ported the six cstring16 POINTER
	// rules but not this one or the []u16 rule above, so `string16(v)` on a cstring16 was
	// still rejected - which is what core/reflect's UTF-16 `any` handling and core/fmt do.
	if are_types_identical(src, t_cstring16) && are_types_identical(dst, t_string16) {
		return true
	}

	// #simd[N]T -> #simd[N]U, when the element types are themselves castable.
	//
	// C++ Reference: check_expr.cpp:3815-3836. BOTH of these arms were absent from the port,
	// so no cast involving a #simd destination was ever allowed. core/simd/x86 is built on
	// them - `x86.__m128i(K_1)` where K_1 is a #simd[2]u64 and __m128i is #simd[2]i64 is the
	// shape that failed, and core/crypto/sha2's Intel SHA path does it in every round.
	if is_type_simd_vector(src) && is_type_simd_vector(dst) {
		src_sv := base_type(src).variant.(Type_Simd_Vector)
		dst_sv := base_type(dst).variant.(Type_Simd_Vector)
		if src_sv.count != dst_sv.count {
			return false
		}
		elem_operand := Operand{
			type = base_array_type(src),
			mode = .Value,
		}
		return check_is_castable_to(ctx, &elem_operand, base_array_type(dst))
	}

	// A scalar may be cast to a #simd vector when it is castable to the element type
	// (C++ check_expr.cpp:3827-3832 - the splat form).
	if is_type_simd_vector(dst) {
		if check_is_castable_to(ctx, operand, base_array_type(dst)) {
			return true
		}
	}

	// Procedure type casting
	if is_type_proc(src) && is_type_proc(dst) {
		return true
	}
	// proc <-> rawptr
	if is_type_proc(src) && are_types_identical(dst, t_rawptr) {
		return true
	}
	if are_types_identical(src, t_rawptr) && is_type_proc(dst) {
		return true
	}
	// proc <-> uintptr
	if is_type_proc(src) && is_type_uintptr(dst) {
		return true
	}
	if is_type_uintptr(src) && is_type_proc(dst) {
		return true
	}

	return false
}

// check_cast_internal is the internal implementation of type casting
// It returns true if the cast is valid
// Reference: /mnt/c/odin/src/check_expr.cpp:3525-3562
check_cast_internal :: proc(ctx: ^Checker_Context, operand: ^Operand, target: ^Type) -> bool {
	is_const_expr := operand.mode == .Constant

	bt := base_type(target)
	if is_const_expr && is_type_constant_type(bt) {
		if core_bt, ok := core_type(bt).variant.(Type_Basic); ok {
			// C++ Reference: check_expr.cpp:3525-3535
			if check_representable_as_constant(ctx, operand.value, bt, &operand.value) {
				return true
			} else if check_is_castable_to(ctx, operand, target) {
				if is_type_pointer(target) {
					return true
				}
			}
			_ = core_bt
		} else if check_is_castable_to(ctx, operand, target) {
			operand.value = nil
			operand.mode = .Value
			return true
		}
	} else if check_is_castable_to(ctx, operand, target) {
		if operand.mode != .Constant {
			operand.mode = .Value
		} else if is_type_slice(target) && is_type_string(operand.type) {
			operand.mode = .Value
		} else if is_type_union(target) {
			// C++ Reference: check_expr.cpp:3545-3550
			if is_type_union_constantable(target) {
				// Union can hold constant values - keep constant mode
				return true
			}
			operand.mode = .Value
		}
		if operand.mode == .Value {
			operand.value = nil
		}
		return true
	}
	return false
}

// check_cast performs type casting validation and updates the operand
// Reference: /mnt/c/odin/src/check_expr.cpp:3564-3658
check_cast :: proc(ctx: ^Checker_Context, operand: ^Operand, target: ^Type, forbid_identical := false) {
	if !is_operand_value(operand^) {
		error(operand.expr, "Only values can be casted")
		operand.mode = .Invalid
		return
	}

	is_const_expr := operand.mode == .Constant
	can_convert := check_cast_internal(ctx, operand, target)

	if !can_convert {
		// C++ Reference: check_expr.cpp:3568-3598
		operand.mode = .Invalid

		expr_str := expr_to_string(operand.expr)
		defer delete(expr_str)
		from_str := type_to_string(operand.type)
		to_str := type_to_string(target)
		// C++ Reference: check_expr.cpp:3901-3923. ERROR_BLOCK keeps the continuation lines
		// attached to this error; without it they printed BEFORE it.
		//
		// The "types have the same size, try 'transmute'" line the port used to emit here does
		// not exist anywhere in C++ -- it was invented, and it fired on cases where C++ gives
		// specific and more useful advice (pointer<->integer must go through 'uintptr').
		begin_error_block()
		defer end_error_block()
		error(operand.expr, "Cannot cast '%s' as '%s' from '%s'", expr_str, to_str, from_str)
		if is_const_expr {
			val_str := exact_value_to_string(operand.value)
			defer delete(val_str)
			if is_type_float(operand.type) && is_type_integer(target) {
				error_line("\t%s cannot be represented without truncation/rounding as the type '%s'\n", val_str, to_str)
				// C++ keeps the mode and retypes, to minimise follow-on errors.
				operand.mode = .Constant
				operand.type = target
			} else {
				error_line("\t'%s' cannot be represented as the type '%s'\n", val_str, to_str)
				if is_type_numeric(target) {
					operand.mode = .Constant
					operand.type = target
				}
			}
		}
		check_cast_error_suggestion(ctx, operand, target, operand.expr)
		return
	}

	// Handle untyped expressions
	// C++ Reference: check_expr.cpp:3602-3610
	if is_type_untyped(operand.type) {
		final_type := target
		if is_const_expr && !is_type_constant_type(target) {
			if is_type_union(target) {
				convert_to_typed(ctx, operand, target)
			}
			final_type = default_type(operand.type)
		}
		update_untyped_expr_type(ctx, operand.expr, final_type, true)
	} else {
		src := core_type(operand.type)
		dst := core_type(target)
		if src != dst {
			// Add runtime dependencies for special conversions
			// Reference: C++ check_expr.cpp:3616-3630
			src_basic, src_is_basic := src.variant.(Type_Basic)
			dst_basic, dst_is_basic := dst.variant.(Type_Basic)

			if src_is_basic && dst_is_basic {
				// 128-bit integer <-> float conversions
				src_is_128 := src_basic.kind == .I128 || src_basic.kind == .U128
				dst_is_128 := dst_basic.kind == .I128 || dst_basic.kind == .U128
				src_is_float := .Float in src_basic.flags
				dst_is_float := .Float in dst_basic.flags

				if src_is_128 && dst_is_float {
					// i128/u128 -> float
					add_package_dependency(ctx, "runtime", "floattidf")
				} else if src_is_float && dst_is_128 {
					// float -> i128/u128
					add_package_dependency(ctx, "runtime", "fixunsdfti")
				}

				// f16 conversions
				if src_basic.kind == .F16 || dst_basic.kind == .F16 {
					add_package_dependency(ctx, "runtime", "gnu_h2f_ieee")
					add_package_dependency(ctx, "runtime", "extendhfsf2")
					add_package_dependency(ctx, "runtime", "truncsfhf2")
					add_package_dependency(ctx, "runtime", "truncdfhf2")
				}
			}
		}

		// Vet check for unnecessary identical casts
		// Reference: C++ check_expr.cpp:3615-3625
		if forbid_identical && .Cast in check_vet_flags(ctx) &&
		   (ctx.curr_proc_sig == nil || !is_type_polymorphic(ctx.curr_proc_sig)) {
			if are_types_identical(operand.type, target) {
				// C++ check_expr.cpp:3968-3970 names the OPERAND as well as the target.
				cast_oper_str := expr_to_string(operand.expr)
				defer delete(cast_oper_str)
				error(operand.expr, "Unneeded cast of '%s' to identical type '%s'", cast_oper_str, type_to_string(target))
			}
		}
		_, _ = src, dst
	}

	operand.type = target
}

// check_transmute performs transmute validation and updates the operand
// transmute does bit-level reinterpretation and requires exact size match
// Reference: /mnt/c/odin/src/check_expr.cpp:3660-3789
check_transmute :: proc(ctx: ^Checker_Context, node: ^ast.Node, operand: ^Operand, target: ^Type, forbid_identical := false) -> bool {
	if !is_operand_value(operand^) {
		error(operand.expr, "'transmute' can only be applied to values")
		operand.mode = .Invalid
		return false
	}

	src := operand

	src_t := operand.type
	dst_t := target
	src_bt := base_type(src_t)
	dst_bt := base_type(dst_t)

	// Cannot transmute untyped expressions
	if is_type_untyped(src_t) {
		// C++ Reference: check_expr.cpp:4019
		tm_str := expr_to_string(operand.expr)
		defer delete(tm_str)
		error(operand.expr, "Cannot transmute untyped expression: '%s'", tm_str)
		operand.mode = .Invalid
		operand.expr = node
		return false
	}

	// Check for invalid types
	if dst_bt == nil || dst_bt == t_invalid {
		// Should have been caught earlier
		operand.mode = .Invalid
		operand.expr = node
		return false
	}

	if src_bt == nil || src_bt == t_invalid {
		// Should have been caught earlier
		operand.mode = .Value
		operand.expr = node
		operand.type = dst_t
		return true
	}

	// Transmute requires exact size match
	srcz := type_size_of(src_t)
	dstz := type_size_of(dst_t)
	if srcz != dstz {
		// C++ check_expr.cpp:4047-4049 names the OPERAND as well as the target.
		tm_expr_str := expr_to_string(operand.expr)
		defer delete(tm_expr_str)
		error(operand.expr, "Cannot transmute '%s' to '%s', %d vs %d bytes", tm_expr_str, type_to_string(dst_t), srcz, dstz)
		operand.mode = .Invalid
		operand.expr = node
		return false
	}

	operand.expr = node
	operand.type = dst_t

	// Handle constant transmutes
	if operand.mode == .Constant {
		if are_types_identical(src_bt, dst_bt) {
			return true
		}

		// Constant transmute between integers (or integer to bit_set) preserves value
		// Since transmute is byte reinterpretation and sizes match, the constant can be preserved
		// Reference: C++ check_expr.cpp:3730-3780
		if (is_type_integer(src_t) && is_type_integer(dst_t)) ||
		   (is_type_integer(src_t) && is_type_bit_set(dst_t)) ||
		   (is_type_bit_set(src_t) && is_type_integer(dst_t)) {
			// For constant integers, the value can be kept as-is since sizes match
			// The type changes but the underlying bits remain the same
			return true
		}
	} else {
		// Vet checks for unnecessary transmutes
		// Reference: C++ check_expr.cpp:3785-3800
		if forbid_identical && .Cast in check_vet_flags(ctx) &&
		   (ctx.curr_proc_sig == nil || !is_type_polymorphic(ctx.curr_proc_sig)) &&
		   check_is_castable_to(ctx, src, dst_t) {

			if are_types_identical(src_t, dst_t) {
				// C++ check_expr.cpp:4103-4105 names the OPERAND as well as the target.
				tm_id_str := expr_to_string(operand.expr)
				defer delete(tm_id_str)
				error(operand.expr, "Unneeded transmute of '%s' to identical type '%s'", tm_id_str, type_to_string(dst_t))
			} else if is_type_internally_pointer_like(src_t) && is_type_internally_pointer_like(dst_t) {
				error(operand.expr, "Use of 'transmute' where 'cast' would be preferred since the types are pointer-like")
			} else if are_types_identical(src_bt, dst_bt) {
				// C++ check_expr.cpp:4112-4114 emits the SAME message as the identical-type
				// branch above -- "identical type", not "identical base type". The port had
				// invented the word "base" for this arm, so the two branches diverged in
				// wording where C++ deliberately does not. LEDGER 288.
				tm_base_str := expr_to_string(operand.expr)
				defer delete(tm_base_str)
				error(operand.expr, "Unneeded transmute of '%s' to identical type '%s'", tm_base_str, type_to_string(dst_t))
			}
		}
	}

	operand.mode = .Value
	operand.value = nil
	return true
}

// Helper function to check if an operand is a value
// C++ Reference: /mnt/c/odin/src/checker.cpp:16-31
//
// NOTE: `.Context` and `.Optional_Ok_Ptr` ARE values. The port previously
// omitted both and listed `.Context` in the false arm, so `&x.(T)` - which
// yields `.Optional_Ok_Ptr` - was rejected as "not a value" by
// determine_type_from_polymorphic, and no polymorphic parameter could ever be
// bound from the address of a type assertion.
is_operand_value :: proc(o: Operand) -> bool {
	#partial switch o.mode {
	case .Value,
	     .Context,
	     .Variable,
	     .Constant,
	     .Map_Index,
	     .Optional_Ok,
	     .Optional_Ok_Ptr,
	     .Soa_Variable,
	     .Swizzle_Value,
	     .Swizzle_Variable:
		return true
	}
	return false
}

// is_type_slice checks if a type is a slice
is_type_slice :: proc(t: ^Type) -> bool {
	if t == nil {
		return false
	}
	_, ok := core_type(t).variant.(Type_Slice)
	return ok
}

// MAXIMUM_TYPE_DISTANCE is defined in check_equivalence.odin (value: 10)
// Reference: /mnt/c/odin/src/check_expr.cpp:665
// Note: Used for "can always convert" scenarios - the large value (1<<30) was incorrect

// check_distance_between_types calculates the "type distance" for assignability
// Returns -1 if not assignable, 0 for exact match, positive for conversion distance
// Lower distance = better match (used for overload resolution)
// Ported from check_expr.cpp:667-989
// check_distance_between_types is defined in check_equivalence.odin

// Note: type_size_of is already defined in types.odin

//
// Call Expression Implementation
// Reference: /mnt/c/odin/src/check_expr.cpp:8155-8418
//

// Data structure for call argument processing
// Reference: /mnt/c/odin/src/check_expr.cpp:41-50 (CallArgumentData struct)
Call_Argument_Data :: struct {
	gen_entity:  ^Entity, // Generated polymorphic entity (if applicable)
	result_type: ^Type, // Procedure's return type (as tuple)
	// The winning candidate's procedure type. C++ carries this as `final_proc_type`
	// through check_call_arguments_internal. The port previously discarded it, so the
	// proc-group path had no way to see per-procedure attributes such as #optional_ok
	// (the group identifier's own recorded type is not a procedure type).
	final_proc_type: ^Type,
	score:       int, // For future overload resolution
	error:       bool, // True if any errors occurred
}

// check_call_expr handles procedure call expressions
// Reference: /mnt/c/odin/src/check_expr.cpp:8155-8418
//
// Implemented: Direct calls, type conversions, procedure groups, polymorphic instantiation
check_call_expr :: proc(ctx: ^Checker_Context, o: ^Operand, node: ^ast.Node, type_hint: ^Type) -> Expr_Kind {
	call := node.derived.(^ast.Call_Expr)

	// Step 0: Handle directive calls like #location(), #defined(), #config(), etc.
	// C++ Reference: check_builtin.cpp:2089-2175
	if _, is_directive := call.expr.derived.(^ast.Basic_Directive); is_directive {
		if check_builtin_procedure_directive(ctx, o, node, type_hint) {
			o.expr = node
			add_type_and_value(ctx, node, o.mode, o.type, o.value)
			return .Expr
		}
		// If directive not handled, continue to report error
	}

	// Step 1: Check the callee expression (the thing being called)
	// Reference: /mnt/c/odin/src/check_expr.cpp:8189-8194
	// Allow arrow operator (->) inside call expressions
	prev_allow_arrow := ctx.allow_arrow_right_selector_expr
	ctx.allow_arrow_right_selector_expr = true
	check_expr_or_type(ctx, o, call.expr)
	ctx.allow_arrow_right_selector_expr = prev_allow_arrow

	// Step 2: Handle invalid operands early
	// Reference: /mnt/c/odin/src/check_expr.cpp:8196-8207
	if o.mode == .Invalid {
		// Check arguments anyway to find more errors
		for arg in call.args {
			arg_op: Operand
			check_expr_base(ctx, &arg_op, arg, nil)
		}
		o.mode = .Invalid
		o.expr = node
		return .Stmt
	}

	// Step 3: Handle type constructor calls (type conversion)
	// Reference: /mnt/c/odin/src/check_expr.cpp:8054-8154
	// Example: int(x), f32(y), complex64(1, 2)
	if o.mode == .Type {
		target_type := o.type

		// Track entity use for the type
		// C++ Reference: check_expr.cpp:8058-8062
		type_entity := entity_of_node(ctx.info, call.expr)
		if type_entity != nil {
			add_entity_use(ctx, call.expr, type_entity)
		}

		// Handle polymorphic record type instantiation
		// When target_type is a polymorphic struct/union, this is type instantiation
		// like Container(int) or Fixed_Array(10, f32), not a type conversion
		// Arguments can be types ($T: typeid) or constants ($N: int)
		// C++ Reference: check_expr.cpp handles this differently - see check_type.cpp:3412
		if is_type_polymorphic_record_unspecialized(target_type) {
			// C++ Reference: check_expr.cpp:8563
			if !check_call_parameter_mixture(call.args, "polymorphic type construction") {
				o.mode = .Invalid
				o.expr = node
				return .Stmt
			}

			// Check all arguments - they can be types or constant values
			named_fields := len(call.args) > 0 && is_call_expr_field_value(call.args[0])

			operand_list := make([dynamic]Operand, 0, 2 * len(call.args), context.temp_allocator)
			if named_fields {
				// C++ Reference: check_expr.cpp:8171-8194. Each named argument is checked on
				// its own; there is nothing positional to unpack. The port used to hand
				// check_expr_or_type the whole Field_Value node rather than its VALUE, so the
				// operand never described `int` in `R(T = int)` - it described the assignment.
				// C++ also hints a constant parameter's value with that parameter's declared
				// type, which is what lets `R(N = 4)` see 4 as an int rather than untyped.
				resize(&operand_list, len(call.args))
				for arg, i in call.args {
					fv, fv_ok := arg.derived.(^ast.Field_Value)
					if !fv_ok {
						check_expr_or_type(ctx, &operand_list[i], arg, nil)
						continue
					}
					if fv.value == nil {
						error_node(arg, "Expected a value")
						continue
					}
					hinted := false
					if ident, id_ok := fv.field.derived.(^ast.Ident); id_ok {
						if index := lookup_polymorphic_record_parameter(target_type, ident.name); index >= 0 {
							if params := get_record_polymorphic_params(target_type); params != nil {
								e := params.variables[index]
								if e != nil && e.kind == .Constant {
									check_expr_with_type_hint(ctx, &operand_list[i], fv.value, entity_type(e))
									hinted = true
								}
							}
						}
					}
					if !hinted {
						check_expr_or_type(ctx, &operand_list[i], fv.value, nil)
					}
				}
			} else {
				// Positional parameters, so a multi-valued expression spreads
				// across them, hinted by the record's polymorphic parameters.
				//
				// C++ Reference: /mnt/c/odin/src/check_expr.cpp check_polymorphic_record_type,
				// the `check_unpack_arguments(c, lhs, lhs_count, &operands, ce->args, UnpackFlag_None)` call.
				lhs: []^Entity = nil
				if params := get_record_polymorphic_params(target_type); params != nil {
					lhs = params.variables[:]
				}
				check_unpack_arguments(ctx, lhs, &operand_list, call.args, {})
			}
			operands := operand_list[:]

			// C++ Reference: check_expr.cpp:8223-8425 - the validation prologue that runs
			// BEFORE the record is instantiated. The port went straight from unpacking the
			// arguments to instantiating, so neither a wrong argument count nor a non-type
			// argument was ever rejected. `R(5)` against `R :: struct($T: typeid)` therefore
			// instantiated R with an untyped-integer operand, and the struct field `v: T`
			// tripped the untyped-parameter diagnostic inside check_record_polymorphic_params
			// - blaming the DECLARATION for a mistake made at the call.
			//
			poly_err := false
			{
				if tuple := get_record_polymorphic_params(target_type); tuple != nil {
					param_count := len(tuple.variables)

					// C++ lines 8225-8235: walk back over trailing constants that carry a
					// default value - those may be omitted at the call.
					minimum_param_count := param_count
					for ; minimum_param_count > 0; minimum_param_count -= 1 {
						e := tuple.variables[minimum_param_count - 1]
						if e == nil || e.kind != .Constant {
							break
						}
						cd, cd_ok := e.variant.(Entity_Constant)
						if !cd_ok || cd.param_value.kind == .Invalid {
							break
						}
					}

					// C++ lines 8241-8302: named arguments are placed at their PARAMETER's
					// index, not at the position they were written. Without this,
					// `R(N = 4, T = int)` bound T:=4 and N:=int. Every diagnostic in this
					// block was absent from the port.
					if named_fields {
						ordered := make([]Operand, param_count, context.temp_allocator)
						visited := make([]bool, param_count, context.temp_allocator)
						for arg, i in call.args {
							fv, fv_ok := arg.derived.(^ast.Field_Value)
							if !fv_ok {
								continue
							}
							ident, id_ok := fv.field.derived.(^ast.Ident)
							if !id_ok {
								field_str := expr_to_string(fv.field)
								error_node(arg, "Invalid parameter name '%s' in polymorphic type call", field_str)
								poly_err = true
								continue
							}
							index := lookup_polymorphic_record_parameter(target_type, ident.name)
							if index < 0 {
								error_node(arg, "No parameter named '%s' for this polymorphic type", ident.name)
								poly_err = true
								continue
							}
							if visited[index] {
								error_node(arg, "Duplicate parameter '%s' in polymorphic type", ident.name)
								poly_err = true
								continue
							}
							visited[index] = true
							if i < len(operands) {
								ordered[index] = operands[i]
							}
						}
						// C++ lines 8281-8301: a parameter nobody named and that has no way to
						// be filled is an error - except a blank one, which cannot be named.
						for i in 0 ..< param_count {
							if visited[i] {
								continue
							}
							e := tuple.variables[i]
							if e == nil || is_blank_ident(e.token.text) {
								continue
							}
							if e.kind == .Type_Name {
								error_node(node, "Type parameter '%s' is missing in polymorphic type call", e.token.text)
							} else {
								type_str := type_to_string(entity_type(e))
								error_node(node, "Parameter '%s' of type '%s' is missing in polymorphic type call", e.token.text, type_str)
							}
							poly_err = true
						}
						operands = ordered
					}

					// C++ lines 8304-8307: ordering failures return before the arity checks,
					// which would otherwise count a list this code already knows is wrong.
					if poly_err {
						o.mode = .Invalid
						o.type = t_invalid
						o.expr = node
						return .Expr
					}

					// C++ lines 8310-8315: drop trailing operands that were never supplied.
					for len(operands) > 0 && operands[len(operands) - 1].expr == nil {
						operands = operands[:len(operands) - 1]
					}

					// C++ lines 8317-8332
					if minimum_param_count != param_count {
						if param_count < len(operands) {
							error(node, "Too many polymorphic type arguments, expected a maximum of %d, got %d", param_count, len(operands))
							poly_err = true
						} else if minimum_param_count > len(operands) {
							error(node, "Too few polymorphic type arguments, expected a minimum of %d, got %d", minimum_param_count, len(operands))
							poly_err = true
						}
					} else {
						if param_count < len(operands) {
							error(node, "Too many polymorphic type arguments, expected %d, got %d", param_count, len(operands))
							poly_err = true
						} else if param_count > len(operands) {
							error(node, "Too few polymorphic type arguments, expected %d, got %d", param_count, len(operands))
							poly_err = true
						}
					}

					// C++ lines 8339-8362: fill the omitted trailing parameters from their
					// declared defaults, so the instantiation sees a full operand list. This
					// is also what stops a SHORT list from reaching
					// check_record_polymorphic_params - see task #181.
					if !poly_err && minimum_param_count != param_count {
						filled := make([dynamic]Operand, 0, param_count, context.temp_allocator)
						append(&filled, ..operands)
						for len(filled) < param_count {
							append(&filled, Operand{})
						}
						for i in 0 ..< param_count {
							if filled[i].expr != nil {
								continue
							}
							e := tuple.variables[i]
							if e == nil {
								continue
							}
							#partial switch e.kind {
							case .Constant:
								if cd, cd_ok := e.variant.(Entity_Constant); cd_ok {
									filled[i].mode = .Constant
									filled[i].type = default_type(entity_type(e))
									filled[i].expr = unparen_expr(cd.param_value.original_ast_expr)
									if cd.param_value.kind == .Constant {
										filled[i].value = cd.param_value.value
									}
								}
							case .Type_Name:
								filled[i].mode = .Type
								filled[i].type = entity_type(e)
								filled[i].expr = e.identifier
							}
						}
						operands = filled[:]
					}

					// C++ lines 8363-8420: validate each operand against its parameter.
					if !poly_err {
						oo_count := min(param_count, len(operands))
						for i in 0 ..< oo_count {
							e := tuple.variables[i]
							op := &operands[i]
							if e == nil || op.mode == .Invalid {
								continue
							}
							if e.kind == .Type_Name {
								// C++ lines 8371-8378: THE check that was missing.
								if op.mode != .Type {
									expr_str := expr_to_string(op.expr)
									error(op.expr, "Expected a type for the argument '%s', got %s", e.token.text, expr_str)
									poly_err = true
								}
							} else {
								// C++ lines 8384-8390: an operand that is itself still generic
								// is a polymorphic name, not a value to check.
								if op.type != nil {
									if _, is_generic := op.type.variant.(Type_Generic); is_generic {
										continue
									}
								}
								s: i64 = 0
								if !check_is_assignable_to_with_score(ctx, op, entity_type(e), &s) {
									check_assignment(ctx, op, entity_type(e), "polymorphic type argument")
									poly_err = true
								}
								op.type = entity_type(e)
								// C++ lines 8398-8412
								if op.mode != .Constant {
									valid := false
									if is_type_proc(op.type) {
										valid = entity_from_expr(ctx.info, op.expr) != nil
									}
									if !valid {
										error(op.expr, "Expected a constant value for this polymorphic type argument")
										poly_err = true
									}
								}
							}
						}
					}
				}
			}

			// C++ lines 8573-8587: on error the operand simply becomes invalid. C++ emits no
			// closing message here - the caller's context supplies it (a type-expression
			// position reports "'R(5)' is not a type", check_type.cpp:3696/4019). The port
			// used to print "Failed to instantiate polymorphic type '%s'", which appears
			// nowhere in src/.
			if poly_err {
				o.mode = .Invalid
				o.type = t_invalid
				o.expr = node
				return .Expr
			}

			// Try polymorphic type instantiation
			specialized_type := check_polymorphic_record_type(ctx, target_type, operands[:], node)
			if specialized_type != nil {
				o.mode = .Type
				o.type = specialized_type
				o.expr = node
				add_type_and_value(ctx, node, o.mode, o.type, o.value)
				return .Expr
			} else {
				o.mode = .Invalid
				o.type = t_invalid
				o.expr = node
				return .Expr
			}
		}

		// C++ Reference: check_expr.cpp:8590
		if !check_call_parameter_mixture(call.args, "type conversion") {
			o.mode = .Invalid
			o.expr = node
			return .Stmt
		}

		// Validate argument count
		// C++ Reference: check_expr.cpp:8064-8072
		if len(call.args) == 0 {
			// No arguments - error
			type_str := type_to_string(target_type)
			error(node, "Missing argument in conversion to '%s'", type_str)   // C++ check_expr.cpp:8598
			o.mode = .Invalid
			o.expr = node
			return .Stmt
		}

		// Check for field value syntax (not allowed in type conversion)
		// C++ Reference: check_expr.cpp:8073-8081
		if call.args[0] != nil {
			if _, is_fv := call.args[0].derived.(^ast.Field_Value); is_fv {
				type_str := type_to_string(target_type)
				error(call.args[0], "Field values are not allowed in type conversion '%s'", type_str)
				error_line("\tSuggestion: use '%s{{...}}' for compound literals", type_str)
				o.mode = .Invalid
				o.expr = node
				return .Stmt
			}
		}


		// Handle complex/quaternion constructors with multiple arguments
		// C++ Reference: check_expr.cpp:8083-8108
		if len(call.args) > 1 {
			// Check if it's complex or quaternion type
			bt := base_type(target_type)
			if bt != nil && bt.kind == .Basic {
				basic := bt.variant.(Type_Basic)
				is_complex := basic.kind == .Complex32 || basic.kind == .Complex64 || basic.kind == .Complex128
				is_quaternion := basic.kind == .Quaternion64 || basic.kind == .Quaternion128 || basic.kind == .Quaternion256

				if is_complex && len(call.args) == 2 {
					// complex(real, imag) style
					arg0, arg1: Operand
					check_expr(ctx, &arg0, call.args[0])
					check_expr(ctx, &arg1, call.args[1])

					if arg0.mode != .Invalid && arg1.mode != .Invalid {
						o.mode = .Value
						o.type = target_type
						o.expr = node
						add_type_and_value(ctx, node, o.mode, o.type, o.value)
						return .Expr
					}
					o.mode = .Invalid
					o.expr = node
					return .Stmt
				} else if is_quaternion && len(call.args) == 4 {
					// quaternion(w, x, y, z) style
					args_valid := true
					for arg in call.args {
						arg_op: Operand
						check_expr(ctx, &arg_op, arg)
						if arg_op.mode == .Invalid {
							args_valid = false
						}
					}

					if args_valid {
						o.mode = .Value
						o.type = target_type
						o.expr = node
						add_type_and_value(ctx, node, o.mode, o.type, o.value)
						return .Expr
					}
					o.mode = .Invalid
					o.expr = node
					return .Stmt
				}
			}

			// Multiple arguments but not complex/quaternion - error
			type_str := type_to_string(target_type)
			error(node, "Type conversion to '%s' expects 1 argument, got %d", type_str, len(call.args))
			o.mode = .Invalid
			o.expr = node
			return .Stmt
		}

		// Single argument type conversion
		// C++ Reference: check_expr.cpp:8110-8151
		arg := call.args[0]
		arg_op: Operand
		// C++ Reference: check_expr.cpp:8634 - check_expr_with_type_hint(c, operand, arg, t).
		// The target type must be pushed down, otherwise an implicit-selector argument
		// (`Futex_Trylock_Pi_Type(.TRYLOCK_PI)`) reaches check_implicit_selector_expr with a
		// nil hint and fails.
		//
		// This was reverted twice while check_expr_base failed to record a type-and-value for
		// every expression: the hint made `m[k] = v` code reachable, and that construct aborted
		// on check_stmt.odin's `has_tav` assertion. The crash was never caused by this line —
		// any map assignment crashed the checker on its own. Fixed at check_expr_base.
		check_expr_with_type_hint(ctx, &arg_op, arg, target_type)

		if arg_op.mode == .Invalid {
			o.mode = .Invalid
			o.expr = node
			return .Stmt
		}

		// Check if conversion is valid
		// C++ Reference: check_expr.cpp:8115-8140
		if check_is_assignable_to(ctx, &arg_op, target_type) {
			// Direct assignment works
			o.mode = arg_op.mode == .Constant ? .Constant : .Value
			o.type = target_type
			o.value = arg_op.value
		} else if check_is_castable_to(ctx, &arg_op, target_type) {
			// Explicit cast works
			check_cast(ctx, &arg_op, target_type)
			o.mode = arg_op.mode
			o.type = target_type
			o.value = arg_op.value
		} else {
			// Conversion not possible
			arg_type_str := type_to_string(arg_op.type)
			target_type_str := type_to_string(target_type)
			error(node, "Cannot convert '%s' to '%s'", arg_type_str, target_type_str)
			o.mode = .Invalid
			o.expr = node
			return .Stmt
		}

		o.expr = node
		add_type_and_value(ctx, node, o.mode, o.type, o.value)
		return .Expr
	}

	// Step 4: Handle built-in procedures
	// Reference: /mnt/c/odin/src/check_expr.cpp:8213-8227
	if o.mode == .Builtin {
		// Dispatch to builtin checker
		// C++ ref: /mnt/c/odin/src/check_builtin.cpp
		builtin_id := o.builtin_id
		success := check_builtin_procedure(ctx, o, call, builtin_id, type_hint)
		if !success {
			o.mode = .Invalid
			o.expr = node
			return .Stmt
		}

		// Determine expression kind from builtin info
		info := builtin_proc_infos[builtin_id]
		return info.kind == .Expr ? .Expr : .Stmt
	}

	// Step 5: Handle procedure groups
	// Reference: /mnt/c/odin/src/check_expr.cpp:8229-8268
	if o.mode == .Proc_Group {
		// Dispatch to procedure group call resolution
		// Reference: /mnt/c/odin/src/check_expr.cpp:6933-7504
		arg_data := check_procedure_group_call(ctx, o, node)

		if arg_data.error {
			o.mode = .Invalid
			o.type = t_invalid
			o.expr = node
			return .Stmt
		}

		// Set result type from the resolved procedure.
		//
		// A SINGLE result must be unwrapped from its tuple. C++ maintains this as an
		// invariant and asserts it: check_not_tuple (check_expr.cpp:12739-12749) ends with
		// GB_ASSERT(count != 1), i.e. a 1-tuple must never reach a single-value context.
		// The other result path in this file (the `case 1:` arm below, ~line 9112) already
		// unwraps; this proc-group path did not, so every call to an overloaded procedure
		// with one result — `copy`, `append`, and the rest of base:runtime's proc groups —
		// produced a 1-tuple and any single-value use of it reported the self-contradictory
		// "1-valued expression found where single value expected". That was 4,201 of the
		// sweep's diagnostics, every one of them a 1.
		o.type = arg_data.result_type
		if o.type != nil && o.type.kind == .Tuple {
			if tup, tup_ok := o.type.variant.(Type_Tuple); tup_ok && len(tup.variables) == 1 {
				o.type = entity_type(tup.variables[0])
			}
		}
		o.mode = .Value
		o.expr = node

		// Record entity use if we resolved to a specific procedure
		// C++ Reference: check_expr.cpp:8248-8250
		if arg_data.gen_entity != nil {
			add_entity_use(ctx, call.expr, arg_data.gen_entity)
		}

		// C++'s optional-ok block sits at the end of check_call_expr and so covers
		// this proc-group path too, which returns before Step 11.
		resolved_proc_type := arg_data.final_proc_type
		if resolved_proc_type == nil && arg_data.gen_entity != nil {
			resolved_proc_type = base_type(entity_type(arg_data.gen_entity))
		}
		apply_optional_ok_call_result(ctx, o, call, resolved_proc_type)

		return .Expr
	}

	// Step 6: Validate it's actually a procedure type
	// Reference: /mnt/c/odin/src/check_expr.cpp:8251-8268
	proc_type := base_type(o.type)
	if proc_type == nil || proc_type.kind != .Proc {
		// Error: trying to call something that's not a procedure
		type_str := type_to_string(o.type)
		// C++ Reference: check_expr.cpp:8830 -- "Cannot call a non-procedure: '<expr>' of type '<T>'"
		callee_str := expr_to_string(call.expr)
		defer delete(callee_str)
		error_node(call.expr, "Cannot call a non-procedure: '%s' of type '%s'", callee_str, type_str)
		o.mode = .Invalid
		o.expr = node
		return .Stmt
	}

	// Step 7: Check the call arguments
	// Reference: /mnt/c/odin/src/check_expr.cpp:8270-8279
	arg_data := check_call_arguments_basic(ctx, o, call)

	if arg_data.error {
		o.mode = .Invalid
		o.type = t_invalid
		o.expr = node
		return .Stmt
	}

	// Step 8: Check calling convention requirements
	// Reference: /mnt/c/odin/src/check_expr.cpp:8295-8305
	pt := &proc_type.variant.(Type_Proc)
	if pt.calling_convention == .Odin {
		// Odin calling convention requires context to be defined
		if .Context_Defined not_in ctx.scope.flags {
			error_node(node, "Procedures requiring a 'context' cannot be called at the global scope")   // C++ check_expr.cpp:8870
			o.mode = .Invalid
			o.expr = node
			return .Stmt
		}
	}

	// Step 9: Validate @(entry_point_only) attribute
	// C++ Reference: check_expr.cpp:8300-8306
	// Procedures marked with @(entry_point_only) can only be called from the entry point
	callee_entity := entity_of_node(ctx.info, call.expr)
	if callee_entity != nil {
		if callee_proc, is_proc := callee_entity.variant.(Entity_Procedure); is_proc {
			if callee_proc.entry_point_only {
				// Check if we're in the entry point procedure (typically "main")
				is_in_entry_point := false
				if ctx.curr_proc_decl != nil && ctx.curr_proc_decl.entity != nil {
					// Entry point is typically "main" procedure
					is_in_entry_point = ctx.curr_proc_decl.entity.token.text == "main"
				}
				if !is_in_entry_point {
					error_node(node, "Procedures with '@(entry_point_only)' can only be called from the entry point procedure")
					o.mode = .Invalid
					o.expr = node
					return .Stmt
				}
			}
		}
	}

	// Step 10: Validate @(require_target_feature) attribute
	// C++ Reference: check_expr.cpp:8421-8453
	// If callee requires target features, caller must enable them
	if len(pt.require_target_feature) > 0 {
		// Get the caller's enabled features
		caller_features := ""
		if ctx.curr_proc_decl != nil && ctx.curr_proc_decl.entity != nil {
			if caller_type := entity_type(ctx.curr_proc_decl.entity); caller_type != nil {
				if caller_pt, is_proc := base_type(caller_type).variant.(Type_Proc); is_proc {
					caller_features = caller_pt.enable_target_feature
				}
			}
		}

		// Check if all required features are available
		required := strings.split(pt.require_target_feature, ",", context.temp_allocator)
		enabled := strings.split(caller_features, ",", context.temp_allocator) if len(caller_features) > 0 else nil

		for req in required {
			req_trimmed := strings.trim_space(req)
			if len(req_trimmed) == 0 {
				continue
			}
			// Check if feature is enabled globally or by caller
			feature_available := false
			// TODO: Check global target features from build context
			// For now, check if caller enables this feature
			if enabled != nil {
				for en in enabled {
					if strings.trim_space(en) == req_trimmed {
						feature_available = true
						break
					}
				}
			}
			if !feature_available {
				error_node(node, "Procedure requires target feature '%s' which is not enabled", req_trimmed)
				error_line("\tSuggestion: Add @(enable_target_feature=\"%s\") to the calling procedure", req_trimmed)
				// Note: We don't return invalid here, just warn, to match C++ behavior
			}
		}
	}

	// Step 11: Set result type based on procedure return type
	// Reference: /mnt/c/odin/src/check_expr.cpp:8307-8325
	set_call_result_type(o, arg_data.result_type, node)

	{
		specialized := arg_data.final_proc_type
		if specialized == nil {
			specialized = proc_type
		}
		apply_optional_ok_call_result(ctx, o, call, specialized)
	}

	// Step 12: Track deferred procedure calls
	// C++ Reference: check_expr.cpp:8292-8298
	// If the called procedure has a deferred attribute, mark this expression
	// as containing a deferred procedure for control flow analysis
	if callee_entity != nil {
		if callee_proc, is_proc := callee_entity.variant.(Entity_Procedure); is_proc {
			if callee_proc.deferred_procedure.entity != nil {
				// Mark this call expression as containing a deferred procedure
				node.viral_state_flags += {.Contains_Deferred_Procedure}
			}
		}
	}

	// Inlining directive validation
	// Reference: /mnt/c/odin/src/check_expr.cpp:8327-8374
	if call.inlining != .None {
		// Get the entity of the procedure being called
		proc_entity := entity_of_node(ctx.info, call.expr)
		if proc_entity != nil && proc_entity.decl_info != nil && proc_entity.decl_info.proc_lit != nil {
			proc_lit := proc_entity.decl_info.proc_lit
			proc_inlining := proc_lit.inlining

			// Check for conflicts
			if call.inlining == .Inline && proc_inlining == .No_Inline {
				error_node(node, "Cannot force inline a procedure marked as '#force_no_inline'")
			} else if call.inlining == .No_Inline && proc_inlining == .Inline {
				// This is usually allowed - caller can suppress inlining
				// But we might want to warn in some cases
			}
		}
	}

	return .Expr
}

// check_call_arguments_basic validates arguments for a basic procedure call
// Reference: /mnt/c/odin/src/check_expr.cpp:7505-7615
//
// Implemented features:
// - Positional arguments
// - Named arguments (with position lookup)
// - Default parameters (constant/nil values)
// - Variadic arguments (including ..any and variadic expansion)
// - Polymorphic procedure instantiation (type inference from call-site arguments)
check_call_arguments_basic :: proc(ctx: ^Checker_Context, callee: ^Operand, call: ^ast.Call_Expr) -> Call_Argument_Data {
	data: Call_Argument_Data
	data.error = false

	proc_type := base_type(callee.type)
	if proc_type != nil {
	} else {
	}
	assert(proc_type.kind == .Proc, "check_call_arguments_basic expects procedure type")

	pt := &proc_type.variant.(Type_Proc)

	// Check 1: Polymorphic procedure instantiation
	// Reference: /mnt/c/odin/src/check_expr.cpp:369-658 (290 LOC)
	if pt.is_polymorphic {
		// Get the base entity for the polymorphic procedure
		// C++ Reference: check_expr.cpp:652
		base_entity := entity_from_expr_ctx(ctx, callee.expr)
		if base_entity == nil {
			error_node(call.expr, "Cannot call polymorphic procedure from non-entity expression")
			data.error = true
			data.result_type = pt.results
			return data
		}

		// Build operands from arguments, in parameter order so check_get_params works.
		//
		// Each argument is checked with its DECLARED parameter type as the hint. C++ does
		// this for polymorphic calls exactly as it does for ordinary ones: the `lhs` array
		// handed to check_unpack_arguments is the parameter entity array (check_expr.cpp
		// :7448-7479, :7502), and a polymorphic procedure is not special-cased there.
		//
		// The hint matters because a parameter can be non-polymorphic even when the
		// procedure is -- `recvfrom :: proc(sock: Fd, buf: []u8, flags: Socket_Msg,
		// addr: ^$T)` has a fully known `flags` type. Without the hint an untyped
		// compound literal argument like `{.TRUNC}` has nothing to resolve against and
		// failed with "Missing type in compound literal".
		poly_param_count := pt.param_count
		poly_operands := make([]Operand, poly_param_count, context.temp_allocator)
		poly_visited := make([]bool, poly_param_count, context.temp_allocator)
		positional_index := 0

		poly_param_types := make([]^Type, poly_param_count, context.temp_allocator)
		if pt.params != nil {
			if params_tuple, is_tuple := pt.params.variant.(Type_Tuple); is_tuple {
				for entity, i in params_tuple.variables {
					if i < poly_param_count {
						poly_param_types[i] = entity_type(entity)
					}
				}
			}
		}

		for arg in call.args {
			if fv, is_field := arg.derived.(^ast.Field_Value); is_field {
				// Named argument - find parameter index
				if ident, is_ident := fv.field.derived.(^ast.Ident); is_ident {
					param_idx := lookup_procedure_parameter(pt, ident.name)
					if param_idx >= 0 && param_idx < poly_param_count {
						arg_op: Operand
						// Use check_expr_or_type to allow type arguments like int in zero(int)
						check_expr_or_type(ctx, &arg_op, fv.value, poly_param_types[param_idx])
						poly_operands[param_idx] = arg_op
						poly_visited[param_idx] = true
					}
				}
			} else {
				// Positional argument - use next position
				if positional_index < poly_param_count {
					arg_op: Operand
					// Use check_expr_or_type to allow type arguments like int in zero(int)
					check_expr_or_type(ctx, &arg_op, arg, poly_param_types[positional_index])
					poly_operands[positional_index] = arg_op
					poly_visited[positional_index] = true
					positional_index += 1
				}
			}
		}

		// Instantiate the polymorphic procedure
		// C++ Reference: check_expr.cpp:657-659
		poly_data: Poly_Proc_Data
		if !find_or_generate_polymorphic_procedure_from_parameters(ctx, base_entity, poly_operands[:], call.expr, &poly_data) {
			// Instantiation failed - error already reported
			data.error = true
			data.result_type = pt.results
			return data
		}

		// Update to the specialized procedure type
		// C++ Reference: check_expr.cpp:486-490
		if poly_data.gen_entity != nil {
			proc_type = base_type(entity_type(poly_data.gen_entity))
			pt = &proc_type.variant.(Type_Proc)
			// Update callee for proper entity tracking
			callee.type = entity_type(poly_data.gen_entity)
			add_entity_use(ctx, call.expr, poly_data.gen_entity)

			// C++ Reference: check_expr.cpp:7281-7305, reached from the SINGLE-procedure
			// call at check_expr.cpp:8107.
			//
			// LEDGER task 278/279. C++ runs one `check_call_arguments_single` for both
			// proc-group and single calls, so this committed pass happens either way. The
			// port has two argument checkers -- `check_call_arguments_single` for groups and
			// this one for everything else -- and only the group copy had the block, so for
			// a plain polymorphic call the committed pass NEVER RAN. Nothing set
			// `where_clauses_evaluated`, so check_proc_body's evaluation (check_proc.odin,
			// print_err = !where_clauses_evaluated) printed the failure on every entry --
			// four times per instantiation, with no "at caller location", because only the
			// call site passes a non-nil call expression.
			//
			// A false clause does NOT abort the call here: C++'s committed branch records
			// the flag and continues, and only skips RE-scheduling the body. The port
			// already schedules unconditionally inside
			// find_or_generate_polymorphic_procedure_from_parameters, exactly as C++ does at
			// check_expr.cpp:651, so there is no re-schedule to skip.
			gen_decl := poly_data.gen_entity.decl_info
			if gen_decl != nil && gen_decl.proc_lit != nil {
				where_ctx := ctx^
				where_ctx.scope = gen_decl.scope
				where_ctx.decl = gen_decl
				where_ctx.proc_name = poly_data.gen_entity.token.text
				where_ctx.curr_proc_decl = gen_decl
				where_ctx.curr_proc_sig = entity_type(poly_data.gen_entity)

				_ = evaluate_where_clauses(&where_ctx, call, gen_decl.scope, gen_decl.proc_lit.where_clauses, true)
				gen_decl.where_clauses_evaluated = true
			}
		}
		// Continue with normal argument checking using the specialized type
	}

	// Variadic handling setup
	// Reference: /mnt/c/odin/src/check_expr.cpp:6369-6413
	variadic_index := pt.variadic_index
	variadic_elem_type: ^Type = nil
	is_variadic_any := false

	if pt.variadic {
		// Get the variadic parameter's element type
		// The variadic param type is already a slice (..int becomes []int)
		if pt.params != nil && pt.params.kind == .Tuple {
			params_tuple := &pt.params.variant.(Type_Tuple)
			if variadic_index >= 0 && variadic_index < len(params_tuple.variables) {
				variadic_param := params_tuple.variables[variadic_index]
				variadic_type := entity_type(variadic_param)
				if variadic_type != nil && variadic_type.kind == .Slice {
					variadic_elem_type = variadic_type.variant.(Type_Slice).elem
					is_variadic_any = is_type_any(variadic_elem_type)
				}
			}
		}
	}

	// Get parameter types from the tuple entities
	// NOTE: Matches C++ implementation which stores Entity* in Tuple.variables
	// Reference: /mnt/c/odin/src/check_expr.cpp:6260-6280
	param_types: [dynamic]^Type
	if pt.params != nil && pt.params.kind == .Tuple {
		param_tuple := &pt.params.variant.(Type_Tuple)
		// Extract types from entity variables
		param_types = make([dynamic]^Type, len(param_tuple.variables), context.temp_allocator)
		for entity, i in param_tuple.variables {
			param_types[i] = entity_type(entity)
		}
	}

	param_count := len(param_types)

	// Split arguments into positional and named
	// Reference: /mnt/c/odin/src/check_expr.cpp:6322-6361
	positional_args: [dynamic]^ast.Expr
	named_args: [dynamic]^ast.Field_Value
	for arg in call.args {
		if fv, is_field := arg.derived.(^ast.Field_Value); is_field {
			append(&named_args, fv)
		} else {
			// Positional arguments must come before named arguments
			if len(named_args) > 0 {
				error_node(arg, "Positional arguments must come before named arguments")
				data.error = true
				data.result_type = pt.results
				return data
			}
			append(&positional_args, arg)
		}
	}

	// Unpack multi-valued positional arguments (`f(returns_two())`) into a flat
	// operand list, giving each one the matching parameter's type as a hint.
	// This is the only place the positional arguments get checked; everything
	// below consumes `positional_operands` rather than the raw argument nodes.
	//
	// C++ Reference: /mnt/c/odin/src/check_expr.cpp check_call_arguments, the
	// `check_unpack_arguments(c, lhs, lhs_count, &positional_operands, positional_args, UnpackFlag_None, variadic_index)` call.
	//
	// No flags: `---` is not a legal call argument (that is `.Allow_Undef`, for
	// variable declarations) and optional-ok does not spread across two
	// parameters at a call site (that is `.Allow_Ok`, for declarations and
	// returns). Only genuine tuples expand here. The variadic index is passed so
	// arguments landing in the variadic slot are hinted with its element type.
	positional_operands := make([dynamic]Operand, 0, 2 * len(positional_args), context.temp_allocator)
	if len(positional_args) > 0 {
		lhs := populate_proc_parameter_list(ctx, proc_type)
		unpack_variadic_index := -1
		if pt.variadic {
			unpack_variadic_index = variadic_index
		}
		check_unpack_arguments(ctx, lhs, &positional_operands, positional_args[:], {}, unpack_variadic_index)
	}

	// Handle variadic expansion (args..)
	// Reference: /mnt/c/odin/src/check_expr.cpp:6274-6288
	vari_expand := call.ellipsis.kind != .Invalid
	if vari_expand {
		if !pt.variadic {
			error_node(call, "Cannot use '..' in call to non-variadic procedure")
			data.error = true
			data.result_type = pt.results
			return data
		}
		// With variadic expansion, positional_args should have exactly variadic_index + 1 args
		// The last one is the slice being expanded
		if len(positional_operands) != variadic_index + 1 {
			error_node(call, "Variadic expansion '..' requires exactly %d positional arguments before the expanded slice", variadic_index)
			data.error = true
			data.result_type = pt.results
			return data
		}
	}

	// Track which parameters have been visited
	visited := make([]bool, param_count, context.temp_allocator)

	// For variadic arguments, we need extra storage
	variadic_operands: [dynamic]Operand
	if pt.variadic {
		variadic_operands = make([dynamic]Operand, 0, len(call.args), context.temp_allocator)
	}

	// Process named arguments
	// Reference: /mnt/c/odin/src/check_expr.cpp:6322-6361
	ordered_operands := make([]Operand, param_count, context.temp_allocator)

	for fv in named_args {
		// Named field must be an identifier
		ident, is_ident := fv.field.derived.(^ast.Ident)
		if !is_ident {
			expr_str := expr_to_string(fv.field)
			defer delete(expr_str)
			error_node(fv.field, "Invalid parameter name '%s' in procedure call", expr_str)
			data.error = true
			continue
		}

		name := ident.name
		param_index := lookup_procedure_parameter(pt, name)
		if param_index < 0 {
			error_node(fv.field, "No parameter named '%s' for this procedure type", name)
			data.error = true
			continue
		}

		if visited[param_index] {
			error_node(fv.field, "Duplicate parameter '%s' in procedure call", name)
			data.error = true
			continue
		}

		visited[param_index] = true

		// Check the named argument value
		param_type := param_types[param_index]
		arg_op: Operand
		check_expr_or_type(ctx, &arg_op, fv.value, param_type)
		ordered_operands[param_index] = arg_op
	}

	// Check positional argument count (before processing)
	// Reference: /mnt/c/odin/src/check_expr.cpp:6304-6312
	// NOTE: counted after unpacking, so `f(returns_two())` counts as two.
	positional_count := len(positional_operands)

	// For variadic procedures, we need at least variadic_index non-variadic args
	// For non-variadic procedures, we can't exceed param_count
	if pt.variadic {
		// Minimum required is variadic_index (the non-variadic parameters)
		if positional_count < variadic_index && !vari_expand {
			// Not enough arguments for non-variadic params (variadic part can be empty)
			// This will be caught in the "required parameters" check below
		}
	} else {
		if positional_count > param_count {
			// C++ Reference: check_expr.cpp:6680-6689. C++ NAMES the procedure and, when
			// some parameters have defaults, reports the accepted RANGE rather than a single
			// count. The port's wording was invented and named neither.
			proc_str := expr_to_string(call.expr)
			defer delete(proc_str)
			required := get_procedure_param_count_excluding_defaults(proc_type)
			if required != param_count {
				error_node(call, "Too many arguments for '%s', expected %d..=%d arguments, got %d", proc_str, required, param_count, positional_count)
			} else {
				error_node(call, "Too many arguments for '%s', expected %d arguments, got %d", proc_str, param_count, positional_count)
			}
			data.error = true
			data.result_type = pt.results
			return data
		}
	}

	// Process positional arguments
	// Reference: /mnt/c/odin/src/check_expr.cpp:6369-6413
	for i in 0 ..< len(positional_operands) {
		// `arg` is the expression this operand came from. For an unpacked tuple
		// every element reports against the multi-valued expression itself,
		// which is what C++ does too.
		arg := positional_operands[i].expr
		if arg == nil {
			arg = call.expr
		}
		// For variadic procedures, arguments at or after variadic_index go to variadic
		if pt.variadic && i >= variadic_index {
			// Handle variadic arguments
			if vari_expand && i == variadic_index {
				// Variadic expansion: the argument should be a slice
				// Reference: /mnt/c/odin/src/check_expr.cpp:6274-6288
				expected_slice_type := param_types[variadic_index]
				arg_op := positional_operands[i]

				if arg_op.mode != .Invalid {
					// Verify it's assignable to the variadic slice type
					if !check_is_assignable_to(ctx, &arg_op, expected_slice_type) {
						arg_type_str := type_to_string(arg_op.type)
						param_type_str := type_to_string(expected_slice_type)
						error_node(arg, "Cannot expand argument of type '%s' as variadic '%s'", arg_type_str, param_type_str)
						data.error = true
					}
				}
				// Mark variadic param as visited
				visited[variadic_index] = true
				ordered_operands[variadic_index] = arg_op
			} else {
				// Regular variadic argument: check against element type
				arg_op := positional_operands[i]

				if arg_op.mode != .Invalid {
					// For ..any, any type is allowed (will be converted to any)
					if is_variadic_any {
						// Any type accepted for ..any
						add_type_info_type(ctx, arg_op.type)
					} else {
						// Check assignability to variadic element type
						if !check_is_assignable_to(ctx, &arg_op, variadic_elem_type) {
							arg_type_str := type_to_string(arg_op.type)
							elem_type_str := type_to_string(variadic_elem_type)
							error_node(arg, "Cannot pass argument of type '%s' to variadic parameter of type '..%s'", arg_type_str, elem_type_str)
							data.error = true
						}
					}
				}
				append(&variadic_operands, arg_op)

				// Mark variadic param as visited (only need to mark once)
				if i == variadic_index {
					visited[variadic_index] = true
				}
			}
		} else {
			// Non-variadic argument
			if i >= param_count {
				// Shouldn't happen for non-variadic after the check above
				error_node(arg, "Too many arguments")
				data.error = true
				continue
			}
			if visited[i] {
				error_node(arg, "Positional argument conflicts with named argument at position %d", i)
				data.error = true
				continue
			}
			visited[i] = true

			ordered_operands[i] = positional_operands[i]
		}
	}

	// For variadic procedures, mark the variadic parameter as visited if we have any variadic args
	// or if there are no variadic args (empty variadic is valid)
	if pt.variadic && variadic_index < param_count {
		visited[variadic_index] = true // Variadic params are always "provided" (can be empty)
	}

	// Mark polymorphic parameters as visited since they are resolved during instantiation:
	// - Type_Name: polymorphic type parameters ($T: typeid)
	// - Constant: polymorphic constant parameters ($N: int)
	if pt.params != nil {
		params_tuple, is_tuple := pt.params.variant.(Type_Tuple)
		if is_tuple {
			for entity, i in params_tuple.variables {
				if entity.kind == .Type_Name || entity.kind == .Constant {
					visited[i] = true
				}
			}
		}
	}

	// Check that all required parameters are provided
	// Reference: /mnt/c/odin/src/check_expr.cpp:6415-6464
	for i := 0; i < param_count; i += 1 {
		if !visited[i] {
			// Check for default parameter values
			// Reference: /mnt/c/odin/src/check_expr.cpp:6415-6464
			has_default := false
			if pt.params != nil {
				params_tuple, is_tuple := pt.params.variant.(Type_Tuple)
				if is_tuple && i < len(params_tuple.variables) {
					param_entity := params_tuple.variables[i]
					if param_entity.kind == .Variable {
						var_entity := &param_entity.variant.(Entity_Variable)
						if var_entity.param_value.kind != .Invalid {
							has_default = true

							// `#+vet explicit-allocators`: an omitted parameter whose
							// default is literally `context.allocator` or
							// `context.temp_allocator` must be passed explicitly.
							// C++ Reference: check_expr.cpp:6798-6812 -- it matches the
							// default's ORIGINAL expression syntactically, an implicit
							// `context` selected with `allocator`/`temp_allocator`, and
							// gates on the per-file vet flag.
							//
							// The flag reaches us because progress#79 populates
							// file.vet_flags from the `#+vet` tag; before that this check
							// could not have fired at all.
							if ctx.file != nil && .Explicit_Allocators in ctx.file.vet_flags {
								if sel, sel_ok := var_entity.param_value.original_ast_expr.derived.(^ast.Selector_Expr); sel_ok {
									is_ctx := false
									if _, imp_ok := sel.expr.derived.(^ast.Implicit); imp_ok {
										is_ctx = true
									} else if id, id_ok := sel.expr.derived.(^ast.Ident); id_ok {
										is_ctx = id.name == "context"
									}
									if is_ctx && sel.field != nil {
										if fid, fid_ok := sel.field.derived.(^ast.Ident); fid_ok {
											if fid.name == "allocator" || fid.name == "temp_allocator" {
												error_node(call, "Parameter '%s' of type '%s' must be explicitly provided in procedure call", param_entity.token.text, type_to_string(entity_type(param_entity)))
											}
										}
									}
								}
							}
							// C++ check_expr.cpp:6816-6821 synthesises an operand
							// for the omitted argument from the parameter's default.
							// Without this the slot stays zeroed, the type-check loop
							// below reads it as Addressing_Invalid and sets data.error,
							// and the whole call collapses to a single invalid value.
							ordered_operands[i].mode = .Value
							ordered_operands[i].type = entity_type(param_entity)
							if var_entity.param_value.kind == .Nil {
								ordered_operands[i].type = t_untyped_nil
							}
							ordered_operands[i].expr = var_entity.param_value.original_ast_expr
						}
					}
				}
			}

			if !has_default {
				// C++ Reference: check_expr.cpp:6835-6844. C++ names the parameter's TYPE as
				// well, and gives type parameters their own message; "Missing argument for
				// parameter '%s'" was invented, and the positional fallback has no C++
				// counterpart at all.
				param_entity: ^Entity = nil
				if pt.params != nil {
					params_tuple, is_tuple := pt.params.variant.(Type_Tuple)
					if is_tuple && i < len(params_tuple.variables) {
						param_entity = params_tuple.variables[i]
					}
				}
				if param_entity != nil && param_entity.kind == .Type_Name {
					error_node(call, "Type parameter '%s' is missing in procedure call", param_entity.token.text)
				} else if param_entity != nil {
					type_str := type_to_string(entity_type(param_entity))
					error_node(call, "Parameter '%s' of type '%s' is missing in procedure call", param_entity.token.text, type_str)
				} else {
					error_node(call, "Missing argument for parameter at position %d", i)
				}
				data.error = true
			}
		}
	}

	if data.error {
		data.result_type = pt.results
		return data
	}

	// Type check each argument
	// Reference: /mnt/c/odin/src/check_expr.cpp:6480-6850 (simplified)
	for i := 0; i < param_count; i += 1 {
		// The variadic slot was already checked above: expanded arguments against the
		// slice type, unexpanded ones element-by-element against the element type.
		// `ordered_operands` never holds a packed operand for it, so checking it here
		// would compare a single element against the slice type -- and in the
		// unexpanded case the slot is still zero-valued, which read as an invalid
		// argument and failed the call with no diagnostic at all.
		if pt.variadic && i == variadic_index {
			continue
		}

		// Skip polymorphic parameters that don't need runtime arguments:
		// - Type_Name: polymorphic type parameters ($T: typeid) - resolved during instantiation
		// - Constant: polymorphic constant parameters ($N: int) - resolved during instantiation
		if pt.params != nil && i < len(pt.params.variant.(Type_Tuple).variables) {
			param_entity := pt.params.variant.(Type_Tuple).variables[i]
			if param_entity.kind == .Type_Name || param_entity.kind == .Constant {
				continue
			}
		}

		arg_op := &ordered_operands[i]
		param_type := param_types[i]

		if arg_op.mode == .Invalid {
			data.error = true
			continue
		}

		// Validate type compatibility
		// Reference: check_call_arguments_internal lines 6480+
		if !check_is_assignable_to(ctx, arg_op, param_type) {
			// Check for #any_int flag allowing integer casts
			// C++ Reference: check_expr.cpp:6475-6479
			ok := false
			if i < len(pt.params.variant.(Type_Tuple).variables) {
				param_entity := pt.params.variant.(Type_Tuple).variables[i]
				if .Any_Int in param_entity.flags {
					if is_type_integer(param_type) {
						ok = check_is_castable_to(ctx, arg_op, param_type)
					}
				}
			}

			if !ok {
				arg_type_str := type_to_string(arg_op.type)
				param_type_str := type_to_string(param_type)
				error_node(arg_op.expr, "Cannot pass argument of type '%s' to parameter of type '%s'", arg_type_str, param_type_str)
				data.error = true
			}
		}
	}

	// Track variadic reuse for stack optimization
	// C++ Reference: check_expr.cpp:6628-6642
	// This allows the backend to minimize stack usage for variadic parameters
	if !vari_expand && len(variadic_operands) > 0 {
		if ctx.decl != nil && pt.variadic && variadic_index >= 0 && variadic_index < len(param_types) {
			slice_type := param_types[variadic_index]
			if slice_type != nil && slice_type.kind == .Slice {
				// Check if we already have an entry for this slice type
				found := false
				for &vr in ctx.decl.variadic_reuses {
					if are_types_identical(slice_type, vr.slice_type) {
						vr.max_count = max(vr.max_count, i64(len(variadic_operands)))
						found = true
						break
					}
				}
				if !found {
					append(&ctx.decl.variadic_reuses, Variadic_Reuse_Data{
						slice_type = slice_type,
						max_count  = i64(len(variadic_operands)),
					})
				}
			}
		}
	}

	// Set result type
	data.result_type = pt.results
	// `proc_type` here is the SPECIALIZED type when this was a polymorphic procedure —
	// it is reassigned from the generated entity above. Callers need that, not the
	// generic declaration, or `$T` is still unbound in the results.
	data.final_proc_type = proc_type

	return data
}

// apply_optional_ok_call_result narrows the result of a call to an
// `#optional_ok` / `#optional_allocator_error` procedure.
//
// Such a call yields ONE value, not the full tuple: the operand carries the first
// result and the `.Optional_Ok` addressing mode. Two-LHS uses are re-expanded by the
// unpacking paths (check_decl_helpers.odin:226, check_stmt.odin:1045), which already
// recognised this mode — they were simply never reached, because a call always
// produced a plain tuple. That is why `a := make([]byte, n)`, dropping the allocator
// error, failed as an assignment count mismatch, and `c := ok2(n)` as an extra initial
// expression, while both two-value forms worked.
//
// C++ Reference: check_expr.cpp:8987-9003. It prefers the type recorded for the callee
// expression and falls back to the procedure type in hand; `fallback` supplies the
// latter. C++ additionally sets `CallExpr.optional_ok_one`, which is backend-only for
// codegen and has no counterpart in core/odin/ast, so it is deliberately not mirrored.
apply_optional_ok_call_result :: proc(ctx: ^Checker_Context, o: ^Operand, call: ^ast.Call_Expr, fallback: ^Type) {
	// Prefer the type recorded for the callee expression, as C++ does. For a call
	// through a proc group that expression names the GROUP, whose recorded type is
	// not a procedure type at all, so fall back whenever it is not a Proc — not only
	// when it is nil.
	t := base_type(type_of_expr(call.expr, &ctx.checker.info))
	// Fall back when the recorded callee type is absent, is not a procedure (a proc
	// GROUP identifier), or is still POLYMORPHIC.
	//
	// The polymorphic case matters: for `new(Tokenizer)` the callee expression still
	// records the generic `proc($T: typeid) -> (^T, Allocator_Error)`, because the port
	// does not re-record the generated entity's type on that expression the way C++ does.
	// Narrowing from it yields `^typeid` instead of `^Tokenizer`, and every field access
	// on the result then failed with "'a' of type '^typeid' has no field ...".
	// `fallback` carries the specialized type from Call_Argument_Data.final_proc_type.
	if t == nil || t.kind != .Proc || t.variant.(Type_Proc).is_polymorphic {
		if fb := base_type(fallback); fb != nil && fb.kind == .Proc {
			t = fb
		}
	}
	if t == nil || t.kind != .Proc {
		return
	}
	pt := &t.variant.(Type_Proc)
	if !pt.optional_ok || pt.result_count <= 0 || pt.results == nil || pt.results.kind != .Tuple {
		return
	}
	results := &pt.results.variant.(Type_Tuple)
	if len(results.variables) == 0 {
		return
	}
	o.mode = .Optional_Ok
	o.type = entity_type(results.variables[0])

	// Re-record the RESOLVED procedure type on the callee expression.
	//
	// check_promote_optional_ok (check_expr.odin:6035) re-derives the callee type with
	// `type_of_expr(call.expr)` in order to read the SECOND result type - which is what
	// distinguishes `#optional_ok` (second value is a bool) from `#optional_allocator_error`
	// (second value is an Allocator_Error). Type_Proc carries a single `optional_ok` flag for
	// both tags, so that second-result lookup is the only thing telling them apart.
	//
	// For a call through a proc GROUP the callee expression names the group, whose recorded
	// type is not a procedure type at all. `is_type_proc` then fails, and the code falls
	// through to `make_optional_ok_type`, which manufactures `(T, bool)` - so
	// `bits, err := make(...)` gave `err` type `bool` and every `err == nil` reported
	// "Cannot compare 'bool' and 'untyped nil'". Plain and polymorphic calls were unaffected
	// because their callee expression does record a proc type.
	//
	// Recording it here is the same correction task 122 made for the result type: C++ puts the
	// resolved entity's type on that expression and the port did not.
	if call.expr != nil {
		add_type_and_value(ctx, call.expr, .Value, t, Exact_Value{})
	}
}

// set_call_result_type sets the operand mode and type based on procedure return type
// Reference: /mnt/c/odin/src/check_expr.cpp:8307-8325
//
// Odin procedures return a tuple type, which needs to be unwrapped:
// - 0 returns: NoValue mode
// - 1 return: Value mode with single type
// - N returns: Value mode with tuple type
set_call_result_type :: proc(o: ^Operand, result_type: ^Type, call_node: ^ast.Node) {
	o.expr = call_node

	// A call's result is never a compile-time constant, so it must not carry an exact value.
	//
	// It could, and did. The callee is checked into THIS SAME operand, and for a procedure
	// entity that sets `o.value = exact_value_procedure(...)` (check_expr.odin:583, matching
	// C++ check_expr.cpp:2025). Nothing downstream cleared it, so after checking `g()` the
	// operand read mode=Value, type=int, value=Exact_Value_Procedure{g} -- the CALLEE's value
	// attached to the CALL's result.
	//
	// C++ avoids this by resetting the whole operand at the top of every expression check
	// (check_expr.cpp:12247-12249: mode=Invalid, type=t_invalid, value={ExactValue_Invalid}).
	// The port's dispatch has no such reset, so the stale value survived.
	//
	// Consequence found via LEDGER #163: check_type.odin's default-parameter chain tests
	// `o.value != nil` as C++ tests `value.kind != ExactValue_Invalid`, so a call passed as a
	// default parameter was silently accepted as constant -- `proc(x: int = g())` produced no
	// diagnostic where the oracle rejects it. Any other site using o.value as a proxy for
	// constness had the same wrong answer available to it.
	o.value = nil

	if result_type == nil {
		// Procedure returns nothing
		o.mode = .No_Value
		o.type = nil
		return
	}

	// Result type should always be a tuple
	if result_type.kind != .Tuple {
		// Defensive: shouldn't happen with valid procedure types
		o.mode = .Invalid
		o.type = t_invalid
		return
	}

	tuple := &result_type.variant.(Type_Tuple)

	switch len(tuple.variables) {
	case 0:
		// No return values
		o.mode = .No_Value
		o.type = nil

	case 1:
		// Single return value - unwrap from tuple
		o.mode = .Value
		o.type = entity_type(tuple.variables[0])

	case:
		// Multiple return values - keep as tuple
		o.mode = .Value
		o.type = result_type
	}
}

// check_compound_literal checks compound literal expressions: T{...}
// Reference: /mnt/c/odin/src/check_expr.cpp:9763-10728 (965 lines)
//
// IMPLEMENTATION NOTE: The full implementation is in check_compound_lit.odin
// Since both files are in the same package (checker), the procedure is
// automatically available here without needing an explicit forward declaration.

// NOTE: The actual implementation is in check_compound_lit.odin lines 227-631
// No stub needed here - Odin allows calling procedures defined later in the same package

// check_for_integer_division_by_zero resolves the division-by-zero behaviour for a node.
//
// C++ Reference: check_expr.cpp:10534-10550. The per-FILE `#+feature integer-division-by-zero:*`
// flags win over the global build setting. The port consulted only
// build_context.integer_division_by_zero_behaviour, so a file opting into `:zero` still got the
// "Division by zero not allowed" error -- an over-rejection.
check_for_integer_division_by_zero :: proc(ctx: ^Checker_Context, node: ^ast.Node) -> Integer_Division_By_Zero_Kind {
	flags := check_feature_flags(ctx, node)
	if .Integer_Division_By_Zero_Trap     in flags { return .Trap }
	if .Integer_Division_By_Zero_Zero     in flags { return .Zero }
	if .Integer_Division_By_Zero_Self     in flags { return .Self }
	if .Integer_Division_By_Zero_All_Bits in flags { return .All_Bits }
	return build_context.integer_division_by_zero_behaviour
}
