package checker

/*
Entity collection from file declarations.

This module implements Phase 1 of the checker pipeline - collecting declarations
from files and creating file scopes. This happens before entity resolution.

C++ Reference: /mnt/c/odin/src/checker.cpp:5548-5775

Architecture:
- collect_when_stmt_from_file: Evaluates compile-time when conditions
- collect_file_decls: Gathers declarations from file AST
- check_create_file_scopes: Creates file-level scopes
- check_collect_entities_all: Orchestrates parallel entity collection

Note: This file uses types and procedures from checker.odin (Checker_Context, Operand, etc.)
*/

import "core:container/queue"
import "core:odin/ast"
import "core:sync"
import "core:odin/tokenizer"
import "core:strings"
import "core:slice"


// ======================================================================================
// WHEN STATEMENT COLLECTION
// C++ Reference: checker.cpp:5551-5624
// ======================================================================================

// collect_when_stmt_from_file evaluates a when statement at compile time and collects entities from the chosen branch
// C++ Reference: checker.cpp:5551-5588
// Returns true if entities were collected successfully
collect_when_stmt_from_file :: proc(ctx: ^Checker_Context, ws: ^ast.When_Stmt) -> bool {
	// C++ line 5552: Create operand for condition evaluation
	operand := Operand {
		mode = .Invalid,
	}

	// C++ line 5553-5564: Determine condition if not already determined
	// Check memoization using AST field before evaluating
	determined_cond: bool
	if ws.is_cond_determined {
		// C++ line 5553: !ws->is_cond_determined check
		// Condition already evaluated, retrieve cached result
		determined_cond = ws.determined_cond
	} else {
		// First evaluation - check expression and cache result
		check_expr(ctx, &operand, ws.cond)

		// C++ line 5554-5557: Validate boolean type
		if operand.mode != .Invalid && !is_type_boolean(operand.type) {
			error(ws.cond, "Non-boolean condition in 'when' statement")
		}

		// C++ line 5558-5560: Validate constant mode
		if operand.mode != .Constant {
			error(ws.cond, "Non-constant condition in 'when' statement")
		}

		// C++ line 5562-5563: Cache determination state
		// ws->is_cond_determined = true;
		// ws->determined_cond = operand.value.kind == ExactValue_Bool && operand.value.value_bool;
		determined_cond = exact_value_to_bool(operand.value)
		ws.is_cond_determined = true
		ws.determined_cond = determined_cond
	}

	// C++ line 5566-5585: Collect entities from chosen branch
	if ws.body == nil {
		error(ws.cond, "Invalid body for 'when' statement")
		return false
	}

	#partial switch body in ws.body.derived {
	case ^ast.Block_Stmt:
		// C++ line 5569-5571: Take true branch
		if determined_cond {
			check_collect_entities(ctx, body.stmts)
			return true
		} else if ws.else_stmt != nil {
			// C++ line 5572-5580: Take false branch
			#partial switch else_body in ws.else_stmt.derived {
			case ^ast.Block_Stmt:
				// C++ line 5574-5576
				check_collect_entities(ctx, else_body.stmts)
				return true
			case ^ast.When_Stmt:
				// C++ line 5577-5579: Recursively handle nested when
				// C++ doesn't return the result, it discards and returns true
				// C++: collect_when_stmt_from_file(ctx, &ws->else_stmt->WhenStmt);
				collect_when_stmt_from_file(ctx, else_body)
				return true
			case:
				error(ws.else_stmt, "Invalid 'else' statement in 'when' statement")
			}
		}
	case:
		error(ws.cond, "Invalid body for 'when' statement")
	}

	// C++ line 5587
	return false
}

// collect_file_decls_from_when_stmt evaluates when statement and collects declarations recursively
// C++ Reference: checker.cpp:5590-5624
// This variant returns declarations rather than immediately processing entities
collect_file_decls_from_when_stmt :: proc(ctx: ^Checker_Context, ws: ^ast.When_Stmt) -> bool {
	// C++ line 5591-5603: Evaluate condition (same as collect_when_stmt_from_file)
	// Use same memoization pattern
	operand := Operand {
		mode = .Invalid,
	}

	determined_cond: bool
	if ws.is_cond_determined {
		// Condition already evaluated, retrieve cached result
		determined_cond = ws.determined_cond
	} else {
		// First evaluation - check expression and cache result
		check_expr(ctx, &operand, ws.cond)

		if operand.mode != .Invalid && !is_type_boolean(operand.type) {
			error(ws.cond, "Non-boolean condition in 'when' statement")
		}

		if operand.mode != .Constant {
			error(ws.cond, "Non-constant condition in 'when' statement")
		}

		determined_cond = exact_value_to_bool(operand.value)
		ws.is_cond_determined = true
		ws.determined_cond = determined_cond
	}

	// C++ line 5605-5621: Recursively collect declarations from chosen branch
	if ws.body == nil {
		error(ws.cond, "Invalid body for 'when' statement")
		return false
	}

	#partial switch body in ws.body.derived {
	case ^ast.Block_Stmt:
		if determined_cond {
			// C++ line 5608-5609: Collect from true branch
			return collect_file_decls(ctx, body.stmts)
		} else if ws.else_stmt != nil {
			#partial switch else_body in ws.else_stmt.derived {
			case ^ast.Block_Stmt:
				// C++ line 5612-5613
				return collect_file_decls(ctx, else_body.stmts)
			case ^ast.When_Stmt:
				// C++ line 5614-5615: Recursively handle nested when
				return collect_file_decls_from_when_stmt(ctx, else_body)
			case:
				error(ws.else_stmt, "Invalid 'else' statement in 'when' statement")
			}
		}
	case:
		error(ws.cond, "Invalid body for 'when' statement")
	}

	// C++ line 5623
	return false
}

// ======================================================================================
// FILE DECLARATION COLLECTION
// C++ Reference: checker.cpp:5627-5704
// ======================================================================================

