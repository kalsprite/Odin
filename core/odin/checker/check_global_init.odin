package checker

import "core:odin/ast"
import "core:slice"
/*
Global variable initialization order analysis.

This module implements the global initialization order algorithm that determines
the order in which global variables must be initialized to satisfy dependencies.

Architecture:
- Build dependency graph from global variable initializer expressions
- Perform topological sort (Kahn's algorithm) to find initialization order
- Detect and report circular dependencies using DFS path finding
- Handle uninitialized variables and validation

C++ Reference: checker.cpp calculate_global_init_order:6398-6465
               checker.cpp find_entity_path:6349-6395, find_entity_path_tuple:6317-6347
               checker.cpp:55-105 (the entity_graph_node helpers: the struct is file-scope, then
                                   entity_graph_node_set_add:66-68, entity_graph_node_cmp:85-97,
                                   entity_graph_node_swap ending at :105 -- a RANGE SPANNING several
                                   functions plus a file-scope struct, so it stays deliberately bare)
               checker.cpp check_all_global_entities:5316-5340
*/


// ======================================================================================
// ENTITY GRAPH NODE OPERATIONS
// C++ Reference: checker.cpp:55-105
// ======================================================================================

// make_entity_graph_node creates a dependency graph node for an entity
// C++ Reference: Inline node creation in generate_entity_dependency_graph
make_entity_graph_node :: proc(entity: ^Entity, allocator := context.allocator) -> ^Entity_Graph_Node {
	node := new(Entity_Graph_Node, allocator)
	node.entity = entity
	node.pred = make(map[^Entity_Graph_Node]struct{}, 8, allocator)
	node.succ = make(map[^Entity_Graph_Node]struct{}, 8, allocator)
	node.index = 0
	node.dep_count = 0
	return node
}

// add_entity_dependency adds a dependency edge between two graph nodes
// C++ Reference: checker.cpp:3070-3071 (entity_graph_node_set_add)
add_entity_dependency :: proc(from: ^Entity_Graph_Node, to: ^Entity_Graph_Node) {
	assert(from != nil && to != nil)

	// Add edge: from->succ contains to, to->pred contains from
	from.succ[to] = {}
	to.pred[from] = {}
}

// is_entity_a_dependency is defined in entity_helpers.odin

/*
DEPENDENCY POPULATION CONTRACT:

Dependencies (decl.deps) are populated during semantic analysis, NOT through AST traversal.

The C++ checker populates decl->deps through the following call chain during check_expr:
  1. check_expr encounters an identifier (e.g., in a variable initializer)
  2. Calls add_entity_use(ctx, identifier, entity)
  3. Which calls add_declaration_dependency(ctx, entity)
  4. Which calls add_dependency(info, ctx->decl, entity)
  5. Which adds entity to ctx->decl->deps

C++ Reference: checker.cpp:862-870 (add_dependency)
               checker.cpp:952-963 (add_declaration_dependency)
               checker.cpp:1934-1960 (add_entity_use)

This means:
- Dependencies are discovered during type checking of expressions
- Each entity reference in an expression automatically records a dependency
- The dependency graph is built incrementally during semantic analysis
- By the time we reach calculate_global_init_order, all deps are populated

ARCHITECTURAL NOTE: Do NOT attempt to collect dependencies through AST traversal.
The dependency collection MUST happen during check_expr when semantic information
is available. AST traversal cannot determine true dependencies (e.g., which identifier
refers to which entity, handling of scopes, imports, etc.).
*/

// is_entity_in_dependency_chain checks if entity appears in a dependency path
// C++ Reference: Used in cycle detection (checker.cpp:6067-6077)
is_entity_in_dependency_chain :: proc(entity: ^Entity, chain: []^Entity) -> bool {
	for e in chain {
		if e == entity {
			return true
		}
	}
	return false
}

// ======================================================================================
// ENTITY DEPENDENCY GRAPH GENERATION
// C++ Reference: checker.cpp:3018-3155
// ======================================================================================

