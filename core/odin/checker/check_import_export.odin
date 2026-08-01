package checker

/*
Import/Export Processing for the Odin checker.

This module handles import declarations, package dependency graph construction,
and entity visibility management for cross-package type checking.

C++ Reference: /mnt/c/odin/src/checker.cpp:5130-5926

*/

import "base:runtime"
import "core:odin/ast"
import "core:odin/tokenizer"
import "core:unicode"

// Import_Graph_Node is defined in check_decl.odin
// Import_Graph is the complete import dependency graph
Import_Graph :: struct {
	nodes:     map[rawptr]^Import_Graph_Node,
	checker:   ^Checker, // Need reference to checker for package lookup
	allocator: runtime.Allocator,
}

// Import_Path_Item tracks an import path for cycle detection
// C++ Reference: struct ImportPathItem in /mnt/c/odin/src/checker.cpp:5170-5173
Import_Path_Item :: struct {
	pkg:  ^ast.Package, // C++ line 5171
	decl: ^ast.Stmt, // C++ line 5172: Import declaration
}

// check_import_decl_attributes processes attributes on import declarations
// C++ Reference: checker.cpp:5237-5252 (import_decl_attribute)
//
// Import declarations support the following attributes:
// - @(require): Forces the import to be used even if not referenced
// - @(user_tag="..."): User-defined tag for metadata
check_import_decl_attributes :: proc(ctx: ^Checker_Context, attributes: []^ast.Attribute, ac: ^Attribute_Context) {
	if len(attributes) == 0 {
		return
	}

	// Process each attribute (C++ line 5253-5300)
	for attr in attributes {
		// attr is already ^ast.Attribute, no need to type-switch
		for elem in attr.elems {
			name := ""
			value: ^ast.Expr = nil

			// Extract attribute name and value (C++ line 5258-5281)
			#partial switch e in elem.derived {
			case ^ast.Ident:
				name = e.name
			case ^ast.Field_Value:
				// Attribute with value like @(user_tag="metadata")
				if field_ident, ok := e.field.derived.(^ast.Ident); ok {
					name = field_ident.name
					value = e.value
				}
			case:
				error(elem, "Invalid attribute element")
				continue
			}

			// Process import-specific attributes
			// C++ Reference: checker.cpp:5237-5252
			if name == "require" {
				// @(require) attribute - forces import to be used
				// C++ line 5244-5249
				if value != nil {
					error(elem, "Expected no parameter for '%s'", name)
				}
				ac.require_declaration = true
			} else if name == "user_tag" {
				// @(user_tag="...") attribute - user-defined metadata
				// C++ line 5238-5243
				// NOTE: We validate but don't store the value (user tags are metadata only)
				if value == nil {
					error(elem, "Expected a string value for '%s'", name)
					continue
				}
				// NOTE: Accepts any expression - full constant validation would need check_expr
			}
			// Other attributes are silently ignored for imports
			// (C++ returns false which triggers unknown attribute warning in check_decl_attributes)
		}
	}
}