// collect_file_decl processes a single file-level declaration
// C++ Reference: checker.cpp:5627-5691
// Returns true if type aliases need correction
collect_file_decl :: proc(ctx: ^Checker_Context, decl: ^ast.Stmt) -> bool {
	// C++ line 5628: Verify file scope
	assert(.File in ctx.scope.flags, "collect_file_decl called outside file scope")

	// C++ line 5630-5631: Get current file
	curr_file := ctx.scope.file
	assert(curr_file != nil, "File scope has nil file")

	// C++ line 5633-5635: Check if already handled
	// NOTE: Since core:odin/ast is immutable, we track this in external map
	if has_been_handled(ctx, decl) {
		return false
	}

	// C++ line 5637-5688: Process by declaration kind
	#partial switch d in decl.derived {
	case ^ast.Value_Decl:
		// C++ line 5638-5640
		check_collect_value_decl(ctx, decl)

	case ^ast.Import_Decl:
		// C++ line 5642-5644
		check_add_import_decl(ctx, d)

	case ^ast.Foreign_Import_Decl:
		// C++ line 5646-5648
		check_add_foreign_import_decl(ctx, decl)

	case ^ast.Foreign_Block_Decl:
		// C++ line 5650-5653: Mark handled and queue for later
		mark_been_handled(ctx, decl)

		// Queue for delayed processing (C++ line 5653)
		// C++ Reference: checker.cpp:5939-5942 (processing phase)
		if ctx.collect_delayed_decls && ctx.file != nil {
			// Queue the foreign block declaration directly on file
			append(&ctx.file.delayed_decls_foreign_block, decl)
		}

	case ^ast.When_Stmt:
		// C++ line 5656-5675: Handle when statements
		ws := d

		// Add is_cond_determined branching logic
		// C++ line 5657-5675: Check if condition is already determined
		if !ws.is_cond_determined {
			// C++ line 5657-5660: Condition not yet determined - try immediate collection
			if collect_when_stmt_from_file(ctx, ws) {
				return true
			}

			// C++ line 5662-5667: Try with delayed decls enabled
			nctx := ctx^
			nctx.collect_delayed_decls = true // C++ line 5663

			if collect_file_decls_from_when_stmt(&nctx, ws) {
				return true
			}
		} else {
			// C++ line 5668-5675: Condition already determined - use alternate path
			nctx := ctx^
			nctx.collect_delayed_decls = true // C++ line 5670

			if collect_file_decls_from_when_stmt(&nctx, ws) {
				return true
			}
		}

	case ^ast.Expr_Stmt:
		// C++ line 5678-5686: Handle directive expressions
		mark_been_handled(ctx, decl)

		es := d
		#partial switch expr in es.expr.derived {
		case ^ast.Call_Expr:
			#partial switch _ in expr.expr.derived {
			case ^ast.Basic_Directive:
				// Queue directive expressions for delayed processing
				// C++ line 5684: array_add(&curr_file->delayed_decls_queues[AstDelayQueue_Expr], es->expr)
				// C++ Reference: checker.cpp:5949-5953 (processing phase)
				if ctx.collect_delayed_decls && ctx.file != nil {
					// Queue the directive expression directly on file
					append(&ctx.file.delayed_decls_expr, es.expr)
				}
			}
		}
	}

	// C++ line 5690
	return false
}

// collect_file_decls collects all declarations from a list of statements
// C++ Reference: checker.cpp:5693-5704
// Returns true if type alias correction was triggered
collect_file_decls :: proc(ctx: ^Checker_Context, decls: []^ast.Stmt) -> bool {
	// C++ line 5694: Verify file scope
	assert(.File in ctx.scope.flags, "collect_file_decls called outside file scope")

	// C++ line 5696-5701: Process each declaration
	for decl in decls {
		if collect_file_decl(ctx, decl) {
			// C++ line 5698: Correct type aliases if needed
			correct_type_aliases_in_scope(ctx, ctx.scope)
			return true
		}
	}

	// C++ line 5702: Always correct type aliases at end
	correct_type_aliases_in_scope(ctx, ctx.scope)
	return false
}

// ======================================================================================
// FILE SCOPE CREATION
// C++ Reference: checker.cpp:5714-5731
// ======================================================================================

// NOTE: create_scope_from_file is defined in scope.odin:468
// C++ Reference: checker.cpp:234-249 (scope creation logic)

// filename_from_path extracts the filename (basename) from a file path
// C++ Reference: checker.cpp:5722-5724 (filename_from_path called in sort_file_by_name)
filename_from_path :: proc(path: string) -> string {
	// Extract last path component (handles both / and \ separators)
	for i := len(path) - 1; i >= 0; i -= 1 {
		if path[i] == '/' || path[i] == '\\' {
			return path[i + 1:]
		}
	}
	return path
}

// check_create_file_scopes creates file-level scopes for all packages
// C++ Reference: checker.cpp:5714-5731
check_create_file_scopes :: proc(c: ^Checker) {
	// NOTE: This assumes we have packages in c.info.packages
	// The C++ version iterates c->parser->packages
	// For our implementation, we'll need packages to be registered first

	// C++ line 5715-5730: Process each package
	for pkg in sorted_packages(&c.info) {
		// C++ line 5718: Sort files by name (for deterministic order)
		// C++ Reference: checker.cpp:5719-5725 (sort_file_by_name comparator)
		// Extract files from map to slice for sorting
		file_list := make([dynamic]^ast.File, 0, len(pkg.files), context.temp_allocator)
		for file in sorted_files(pkg.files) {
			append(&file_list, file)
		}

		// Sort files by filename (basename of fullpath)
		slice.sort_by(file_list[:], proc(a, b: ^ast.File) -> bool {
			name_a := filename_from_path(a.fullpath)
			name_b := filename_from_path(b.fullpath)
			return strings.compare(name_a, name_b) < 0
		})

		// total_pkg_decl_count not used

		// C++ line 5721-5727: Create scope for each file
		for file in file_list {
			// C++ line 5723: Register file in info.files map
			c.info.files[file.fullpath] = file

			// Register file by ID for node->file lookups
			// C++ equivalent: global_files[file_id] = file (parser.hpp:868-871)
			// This enables get_file_from_node(info, node) to retrieve file from node.file_id
			c.info.files_by_id[i32(file.id)] = file

			// C++ line 5725: Create file scope
			pkg_scope := get_package_scope(&c.info, pkg)
			file_scope := create_scope_from_file(pkg_scope, file, c.allocator)

			// Store scope in file_scopes external map
			// C++ Reference: checker.cpp:246 - f->scope = s (in create_scope_from_file)
			// NOTE: Cannot use file.scope because ast.File.scope has type ^ast.Scope,
			// while we use checker.Scope. External map required until type unification.
			c.info.file_scopes[file] = file_scope

			// C++ line 5726: Count declarations
			// total_pkg_decl_count += f->total_file_decl_count;
		}

		// C++ line 5729: Initialize export queue
		// C++ Reference: checker.cpp:5729 - mpmc_init(&pkg->exported_entity_queue, total_pkg_decl_count);
		// The exported_entity_queue is a multi-producer multi-consumer queue used in C++ for
		// thread-safe entity collection (see checker.cpp:2044 enqueue, 5780 dequeue).
		// In multi-threaded mode, entities are enqueued during parallel file collection,
		// then dequeued and added to package scope in check_export_entities_in_pkg.
		// MPMC queue implementation complete: see /mnt/c/odin/core/container/queue/mp_queue.odin
		// and package_helpers.odin for queue operations on pkg.exported_entity_queue
	}
}

// ======================================================================================
// PARALLEL ENTITY COLLECTION
// C++ Reference: checker.cpp:5759-5775
// ======================================================================================

// Collect_Entities_Task holds data for parallel entity collection
// C++ Reference: checker.cpp:5770-5775 (check_collect_entities_all_worker_proc)
Collect_Entities_Task :: struct {
	checker:    ^Checker,
	file:       ^ast.File,
	file_scope: ^Scope,
}