// generate_entity_dependency_graph builds a dependency graph with procedure elimination
// Returns only variable nodes with direct dependencies (procedures eliminated)
// C++ Reference: checker.cpp:3018-3155
generate_entity_dependency_graph :: proc(info: ^Checker_Info, allocator := context.allocator) -> []^Entity_Graph_Node {
	// Separate entities into procedures, variables, and other
	// C++ Reference: checker.cpp:3019-3044
	M_procs := make(map[^Entity]^Entity_Graph_Node, len(info.entities), allocator)
	M_vars := make(map[^Entity]^Entity_Graph_Node, len(info.entities), allocator)
	M_other := make(map[^Entity]^Entity_Graph_Node, len(info.entities), allocator)

	// Create nodes for all dependency-eligible entities
	for entity in info.entities {
		if entity == nil || !is_entity_a_dependency(entity) {
			continue
		}

		node := make_entity_graph_node(entity, allocator)

		#partial switch entity.kind {
		case .Procedure:
			M_procs[entity] = node
		case .Variable:
			M_vars[entity] = node
		case:
			M_other[entity] = node
		}
	}

	// Calculate edges for graph M - Part 1 (procedures)
	// C++ Reference: checker.cpp:3046-3073
	for entity, node in M_procs {
		decl := entity.decl_info
		if decl == nil {
			continue
		}

		// Add edges for each dependency
		for dep in decl.deps {
			if dep == nil {
				continue
			}

			// Skip field entities
			if .Field in dep.flags {
				continue
			}

			if !is_entity_a_dependency(dep) {
				continue
			}

			// Find the dependency node in appropriate map
			dep_node: ^Entity_Graph_Node = nil
			#partial switch dep.kind {
			case .Procedure:
				dep_node = M_procs[dep]
			case .Variable:
				dep_node = M_vars[dep]
			case:
				dep_node = M_other[dep]
			}

			if dep_node != nil {
				add_entity_dependency(node, dep_node)
			}
		}
	}

	// NOTE: Only M_procs needs edge calculation (C++ checker.cpp:3046-3073)
	// Variables and constants are handled through procedure dependencies.
	// The procedure elimination algorithm below creates the transitive variable-to-variable edges.

	// CRITICAL: Eliminate procedure nodes (lines 3079-3115 in C++)
	// This is the key algorithm that makes initialization order work correctly
	// For each procedure node:
	//   - Connect each predecessor directly to each successor
	//   - Remove the procedure node from the graph
	// This transforms: var_a -> proc -> var_b  into: var_a -> var_b
	// C++ Reference: checker.cpp:3079-3115
	for _, proc_node in M_procs {
		// Connect each predecessor 'p' of proc_node with each successor 's'
		for pred_node in proc_node.pred {
			// Ignore self-cycles
			if pred_node == proc_node {
				continue
			}

			// Each successor 's' of proc_node becomes a successor of pred_node
			// Each predecessor 'p' of proc_node becomes a predecessor of succ_node
			for succ_node in proc_node.succ {
				// Ignore self-cycles
				if succ_node == proc_node {
					continue
				}

				// Skip procedure-to-procedure edges (we only care about variable ordering)
				// C++ Reference: checker.cpp:3098-3102
				if pred_node.entity.kind == .Procedure && succ_node.entity.kind == .Procedure {
					continue
				}

				// Add direct edge from predecessor to successor
				add_entity_dependency(pred_node, succ_node)

				// Remove edge to proc_node from successor
				delete_key(&succ_node.pred, proc_node)
			}

			// Remove edge to proc_node from predecessor
			delete_key(&pred_node.succ, proc_node)
		}
	}

	// Build final graph G containing only variable nodes
	// C++ Reference: checker.cpp:3117-3122
	G := make([dynamic]^Entity_Graph_Node, 0, len(M_vars), allocator)
	for _, node in M_vars {
		append(&G, node)
	}

	// Calculate dependency counts and indices
	// C++ Reference: checker.cpp:3124-3130
	for node, i in G {
		node.index = i
		node.dep_count = len(node.succ)
		assert(node.dep_count >= 0)
	}

	return G[:]
}