// check_add_import_decl processes an import declaration and adds imported package to scope
// C++ Reference: checker.cpp:5254-5336
//
// This function:
// - Resolves the import path to a package
// - Creates an import entity
// - Adds the entity to the current scope
// - Marks the import relationship for dependency tracking
//
// NOTE: Unlike the C++ version, we don't need to handle import name generation
// as robustly since Odin has simpler import semantics (verified in impl).
check_add_import_decl :: proc(ctx: ^Checker_Context, import_decl: ^ast.Import_Decl) {
	if import_decl == nil {
		return
	}

	// Check if already handled (C++ line 5255-5256)
	decl_node := cast(^ast.Node)import_decl
	if has_ast_flag(ctx, decl_node, .Been_Handled) {
		return
	}
	set_ast_flag(ctx, decl_node, .Been_Handled)

	// Get parent scope - must be a file scope (C++ line 5261-5262)
	parent_scope := ctx.scope
	if parent_scope == nil || !is_scope_file(parent_scope) {
		error_node(import_decl, "Import declarations must be at file scope")
		return
	}

	// Extract import path from the import declaration
	// C++ line 5258-5259: ast_node(id, ImportDecl, decl)
	import_path := ""
	if import_decl.fullpath != "" {
		import_path = import_decl.fullpath
		// Strip quotes if present (parser may include them)
		if len(import_path) >= 2 && import_path[0] == '"' && import_path[len(import_path) - 1] == '"' {
			import_path = import_path[1:len(import_path) - 1]
		}
	} else {
		error_node(import_decl, "Import path is required")
		return
	}

	// Resolve package from import path (C++ line 5264-5290)
	scope: ^Scope = nil
	force_use := false

	// Handle builtin packages (C++ line 5270-5276)
	// These are special compiler-provided packages that can't be parsed normally
	if import_path == "builtin" || import_path == "base:builtin" {
		if ctx.checker.info.builtin_package != nil {
			scope = get_package_scope(ctx.info, ctx.checker.info.builtin_package)
		}
		force_use = true
	} else if import_path == "intrinsics" || import_path == "base:intrinsics" {
		// Intrinsics package - use the builtin intrinsics package scope
		// This allows code to use `intrinsics.trap()` style syntax
		// The actual builtin resolution happens during expression checking
		if ctx.checker.info.intrinsics_package != nil {
			scope = get_package_scope(ctx.info, ctx.checker.info.intrinsics_package)
		}
		if scope == nil {
			// Intrinsics package not available - allow import without error
			return
		}
	} else if import_path == "runtime" || import_path == "base:runtime" {
		// Runtime package - use extracted runtime types
		if ctx.checker.info.runtime_package != nil {
			scope = get_package_scope(ctx.info, ctx.checker.info.runtime_package)
		}
		if scope == nil {
			// Runtime not available - allow import without error
			return
		}
	} else {
		// Look up package in package map (C++ line 5277-5288)
		if pkg, ok := ctx.info.packages[import_path]; ok {
			scope = get_package_scope(ctx.info, pkg)
		} else {
			error_node(import_decl, "Unable to find package: %s", import_path)
			return
		}
	}

	// Verify we found a valid package scope (C++ line 5290)
	if scope == nil || !is_scope_pkg(scope) {
		error_node(import_decl, "Invalid package scope for: %s", import_path)
		return
	}

	// Mark this scope as imported (C++ line 5293)
	scope_import(parent_scope, scope)

	// Get import name (C++ line 5298-5301)
	// In Odin, import names are derived from the package name or can be aliased
	// C++ Reference: checker.cpp:5298 - path_to_entity_name(id->import_name.string, id->fullpath, false)
	import_name := path_to_entity_name(import_decl.name.text, import_path, false)

	// Check if this is a blank import (underscore) (C++ line 5299-5301)
	if is_blank_ident(import_name) {
		force_use = true
	}

	// Check attributes for @(require) and other import attributes
	// C++ Reference: checker.cpp:5303-5307
	ac := Attribute_Context{}
	check_import_decl_attributes(ctx, import_decl.attributes[:], &ac)
	if ac.require_declaration {
		force_use = true
	}

	// Validate import name is a valid identifier (C++ line 5310-5322)
	// Check if we attempted to derive a name but it's invalid
	if is_blank_ident(import_name) && !is_blank_ident(import_decl.name.text) {
		// The user provided a name, but it's not valid
		// C++ line 5310-5321
		invalid_name := import_path
		invalid_name = get_invalid_import_name(invalid_name)

		if len(import_decl.name.text) > 0 {
			error_node(import_decl, "Import name '%s' cannot be used as an import name as it is not a valid identifier", import_decl.name.text)
		} else {
			error_node(import_decl, "Import name '%s' is not a valid identifier", invalid_name)
			// C++ line 5320: Add suggestion for how to fix the error
			error_line("\tSuggestion: Rename the directory or explicitly set an import name like this 'import <new_name> \"%s\"'", import_path)
		}
		return
	}

	// Only create entity if we have a non-blank identifier (C++ line 5322-5333)
	if !is_blank_ident(import_name) {
		if !is_string_an_identifier(import_name) {
			error_node(import_decl, "Import name '%s' is not a valid identifier", import_name)
			return
		}

		// Create import entity (C++ line 5325-5327)
		import_token := import_decl.name
		if import_token.text == "" {
			// Use a synthetic token for unnamed imports
			import_token = tokenizer.Token {
				text = import_name,
				kind = .Ident,
				pos  = import_decl.pos,
			}
		}

		import_entity := alloc_entity_import_name(parent_scope, import_token, t_invalid, import_path, import_name, scope, ctx.checker.allocator)

		// Add entity to scope (C++ line 5329)
		add_entity(ctx, parent_scope, nil, import_entity)

		// Mark as used if forced (C++ line 5330-5332)
		if force_use {
			add_entity_use(ctx, nil, import_entity)
		}
	}

	// Mark the imported scope as having been imported (C++ line 5335)
	if scope != nil {
		scope.flags += {.Has_Been_Imported}
	}
}