// check_collect_entities_all_worker_proc is the worker task for parallel entity collection
// C++ Reference: checker.cpp:5770-5775
check_collect_entities_all_worker_proc :: proc(task: rawptr) -> int {
	t := cast(^Collect_Entities_Task)task

	// Create checker context for this file
	ctx := make_checker_context(t.checker)
	defer destroy_checker_context(&ctx)

	// Set up context for file
	ctx.file = t.file
	ctx.pkg = t.file.pkg
	ctx.scope = t.file_scope
	ctx.collect_delayed_decls = true // Enable delayed declaration collection for file-level directives

	// Collect entities from file declarations
	check_collect_entities(&ctx, t.file.decls[:])

	// Add untyped expressions to global map (thread-safe via sync primitives)
	add_untyped_expressions(&t.checker.info, ctx.untyped)

	return 0
}

// check_collect_entities_all collects entities from all files
// C++ Reference: checker.cpp:5759-5804
// Uses thread pool for parallel entity collection matching C++ implementation
check_collect_entities_all :: proc(c: ^Checker) {
	// Count files for task allocation
	file_count := len(c.info.files)
	if file_count == 0 {
		return
	}

	// C++ Reference: checker.cpp:5789-5803
	// Check if threading is available
	use_threading := global_thread_pool != nil && !build_context.no_threaded_checker

	if use_threading {
		// Allocate tasks array
		tasks := make([]Collect_Entities_Task, file_count, c.allocator)
		defer delete(tasks)

		// Set up tasks for each file
		task_idx := 0
		for file in sorted_files(c.info.files) {
			file_scope := c.info.file_scopes[file]
			if file_scope == nil {
				assert(false, "File scope missing for file - check_create_file_scopes not run?")
				continue
			}

			tasks[task_idx] = Collect_Entities_Task{
				checker    = c,
				file       = file,
				file_scope = file_scope,
			}

			// Submit task to thread pool
			// C++ line 5801: thread_pool_add_task(check_collect_entities_all_worker_proc, f)
			thread_pool_add_task(check_collect_entities_all_worker_proc, &tasks[task_idx])
			task_idx += 1
		}

		// Wait for all tasks to complete
		// C++ line 5803: thread_pool_wait()
		thread_pool_wait()
	} else {
		// Single-threaded fallback
		for file in sorted_files(c.info.files) {
			// Create checker context for this file
			ctx := make_checker_context(c)
			defer destroy_checker_context(&ctx)

			ctx.file = file
			ctx.pkg = file.pkg
			ctx.collect_delayed_decls = true // Enable delayed declaration collection for file-level directives

			file_scope := c.info.file_scopes[file]
			if file_scope == nil {
				assert(false, "File scope missing for file - check_create_file_scopes not run?")
				continue
			}
			ctx.scope = file_scope

			check_collect_entities(&ctx, file.decls[:])
			add_untyped_expressions(&c.info, ctx.untyped)
		}
	}

	// Process delayed declarations for all files
	// C++ Reference: checker.cpp:5885-5957 (process all delayed_decls_queues)
	// This must happen after entity collection is complete for all files
	for file in sorted_files(c.info.files) {
		ctx := make_checker_context(c)
		defer destroy_checker_context(&ctx)
		ctx.file = file
		ctx.pkg = file.pkg
		file_scope := c.info.file_scopes[file]
		if file_scope != nil {
			ctx.scope = file_scope
		}
		process_all_delayed_decls(&ctx, file)
	}
}

// ======================================================================================
// HELPER FUNCTIONS AND PLACEHOLDERS
// ======================================================================================

// Helper: Check if AST node is a declaration
// C++ Reference: is_ast_decl in checker.cpp
is_ast_decl :: proc(node: ^ast.Stmt) -> bool {
	if node == nil {
		return false
	}
	#partial switch _ in node.derived {
	case ^ast.Value_Decl, ^ast.Import_Decl, ^ast.Foreign_Import_Decl, ^ast.Foreign_Block_Decl:
		return true
	}
	return false
}

// Helper: Check if AST node is a when statement
// C++ Reference: is_ast_when_stmt in checker.cpp
is_ast_when_stmt :: proc(node: ^ast.Stmt) -> bool {
	if node == nil {
		return false
	}
	_, ok := node.derived.(^ast.When_Stmt)
	return ok
}

// is_ast_type checks if an AST node represents a type expression
// C++ Reference: is_ast_type in parser.hpp
// Returns true for type nodes (pointer, array, struct, enum, etc.)
is_ast_type :: proc(node: ^ast.Node) -> bool {
	if node == nil {
		return false
	}

	// Check if node is a type expression
	// In the Odin AST, type nodes are directly in the Any_Node union
	#partial switch _ in node.derived {
	// Type expressions
	case ^ast.Pointer_Type, ^ast.Multi_Pointer_Type, ^ast.Array_Type, ^ast.Dynamic_Array_Type, ^ast.Struct_Type, ^ast.Union_Type, ^ast.Enum_Type, ^ast.Bit_Set_Type, ^ast.Map_Type, ^ast.Proc_Type, ^ast.Typeid_Type, ^ast.Helper_Type, ^ast.Poly_Type, ^ast.Matrix_Type, ^ast.Distinct_Type:
		return true
	}

	return false
}

// get_total_value_count computes the total number of values considering tuple unpacking
// C++ Reference: checker.cpp:4320-4336
// For single values, returns 1. For tuple-returning expressions, returns tuple element count.
get_total_value_count :: proc(ctx: ^Checker_Context, values: []^ast.Expr) -> int {
	count := 0
	for value in values {
		// Get the type of this expression (may be nil if not yet checked)
		// C++ line 4323-4326
		t := type_of_expr(value, ctx.info)
		if t == nil {
			count += 1
			continue
		}

		// Unwrap to core type (C++ line 4328)
		t = base_type(t)

		// If it's a tuple, add the number of elements; otherwise add 1
		// C++ line 4329-4333
		if t.kind == .Tuple {
			tuple := t.variant.(Type_Tuple)
			count += len(tuple.variables)
		} else {
			count += 1
		}
	}
	return count
}

// type_of_expr retrieves the type of an expression from the type_and_value_map
// C++ Reference: type_of_expr in checker.cpp
// Returns nil if the expression hasn't been type-checked yet
type_of_expr :: proc(expr: ^ast.Node, info: ^Checker_Info) -> ^Type {
	if expr == nil {
		return nil
	}

	// Check type_and_value_map (C++ equivalent: info->type_and_value_of_expr)
	if tav, ok := tav_lookup(info, expr); ok {
		if tav.mode != .Invalid {
			return tav.type
		}
	}

	return nil
}