// ======================================================================================
// ENTITY PATH FINDING (CYCLE DETECTION)
// C++ Reference: checker.cpp:5995-6041
// ======================================================================================

// find_entity_path_tuple searches tuple type dependencies for a path to end entity
// Used for procedure parameter/result dependency tracking
// C++ Reference: checker.cpp:5963-5993
find_entity_path_tuple :: proc(tuple: ^Type, end: ^Entity, visited: ^map[^Entity]bool, allocator := context.temp_allocator) -> []^Entity {
	if tuple == nil {
		return nil
	}

	// Ensure we have a tuple type
	tuple_info, ok := tuple.variant.(Type_Tuple)
	if !ok {
		return nil
	}

	// Search through tuple variables
	// C++ Reference: checker.cpp:5969-5990
	for var_entity in tuple_info.variables {
		var_decl := var_entity.decl_info
		if var_decl == nil {
			continue
		}

		// Check direct dependencies
		for dep in var_decl.deps {
			if dep == end {
				// Found direct path
				path := make([dynamic]^Entity, 0, 2, allocator)
				append(&path, dep)
				return path[:]
			}

			// Recursively search from dependency
			next_path := find_entity_path_internal(dep, end, visited, allocator)
			if len(next_path) > 0 {
				// Add current dep to path
				path := make([dynamic]^Entity, 0, len(next_path) + 1, allocator)
				append(&path, ..next_path)
				append(&path, dep)
				return path[:]
			}
		}
	}

	return nil
}

// find_entity_path_internal is the internal recursive implementation
// Separated to allow visited set management
// C++ Reference: checker.cpp:5995-6041
find_entity_path_internal :: proc(start: ^Entity, end: ^Entity, visited: ^map[^Entity]bool, allocator := context.temp_allocator) -> []^Entity {
	empty_path: []^Entity = nil

	// Check if already visited
	if start in visited^ {
		return empty_path
	}

	// Mark as visited
	visited[start] = true

	decl := start.decl_info
	if decl == nil {
		return empty_path
	}

	// Special handling for procedures - check parameter and result dependencies
	// C++ Reference: checker.cpp:6014-6024
	if start.kind == .Procedure {
		proc_type := start.type
		if proc_type != nil {
			proc_info, ok := proc_type.variant.(Type_Proc)
			if ok {
				// Check parameters
				if proc_info.params != nil {
					path := find_entity_path_tuple(proc_info.params, end, visited, allocator)
					if len(path) > 0 {
						return path
					}
				}

				// Check results
				if proc_info.results != nil {
					path := find_entity_path_tuple(proc_info.results, end, visited, allocator)
					if len(path) > 0 {
						return path
					}
				}
			}
		}
	} else {
		// Non-procedure entities: check regular dependencies
		// C++ Reference: checker.cpp:6026-6037
		for dep in decl.deps {
			if dep == end {
				// Found direct path
				path := make([dynamic]^Entity, 0, 1, allocator)
				append(&path, dep)
				return path[:]
			}

			// Recursively search from dependency
			next_path := find_entity_path_internal(dep, end, visited, allocator)
			if len(next_path) > 0 {
				// Add current dep to path
				path := make([dynamic]^Entity, 0, len(next_path) + 1, allocator)
				append(&path, ..next_path)
				append(&path, dep)
				return path[:]
			}
		}
	}

	return empty_path
}

// find_entity_path performs DFS to find a dependency path from start to end
// Used for reporting circular dependency cycles
// C++ Reference: checker.cpp:5995-6041
find_entity_path :: proc(start: ^Entity, end: ^Entity, graph: map[^Entity]^Entity_Graph_Node, allocator := context.temp_allocator) -> []^Entity {
	// Create visited set
	visited := make(map[^Entity]bool, allocator)
	defer delete(visited)

	// Call internal implementation
	return find_entity_path_internal(start, end, &visited, allocator)
}