// check_import_entities processes import declarations across all packages
// C++ Reference: checker.cpp:5817-5926
//
// This function:
// - Generates import dependency graph
// - Performs topological sort to determine package order
// - Detects circular imports
// - Processes import declarations in dependency order
//
// Note: Entity collection (check_collect_entities_all) uses thread pool for parallel processing.
// Export handling (check_export_entities) drains deferred queues after collection completes.
check_import_entities :: proc(c: ^Checker) {
	if c == nil {
		return
	}

	// Generate dependency graph (C++ line 5820)
	dep_graph := generate_import_dependency_graph(c, c.allocator)
	defer destroy_import_graph(&dep_graph)

	// Topologically sort packages (C++ line 5822-5871)
	package_order := topological_sort_packages(&dep_graph, c.allocator)
	defer delete(package_order)

	// Process packages in dependency order (C++ line 5873-5909)
	ctx := make_checker_context(c)
	defer destroy_checker_context(&ctx)

	// C++ Reference: checker.cpp:6214-6243. This is a FIXPOINT loop, not a simple walk.
	//
	// collect_file_decls returns true to mean "new declarations became visible". C++ responds by
	// re-exporting that package and RESTARTING the package walk from min_pkg_index, so declarations
	// revealed by one pass are in scope for the next. An earlier attempt called collect_file_decls
	// but discarded its result, so only the FIRST `when` block in each file was ever collected.
	min_pkg_index := 0
	for pkg_index := 0; pkg_index < len(package_order); pkg_index += 1 {
		node := package_order[pkg_index]
		pkg := node.pkg
		if pkg == nil {
			continue
		}

		// Set package order (C++ line 5883)
		// C++: pkg->order = 1+pkg_index
		pkg.order = 1 + pkg_index

		restart := false

		// Process each file in the package (C++ line 5885-5904)
		for file in sorted_files(pkg.files) {
			// Reset context for this file
			reset_checker_context(&ctx, file)
			ctx.collect_delayed_decls = true // C++ line 6224

			// Process import declarations
			// NOTE: In C++, imports are stored in f->delayed_decls_queues[AstDelayQueue_Import]
			// In our version, we'd process them from the file's import list directly
			for decl in file.decls {
				import_decl, ok := decl.derived.(^ast.Import_Decl)
				if ok {
					check_add_import_decl(&ctx, import_decl)
				}
			}

			// C++ Reference: checker.cpp:6232-6236. The second collection phase, and the only path
			// that descends into a file-scope `when` block (collect_file_decl ->
			// collect_when_stmt_from_file). Run after this file's imports so the condition can refer
			// to imported names.
			if collect_file_decls(&ctx, file.decls[:]) {
				check_export_entities_in_pkg(c, pkg)
				pkg_index = min_pkg_index - 1
				restart = true
				break
			}
		}

		if restart {
			continue
		}

		// C++ line 6243
		min_pkg_index = pkg_index
	}
}