// check_arity_match validates that the number of names matches the number of values
// C++ Reference: check_arity_match in checker.cpp:4338-4381
// For value declarations, ensures: x, y := 1, 2 (valid) vs x, y := 1 (invalid unless special case)
check_arity_match :: proc(ctx: ^Checker_Context, vd: ^ast.Value_Decl, is_global: bool) {
	// C++ line 4339-4340: Count LHS names and RHS values
	lhs := len(vd.names)
	rhs := 0

	// C++ line 4341-4346: For globals, disallow multi-valued expressions
	// For locals, compute total value count including tuple unpacking
	if is_global {
		// NOTE(bill): Disallow global variables to be multi-valued for a few reasons
		// C++ line 4342-4343
		rhs = len(vd.values)
	} else {
		// C++ line 4345
		rhs = get_total_value_count(ctx, vd.values[:])
	}

	// C++ line 4348-4352: No values means type must be specified
	if rhs == 0 {
		if vd.type == nil {
			// C++ line 4350
			error(vd.names[0], "Missing type or initial expression")
			return
		}
	} else if lhs < rhs {
		// C++ line 4353-4362: Too many values on RHS
		if lhs < len(vd.values) {
			// C++ line 4354-4358: Show which expression is extra
			n := vd.values[lhs]
			str := expr_to_string(n)
			defer delete(str)
			error(n, "Extra initial expression '%s'", str)
		} else {
			// C++ line 4360: Generic error
			error(vd.names[0], "Extra initial expression")
		}
		return
	} else if lhs > rhs {
		// C++ line 4363-4377: Too few values on RHS
		if !is_global && rhs != 1 {
			// C++ line 4364-4369: Local with multiple values but not enough
			n := vd.names[rhs]
			str := expr_to_string(n)
			defer delete(str)
			error(n, "Missing expression for '%s'", str)
			return
		} else if is_global {
			// C++ line 4370-4377: Global with mismatch
			// ERROR_BLOCK() in C++ - we just do inline errors
			n := vd.values[rhs - 1]
			error(n, "Expected %d expressions on the right hand side, got %d", lhs, rhs)
			error_line("Note: Global declarations do not allow for multi-valued expressions")
			return
		}
	}

	// C++ line 4380: Success
}

// check_builtin_attributes validates and processes builtin attributes on entities
// C++ Reference: check_builtin_attributes in checker.cpp
// Handles attributes like @(deprecated), @(require_results), @(link_name), etc.
check_builtin_attributes :: proc(ctx: ^Checker_Context, e: ^Entity, attributes: []^ast.Attribute) {
	// C++ Reference: checker.cpp - processes various builtin attributes
	// Process attributes and store in Attribute_Context
	// C++ Reference: checker.cpp:4790-4800. An @(builtin) declaration is added to the BUILTIN
	// PACKAGE SCOPE so it resolves everywhere without an import. Nothing in this port did that, so
	// every @(builtin) proc group in base:runtime - append, resize, reserve, delete, make, clear and
	// the rest - was undeclared in every consuming package.
	for attr in attributes {
		for elem in attr.elems {
			attr_name := ""
			has_value := false
			#partial switch en in elem.derived {
			case ^ast.Ident:
				attr_name = en.name
			case ^ast.Field_Value:
				if fi, fi_ok := en.field.derived.(^ast.Ident); fi_ok {
					attr_name = fi.name
					has_value = true
				}
			}
			if attr_name != "builtin" {
				continue
			}
			// C++ Reference: checker.cpp:4796-4798
			if has_value {
				error(elem, "'builtin' cannot have a field value")
			}
			if ctx.info != nil && ctx.info.builtin_package != nil && ctx.info.builtin_package.scope != nil {
				sync.mutex_lock(&ctx.info.builtin_mutex)
				add_entity(ctx, ctx.info.builtin_package.scope, nil, e)
				sync.mutex_unlock(&ctx.info.builtin_mutex)
			}
		}
	}

	// C++ Reference: checker.cpp:4754-4818. C++ evaluates NO attribute values here - it registers
	// @(builtin) declarations (above) and returns. Values are evaluated later, once every
	// declaration in the file is in scope.
	//
	// Evaluating them during collection means a value naming a constant declared later in the file
	// is not yet visible. That is fine for a plain forward reference, but NOT for one declared
	// inside a file-scope `when` block, since those are collected after the declarations preceding
	// them. core/c/libc is built on exactly that shape - `@(link_name=LSETLOCALE)` with LSETLOCALE
	// defined in a later `when ODIN_OS == .NetBSD { ... } else { ... }` - which produced
	// "Expected a string value for 'link_name'" plus "Undeclared name: ...".
	//
	// KNOWN GAP, tracked separately: the code removed from here was the only place that populated
	// entity.link_name, link_prefix, link_suffix, deferred_procedure and is_export. C++ sets those
	// from its own attribute pass in check_proc_decl / check_var_decl; this port has no equivalent
	// yet. They are codegen-facing rather than semantic, so nothing in the checker reads them today.
}

// check_collect_entities_from_when_stmt evaluates a when statement and collects entities
// C++ Reference: checker.cpp:4383-4416
// This is called during entity collection for when statements at non-file scope
check_collect_entities_from_when_stmt :: proc(ctx: ^Checker_Context, ws: ^ast.When_Stmt) {
	// C++ line 4384-4395: Evaluate condition
	operand := Operand {
		mode = .Invalid,
	}

	// Check memoization
	determined_cond: bool
	if ws.is_cond_determined {
		determined_cond = ws.determined_cond
	} else {
		check_expr(ctx, &operand, ws.cond)

		if operand.mode != .Invalid && !is_type_boolean(operand.type) {
			error(ws.cond, "Non-boolean condition in 'when' statement")
		}

		if operand.mode != .Constant {
			error(ws.cond, "Non-constant condition in 'when' statement")
		}

		determined_cond = exact_value_to_bool(operand.value)
		ws.is_cond_determined = true
		ws.determined_cond = determined_cond
	}

	// C++ line 4397-4415: Collect entities from chosen branch
	if ws.body == nil {
		return
	}

	#partial switch body in ws.body.derived {
	case ^ast.Block_Stmt:
		if determined_cond {
			// C++ line 4402: Take true branch
			check_collect_entities(ctx, body.stmts)
		} else if ws.else_stmt != nil {
			#partial switch else_body in ws.else_stmt.derived {
			case ^ast.Block_Stmt:
				// C++ line 4406: Take false branch
				check_collect_entities(ctx, else_body.stmts)
			case ^ast.When_Stmt:
				// C++ line 4409: Recursively handle nested when
				check_collect_entities_from_when_stmt(ctx, else_body)
			}
		}
	}
}

// Helper: Check if declaration has been handled
// C++ Reference: checker.cpp:5633 (decl->state_flags & StateFlag_BeenHandled)
has_been_handled :: proc(ctx: ^Checker_Context, decl: ^ast.Stmt) -> bool {
	// Use AST node's state_flags directly
	// (Stmt embeds Node which has state_flags)
	return .Been_Handled in decl.state_flags
}

// Helper: Mark declaration as handled
// C++ Reference: checker.cpp:5652, 5680 (decl->state_flags |= StateFlag_BeenHandled)
mark_been_handled :: proc(ctx: ^Checker_Context, decl: ^ast.Stmt) {
	// Set been handled flag directly on AST node
	decl.state_flags |= {.Been_Handled}
}

// correct_type_aliases_in_scope is defined in scope.odin

