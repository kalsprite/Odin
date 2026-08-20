package checker

/*
Import/Export Processing for the Odin checker.

This module handles import declarations, package dependency graph construction,
and entity visibility management for cross-package type checking.

C++ Reference: checker.cpp:5130-5926

*/

import "base:runtime"
import "core:mem"
import "core:odin/ast"
import "core:odin/tokenizer"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:unicode"

// lookup_imported_package maps an import declaration's path to the package it names.
//
// C++ has it easier here: the parser stores the *resolved absolute* path in id->fullpath
// (determine_path_from_string, src/parser.cpp:6236), so the info->packages key is globally
// unique and the lookup is a single hit. The Odin parser leaves fullpath as the literal source
// text (parser.odin:3936), so a relative import such as `import "../../_sha3"` only finds its
// package if the loader happened to register that exact spelling - which it does not when the
// directory was already reachable under another spelling (`core:crypto/_sha3`), because the
// `already loaded` guard in load_package_with_dependencies skips registration entirely.
//
// Resolving the path against the importing package's directory and retrying under the resolved
// key - which the loader always registers - restores the C++ property that a package is
// identified by where it is, not by how it was spelled.
// A RELATIVE path must be resolved BEFORE the literal key is consulted, because a relative
// spelling only names a package relative to the file that wrote it. register_package
// (build_infrastructure.odin:433) deliberately registers a package under more than one key --
// "import path vs resolved path" -- so the literal spelling ".." is a live key pointing at
// whichever package was FIRST imported that way. Two packages in a chain both spelling their
// parent ".." then collide, and the second one silently resolves to the first one's target.
//
// Measured: leaf imports ".." (mid), mid imports ".." (top). Checked alone, mid and top are
// both clean; checking leaf made mid's `top.Thing` report "'Thing' is not declared by 'top'",
// because `top` bound to mid via the shared ".." key. That is the whole of the spec_* failure
// (core/odin/checker/tests imports its parent as `checker ".."`, and each spec_* imports tests
// as `helpers ".."`): oracle 0 errors, port ~30, across all ten packages. LEDGER #387.
//
// C++ does not have the bug because the parser stores the resolved ABSOLUTE path in
// id->fullpath (determine_path_from_string, src/parser.cpp:6236), so its key is already unique.
lookup_imported_package :: proc(info: ^Checker_Info, import_path: string, importer: ^ast.Package) -> (^ast.Package, bool) {
	is_relative := strings.has_prefix(import_path, "./") ||
	               strings.has_prefix(import_path, "../") ||
	               import_path == "." ||
	               import_path == ".."

	if importer != nil {
		// #915: package_base_dir, NOT importer.fullpath directly -- a single-file package's
		// fullpath is the FILE. The loader resolves the same import through the same helper, and
		// if these two disagree the loader loads a package this lookup then fails to find.
		if resolved, res_ok := resolve_import_path(import_path, package_base_dir(importer.fullpath), context.temp_allocator); res_ok {
			if pkg, ok := info.packages[resolved]; ok {
				return pkg, true
			}
		}
	}
	// The literal key is a valid identity only for a NON-relative path (a collection path such
	// as "core:strings", which names the same package from anywhere).
	if !is_relative {
		if pkg, ok := info.packages[import_path]; ok {
			return pkg, true
		}
	}
	return nil, false
}

// Import_Graph_Node is defined in check_decl.odin
// Import_Graph is the complete import dependency graph
Import_Graph :: struct {
	nodes:     map[rawptr]^Import_Graph_Node,
	checker:   ^Checker, // Need reference to checker for package lookup
	allocator: runtime.Allocator,
}

// Import_Path_Item tracks an import path for cycle detection
// C++ Reference: struct ImportPathItem in checker.cpp:5170-5173
Import_Path_Item :: struct {
	pkg:  ^ast.Package, // C++ line 5171
	decl: ^ast.Stmt, // C++ line 5172: Import declaration
}

