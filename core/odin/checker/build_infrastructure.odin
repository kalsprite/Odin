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

// ======================================================================================
// FILE FLAGS
// C++ Reference: parser.hpp:91-98 - enum AstFileFlag
// ======================================================================================

// File flag constants are defined in checker.odin as Ast_File_Flag enum
// This module provides helper functions for working with those flags

// has_file_flag checks if a file has a specific flag set
// C++ Reference: checker.cpp:1878 - (c->file->flags & AstFile_IsLazy)
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
// C++ Reference: checker.cpp:4571 - (c->scope->file->flags & AstFile_IsPrivatePkg)
is_file_private_to_pkg :: proc(info: ^Checker_Info, file: ^ast.File) -> bool {
	return has_file_flag(info, file, .Is_Private_Pkg)
}

// is_file_private checks if file is private (to file scope)
// C++ Reference: checker.cpp:4569 - (c->scope->file->flags & AstFile_IsPrivateFile)
is_file_private :: proc(info: ^Checker_Info, file: ^ast.File) -> bool {
	return has_file_flag(info, file, .Is_Private_File)
}

// is_file_lazy checks if file uses lazy compilation
// C++ Reference: checker.cpp:1878 - (c->file->flags & AstFile_IsLazy)
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

// is_package_init_simple is a simplified version without fullpath checking
// Use is_package_init() with Checker_Info for complete checking
is_package_init_simple :: proc(pkg: ^ast.Package) -> bool {
	if pkg == nil {
		return false
	}
	return pkg.kind == .Init
}

// is_package_builtin checks if package is the builtin package
// C++ Reference: checker.cpp:1003 - pkg->kind = Package_Builtin
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

// is_package_special_simple is a simplified version without fullpath checking
// Use is_package_special() with Checker_Info for complete checking
is_package_special_simple :: proc(pkg: ^ast.Package) -> bool {
	return is_package_runtime(pkg) || is_package_init_simple(pkg) || is_package_builtin(pkg)
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
// C++ Reference: checker.cpp:4243 - c->scope->file->pkg->kind == Package_Runtime
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

// is_in_init_package_simple is a simplified version without fullpath checking
// Use is_in_init_package() with Checker_Info for complete checking
is_in_init_package_simple :: proc(file: ^ast.File) -> bool {
	if file == nil || file.pkg == nil {
		return false
	}
	return is_package_init_simple(file.pkg)
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
	for _, pkg in info.packages {
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
	for _, pkg in info.packages {
		if is_package_special(info, pkg) {
			append(&result, pkg)
		}
	}
	return result
}