// check_collect_entities is the main entity collection dispatcher
// C++ Reference: checker.cpp:4840-4930
// Iterates through statements and delegates to specialized handlers based on node type
check_collect_entities :: proc(ctx: ^Checker_Context, nodes: []^ast.Stmt) {
	// C++ line 4841-4845: Determine if we're in a file scope
	curr_file: ^ast.File = nil
	if .File in ctx.scope.flags {
		curr_file = ctx.scope.file
		assert(curr_file != nil, "File scope without file")
	}

	// C++ line 4848-4908: Process each declaration
	for decl in nodes {
		// C++ line 4850-4863: Skip non-declarations and non-when statements
		if !is_ast_decl(decl) && !is_ast_when_stmt(decl) {
			// C++ line 4851-4862: Handle directive expressions in file scope
			if curr_file != nil {
				#partial switch expr_stmt in decl.derived {
				case ^ast.Expr_Stmt:
					expr := expr_stmt.expr
					#partial switch call in expr.derived {
					case ^ast.Call_Expr:
						#partial switch _ in call.expr.derived {
						case ^ast.Basic_Directive:
							// C++ line 4854-4859: Queue delayed directive expressions
							if ctx.collect_delayed_decls {
								if has_been_handled(ctx, decl) {
									continue
								}
								mark_been_handled(ctx, decl)

								// Queue directive expression directly on file
								append(&curr_file.delayed_decls_expr, expr)
							}
							continue
						}
					}
				}
			}
			continue
		}

		// C++ line 4865-4907: Process by declaration kind
		#partial switch d in decl.derived {
		case ^ast.Bad_Decl:
			// C++ line 4866: Ignore bad declarations
			continue

		case ^ast.When_Stmt:
			// C++ line 4869-4871: When statements handled later
			// Skip - will be processed in second pass
			continue

		case ^ast.Value_Decl:
			// C++ line 4873-4875: Collect value declarations
			check_collect_value_decl(ctx, decl)

		case ^ast.Import_Decl:
			// C++ line 4877-4885: Queue import declarations for later processing
			if curr_file == nil {
				error(decl, "import declarations are only allowed in the file scope")
				// NOTE(bill): _Should_ be caught by the parser
				continue
			}
			// Will be handled later - add to delayed queue directly on file
			append(&curr_file.delayed_decls_import, decl)

		case ^ast.Foreign_Import_Decl:
			// C++ line 4887-4894: Handle foreign import declarations
			if .File not_in ctx.scope.flags {
				error(decl, "foreign_import declarations are only allowed in the file scope")
				// NOTE(bill): _Should_ be caught by the parser
				continue
			}
			check_add_foreign_import_decl(ctx, decl)

		case ^ast.Foreign_Block_Decl:
			// C++ line 4896-4900: Queue foreign block declarations
			if curr_file != nil {
				// Queue directly on file
				append(&curr_file.delayed_decls_foreign_block, decl)
			}

		case:
			// C++ line 4902-4906: Error on invalid file-scope declarations
			if .File in ctx.scope.flags {
				error(decl, "Only declarations are allowed at file scope")
			}
		}
	}

	// C++ line 4910: Type alias correction handled by caller
	// correct_type_aliases(c);

	// C++ line 4912-4929: Second pass - handle 'when' statements and foreign blocks
	// NOTE(bill): 'when' stmts need to be handled after the other as the condition may refer to something
	// declared after this stmt in source
	if curr_file == nil {
		// C++ line 4914-4921: For 'foreign' block statements that are not in file scope
		for decl in nodes {
			#partial switch _ in decl.derived {
			case ^ast.Foreign_Block_Decl:
				check_add_foreign_block_decl(ctx, decl)
			}
		}

		// C++ line 4923-4928: Process when statements
		for decl in nodes {
			#partial switch ws in decl.derived {
			case ^ast.When_Stmt:
				check_collect_entities_from_when_stmt(ctx, ws)
			}
		}
	}
}

