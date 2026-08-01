package checker

/*
Build Infrastructure - File Flags and Package Kind Systems

This module implements helper functions for working with file flags and package kinds,
which are part of the build configuration and package management system.

C++ References:
- parser.hpp:91-98 - enum AstFileFlag
- parser.hpp:77-82 - enum PackageKind
- checker.cpp - Various usage patterns
*/

import "core:odin/ast"
import "core:slice"

// ======================================================================================
// FILE FLAGS
// C++ Reference: parser.hpp:91-98 - enum AstFileFlag
// ======================================================================================

// File flag constants are defined in checker.odin as Ast_File_Flag enum
// This module provides helper functions for working with those flags

// has_file_flag checks if a file has a specific flag set
// C++ Reference: checker.cpp:2071 - (c->file->flags & AstFile_IsLazy)
has_file_flag :: proc(info: ^Checker_Info, file: ^ast.File, flag: ast.File_Flag) -> bool {
	if file == nil {
		return false
	}
	return flag in file.flags
}

// set_file_flag sets a specific flag on a file
// C++ Reference: Direct flag assignment in C++ - file->flags |= flag
set_file_flag :: proc(info: ^Checker_Info, file: ^ast.File, flag: ast.File_Flag) {
	if file == nil {
		return
	}
	file.flags |= {flag}
}

// clear_file_flag removes a specific flag from a file
// C++ Reference: file->flags &= ~flag
clear_file_flag :: proc(info: ^Checker_Info, file: ^ast.File, flag: ast.File_Flag) {
	if file == nil {
		return
	}
	file.flags &= ~{flag}
}

// get_file_flags retrieves all flags for a file
// Returns empty set if no flags are set
get_file_flags :: proc(info: ^Checker_Info, file: ^ast.File) -> ast.File_Flags {
	if file == nil {
		return {}
	}
	return file.flags
}

// set_file_flags sets all flags for a file
// Replaces any existing flags
set_file_flags :: proc(info: ^Checker_Info, file: ^ast.File, flags: ast.File_Flags) {
	if file == nil {
		return
	}
	file.flags = flags
}

// is_file_private_to_pkg checks if file is private to package
// C++ Reference: checker.cpp:4908 - (c->scope->file->flags & AstFile_IsPrivatePkg)
is_file_private_to_pkg :: proc(info: ^Checker_Info, file: ^ast.File) -> bool {
	return has_file_flag(info, file, .Is_Private_Pkg)
}

// is_file_private checks if file is private (to file scope)
// C++ Reference: checker.cpp:4906 - (c->scope->file->flags & AstFile_IsPrivateFile)
is_file_private :: proc(info: ^Checker_Info, file: ^ast.File) -> bool {
	return has_file_flag(info, file, .Is_Private_File)
}

// is_file_lazy checks if file uses lazy compilation
// C++ Reference: checker.cpp:2071 - (c->file->flags & AstFile_IsLazy)
is_file_lazy :: proc(info: ^Checker_Info, file: ^ast.File) -> bool {
	return has_file_flag(info, file, .Is_Lazy)
}

// is_file_instrumentation_disabled checks if instrumentation is disabled for file
// C++ Reference: parser.hpp:97 - AstFile_NoInstrumentation
has_file_no_instrumentation :: proc(info: ^Checker_Info, file: ^ast.File) -> bool {
	return has_file_flag(info, file, .No_Instrumentation)
}

// mark_file_private_to_pkg marks a file as private to its package
// Used during attribute processing
mark_file_private_to_pkg :: proc(info: ^Checker_Info, file: ^ast.File) {
	set_file_flag(info, file, .Is_Private_Pkg)
}

// mark_file_private marks a file as private (file-scoped)
// Used during attribute processing
mark_file_private :: proc(info: ^Checker_Info, file: ^ast.File) {
	set_file_flag(info, file, .Is_Private_File)
}

// mark_file_lazy marks a file for lazy compilation
// Used during build configuration
mark_file_lazy :: proc(info: ^Checker_Info, file: ^ast.File) {
	set_file_flag(info, file, .Is_Lazy)
}

// disable_file_instrumentation disables instrumentation for a file
// Used during attribute processing
disable_file_instrumentation :: proc(info: ^Checker_Info, file: ^ast.File) {
	set_file_flag(info, file, .No_Instrumentation)
}

// ======================================================================================
// PACKAGE KIND HELPERS
// C++ Reference: parser.hpp:77-82 - enum PackageKind
// ======================================================================================