// generate_import_dependency_graph builds the import dependency graph
// C++ Reference: checker.cpp:5132-5168
//
// generate_import_dependency_graph and add_import_dependency_node are defined in check_decl.odin

// topological_sort_packages performs topological sort on the import graph
// Returns packages in dependency order (dependencies before dependents)
// Also detects and reports circular imports
// C++ Reference: checker.cpp:5822-5871 (priority queue implementation)
topological_sort_packages :: proc(graph: ^Import_Graph, allocator: runtime.Allocator) -> [dynamic]^Import_Graph_Node {
	// Create array of all nodes
	nodes := make([dynamic]^Import_Graph_Node, 0, len(graph.nodes), allocator)
	for _, node in graph.nodes {
		append(&nodes, node)
	}

	// Result array
	result := make([dynamic]^Import_Graph_Node, 0, len(nodes), allocator)

	// Emitted set to track processed packages
	emitted := make(map[rawptr]struct{}, allocator)
	defer delete(emitted)

	// Process nodes in order of dependency count (C++ line 5832-5871)
	// Kahn's algorithm for topological sort with priority handling
	for len(nodes) > 0 {
		// Find node with minimum dependency count (C++ uses priority queue)
		// C++ Reference: checker.cpp:139-153 (import_graph_node_cmp)
		// Priority: 1) dep_count ascending, 2) Global scopes first, 3) package ID for determinism
		min_idx := 0
		min_count := nodes[0].dep_count
		for i := 1; i < len(nodes); i += 1 {
			current_count := nodes[i].dep_count

			// Primary: Compare by dependency count
			if current_count < min_count {
				min_count = current_count
				min_idx = i
			} else if current_count == min_count {
				// Secondary: When dep_counts are equal, prioritize by Global flag
				// C++ lines 146-149:
				//   bool xg = (x->scope->flags&ScopeFlag_Global) != 0;
				//   bool yg = (y->scope->flags&ScopeFlag_Global) != 0;
				//   if (xg != yg) return xg ? -1 : +1;
				current_global := .Global in nodes[i].scope.flags
				min_global := .Global in nodes[min_idx].scope.flags

				if current_global && !min_global {
					// Current is global, min is not - choose current
					min_idx = i
				} else if current_global == min_global {
					// Tertiary: Both same Global status, use package ID for determinism
					// C++ line 149: if (xg && yg) return x->pkg->id < y->pkg->id ? +1 : -1;
					// Lower ID gets higher priority (processed earlier)
					if nodes[i].pkg != nil && nodes[min_idx].pkg != nil {
						if current_global && min_global {
							// Both global - reverse order by ID (higher ID first)
							if nodes[i].pkg.id > nodes[min_idx].pkg.id {
								min_idx = i
							}
						} else {
							// Both non-global or normal priority - first found wins (matches C++ behavior)
						}
					}
				}
			}
		}

		// Remove node from queue
		node := nodes[min_idx]
		ordered_remove(&nodes, min_idx)

		pkg := node.pkg
		if pkg == nil {
			continue
		}

		// Check for cycles (C++ line 5837-5856)
		if node.dep_count > 0 {
			// There's a cycle - find and report it
			path := find_import_cycle(graph, node, allocator)
			if len(path) > 1 {
				// Report cycle error
				first_item := path[len(path) - 1]
				error_node(first_item.decl, "Cyclic importation of '%s'", first_item.pkg.name)
				for i := 0; i < len(path); i += 1 {
					item := path[i]
					error_node(item.decl, "'%s' refers to", first_item.pkg.name)
					first_item = item
				}
				error_node(first_item.decl, "'%s'", first_item.pkg.name)
			}
		}

		// Decrement dependency counts of predecessors (C++ line 5858-5861)
		for pred in node.pred {
			pred.dep_count = max(pred.dep_count - 1, 0)
		}

		// Skip if already emitted
		if _, already_emitted := emitted[rawptr(pkg)]; already_emitted {
			continue
		}
		emitted[rawptr(pkg)] = {}

		append(&result, node)
	}

	return result
}