// check_collect_value_decl collects value declarations (variables, constants, types, procedures)
// C++ Reference: checker.cpp:4483-4756
// This handles both mutable (var) and immutable (const/proc/type) declarations
check_collect_value_decl :: proc(ctx: ^Checker_Context, decl: ^ast.Stmt) {
	// C++ line 4484-4485: Check if already handled
	if has_been_handled(ctx, decl) {
		return
	}
	mark_been_handled(ctx, decl)

	// C++ line 4487: Cast to ValueDecl
	vd, ok := decl.derived.(^ast.Value_Decl)
	if !ok {
		return
	}

	// C++ line 4489-4493: Initialize visibility and attribute flags
	entity_visibility_kind := Entity_Visibility_Kind.Public
	is_test := false
	is_init := false
	is_fini := false

	// C++ line 4495-4559: Process attributes
	// Parse attributes for visibility and test/init/fini flags
	for attr in vd.attributes {
		for elem in attr.elems {
			name: string
			value: ^ast.Expr = nil

			#partial switch e in elem.derived {
			case ^ast.Ident:
				name = e.name
			case ^ast.Field_Value:
				if field_ident, ok2 := e.field.derived.(^ast.Ident); ok2 {
					name = field_ident.name
					value = e.value
				}
			case:
				continue
			}

			if name == "private" {
				// C++ line 4516-4546: Parse @(private) visibility
				kind := Entity_Visibility_Kind.Private_To_Package
				success := false

				if value != nil {
					// Check for string literal specifying "file" or "package"
					operand := Operand{}
					check_expr(ctx, &operand, value)

					if operand.mode == .Constant {
						if v_str, ok3 := operand.value.(string); ok3 {
							if v_str == "file" {
								kind = .Private_To_File
								success = true
							} else if v_str == "package" {
								kind = .Private_To_Package
								success = true
							}
						}
					}
				} else {
					// No value means @(private) which defaults to Private_To_Package
					success = true
				}

				if !success {
					error(value, "'%s' expects no parameter, or a string literal containing \"file\" or \"package\"", name)
				} else {
					// C++ line 4541-4545: Set visibility kind (use most restrictive)
					if entity_visibility_kind >= kind {
						error(elem, "Previous declaration of '%s'", name)
					} else {
						entity_visibility_kind = kind
					}
				}
			} else if name == "test" {
				// C++ line 4547
				is_test = true
			} else if name == "init" {
				// C++ line 4549
				is_init = true
			} else if name == "fini" {
				// C++ line 4551
				is_fini = true
			}
		}
	}

	// C++ line 4566-4574: Apply file-level visibility
	// Inherit visibility from file-level @private directive if:
	// 1. Entity is still Public (not explicitly marked private via attributes)
	// 2. We're in a file scope
	// 3. The file has @(private) or @(private="file") directive
	// C++ Reference: checker.cpp:4579-4587
	if entity_visibility_kind == .Public && .File in ctx.scope.flags && ctx.scope.file != nil {
		// Get file flags from AST node directly
		file_flags := ctx.scope.file.flags

		if .Is_Private_File in file_flags {
			// C++ line 4582-4583: File marked @(private="file")
			entity_visibility_kind = .Private_To_File
		} else if .Is_Private_Pkg in file_flags {
			// C++ line 4584-4586: File marked @(private) or @(private="package")
			entity_visibility_kind = .Private_To_Package
		}
	}

	// C++ line 4581-4635: Handle mutable declarations (variables)
	if vd.is_mutable {
		// For non-file-scope variables, we still need to add them to the scope
		// so that later declarations (like `T :: type_of(x)`) can reference them.
		// However, their actual checking happens in check_stmt.
		is_file_scope := .File in ctx.scope.flags
		if !is_file_scope {
			// Add variables to scope without full processing
			// This allows later declarations like `T :: type_of(x)` to find them
			for name, i in vd.names {
				ident, name_ok := name.derived.(^ast.Ident)
				if !name_ok || is_blank_ident(ident.name) {
					continue
				}

				token := tokenizer.Token {
					kind = .Ident,
					text = ident.name,
					pos  = ident.pos,
				}

				// Resolve the variable's type so that type_of() can find it
				var_type: ^Type = nil
				if vd.type != nil {
					// Explicit type annotation
					var_type = check_type(ctx, vd.type)
				} else if len(vd.names) == 1 && i < len(vd.values) && vd.values[i] != nil {
					// Only infer type for single-value declarations
					// Multi-value declarations (like a, b := expand_values(p)) are handled in check_stmt
					o: Operand
					check_multi_expr_or_type(ctx, &o, vd.values[i])
					if o.mode != .Invalid && o.type != nil && o.type.kind != .Tuple {
						inferred_type := default_type(o.type)
						// Don't pre-set type for untyped nil/uninit - let check_init_variable detect the error
						if !is_type_untyped_nil(inferred_type) && !is_type_untyped_uninit(inferred_type) {
							var_type = inferred_type
						}
					}
				}

				e := alloc_entity_variable(ctx.scope, token, var_type, .Resolved, ctx.checker.allocator)
				e.identifier = name
				e.file = ctx.file
				e.parent_proc_decl = ctx.curr_proc_decl

				// Set the type on the variable entity variant
				if var, var_ok := &e.variant.(Entity_Variable); var_ok {
					var.type = var_type
				}

				// Insert into scope so lookups can find it
				scope_insert(ctx.scope, e)
				set_entity_for_node(&ctx.checker.info, name, e)
			}
			return
		}

		// C++ line 4587-4633: Process each name in the declaration
		for name, i in vd.names {
			// Get corresponding value if exists
			value: ^ast.Expr = nil
			if i < len(vd.values) {
				value = vd.values[i]
			}

			// C++ line 4593-4596: Validate name is identifier
			ident, name_ok := name.derived.(^ast.Ident)
			if !name_ok {
				error(name, "A declaration's name must be an identifier")
				continue
			}

			// C++ line 4597-4600: Create variable entity
			token := tokenizer.Token {
				kind = .Ident,
				text = ident.name,
				pos  = ident.pos,
			}
			e := alloc_entity_variable(ctx.scope, token, nil)
			e.identifier = name
			e.file = ctx.file
			// C++ line 4600: e->Variable.is_global = true
			if var_ent, ok4 := &e.variant.(Entity_Variable); ok4 {
				var_ent.is_global = true
			}

			// C++ line 4611-4619: Handle foreign variables
			fl := ctx.foreign_context.curr_library
			if fl != nil {
				// Merge foreign block visibility with entity visibility (use most restrictive)
				// C++ Reference: checker.cpp - foreign block visibility applies to all entities within
				if ctx.foreign_context.visibility_kind != .Public {
					if entity_visibility_kind == .Public || ctx.foreign_context.visibility_kind > entity_visibility_kind {
						entity_visibility_kind = ctx.foreign_context.visibility_kind
					}
				}

				// C++ line 4614: e->Variable.is_foreign = true
				if var_ent, ok5 := &e.variant.(Entity_Variable); ok5 {
					var_ent.is_foreign = true
					var_ent.foreign_library_ident = fl
					var_ent.link_prefix = ctx.foreign_context.link_prefix
					var_ent.link_suffix = ctx.foreign_context.link_suffix
				}
			}

			// C++ line 4602-4604: Apply visibility
			if entity_visibility_kind != .Public {
				e.flags |= {.Not_Exported}
			}

			// C++ line 4606-4609: Error on 'using' at file scope
			if vd.is_using {
				error(name, "'using' is not allowed at the file scope")
			}

			// C++ line 4621-4630: Create declaration info
			d := make_decl_info(ctx.scope, ctx.decl)
			d.decl_node = decl
			d.comment = vd.comment
			d.docs = vd.docs
			d.entity = e
			d.type_expr = vd.type
			d.init_expr = value
			d.attributes = vd.attributes[:]

			// C++ line 4631-4632: Add entity and decl info
			is_exported := entity_visibility_kind != .Private_To_File
			add_entity_and_decl_info(ctx, name, e, d, is_exported)
		}

		// C++ line 4635: Check arity match
		check_arity_match(ctx, vd, true)

	} else {
		// C++ line 4636-4755: Handle immutable declarations (constants, types, procedures)
		for name, i in vd.names {
			// C++ line 4639-4642: Validate name is identifier
			ident, name_ok := name.derived.(^ast.Ident)
			if !name_ok {
				error(name, "A declaration's name must be an identifier")
				continue
			}

			// C++ line 4644-4648: Get init expression
			init_node := unparen_expr(vd.values[i])
			if init_node == nil {
				error(name, "Expected a value for this constant value declaration")
				continue
			}
			init := cast(^ast.Expr)init_node

			token := tokenizer.Token {
				kind = .Ident,
				text = ident.name,
				pos  = ident.pos,
			}
			fl := ctx.foreign_context.curr_library

			// C++ line 4653-4661: Create declaration info
			d := make_decl_info(ctx.scope, ctx.decl)
			d.decl_node = decl
			d.comment = vd.comment
			d.docs = vd.docs
			d.attributes = vd.attributes[:]
			d.type_expr = vd.type
			d.init_expr = init

			// C++ line 4664-4720: Determine entity kind based on init expression
			e: ^Entity

			if is_ast_type(init) {
				// C++ line 4665: Type name
				e = alloc_entity_type_name(d.scope, token, nil)

			} else if proc_lit, is_proc := init.derived.(^ast.Proc_Lit); is_proc {
				// C++ line 4666-4698: Procedure
				if .Type in ctx.scope.flags {
					error(name, "Procedure declarations are not allowed within a struct")
					continue
				}

				// Convert Proc_Tags (bit_set[Proc_Tag; u32]) to u64
				// We need to extract the u32 value first, then extend to u64
				e = alloc_entity_procedure(d.scope, token, nil, u64(transmute(u32)proc_lit.tags))
				d.foreign_require_results = ctx.foreign_context.require_results

				if fl != nil {
					// C++ line 4677: e->Procedure.is_foreign = true
					if proc_ent, ok6 := &e.variant.(Entity_Procedure); ok6 {
						proc_ent.is_foreign = true
						proc_ent.foreign_library_ident = fl
						// C++ Reference: checker.cpp:5016-5034. The foreign block's calling
						// convention is resolved HERE, while foreign_context is still live,
						// and written back into the AST node. By the time check_procedure_type
						// runs the node no longer says .Foreign_Block_Default, so that
						// function's own fallback never fires for these procedures.
						if proc_lit.type != nil {
							extra, is_extra := proc_lit.type.calling_convention.(ast.Proc_Calling_Convention_Extra)
							if is_extra && extra == .Foreign_Block_Default {
								cc := Calling_Convention.C // C++ line 5019
								if ctx.foreign_context.default_cc_set {
									cc = ctx.foreign_context.default_cc
								} else if is_arch_wasm() {
									// C++ line 5022-5028
									error_node(init, "For wasm related targets, it is required that you either define the @(default_calling_convention=<string>) on the foreign block or explicitly assign it on the procedure signature")
									error_line("\tSuggestion: when dealing with normal Odin code (e.g. js_wasm32), use \"contextless\"; when dealing with Emscripten like code, use \"c\"\n")
								}
								// C++ line 5034: write the resolved convention back.
								proc_lit.type.calling_convention = calling_convention_to_string(cc)
							}
						}

						proc_ent.link_prefix = ctx.foreign_context.link_prefix
						proc_ent.link_suffix = ctx.foreign_context.link_suffix
					}
				}

				d.proc_lit = proc_lit
				d.init_expr = init

				// C++ line 4702-4711: Apply procedure attributes
				if is_test {
					e.flags |= {.Test}
				}
				if is_init && is_fini {
					error(name, "A procedure cannot be both declared as @(init) and @(fini)")
				} else if is_init {
					e.flags |= {.Init}
				} else if is_fini {
					e.flags |= {.Fini}
				}

			} else if _, is_pg := init.derived.(^ast.Proc_Group); is_pg {
				// C++ line 4712-4717: Procedure group
				e = alloc_entity_proc_group(d.scope, token, nil)
				if fl != nil {
					error(name, "Procedure groups are not allowed within a foreign block")
				}

			} else {
				// C++ line 4718-4719: Constant
				e = alloc_entity_constant(d.scope, token, nil, Exact_Value{})
			}

			e.identifier = name

			// Merge foreign block visibility with entity visibility (use most restrictive)
			// C++ Reference: checker.cpp - foreign block visibility applies to all entities within
			if fl != nil && ctx.foreign_context.visibility_kind != .Public {
				if entity_visibility_kind == .Public || ctx.foreign_context.visibility_kind > entity_visibility_kind {
					entity_visibility_kind = ctx.foreign_context.visibility_kind
				}
			}

			// C++ line 4723-4726: Apply visibility and file flags
			if entity_visibility_kind != .Public {
				e.flags |= {.Not_Exported}
			}
			add_entity_flags_from_file(ctx, e, ctx.scope)

			// C++ line 4728-4734: Handle 'using' for enum types
			if vd.is_using {
				if e.kind == .Type_Name {
					if _, is_enum := init.derived.(^ast.Enum_Type); is_enum {
						d.is_using = true
					} else {
						error(name, "'using' is not allowed on this constant value declaration")
					}
				} else {
					error(name, "'using' is not allowed on this constant value declaration")
				}
			}

			// C++ line 4736-4746: Validate foreign block constraints
			if e.kind != .Procedure {
				if fl != nil {
					// Check for common mistake: proc type instead of proc lit
					if _, is_proc_type := init.derived.(^ast.Proc_Type); is_proc_type {
						error(name, "Only procedures and variables are allowed to be in a foreign block, got procedure type")
						error_line("\tDid you forget to append '---' to the procedure?")
					} else {
						error(name, "Only procedures and variables are allowed to be in a foreign block")
					}
				}
			}

			// C++ line 4748: Check builtin attributes
			check_builtin_attributes(ctx, e, d.attributes)

			// C++ line 4750-4751: Add entity and decl info
			is_exported := entity_visibility_kind != .Private_To_File
			add_entity_and_decl_info(ctx, name, e, d, is_exported)
		}

		// C++ line 4754: Check arity match
		check_arity_match(ctx, vd, true)
	}
}