// find_path_dfs is the recursive DFS implementation (DEPRECATED - kept for compatibility)
// Use find_entity_path_internal instead for new code
// C++ Reference: checker.cpp:5995-6041 (recursive logic)
find_path_dfs :: proc(current: ^Entity, target: ^Entity, graph: map[^Entity]^Entity_Graph_Node, visited: ^map[^Entity]bool, path: ^[dynamic]^Entity) -> bool {
	// Found target
	if current == target {
		append(path, current)
		return true
	}

	// Already visited (cycle in another branch)
	if current in visited^ {
		return false
	}

	// Mark as visited
	visited[current] = true
	append(path, current)

	// Explore dependencies
	if _, ok := graph[current]; ok {
		// Check entity's declaration dependencies
		if decl := current.decl_info; decl != nil {
			// Iterate dependencies (C++ uses FOR_PTR_SET macro)
			for dep in decl.deps {
				if find_path_dfs(dep, target, graph, visited, path) {
					return true
				}
			}
		}
	}

	// Backtrack
	pop(path)
	return false
}

// ======================================================================================
// GLOBAL INITIALIZATION ORDER CALCULATION
// C++ Reference: checker.cpp:6044-6110
// ======================================================================================

// calculate_global_init_order determines the initialization order for global variables
// Uses topological sort (Kahn's algorithm) to order variables by dependencies
// C++ Reference: checker.cpp:6044-6110
calculate_global_init_order :: proc(info: ^Checker_Info, allocator := context.allocator) -> []^Entity {
	// Build dependency graph with procedure elimination
	// C++ Reference: checker.cpp calculate_global_init_order:6405 (generate_entity_dependency_graph)
	dep_graph := generate_entity_dependency_graph(info, context.temp_allocator)

	// Build entity->node map for cycle detection
	nodes := make(map[^Entity]^Entity_Graph_Node, len(dep_graph), allocator)
	defer delete(nodes)

	for node in dep_graph {
		nodes[node.entity] = node
	}

	// Topological sort using Kahn's algorithm with priority queue
	// C++ Reference: checker.cpp calculate_global_init_order:6409-6454 (priority queue processing)
	ordered := make([dynamic]^Entity, 0, len(nodes), allocator)
	queue := make([dynamic]^Entity_Graph_Node, 0, len(nodes), allocator)
	defer delete(queue)

	// Deduplication set to prevent adding the same entity twice
	// C++ Reference: checker.cpp calculate_global_init_order:6411-6412 (PtrSet<DeclInfo *> emitted)
	emitted := make(map[^Decl_Info]bool, len(nodes), allocator)
	defer delete(emitted)

	// Initialize priority queue with ALL nodes
	// C++ Reference: checker.cpp calculate_global_init_order:6409 - priority_queue_create(dep_graph, ...)
	// The priority queue will sort by (dep_count, order_in_src) to always process
	// the node with smallest dependency count first
	for node in dep_graph {
		append(&queue, node)
	}

	// Sort queue for deterministic processing
	// C++ uses a min-heap priority queue that sorts by (dep_count, order_in_src)
	// We sort once per iteration since we don't have incremental heap updates
	sort_entity_graph_nodes :: proc(nodes: []^Entity_Graph_Node) {
		slice.sort_by(
			nodes,
			proc(a, b: ^Entity_Graph_Node) -> bool {
				// Primary: dep_count (ascending)
				if a.dep_count != b.dep_count {
					return a.dep_count < b.dep_count
				}
				// Secondary: order_in_src (ascending) for determinism
				return a.entity.order_in_src < b.entity.order_in_src
			},
		)
	}

	// Process queue
	for len(queue) > 0 {
		// Sort queue to get node with smallest (dep_count, order_in_src)
		// C++ Reference: checker.cpp calculate_global_init_order:6416 (priority_queue_pop)
		sort_entity_graph_nodes(queue[:])

		// Pop node with smallest priority
		node := queue[0]
		ordered_remove(&queue, 0)

		// Check for cycles during processing
		// C++ Reference: checker.cpp calculate_global_init_order:6419-6432
		if node.dep_count > 0 {
			// Circular dependency detected
			e := node.entity
			path := find_entity_path(e, e, nodes, context.temp_allocator)

			if len(path) > 0 {
				report_circular_dependency(e, path)
			}
		}

		// Reduce dependency count for predecessor nodes
		// C++ Reference: checker.cpp calculate_global_init_order:6434-6438
		for pred_node in node.pred {
			pred_node.dep_count -= 1
			if pred_node.dep_count < 0 {
				pred_node.dep_count = 0
			}
			// Note: priority_queue_fix would be called here in C++
			// We handle this by re-sorting the entire queue each iteration
		}

		// Filter: only add variables to the initialization order
		// C++ Reference: checker.cpp calculate_global_init_order:6440-6453
		e := node.entity
		d := decl_info_of_entity(e)

		// Only include Entity_Variable in the init order
		// C++ Reference: checker.cpp calculate_global_init_order:6441-6443
		if e.kind != .Variable {
			continue
		}

		// IMPORTANT NOTE(bill, 2019-08-29): Just add it regardless of the ordering
		// because it does not need any initialization other than zero
		// C++ Reference: checker.cpp calculate_global_init_order:6444-6448
		// (Original code had: if (!decl_info_has_init(d)) continue; - now commented out)

		// Deduplicate: check if we've already emitted this decl
		// C++ Reference: checker.cpp calculate_global_init_order:6449-6451 (ptr_set_update returns true if already exists)
		if d in emitted {
			continue
		}
		emitted[d] = true

		// Add to ordered list
		// C++ Reference: checker.cpp calculate_global_init_order:6453
		append(&ordered, e)
	}

	// Debug output (disabled by default)
	// C++ Reference: checker.cpp calculate_global_init_order:6456-6464
	when false {
		fmt.printf("Variable Initialization Order:\n")
		for e in ordered {
			fmt.printf("\t'%s' %d\n", e.token.text, e.order_in_src)
		}
		fmt.printf("\n")
	}

	return ordered[:]
}