// Package kind is stored directly in ast.Package.kind
// These helpers provide convenient access patterns used in C++

// is_package_normal checks if package is a normal user package
// C++ Reference: pkg->kind == Package_Normal
is_package_normal :: proc(pkg: ^ast.Package) -> bool {
	if pkg == nil {
		return false
	}
	return pkg.kind == .Normal
}

// is_package_runtime checks if package is the runtime package
// C++ Reference: checker.cpp:271 - pkg->kind == Package_Runtime
// Used to enable special runtime-only features
is_package_runtime :: proc(pkg: ^ast.Package) -> bool {
	if pkg == nil {
		return false
	}
	return pkg.kind == .Runtime
}

// is_package_init checks if package is an init package (requires info for fullpath check)
// C++ Reference: checker.cpp:267 - pkg->fullpath == c->checker->parser->init_fullpath || pkg->kind == Package_Init
// Init packages contain the main() entry point
is_package_init :: proc(info: ^Checker_Info, pkg: ^ast.Package) -> bool {
	if pkg == nil {
		return false
	}
	// Check both fullpath match and Package_Init kind for complete detection
	return pkg.fullpath == info.init_fullpath || pkg.kind == .Init
}

// NOTE: there is deliberately no `is_package_init_simple`. A kind-only variant
// (`pkg.kind == .Init`, without the fullpath half of C++ checker.cpp:267) is
// unconditionally FALSE in this port: nothing ever assigns `pkg.kind = .Init` --
// the init package is identified solely by `info.init_fullpath`, set in
// check_files.odin. Such a helper is a trap for a future caller, not a shortcut.
// Use is_package_init(info, pkg).

// is_package_builtin checks if package is the builtin package
// C++ Reference: checker.cpp:1035 - pkg->kind = Package_Builtin
// NOTE: Odin's ast.Package_Kind lacks a Builtin variant
// Workaround: Check package name since builtin is always named "builtin"
is_package_builtin :: proc(pkg: ^ast.Package) -> bool {
	if pkg == nil {
		return false
	}
	// Odin doesn't have .Builtin in Package_Kind enum
	// Use name-based detection as fallback
	return pkg.name == "builtin"
}

// is_package_special checks if package is runtime, init, or builtin (with fullpath check)
// Convenience function for checking if special handling is needed
is_package_special :: proc(info: ^Checker_Info, pkg: ^ast.Package) -> bool {
	return is_package_runtime(pkg) || is_package_init(info, pkg) || is_package_builtin(pkg)
}

// get_package_kind_name returns human-readable package kind name
// Useful for diagnostics and error messages
get_package_kind_name :: proc(pkg: ^ast.Package) -> string {
	if pkg == nil {
		return "nil"
	}

	if is_package_builtin(pkg) {
		return "builtin"
	}

	switch pkg.kind {
	case .Normal:
		return "normal"
	case .Runtime:
		return "runtime"
	case .Init:
		return "init"
	case:
		return "unknown"
	}
}

// ======================================================================================
// COMBINED HELPERS - File and Package Context
// ======================================================================================

// is_in_runtime_package checks if a file belongs to the runtime package
// C++ Reference: checker.cpp:4578 - c->scope->file->pkg->kind == Package_Runtime
is_in_runtime_package :: proc(file: ^ast.File) -> bool {
	if file == nil || file.pkg == nil {
		return false
	}
	return is_package_runtime(file.pkg)
}

// is_in_init_package checks if a file belongs to an init package (requires info for fullpath check)
// C++ Reference: checker.cpp:267 - pkg->fullpath == c->checker->parser->init_fullpath || pkg->kind == Package_Init
is_in_init_package :: proc(info: ^Checker_Info, file: ^ast.File) -> bool {
	if file == nil || file.pkg == nil {
		return false
	}
	pkg := file.pkg
	// Check both fullpath match and Package_Init kind for complete detection
	return pkg.fullpath == info.init_fullpath || pkg.kind == .Init
}

// is_in_builtin_package checks if a file belongs to the builtin package
is_in_builtin_package :: proc(file: ^ast.File) -> bool {
	if file == nil || file.pkg == nil {
		return false
	}
	return is_package_builtin(file.pkg)
}