// check_add_foreign_import_decl handles foreign import declarations
// C++ Reference: checker.cpp:5490-5545
check_add_foreign_import_decl :: proc(ctx: ^Checker_Context, decl: ^ast.Stmt) {
	// C++ line 5491-5492: Check if already handled
	if has_been_handled(ctx, decl) {
		return
	}
	mark_been_handled(ctx, decl)

	// Cast to Foreign_Import_Decl
	fl, ok := decl.derived.(^ast.Foreign_Import_Decl)
	if !ok {
		return
	}

	// C++ line 5496-5497: Verify file scope
	parent_scope := ctx.scope
	assert(.File in parent_scope.flags, "check_add_foreign_import_decl must be in file scope")

	// C++ line 5499-5507: Determine library name
	library_name := fl.name != nil ? fl.name.name : ""
	if library_name == "" && len(fl.fullpaths) != 0 {
		// Use first source path as basis for library name
		// C++ Reference: checker.cpp:5502 - path_to_entity_name(fl->library_name.string, fullpath)
		// Extract library name from first fullpath
		if basic_lit, fullpath_ok := fl.fullpaths[0].derived_expr.(^ast.Basic_Lit); fullpath_ok {
			library_name = path_to_entity_name(library_name, basic_lit.tok.text)
		}
	}
	if library_name == "" || is_blank_ident(library_name) {
		error(decl, "File name cannot be used as a library name as it is not a valid identifier")
		return
	}

	// C++ line 5509-5510: Assign library name back to AST
	// NOTE: In C++, AST is mutable so this updates fl->library_name.string
	// In our immutable AST, we can't do this, but it's OK since we use library_name directly

	// C++ line 5513-5514: Check attributes
	ac := Attribute_Context{}
	check_foreign_import_attributes(ctx, fl.attributes[:], &ac)

	// C++ line 5516-5519: Determine scope (export to parent or keep in file)
	scope := parent_scope
	if ac.is_export {
		scope = parent_scope.parent
	}

	// C++ line 5521-5525: Create library name entity
	// Convert fullpath expressions to string slice
	fullpaths := make([dynamic]string, 0, len(fl.fullpaths), context.temp_allocator)
	for fullpath_expr in fl.fullpaths {
		if basic_lit, path_ok := fullpath_expr.derived_expr.(^ast.Basic_Lit); path_ok {
			append(&fullpaths, basic_lit.tok.text)
		}
	}

	token := tokenizer.Token {
		kind = .Ident,
		text = library_name,
		pos  = fl.pos,
	}
	e := alloc_entity_library_name(parent_scope, token, t_invalid, fullpaths[:], library_name)

	// C++ line 5526: e->LibraryName.decl = decl;
	if lib_name, lib_ok := &e.variant.(Entity_Library_Name); lib_ok {
		lib_name.decl = decl
	}

	// C++ line 5527: add_entity_flags_from_file(ctx, e, parent_scope);
	add_entity_flags_from_file(ctx, e, parent_scope)

	// C++ line 5528: add_entity(ctx, scope, nullptr, e);
	add_entity(ctx, scope, nil, e)

	// C++ line 5531-5533: Handle require_declaration attribute
	if ac.require_declaration {
		// C++ line 5532: queue.mpsc_enqueue(&ctx->info->required_foreign_imports_through_force_queue, e);
		queue.mpsc_enqueue(&ctx.info.required_foreign_imports_through_force_queue, e)
		// C++ line 5533: add_entity_use(ctx, nullptr, e);
		add_entity_use(ctx, nil, e)
	}

	// C++ line 5534-5536: Handle priority index
	if ac.foreign_import_priority != 0 {
		if lib_name, lib_ok := &e.variant.(Entity_Library_Name); lib_ok {
			lib_name.priority_index = ac.foreign_import_priority
		}
	}

	// C++ line 5537-5539: Handle ignore_duplicates
	if ac.ignore_duplicates {
		if lib_name, lib_ok := &e.variant.(Entity_Library_Name); lib_ok {
			lib_name.ignore_duplicates = true
		}
	}

	// C++ line 5540-5542: Handle extra_linker_flags
	extra_linker_flags := strings.trim_space(ac.extra_linker_flags)
	if len(extra_linker_flags) != 0 {
		if lib_name, lib_ok := &e.variant.(Entity_Library_Name); lib_ok {
			lib_name.extra_linker_flags = extra_linker_flags
		}
	}

	// C++ line 5544: Enqueue for fullpath checking
	queue.mpsc_enqueue(&ctx.info.foreign_imports_to_check_fullpaths, e)
}