// NOTE: check_import_decl_attributes (a hand-rolled attribute walk) USED TO LIVE HERE and was
// deleted in t208. It diverged from C++ in two ways at once, and each hid the other:
//   * it matched the user tag as "user_tag"; C++ spells it "tag"
//     (`#define ATTRIBUTE_USER_TAG_NAME "tag"`, checker.cpp:3712, and import_decl_attribute at
//     checker.cpp:5580 makes it the first arm)
//   * it had NO unknown-attribute arm -- its own closing comment admitted as much: "Other
//     attributes are silently ignored for imports (C++ returns false which triggers unknown
//     attribute warning in check_decl_attributes)"
// Because unknown names were never reported, BOTH spellings were silently accepted, so a probe
// using `tag` saw no divergence and the wrong-name half looked like a non-defect. `user_tag` is the
// probe that separates them: the reference rejects it as unknown, the port accepted it.
// check_add_import_decl now calls the generic check_decl_attributes with kind .Import, which is
// what C++ does (checker.cpp:5646 passes import_decl_attribute to check_decl_attributes). That
// dispatcher already had the correct attr_names_import table {"require","tag"} and
// report_unknown_attribute -- WITH NO CALLER PASSING .Import, so the table was dead.

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

	// C++ parser.cpp:6225-6247 (determine_path_from_string). `core:runtime`, `core:intrinsics`
	// and `core:builtin` are rewritten to the `base:` collection and the deprecation is reported.
	// The loader applies the same rewrite so the package actually resolves; the DIAGNOSTIC is
	// emitted only here, because this runs exactly once per import decl whereas the loader's walk
	// revisits each decl on every package load.
	//
	// SEVERITY IS VET-GATED, and the two arms differ in more than wording: parser.cpp:6241 uses
	// do_error(node, ...) -- an Ast* overload, so the caret spans the whole decl -- while :6244
	// uses do_warning(ast_token(node), ...), a bare token with no end, which is why the reference
	// prints the warning WITHOUT a source-line snippet and the error WITH one. Reproduced by
	// passing node_end_pos for the error and {} for the warning. wit_deprec206 pins both arms.
	//
	// `use_check_errors` defaults to false at the parse-time call site (parser.cpp:6156-6157), so
	// these are syntax_error/syntax_warning, not error/warning -- hence the "Syntax " prefix.
	if rewritten, is_deprecated := normalize_deprecated_core_collection(
		import_path,
		ctx.checker.allocator,
	); is_deprecated {
		file_str := rewritten[len("base:"):]
		if ast_file_vet_deprecated(get_file_from_node(ctx.info, import_decl)) {
			syntax_error_va(
				ast_token_pos(import_decl),
				node_end_pos(import_decl),
				"import \"core:%s\" has been deprecated in favour of \"base:%s\"",
				file_str,
				file_str,
			)
		} else {
			syntax_warning_pos(
				ast_token_pos(import_decl),
				"import \"core:%s\" has been deprecated in favour of \"base:%s\"",
				file_str,
				file_str,
			)
		}
		import_path = rewritten
	}

	// C++ parser.cpp:6248-6272, the two checks that immediately FOLLOW the core->base rewrite in
	// determine_path_from_string. Both were absent, and both are over-permissiveness rather than
	// wording drift -- the port accepted input the reference rejects, or invented its own message.
	//
	//	} else if (!find_library_collection_path(collection_name, &base_dir)) {
	//	        do_error(node, "Unknown library collection: '%.*s'", LIT(collection_name));
	//	...
	//	if (is_package_name_reserved(file_str)) {
	//	        *path = file_str;
	//	        if (collection_name == "core" || collection_name == "base") { return true; }
	//	        else { do_error(node, "The package '%.*s' must be imported with the 'base' library
	//	                             collection: 'base:%.*s'", ...); }
	//	}
	//
	// NOTE the reserved-name gate is reached with an EMPTY collection_name for a bare
	// `import "builtin"` -- no colon means the collection block above is skipped entirely -- and ""
	// is neither "core" nor "base", which is exactly why the bare spelling is an error. That is the
	// case wit_bh206/h_builtin_bare pins; the port accepted it silently.
	//
	// syntax_error, not error: do_error is &syntax_error at the default use_check_errors=false
	// (parser.cpp:6156). wit_bh206/h_coll_unknown showed the port emitting its own invented
	// "Unable to find package: bogus:thing" instead of "Unknown library collection: 'bogus'".
	{
		// C++ parser.cpp:6196-6200, and it comes FIRST -- before the collection lookup and before
		// the reserved-name gate:
		//
		//	String file_str = {};
		//	if (colon_pos == 0) {
		//	        do_error(node, "Expected a collection name");
		//	        return false;
		//	}
		//
		// A LEADING colon is not "an empty collection name"; it is its own diagnostic, and the
		// reference bails immediately. The port fell through to package resolution and invented
		// "Error: Unable to find package: :foo" where the oracle says
		// "Syntax Error: Expected a collection name". Witness wit_bi213/i_leading_colon.
		// split_import_collection cannot report this case -- it returns an empty collection for a
		// leading colon AND for no colon at all -- so the test is on the raw path.
		if len(import_path) > 0 && import_path[0] == ':' {
			syntax_error_va(
				ast_token_pos(import_decl),
				node_end_pos(import_decl),
				"Expected a collection name",
			)
			return
		}

		collection_name, file_str := split_import_collection(import_path)
		if collection_name != "" && collection_name != "system" {
			if _, found := find_library_collection_path(collection_name); !found {
				syntax_error_va(
					ast_token_pos(import_decl),
					node_end_pos(import_decl),
					"Unknown library collection: '%s'",
					collection_name,
				)
				return
			}
		}
		if is_package_name_reserved(file_str) &&
		   collection_name != "core" &&
		   collection_name != "base" {
			syntax_error_va(
				ast_token_pos(import_decl),
				node_end_pos(import_decl),
				"The package '%s' must be imported with the 'base' library collection: 'base:%s'",
				file_str,
				file_str,
			)
			return
		}
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
		// C++ checker.cpp check_add_import_decl sets force_use for "intrinsics" exactly as it does for
		// "builtin" two lines above. The port had it on the builtin branch only, so an
		// `import "base:intrinsics"` that is never referenced by name was reported as an
		// unused import -- which the real compiler never does, for either package. Found
		// with the vet harness from LEDGER 289; the sweep could not see it. LEDGER 291.
		force_use = true
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
		if pkg, ok := lookup_imported_package(ctx.info, import_path, ctx.pkg); ok {
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
	// C++ Reference: checker.cpp check_add_import_decl - path_to_entity_name(id->import_name.string, id->fullpath, false)
	import_name := path_to_entity_name(import_decl.name.text, import_path, false)

	// Check if this is a blank import (underscore) (C++ line 5299-5301)
	if is_blank_ident(import_name) {
		force_use = true
	}

	// Check attributes for @(require) and other import attributes
	// C++ Reference: checker.cpp:5303-5307
	ac := Attribute_Context{}
	check_decl_attributes(ctx, import_decl.attributes[:], &ac, .Import)
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

		// C++ Reference: checker.cpp check_add_import_decl opens an ERROR_BLOCK here; the port had none, so the
		// suggestion below escaped the collector and printed ahead of its own diagnostic.
		begin_error_block()
		defer end_error_block()

		// C++ (checker.cpp check_add_import_decl) used to read "cannot be use as an import name as it is not a
		// valid identifier" -- a grammatical slip the port reproduced verbatim, because this text
		// is compared byte-for-byte. It was filed as #187, fixed upstream and merged, and the
		// reference now uses the SAME message in both branches:
		//     error(token,     "Import name '%.*s' is not a valid identifier", ...)
		//     error(id->token, "Import name '%.*s' is not a valid identifier", ...)
		// So the two arms differ only in which token they anchor on and whether the Suggestion
		// follows. LEDGER #385.
		if len(import_decl.name.text) > 0 {
			error_node(import_decl, "Import name '%s' is not a valid identifier", import_decl.name.text)
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
			// Use a synthetic token for unnamed imports.
			//
			// C++ Reference: parser.cpp:5151-5159. The position is the PATH string, not the
			// `import` keyword:
			//
			//	Token import_name = {};
			//	switch (f->curr_token.kind) {
			//	case Token_Ident: import_name = advance_token(f); break;
			//	default:          import_name.pos = f->curr_token.pos; break;
			//	}
			//
			// At the `default` arm the parser has consumed `import` and not yet consumed the
			// path, so curr_token IS the path string. checker.cpp check_add_import_decl then hands that token to
			// alloc_entity_import_name, and checker.cpp:842 reports "declared but not used" at
			// e->token -- so the oracle points at `"core:sync"`, column 8, while this port
			// pointed at `import`, column 1.
			//
			// import_decl.pos is the keyword (Import_Decl embeds Decl, whose pos is import_tok's).
			// relpath is the path token, which is the equivalent of C++'s curr_token here.
			import_token = tokenizer.Token {
				text = import_name,
				kind = .Ident,
				pos  = import_decl.relpath.pos,
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

	// C++ Reference: checker.cpp check_import_entities. This is a FIXPOINT loop, not a simple walk.
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

			// C++ Reference: checker.cpp check_import_entities. The second collection phase, and the only path
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

	// LEDGER #446 (task #335). DETERMINISM HARDENING. Same shape as #271: C++'s comparator is
	// ported faithfully but fed a nondeterministically ordered input where C++'s is deterministic.
	//
	// The selection loop below breaks ties by (dep_count, Global flag, pkg.id) -- but the pkg.id
	// arm fires ONLY when both nodes are Global. For two NON-global packages, the ordinary case,
	// it takes "first found wins", and "first found" is the order of `nodes` above: raw Odin map
	// order, which is address-seeded (LEDGER #437). C++ builds its node array by walking packages
	// rather than a hash map, so its "first found" is stable and its comparator never needed the
	// tiebreak the port needs.
	//
	// Sorting by pkg.id reproduces that: ids are assigned in package LOAD order, which is the
	// order C++'s array is built in. Nodes with no package sort last, deterministically.
	//
	// NO MEASURED EFFECT on core/odin/parser (moved_positions 1125/1125/1121 before,
	// 1125/1125/1114 after -- inside the +-10 noise band of LEDGER #441), most likely because
	// dep_count and the Global flag already give a total order over that package set, so the
	// tiebreak is never reached. Landed anyway: this SPECIFIES an order that was previously
	// undefined rather than changing a defined one, so there is nothing load-bearing to break, and
	// it costs one sort of ~34 nodes once per run. Gated: parity 323/323 0/0/0, corpus 198/198.
	slice.sort_by(nodes[:], proc(a, b: ^Import_Graph_Node) -> bool {
		if a.pkg == nil || b.pkg == nil {
			return b.pkg == nil && a.pkg != nil
		}
		return a.pkg.id < b.pkg.id
	})

	// Result array
	result := make([dynamic]^Import_Graph_Node, 0, len(nodes), allocator)

	// Emitted set to track processed packages
	emitted := make(map[rawptr]struct{}, allocator)
	defer delete(emitted)

	// Process nodes in order of dependency count (C++ line 5832-5871)
	// Kahn's algorithm for topological sort with priority handling
	for len(nodes) > 0 {
		// Find node with minimum dependency count (C++ uses priority queue)
		// C++ Reference: checker.cpp import_graph_node_cmp
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
				// C++ Reference: checker.cpp:6187-6196. The loop is PRINT-THEN-ADVANCE:
				//     error(item.decl, "'%s' refers to", pkg_name);   // current decl AND name
				//     item = path[i];                                  // then step
				//     pkg_name = item.pkg->name;
				// The port advanced FIRST (`item := path[i]`) and then printed `item.decl` with
				// the PREVIOUS `first_item.pkg.name`, so its ANCHOR ran one step ahead of its
				// NAME. Net effect on a two-package cycle: the two diagnostics land on each
				// other's files and name each other's packages --
				//     oracle: a.odin "'b' refers to"            b.odin "Cyclic importation of 'a'"
				//     port:   a.odin "Cyclic importation of 'b'" b.odin "'b' refers to"
				// *** THE COUNT AND THE EXIT STATUS ARE IDENTICAL, so the verdict corpus calls
				// this cell clean. It was found by a CONTROL cell (a top-level cycle) written only
				// to prove the detector fired at all. ***
				item := path[len(path) - 1]
				pkg_name := item.pkg.name
				error_node(item.decl, "Cyclic importation of '%s'", pkg_name)
				for i := 0; i < len(path); i += 1 {
					error_node(item.decl, "'%s' refers to", pkg_name)
					item = path[i]
					pkg_name = item.pkg.name
				}
				error_node(item.decl, "'%s'", pkg_name)
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
				imported_pkg, pkg_ok := lookup_imported_package(&graph.checker.info, import_path, pkg)
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
	//
	// DETERMINISM (#271). C++ publishes in sorted-FILE order, but gets that emergently from its
	// thread pool's FIFO dispatch, NOT from an explicit sort: checker.cpp:2229-2237 enqueues from
	// inside the parallel collect worker (bill's own comment there notes multiple threads reach
	// it). Measured: oracle 60/60 identical on core/rexcode/isa/ppc_vle/tools; the port's raw
	// queue order was 16/20 sorted-file order and 4/20 scrambled, which flipped WHICH of two
	// duplicate `main`s was named the redeclaration and which the original.
	//
	// So this sort is NOT a transcription of C++ code -- there is no sort to cite. It reproduces
	// C++'s OBSERVABLE publish order, which is what parity requires. Do not "correct" it to match
	// C++ line-for-line by removing it.
	//
	// Sorted by (file basename, byte offset): basename to match the collect dispatch's own
	// ordering (check_collect.odin uses filename_from_path), offset to keep declaration order
	// within a file. Every file in a package shares a directory, so basename order and full-path
	// order agree here.
	drained := make([dynamic]ast.Package_Exported_Entity, 0, 64, context.temp_allocator)
	defer delete(drained)
	for {
		exported, ok := dequeue_exported_entity(&c.info, pkg)
		if !ok {
			break
		}
		append(&drained, exported)
	}
	slice.sort_by(drained[:], proc(a, b: ast.Package_Exported_Entity) -> bool {
		pa, pb := a.entity.token.pos, b.entity.token.pos
		na, nb := filename_from_path(pa.file), filename_from_path(pb.file)
		if na != nb {
			return strings.compare(na, nb) < 0
		}
		return pa.offset < pb.offset
	})

	for exported in drained {

		// C++ Reference: checker.cpp check_export_entities_in_pkg — `add_entity(ctx, pkg->scope, ee.identifier, ee.entity)`.
		//
		// This goes through add_entity, not scope_insert. add_entity skips BLANK
		// identifiers (entity_helpers.odin, mirroring checker.cpp:2089), reports
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
		//
		// TASK 109 RESOLVED: routing this through add_entity previously produced a false
		// "Redeclaration of 'compress'" because add_entity_and_decl_info ALSO inserted
		// the entity into the file scope. C++ only enqueues there (checker.cpp:2229-2245,
		// where the add_entity call is in the ELSE branch). With that double insertion
		// removed, this drain is the single point where a package-level entity is
		// published, and it is the only place a package-level redeclaration can be
		// reported.
		ctx := make_checker_context(c)
		defer destroy_checker_context(&ctx)
		ctx.pkg = pkg
		ctx.scope = pkg.scope
		add_entity(&ctx, pkg.scope, exported.identifier, exported.entity)
	}
}

// Helper functions

// is_package_name_reserved checks if a package name is a reserved system package
is_package_name_reserved :: proc(name: string) -> bool {
	return name == "builtin" || name == "intrinsics"
}

// split_import_collection splits "core:fmt" into ("core", "fmt").
//
// C++ Reference: parser.cpp:6168-6205 inside determine_path_from_string -- the FIRST ':' splits,
// and a path with no colon has an empty collection and is entirely file_str.
//
// The Windows-drive special case at parser.cpp:6177-6185 is deliberately not reproduced: it is
// guarded by `!is_import_decl_path`, and every caller here IS an import decl.
//
// A leading colon (colon_pos == 0) makes C++ report "Expected a collection name" (parser.cpp:6197)
// and bail. That diagnostic is NOT ported yet and is queued separately -- this helper only reports
// the split, returning an empty collection for that case so no caller mistakes ":foo" for a
// collection named "".
split_import_collection :: proc(import_path: string) -> (collection: string, file_str: string) {
	for i in 0 ..< len(import_path) {
		if import_path[i] == ':' {
			if i == 0 {
				return "", import_path[1:]
			}
			return import_path[:i], import_path[i + 1:]
		}
	}
	return "", import_path
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
// C++ Reference: unicode.cpp rune_is_letter (rune_is_letter)
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
// C++ Reference: unicode.cpp rune_is_digit (rune_is_digit)
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
// C++ Reference: checker.cpp reset_checker_context (reset_checker_context)
//
// LEDGER #463 (task #344). This was a 12-line reimplementation and diverged from C++ in five ways.
// The one that mattered: it returned early when `file == nil`, where C++ bails only on a null
// CONTEXT and then installs builtin-package defaults. C++'s ctx->pkg is therefore NEVER null; the
// port's could be, and `e.pkg = ctx.pkg` (entity_helpers.odin:636) wrote that null straight onto
// the entity.
//
// That is what made the model nondeterministic. An entity is created once, by whichever path
// reaches it first. Under threading that is sometimes a body-checking worker (file set, so
// pkg=the real package) and sometimes an on-demand resolution through a nil-file context (early
// bail, so pkg=nil). Measured on base/runtime: 23 entities flipping between 'runtime' and nil
// across 8 runs, with every other field -- type, size, align, flags, position -- identical.
//
// The `untyped` parameter is C++'s third argument. It still defaults to nil, but the claim that
// used to stand here -- "NO caller in the port passes one yet ... that cache has never operated" --
// is OUT OF DATE as of LEDGER #856/#857. check_set_expr_info now has a live writer (add_untyped,
// via check_expr_base), and check_collect.odin's collect and delayed-decl passes now hand it a
// real map. This particular procedure still has no caller that passes one, because the collect
// worker sets ctx.untyped directly rather than going through a context reset; see #857 for why
// that shape was kept.
reset_checker_context :: proc(ctx: ^Checker_Context, file: ^ast.File, untyped: ^map[^ast.Expr]^Expr_Info = nil) {
	// C++ guards the CONTEXT only. A nil file is a legitimate input that must still produce a
	// well-formed context, which is precisely what the old early return got wrong.
	if ctx == nil {
		return
	}
	assert(ctx.checker != nil)

	sync.lock(&ctx.mutex)
	defer sync.unlock(&ctx.mutex)

	// C++ Reference: checker.cpp reset_checker_context, 1726-1727
	// The type path object is retained across the reset, but emptied, so that a context
	// reused for the next file does not inherit a stale (or leaked) cycle-detection path.
	type_path := ctx.type_path
	if type_path != nil {
		clear(type_path)
	}

	// C++ line 1719: gb_zero_size(&ctx->pkg, gb_size_of(CheckerContext) - gb_offset_of(CheckerContext, pkg))
	// Every field from `pkg` onward is cleared; mutex, checker and info precede it and survive.
	// Checker_Context declares its fields in the same order, so the tail zero transfers directly.
	// Doing it field-by-field would silently rot the moment a field is added -- the memset does not.
	tail_off := int(offset_of(Checker_Context, pkg))
	mem.zero(rawptr(uintptr(ctx) + uintptr(tail_off)), size_of(Checker_Context) - tail_off)

	// C++ lines 1721-1724. The builtin package is the FLOOR: after this, pkg and scope are
	// non-nil whatever `file` turns out to be.
	ctx.file = nil
	if ctx.info != nil && ctx.info.builtin_package != nil {
		ctx.scope = ctx.info.builtin_package.scope
		ctx.pkg = ctx.info.builtin_package
	}
	ctx.decl = nil

	ctx.type_path = type_path
	ctx.type_level = 0

	// C++ line 1729
	add_curr_ast_file(ctx, file)

	// C++ line 1731
	ctx.untyped = untyped
}

// make_checker_context is defined in check_collect.odin
// add_entity_use is defined in check_decl_helpers.odin