// report_circular_dependency reports a circular dependency error
// C++ Reference: checker.cpp calculate_global_init_order:6423-6431
report_circular_dependency :: proc(start_entity: ^Entity, cycle_path: []^Entity) {
	if len(cycle_path) == 0 {
		return
	}

	// Report error on first entity in cycle
	entity := cycle_path[0]
	error(entity.token, "Cyclic initialization of '%s'", entity.token.text)

	// Print dependency chain
	for i := len(cycle_path) - 1; i >= 0; i -= 1 {
		e := cycle_path[i]
		error(e.token, "\t'%s' refers to", e.token.text)
	}

	// Print closing reference back to start
	error(entity.token, "\t'%s'", entity.token.text)
}

// ======================================================================================
// GLOBAL ENTITY CHECKING
// C++ Reference: checker.cpp check_all_global_entities:5316-5340
// (was :4938-4995, which resolves to check_collect_value_decl -- a declaration-collection routine,
//  not this phase. The cited extent was 57 lines where the real function is 25, so the drift was
//  never a shift; every anchor below is mapped by CONTENT.)
// ======================================================================================

// check_single_global_entity checks a single global entity (on-demand checking)
// C++ Reference: checker.cpp check_single_global_entity:5283-5314 (the port's is in type_info.odin)
//
// check_single_global_entity is defined in type_info.odin