// make_checker_context creates a new checker context for a file
// C++ Reference: Context initialization in checker.cpp
// Used by check_collect_entities_all to create per-file contexts
// The returned context owns a freshly allocated type path; pair every call with
// `defer destroy_checker_context(&ctx)`.
// C++ Reference: checker.cpp:1685-1693 (init_checker_context)
make_checker_context :: proc(c: ^Checker) -> Checker_Context {
	ctx := Checker_Context{}
	ctx.checker = c
	ctx.info = &c.info
	// C++ line 1691: ctx->type_path = new_checker_type_path()
	ctx.type_path = new_checker_type_path(c.allocator)
	ctx.type_level = 0
	return ctx
}

// ======================================================================================
// DELAYED DECLARATION PROCESSING
// C++ Reference: checker.cpp:5885-5957
// ======================================================================================

// process_delayed_import_decls processes queued import declarations for a file
// C++ Reference: checker.cpp:5892-5895, 5921-5924
//
// Import declarations may be delayed during initial collection if they depend on
// entities not yet available. This function processes them in a second pass.
process_delayed_import_decls :: proc(ctx: ^Checker_Context, file: ^ast.File) {
	if file == nil {
		return
	}

	// C++ line 5892-5895: Process delayed import declarations from file
	for stmt in file.delayed_decls_import {
		// Type assert ^ast.Stmt to ^ast.Import_Decl
		// C++ Reference: checker.cpp:5893
		if import_decl, ok := stmt.derived.(^ast.Import_Decl); ok {
			check_add_import_decl(ctx, import_decl)
		}
	}
	// Clear the queue after processing (C++ line 5895)
	clear(&file.delayed_decls_import)
}

// process_delayed_foreign_block_decls processes queued foreign block declarations for a file
// C++ Reference: checker.cpp:5939-5942
//
// Foreign blocks may be delayed during initial collection. This function processes them
// after imports have been resolved.
// check_add_foreign_block_decl COLLECTS the declarations inside a foreign block.
// C++ Reference: checker.cpp:5097-5117 (check_add_foreign_block_decl)
//
// This is distinct from check_foreign_block_decl (check_stmt.odin), which CHECKS a foreign block in
// statement position via check_stmt_list. The two were conflated: the collection sites called the
// statement checker, so a foreign block's procedures were type-checked but never added to any scope.
// Every `foreign { ... }` declaration was therefore undeclared at its use sites - 103 of them in
// core/c/libc/math.odin alone, plus the proc-group errors cascading from those.
//
// Returns true when collect_file_decls signalled that new declarations became visible, so callers can
// propagate the restart the same way they do for a file-scope `when`.
check_add_foreign_block_decl :: proc(ctx: ^Checker_Context, decl: ^ast.Stmt) -> bool {
	fb, ok := decl.derived.(^ast.Foreign_Block_Decl)
	if !ok {
		return false
	}

	// C++ Reference: checker.cpp:5100-5107
	c := ctx^
	foreign_library := fb.foreign_library
	if foreign_library != nil {
		if _, is_ident := foreign_library.derived.(^ast.Ident); is_ident {
			c.foreign_context.curr_library = foreign_library
		} else {
			error_node(foreign_library, "Foreign block name must be an identifier or 'export'")
			c.foreign_context.curr_library = nil
		}
	}

	// C++ Reference: checker.cpp:5109
	check_foreign_block_attributes(&c, fb.attributes)

	// C++ Reference: checker.cpp:5111-5116
	block, block_ok := fb.body.derived.(^ast.Block_Stmt)
	if !block_ok {
		return false
	}
	if c.collect_delayed_decls && c.scope != nil && .File in c.scope.flags {
		return collect_file_decls(&c, block.stmts)
	}
	check_collect_entities(&c, block.stmts)
	return false
}

process_delayed_foreign_block_decls :: proc(ctx: ^Checker_Context, file: ^ast.File) {
	if file == nil {
		return
	}

	// C++ line 5939-5942: Process delayed foreign block declarations from file
	for stmt in file.delayed_decls_foreign_block {
		// Process foreign block declaration
		// C++ Reference: checker.cpp:5940
		// Note: C++ calls check_add_foreign_block_decl, but we have check_foreign_block_decl
		// which is the actual implementation (check_stmt.odin:1728)
		check_add_foreign_block_decl(ctx, stmt)
	}
	// Clear the queue after processing (C++ line 5942)
	clear(&file.delayed_decls_foreign_block)
}

// process_delayed_expr_decls processes queued directive expressions for a file
// C++ Reference: checker.cpp:5949-5953
//
// Directive expressions (like #assert, #config) may be delayed during collection.
// This function evaluates them after all declarations are available.
process_delayed_expr_decls :: proc(ctx: ^Checker_Context, file: ^ast.File) {
	if file == nil {
		return
	}

	// C++ line 5949-5953: Process delayed directive expressions from file
	for expr in file.delayed_decls_expr {
		// Evaluate the directive expression
		// C++ Reference: checker.cpp:5950-5951
		operand := Operand{}
		check_expr(ctx, &operand, expr)
	}
	// Clear the queue after processing (C++ line 5953)
	clear(&file.delayed_decls_expr)
}

// process_all_delayed_decls processes all delayed declarations for a file in correct order
// C++ Reference: checker.cpp:5885-5957
//
// This function processes delayed declarations in three phases:
// 1. Import declarations (C++ line 5892-5895, 5921-5924)
// 2. Foreign block declarations (C++ line 5939-5942)
// 3. Directive expressions (C++ line 5949-5953)
//
// The order is important because later phases may depend on earlier ones.
process_all_delayed_decls :: proc(ctx: ^Checker_Context, file: ^ast.File) {
	// Phase 1: Process import declarations (C++ line 5892-5895)
	process_delayed_import_decls(ctx, file)

	// Phase 2: Process foreign block declarations (C++ line 5939-5942)
	process_delayed_foreign_block_decls(ctx, file)

	// Phase 3: Process directive expressions (C++ line 5949-5953)
	process_delayed_expr_decls(ctx, file)
}
