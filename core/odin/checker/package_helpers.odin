package checker

/*
Package helper functions for accessing package-level metadata.

These helpers provide safe access to package metadata stored directly on ast.Package.
This achieves perfect parity with C++ AstPackage structure.

C++ Reference: parser.hpp:193-215 - struct AstPackage
*/

import "core:container/queue"
import "core:odin/ast"

// NOTE: get_package_scope and set_package_scope are defined in type_info.odin
// They have been updated to use the external map (package_scopes)

// get_package_decl_info retrieves the declaration info for a package
// C++ Reference: parser.hpp:213 - DeclInfo *decl_info
// NOTE: Cannot use pkg.decl_info directly because ast.Package.decl_info has type ^ast.Decl_Info,
// while checker uses ^Decl_Info. External map required until type unification.
get_package_decl_info :: proc(info: ^Checker_Info, pkg: ^ast.Package) -> ^Decl_Info {
	if pkg == nil {
		return nil
	}
	// Use external map (package_decl_infos in Checker_Info)
	if decl_info, found := info.package_decl_infos[pkg]; found {
		return decl_info
	}
	return nil
}

// set_package_decl_info associates declaration info with a package
// C++ Reference: parser.hpp:213 - pkg->decl_info = decl_info
// This is typically set by the checker during package-level declaration processing
// NOTE: Cannot use pkg.decl_info directly because ast.Package.decl_info has type ^ast.Decl_Info,
// while checker uses ^Decl_Info. External map required until type unification.
set_package_decl_info :: proc(info: ^Checker_Info, pkg: ^ast.Package, decl_info: ^Decl_Info) {
	if pkg == nil {
		return
	}
	// Use external map (package_decl_infos in Checker_Info)
	info.package_decl_infos[pkg] = decl_info
}

// is_package_extra checks if a package is marked as "extra"
// C++ Reference: parser.hpp:214 - bool is_extra
// Extra packages are typically runtime or internal packages
is_package_extra :: proc(info: ^Checker_Info, pkg: ^ast.Package) -> bool {
	if pkg == nil {
		return false
	}
	return pkg.is_extra
}

// set_package_extra marks a package as "extra" or not
// C++ Reference: parser.hpp:214 - pkg->is_extra = value
set_package_extra :: proc(info: ^Checker_Info, pkg: ^ast.Package, is_extra: bool) {
	if pkg == nil {
		return
	}
	pkg.is_extra = is_extra
}

// get_package_exported_entity_queue retrieves the exported entity queue for a package
// C++ Reference: parser.hpp:209 - MPMCQueue<AstPackageExportedEntity> exported_entity_queue
// Returns a pointer to the queue stored directly on the package
get_package_exported_entity_queue :: proc(info: ^Checker_Info, pkg: ^ast.Package) -> ^queue.MPMC_Queue(ast.Package_Exported_Entity) {
	if pkg == nil {
		return nil
	}
	return &pkg.exported_entity_queue
}

// init_package_exported_entity_queue initializes the exported entity queue for a package
// C++ Reference: parser.hpp:209 - Queue is initialized when package is created
// Must be called before enqueueing any exported entities
init_package_exported_entity_queue :: proc(info: ^Checker_Info, pkg: ^ast.Package) {
	if pkg == nil {
		return
	}
	// Initialize the queue directly on the package
	queue.mpmc_init(&pkg.exported_entity_queue)
}

// enqueue_exported_entity adds an exported entity to a package's queue
// C++ Reference: parser.hpp:209 - queue.mpmc_enqueue(&pkg->exported_entity_queue, entity)
// Used during multi-threaded entity collection to track exported symbols
// The queue will be auto-initialized if needed (MPMC queue auto-grows)
enqueue_exported_entity :: proc(info: ^Checker_Info, pkg: ^ast.Package, identifier: ^ast.Node, entity: ^Entity) {
	if pkg == nil {
		return
	}

	exported := ast.Package_Exported_Entity {
		identifier = identifier,
		entity     = entity,
	}

	queue.mpmc_enqueue(&pkg.exported_entity_queue, exported)
}

// dequeue_exported_entity retrieves and removes an exported entity from a package's queue
// C++ Reference: parser.hpp:209 - queue.mpmc_dequeue(&pkg->exported_entity_queue, &entity)
// Returns true if an entity was dequeued, false if the queue is empty
// Used to process exported entities after collection phase
dequeue_exported_entity :: proc(info: ^Checker_Info, pkg: ^ast.Package) -> (exported: ast.Package_Exported_Entity, ok: bool) {
	if pkg == nil {
		return {}, false
	}
	return queue.mpmc_dequeue(&pkg.exported_entity_queue)
}


// has_exported_entities checks if a package has any exported entities in its queue
// Useful for checking if processing is needed without dequeuing
has_exported_entities :: proc(info: ^Checker_Info, pkg: ^ast.Package) -> bool {
	if pkg == nil {
		return false
	}
	return !queue.mpmc_is_empty(&pkg.exported_entity_queue)
}

// destroy_package_exported_entity_queue cleans up a package's exported entity queue
// C++ Reference: Cleanup happens during package destruction
// Should be called when the package is no longer needed
destroy_package_exported_entity_queue :: proc(info: ^Checker_Info, pkg: ^ast.Package) {
	if pkg == nil {
		return
	}
	queue.mpmc_destroy(&pkg.exported_entity_queue)
}

// NOTE: Package kind helpers (is_package_builtin, is_package_runtime, is_package_init, etc.)
// are now in build_infrastructure.odin to consolidate all package kind operations.