// find_import_cycle finds a cycle in the import graph starting from a node
// C++ Reference: checker.cpp:5175-5222 (find_import_path)
//
// Returns the path forming the cycle, or empty array if no cycle
find_import_cycle :: proc(graph: ^Import_Graph, start: ^Import_Graph_Node, allocator: runtime.Allocator) -> [dynamic]Import_Path_Item {
	visited := make(map[rawptr]struct{}, allocator)
	defer delete(visited)

	return find_import_path_recursive(graph, start, start, &visited, allocator)
}

// find_import_path_recursive recursively searches for an import path
// C++ Reference: checker.cpp:5175-5222
find_import_path_recursive :: proc(graph: ^Import_Graph, current: ^Import_Graph_Node, target: ^Import_Graph_Node, visited: ^map[rawptr]struct{}, allocator: runtime.Allocator) -> [dynamic]Import_Path_Item {
	empty_path := make([dynamic]Import_Path_Item, 0, 0, allocator)

	// Mark as visited (C++ line 5178-5180)
	if _, ok := visited[rawptr(current)]; ok {
		return empty_path
	}
	visited[rawptr(current)] = {}

	pkg := current.pkg
	if pkg == nil {
		return empty_path
	}

	// Search through imports (C++ line 5188-5219)
	for file in sorted_files(pkg.files) {
		// NOTE: In C++, this uses f->imports array
		// In our version, we scan decls for import statements
		for decl in file.decls {
			import_decl, ok := decl.derived.(^ast.Import_Decl)
			if ok {
				import_path := import_decl.fullpath

				// Find imported package node
				imported_pkg, pkg_ok := graph.checker.info.packages[import_path]
				if !pkg_ok {
					continue
				}

				imported_node, node_ok := graph.nodes[rawptr(imported_pkg)]
				if !node_ok || imported_node.scope == nil {
					continue
				}

				// Build path item (C++ line 5207)
				item := Import_Path_Item {
					pkg  = imported_pkg,
					decl = decl,
				}

				// Check if we found the target (cycle detected) (C++ line 5208-5211)
				if imported_node == target {
					path := make([dynamic]Import_Path_Item, 0, 1, allocator)
					append(&path, item)
					return path
				}

				// Recurse (C++ line 5213-5217)
				next_path := find_import_path_recursive(graph, imported_node, target, visited, allocator)
				if len(next_path) > 0 {
					append(&next_path, item)
					return next_path
				}
			}
		}
	}

	return empty_path
}

// destroy_import_graph frees import graph resources
destroy_import_graph :: proc(graph: ^Import_Graph) {
	for _, node in graph.nodes {
		delete(node.pred)
		delete(node.succ)
		free(node, graph.allocator)
	}
	delete(graph.nodes)
}

// check_export_entities processes deferred export queue for multi-threaded entity collection
// C++ Reference: checker.cpp:5777-5815 - check_export_entities_in_pkg
//
// During entity collection phase, exported entities are queued using enqueue_exported_entity()
// instead of being added directly to package scope. This allows parallel entity collection
// without scope contention - multiple threads can collect entities simultaneously.
//
// This function is called after entity collection completes to drain all queues and
// add the entities to their respective package scopes for cross-file visibility.
check_export_entities :: proc(c: ^Checker) {
	// C++ Reference: checker.cpp:5777-5815 - check_export_entities_in_pkg
	// Drains the exported_entity_queue for each package and adds entities to package scope
	//
	// This function is called after entity collection phase completes.
	// During collection, exported entities are queued instead of being added directly
	// to package scope. This allows parallel entity collection without scope contention.

	// Process each package's exported entity queue
	// C++ Reference: checker.cpp:5778-5814
	for pkg in sorted_packages(&c.info) {
		check_export_entities_in_pkg(c, pkg)
	}

	// C++ Reference: checker.cpp:6266 — correct_type_aliases_in_scope over pkg->scope.
	//
	// This pass already ran during collection (check_collect.odin:281/287), but that runs
	// against the FILE scope, and this port queues package-level entities for export instead
	// of inserting them directly. So a package-level `N :: E` is not in any scope the earlier
	// pass can see; it only lands in pkg.scope here. Without this second sweep every
	// package-level alias of a named type stays a Constant and never reaches
	// check_type_decl's alias handling — `x: N = .A` and `bit_set[N]{.A}` then fail while the
	// `E` equivalents work.
	//
	// Must run AFTER the drain loop above, not interleaved: an alias can name a type exported
	// by a package drained later.
	for pkg in sorted_packages(&c.info) {
		if pkg == nil || pkg.scope == nil {
			continue
		}
		ctx := make_checker_context(c)
		defer destroy_checker_context(&ctx)
		ctx.scope = pkg.scope
		ctx.pkg = pkg
		correct_type_aliases_in_scope(&ctx, pkg.scope)
	}
}