// check_all_global_entities checks all global entities in initialization order
// Main entry point for global entity type checking
// C++ Reference: checker.cpp check_all_global_entities:5316-5340
check_all_global_entities :: proc(ctx: ^Checker_Context) {
	// NOTE: This must be single threaded (C++ line 4972-4975)
	// Don't bother trying to parallelize
	// C++ Reference: checker.cpp check_all_global_entities:5317
	// in_single_threaded_checker_stage.store(true, std::memory_order_relaxed)
	set_single_threaded_checker_stage(true)

	c := ctx.checker
	info := ctx.info

	// Check entities in order
	// C++ Reference: checker.cpp check_all_global_entities:5321-5337
	for entity in info.entities {
		assert(entity != nil)

		// Skip lazy entities (checked on demand)
		// C++ Reference: checker.cpp check_all_global_entities:5324-5326
		if .Lazy in entity.flags {
			continue
		}

		// Get declaration info
		decl := entity.decl_info

		// Check the entity
		// C++ Reference: checker.cpp check_all_global_entities:5328
		check_single_global_entity(c, entity, decl)

		// Complete SOA types and calculate type size/alignment
		// C++ Reference: checker.cpp check_all_global_entities:5329-5336
		if entity.type != nil && is_type_typed(entity.type) {
			// Complete SOA types if needed
			// C++ Reference: checker.cpp check_all_global_entities:5330-5332
			drain_and_complete_soa_types(c)

			// Ensure type size/alignment is calculated
			// C++ Reference: checker.cpp check_all_global_entities:5334-5335
			_ = type_size_of(entity.type)
			_ = type_align_of(entity.type)
		}
	}

	// THE calculate_global_init_order CALL USED TO BE HERE, AND THAT WAS THE WRONG PHASE.
	// C++ calls it exactly once, from check_parsed_files at checker.cpp check_parsed_files:7760 -- AFTER
	// check_procedure_bodies, check_deferred_procedures and check_objc_context_provider_procedures.
	// Running it here computed the order from an entity dependency graph that predates every
	// dependency discovered while checking bodies. It is now called from its C++ position in
	// check_files.odin; see the comment there. The port's own comment here used to read
	// "calculate_global_init_order is called from check_init", i.e. it recorded that C++ calls it
	// somewhere else and then called it here anyway.
	//
	// Note: init_preload is called from check_files after check_all_global_entities
	// C++ Reference: checker.cpp check_parsed_files:7706 (the init_preload call site; the old
	// citation said :7333, which is inside handle_raddbg_type_view -- I anchored it by guess and
	// --check caught it in the same session)

	// Exit single-threaded stage - enable parallel checking from this point
	// C++ Reference: checker.cpp check_all_global_entities:5339
	// in_single_threaded_checker_stage.store(false, std::memory_order_relaxed)
	set_single_threaded_checker_stage(false)
}

// store_global_init_order runs C++'s calculate_global_init_order and publishes the result.
//
// C++ Reference: checker.cpp calculate_global_init_order:6398-6465
//
// SPLIT SHAPE, DELIBERATE: C++'s calculate_global_init_order appends DeclInfo straight into
// info->variable_init_order (:6453). The port's returns []^Entity and this wrapper publishes it. The
// dedup that matters happens INSIDE calculate_global_init_order, keyed on decl_info_of_entity, so
// the two-step form cannot reintroduce duplicates.
store_global_init_order :: proc(c: ^Checker) {
	info := &c.info
	init_order := calculate_global_init_order(info, c.allocator)

	// C++ Reference: checker.cpp calculate_global_init_order:6453
	clear(&info.variable_init_order)
	for entity in init_order {
		if decl := entity.decl_info; decl != nil {
			append(&info.variable_init_order, decl)
		}
	}
}

// check_entity_decl is defined in check_decl.odin

// add_curr_ast_file sets the current file context
// C++ Reference: checker.cpp:1525-1534
add_curr_ast_file :: proc(ctx: ^Checker_Context, file: ^ast.File) -> bool {
	if file != nil {
		// Set file, decl, scope, and package from file
		// C++ Reference: checker.cpp:1527-1530
		ctx.file = file
		// C++ line 1528: ctx->decl = file->pkg->decl_info
		// Odin: Use package_helpers.odin get_package_decl_info
		ctx.decl = get_package_decl_info(ctx.info, file.pkg)
		// Use file_scopes external map
		ctx.scope = ctx.info.file_scopes[file]
		ctx.pkg = file.pkg
		return true
	}
	return false
}