// should_check_file determines if a file should be type-checked
// Lazy files are skipped unless explicitly needed
// C++ Reference: checker.cpp:1878 - if (c->file != nullptr && (c->file->flags & AstFile_IsLazy) != 0)
should_check_file :: proc(info: ^Checker_Info, file: ^ast.File) -> bool {
	if file == nil {
		return false
	}

	// Skip lazy files
	if is_file_lazy(info, file) {
		return false
	}

	return true
}

// ======================================================================================
// VET FLAGS AND FEATURE FLAGS
// C++ Reference: parser.hpp:128-131
// ======================================================================================

// has_vet_flags checks if file has vet flags set
// C++ Reference: parser.hpp:130 - bool vet_flags_set
has_vet_flags :: proc(info: ^Checker_Info, file: ^ast.File) -> bool {
	if file == nil {
		return false
	}
	return file.vet_flags_set
}

// get_vet_flags retrieves vet flags for a file
// Returns empty set if no vet flags are set
// C++ Reference: parser.hpp:128 - u64 vet_flags
get_vet_flags :: proc(info: ^Checker_Info, file: ^ast.File) -> ast.Vet_Flags {
	if file == nil {
		return {}
	}
	if !has_vet_flags(info, file) {
		return {}
	}
	return file.vet_flags
}

// set_vet_flags sets vet flags for a file
// C++ Reference: Direct assignment - file->vet_flags = flags; file->vet_flags_set = true
set_vet_flags :: proc(info: ^Checker_Info, file: ^ast.File, flags: ast.Vet_Flags) {
	if file == nil {
		return
	}
	file.vet_flags = flags
	file.vet_flags_set = true
}

// clear_vet_flags removes vet flags from a file
clear_vet_flags :: proc(info: ^Checker_Info, file: ^ast.File) {
	if file == nil {
		return
	}
	file.vet_flags = {}
	file.vet_flags_set = false
}

// has_feature_flags checks if file has feature flags set
// C++ Reference: parser.hpp:131 - bool feature_flags_set
has_feature_flags :: proc(info: ^Checker_Info, file: ^ast.File) -> bool {
	if file == nil {
		return false
	}
	return file.feature_flags_set
}

// get_feature_flags retrieves feature flags for a file
// Returns empty set if no feature flags are set
// C++ Reference: parser.hpp:129 - u64 feature_flags
get_feature_flags :: proc(info: ^Checker_Info, file: ^ast.File) -> ast.Feature_Flags {
	if file == nil {
		return {}
	}
	if !has_feature_flags(info, file) {
		return {}
	}
	return file.feature_flags
}

// set_feature_flags sets feature flags for a file
// C++ Reference: Direct assignment - file->feature_flags = flags; file->feature_flags_set = true
set_feature_flags :: proc(info: ^Checker_Info, file: ^ast.File, flags: ast.Feature_Flags) {
	if file == nil {
		return
	}
	file.feature_flags = flags
	file.feature_flags_set = true
}

// clear_feature_flags removes feature flags from a file
clear_feature_flags :: proc(info: ^Checker_Info, file: ^ast.File) {
	if file == nil {
		return
	}
	file.feature_flags = {}
	file.feature_flags_set = false
}

// ======================================================================================
// VISIBILITY HELPERS
// ======================================================================================

// Entity_Visibility determines export scope based on file/package flags
// C++ Reference: checker.cpp:4569-4573 - Visibility calculation
Entity_Visibility :: enum {
	Public, // Exported from package
	Private_To_Package, // Private to package (@private)
	Private_To_File, // Private to file (@private="file")
}

// get_file_default_visibility determines default visibility for entities in a file
// C++ Reference: checker.cpp:4569-4573
// - AstFile_IsPrivateFile -> Private to file
// - AstFile_IsPrivatePkg -> Private to package
// - else -> Public
get_file_default_visibility :: proc(info: ^Checker_Info, file: ^ast.File) -> Entity_Visibility {
	if file == nil {
		return .Public
	}

	// Check file-level privacy first (most restrictive)
	if is_file_private(info, file) {
		return .Private_To_File
	}

	// Check package-level privacy
	if is_file_private_to_pkg(info, file) {
		return .Private_To_Package
	}

	// Default is public
	return .Public
}

// ======================================================================================
// PACKAGE FILTERING
// ======================================================================================

// PackageFilter is a predicate function for filtering packages
Package_Filter :: #type proc(pkg: ^ast.Package) -> bool

// filter_packages returns all packages matching a predicate
filter_packages :: proc(info: ^Checker_Info, predicate: Package_Filter) -> [dynamic]^ast.Package {
	result := make([dynamic]^ast.Package)
	for pkg in sorted_packages(info) {
		if predicate(pkg) {
			append(&result, pkg)
		}
	}
	return result
}