// check_export_entities_in_pkg drains one package's exported entity queue into its scope.
// C++ Reference: checker.cpp:5777-5815 (check_export_entities_in_pkg)
//
// Split out of check_export_entities because the collection fixpoint in check_import_entities has to
// re-export a single package mid-loop, exactly as C++ does at checker.cpp:6233. Draining an already
// empty queue is a no-op, so calling this repeatedly is safe.
check_export_entities_in_pkg :: proc(c: ^Checker, pkg: ^ast.Package) {
	if pkg == nil || pkg.scope == nil {
		return
	}

	// C++ line 5785-5813: while (mpmc_dequeue(&pkg->exported_entity_queue, &ee))
	for {
		exported, ok := dequeue_exported_entity(&c.info, pkg)
		if !ok {
			break
		}

		// C++ Reference: checker.cpp:6119 — `add_entity(ctx, pkg->scope, ee.identifier, ee.entity)`.
		//
		// This must go through add_entity, not scope_insert. add_entity skips BLANK
		// identifiers (entity_helpers.odin:443, mirroring checker.cpp:2089), reports
		// redeclarations, and records the entity definition. Calling scope_insert
		// directly published `_` into the package scope for any file-scope
		// `_ :: something` — of which base/runtime has two (`_ :: intrinsics` in
		// core_builtin_soa.odin and dynamic_map_internal.odin).
		//
		// The visible symptom was elsewhere entirely: an anonymous `foreign { }` block
		// synthesises `_` as its library name, and check_foreign_library_name
		// (check_decl_helpers.odin, mirroring check_decl.cpp:998) treats "found in scope
		// but not a Library_Name" as an error. C++ never finds anything, because blanks
		// are never inserted, and so takes its "link against nothing" path.
		// NOTE: only the BLANK guard is taken from add_entity here, not its
		// redeclaration reporting. Routing this call through add_entity wholesale is
		// what C++ does, but the port reaches this drain along a different path and
		// doing so produced a false "Redeclaration of 'compress'" for a package with a
		// single `import "core:compress"`. Reconciling the enqueue paths is task 109.
		if exported.entity != nil && !is_blank_ident(exported.entity.token.text) {
			scope_insert(pkg.scope, exported.entity)
		}
	}
}

// Helper functions

// is_package_name_reserved checks if a package name is a reserved system package
is_package_name_reserved :: proc(name: string) -> bool {
	return name == "builtin" || name == "intrinsics"
}

// get_invalid_import_name extracts the last path component for error messages
// C++ Reference: checker.cpp:5225-5235
get_invalid_import_name :: proc(input: string) -> string {
	s := input

	// Strip quotes if present
	if len(s) >= 2 && s[0] == '"' && s[len(s) - 1] == '"' {
		s = s[1:len(s) - 1]
	}

	// Find the last separator (/ \ :) to get the final path component
	// C++ line 5226-5232
	start := 0
	for i := len(s) - 1; i >= 0; i -= 1 {
		if s[i] == '/' || s[i] == '\\' || s[i] == ':' {
			start = i + 1
			break
		}
	}
	// Extract substring from last separator to end
	// C++ line 5233
	return s[start:]
}

// path_to_entity_name extracts an entity name from an import path
// C++ Reference: checker.cpp:5022-5060 (path_to_entity_name)
//
// path_to_entity_name is defined in check_decl.odin

// is_string_an_identifier is defined in entity_helpers.odin

// is_letter checks if a rune is a letter (including underscore)
// C++ Reference: unicode.cpp:15-31 (rune_is_letter)
//
// CRITICAL: Underscore '_' is treated as a letter in Odin identifiers!
// This matches the C++ implementation which explicitly checks (r == '_')
is_letter :: proc(r: rune) -> bool {
	// C++ line 16-21: Fast path for ASCII (r < 0x80)
	if r < 0x80 {
		// C++ line 17-19: CRITICAL - underscore is treated as a letter
		if r == '_' {
			return true
		}
		// C++ line 20: Clever bit trick for a-z/A-Z
		// (r | 0x20) converts uppercase to lowercase via OR 0x20
		// Then checks if result is in range [a-z] (0x61-0x7a)
		return (u32(r) | 0x20) - 0x61 < 26
	}

	// C++ line 22-30: Unicode path - check letter categories
	// UTF8PROC_CATEGORY_LU = Uppercase Letter
	// UTF8PROC_CATEGORY_LL = Lowercase Letter
	// UTF8PROC_CATEGORY_LT = Titlecase Letter
	// UTF8PROC_CATEGORY_LM = Modifier Letter
	// UTF8PROC_CATEGORY_LO = Other Letter
	return unicode.is_letter(r)
}

// is_digit checks if a rune is a digit (including Unicode digits)
// C++ Reference: unicode.cpp:33-38 (rune_is_digit)
is_digit :: proc(r: rune) -> bool {
	// C++ line 34-35: Fast path for ASCII digits
	// Clever trick: (r - '0') < 10 works because unsigned arithmetic
	if r < 0x80 {
		return (u32(r) - '0') < 10
	}

	// C++ line 37: Unicode path - check decimal number category
	// UTF8PROC_CATEGORY_ND = Decimal Number
	// NOTE: core:unicode.is_digit only checks ASCII, so we use is_number
	// which checks the pN (numeric) property flag for Unicode numbers
	return unicode.is_number(r)
}

// is_blank_ident is defined in check_decl.odin
// is_entity_exported is defined in entity.odin

// AST flag management helpers
// These work with the external AST flag storage in Checker_Info

has_ast_flag :: proc(ctx: ^Checker_Context, node: ^ast.Node, flag: State_Flag) -> bool {
	if ctx == nil || node == nil {
		return false
	}

	flags, ok := ctx.info.ast_state_flags[rawptr(node)]
	if !ok {
		return false
	}

	return flag in flags
}

set_ast_flag :: proc(ctx: ^Checker_Context, node: ^ast.Node, flag: State_Flag) {
	if ctx == nil || node == nil {
		return
	}

	flags := ctx.info.ast_state_flags[rawptr(node)]
	flags += {flag}
	ctx.info.ast_state_flags[rawptr(node)] = flags
}

// reset_checker_context resets the context for a new file
// C++ Reference: checker.cpp:5888 (reset_checker_context)
reset_checker_context :: proc(ctx: ^Checker_Context, file: ^ast.File) {
	if ctx == nil || file == nil {
		return
	}

	// C++ Reference: checker.cpp:1716-1717, 1726-1727
	// The type path object is retained across the reset, but emptied, so that a context
	// reused for the next file does not inherit a stale (or leaked) cycle-detection path.
	if ctx.type_path != nil {
		clear(ctx.type_path)
	}
	ctx.type_level = 0

	ctx.file = file
	ctx.scope = ctx.info.file_scopes[file]
	ctx.pkg = file.pkg

	// In the C++ version, this also resets the untyped expressions map
	// and updates other context state
}

// make_checker_context is defined in check_collect.odin
// add_entity_use is defined in check_decl_helpers.odin