// get_normal_packages returns all normal user packages
get_normal_packages :: proc(info: ^Checker_Info) -> [dynamic]^ast.Package {
	return filter_packages(info, is_package_normal)
}

// get_special_packages returns all special packages (runtime, init, builtin)
// Includes fullpath checking for init packages
get_special_packages :: proc(info: ^Checker_Info) -> [dynamic]^ast.Package {
	result := make([dynamic]^ast.Package)
	for pkg in sorted_packages(info) {
		if is_package_special(info, pkg) {
			append(&result, pkg)
		}
	}
	return result
}


// ======================================================================================
// DETERMINISTIC ITERATION
// ======================================================================================
//
// Checker_Info stores packages and files in `map`s. Odin derives a map's hash seed from the
// map's DATA POINTER (base/runtime/dynamic_map_internal.odin:198-205), so with ASLR the
// iteration order of any map differs on every run of the same binary. In the checker that
// reorders entity resolution, which changes which cascades fire - measured on core/log as
// 542 vs 717 diagnostics across runs, with the diagnostic SETS differing, not just their order.
//
// The C++ checker does not have this problem: it keeps packages and files in Arrays appended in
// deterministic order, and sorts explicitly where an order is required (checker.cpp:6052
// `array_sort(pkg->files, sort_file_by_name)`).
//
// Any order-sensitive walk over info.packages / info.files must go through these helpers.
// The returned slices use the temp allocator by default.

// register_package inserts a package under `key` and records its discovery order.
// Every write to info.packages must go through here so packages_ordered stays complete.
register_package :: proc(info: ^Checker_Info, key: string, pkg: ^ast.Package) {
	if pkg == nil {
		return
	}
	if _, existed := info.packages[key]; !existed {
		info.packages[key] = pkg
		// A package can be reachable under more than one key (import path vs resolved path);
		// only record it once in the ordering.
		for p in info.packages_ordered {
			if p == pkg {
				return
			}
		}
		append(&info.packages_ordered, pkg)
	}
}

// sorted_packages returns the packages in discovery order, matching C++'s walk over the
// `parser->packages` Array. Falls back to sorting by fullpath for any package that predates the
// ordered registry, so the result is deterministic either way.
//
// NOTE: do NOT sort by pkg.order here. That field is only assigned in check_import_entities
// (check_import_export.odin:293, from the topologically sorted import graph), which runs AFTER
// create_package_scopes, check_create_file_scopes and check_collect_entities_all - so during those
// passes every pkg.order is still 0 and sorting on it degenerates to alphabetical.
sorted_packages :: proc(info: ^Checker_Info, allocator := context.temp_allocator) -> []^ast.Package {
	out := make([dynamic]^ast.Package, 0, len(info.packages), allocator)
	seen := make(map[^ast.Package]bool, len(info.packages), allocator)
	for pkg in info.packages_ordered {
		if pkg != nil && !(pkg in seen) {
			seen[pkg] = true
			append(&out, pkg)
		}
	}
	// Any package registered without going through register_package.
	rest := make([dynamic]^ast.Package, 0, len(info.packages), allocator)
	for _, pkg in info.packages {
		if pkg != nil && !(pkg in seen) {
			seen[pkg] = true
			append(&rest, pkg)
		}
	}
	slice.sort_by(rest[:], proc(a, b: ^ast.Package) -> bool {
		return a.fullpath < b.fullpath
	})
	append(&out, ..rest[:])
	return out[:]
}

// sorted_files returns the files in a stable order.
// C++ Reference: checker.cpp:6040-6046 (sort_file_by_name) sorts on the BASENAME, not the full
// path; fullpath is the tie-break here so files sharing a basename across directories are still
// ordered deterministically.
sorted_files :: proc(files: map[string]^ast.File, allocator := context.temp_allocator) -> []^ast.File {
	out := make([dynamic]^ast.File, 0, len(files), allocator)
	for _, file in files {
		if file != nil {
			append(&out, file)
		}
	}
	slice.sort_by(out[:], proc(a, b: ^ast.File) -> bool {
		a_name := filename_from_path(a.fullpath)
		b_name := filename_from_path(b.fullpath)
		if a_name != b_name {
			return a_name < b_name
		}
		return a.fullpath < b.fullpath
	})
	return out[:]
}
