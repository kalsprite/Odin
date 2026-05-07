package checker

/*
Package Resolver for the Odin Checker

This module handles recursive package loading and import path resolution.
It enables the checker to work on real codebases by:
1. Resolving import paths like "core:fmt" to filesystem paths
2. Parsing imported packages recursively
3. Adding packages to the checker's package map

C++ Reference: The C++ compiler handles this in the parser phase before
checking. Our implementation does it as a pre-check step.
*/

import "base:runtime"

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:odin/ast"
import "core:odin/parser"

// resolve_import_path converts an import path to a filesystem path
// Examples:
//   "core:fmt"     -> ODIN_ROOT/core/fmt
//   "base:runtime" -> ODIN_ROOT/base/runtime
//   "vendor:raylib" -> ODIN_ROOT/vendor/raylib
//   "./relative"   -> current_pkg_dir/relative
//   "../parent"    -> current_pkg_dir/../parent
resolve_import_path :: proc(import_path_raw: string, current_pkg_path: string, allocator := context.temp_allocator) -> (fullpath: string, ok: bool) {
	if len(import_path_raw) == 0 {
		return "", false
	}

	// Strip quotes from the import path (parser may include them)
	import_path := import_path_raw
	if len(import_path) >= 2 && import_path[0] == '"' && import_path[len(import_path) - 1] == '"' {
		import_path = import_path[1:len(import_path) - 1]
	}

	// Check for collection path (contains colon, not Windows drive letter)
	colon_idx := strings.index_byte(import_path, ':')
	if colon_idx > 0 {
		// Check if it's a Windows drive letter (single letter before colon)
		if colon_idx == 1 && len(import_path) > 2 && (import_path[2] == '/' || import_path[2] == '\\') {
			// Windows absolute path like "C:/path"
			return import_path, true
		}

		// Collection path like "core:fmt" or "base:runtime"
		collection := import_path[:colon_idx]
		path_part := import_path[colon_idx + 1:]

		// Get ODIN_ROOT
		odin_root := build_context.ODIN_ROOT
		if len(odin_root) == 0 {
			// Try to get from environment
			odin_root = os.get_env("ODIN_ROOT", allocator)
		}

		if len(odin_root) == 0 {
			return "", false
		}

		// Build: ODIN_ROOT/collection/path
		fullpath = filepath.join({odin_root, collection, path_part}, allocator)
		return fullpath, true
	}

	// Relative or absolute path
	if import_path[0] == '/' || import_path[0] == '\\' {
		// Absolute path
		return import_path, true
	}

	if strings.has_prefix(import_path, "./") || strings.has_prefix(import_path, "../") {
		// Relative to current package
		if len(current_pkg_path) == 0 {
			return "", false
		}
		fullpath = filepath.join({current_pkg_path, import_path}, allocator)
		// Clean the path to resolve ../ and ./
		fullpath, ok = filepath.abs(fullpath, allocator)
		return fullpath, ok
	}

	// Just a name - treat as relative to current package
	if len(current_pkg_path) > 0 {
		fullpath = filepath.join({current_pkg_path, import_path}, allocator)
		return fullpath, true
	}

	return import_path, true
}

// Package_Load_Result contains the result of loading packages
Package_Load_Result :: struct {
	packages:     [dynamic]^ast.Package,
	parse_errors: int,
	total_files:  int,
}

// Reserved packages that are handled by the compiler, not regular parsing
// These packages use reserved names and/or require compiler-specific handling
RESERVED_PACKAGES :: []string{
	"builtin",
	"intrinsics",
	"runtime",
	"base:builtin",
	"base:intrinsics",
	"base:runtime",
}

// is_reserved_package checks if an import path refers to a reserved/builtin package
is_reserved_package :: proc(import_path: string) -> bool {
	for reserved in RESERVED_PACKAGES {
		if import_path == reserved {
			return true
		}
	}
	return false
}

// Package_To_Load tracks a package with both its import path and filesystem path
Package_To_Load :: struct {
	import_path: string, // The original import path like "core:fmt"
	fullpath:    string, // The resolved filesystem path
}

// load_package_with_dependencies loads a package and all its imported dependencies
// Returns all packages in dependency order (dependencies before dependents)
load_package_with_dependencies :: proc(
	root_path: string,
	info: ^Checker_Info,
	allocator := context.allocator,
) -> (result: Package_Load_Result, ok: bool) {
	result.packages = make([dynamic]^ast.Package, allocator)

	// Track loaded packages by filesystem path to avoid duplicates
	loaded := make(map[string]^ast.Package)
	defer delete(loaded)

	// Queue of packages to load (with both import and filesystem paths)
	to_load := make([dynamic]Package_To_Load, allocator)
	defer delete(to_load)

	// Start with root package
	root_fullpath, root_ok := filepath.abs(root_path)
	if !root_ok {
		return result, false
	}
	// Root package has empty import path (it's the target, not an import)
	append(&to_load, Package_To_Load{import_path = "", fullpath = root_fullpath})

	// Process queue
	for len(to_load) > 0 {
		pkg_to_load := pop_front(&to_load)
		pkg_path := pkg_to_load.fullpath
		import_path := pkg_to_load.import_path

		// Skip if already loaded
		if pkg_path in loaded {
			continue
		}

		// Parse the package
		pkg, parse_ok := parser.parse_package_from_path(pkg_path)
		if !parse_ok || pkg == nil {
			result.parse_errors += 1
			continue
		}

		// Register the package
		loaded[pkg_path] = pkg
		append(&result.packages, pkg)
		result.total_files += len(pkg.files)

		// Register in info.packages for the checker using the IMPORT path
		// The checker looks up packages by their import path (like "core:fmt")
		if info != nil {
			// Register by import path if we have one
			if len(import_path) > 0 {
				info.packages[import_path] = pkg
			}
			// Also register by fullpath as a fallback
			info.packages[pkg_path] = pkg
		}

		// Find and queue all imports
		for _, file in pkg.files {
			for decl in file.decls {
				if import_decl, is_import := decl.derived.(^ast.Import_Decl); is_import {
					child_import_path := import_decl.fullpath

					// Strip quotes from the import path (parser may include them)
					// This ensures consistency between registration and lookup
					stripped_path := child_import_path
					if len(stripped_path) >= 2 && stripped_path[0] == '"' {
						stripped_path = stripped_path[1:len(stripped_path) - 1]
					}

					// Skip reserved/builtin packages - they're handled by the compiler
					if is_reserved_package(stripped_path) {
						continue
					}

					child_fullpath, resolve_ok := resolve_import_path(child_import_path, pkg_path, allocator)
					if resolve_ok && !(child_fullpath in loaded) {
						// Check if the path exists
						if os.is_dir(child_fullpath) {
							// Use the stripped (unquoted) path for registration
							// This matches how check_import_export looks up packages
							append(&to_load, Package_To_Load{
								import_path = stripped_path,
								fullpath    = child_fullpath,
							})
						}
					}
				}
			}
		}
	}

	ok = result.parse_errors == 0
	return result, ok
}

// init_odin_root_from_env initializes ODIN_ROOT from environment if not set
// Falls back to auto-detection from current working directory
// Uses heap allocator to ensure the string persists across temp allocator resets
init_odin_root_from_env :: proc() {
	if len(build_context.ODIN_ROOT) == 0 {
		// Use heap allocator for persistent storage - tests may use temp_allocator
		// which would cause ODIN_ROOT to become garbage after the test completes
		persistent_allocator := context.allocator
		if context.allocator == context.temp_allocator {
			persistent_allocator = runtime.heap_allocator()
		}

		if odin_root := os.get_env("ODIN_ROOT", persistent_allocator); len(odin_root) > 0 {
			build_context.ODIN_ROOT = odin_root
			return
		}

		// Auto-detect ODIN_ROOT by looking for base/runtime in current or parent directories
		// This enables tests to run without ODIN_ROOT being explicitly set
		cwd := os.get_current_directory(persistent_allocator)
		if len(cwd) > 0 {
			// Check if base/runtime exists in cwd (we're at ODIN_ROOT)
			runtime_path := filepath.join({cwd, "base", "runtime"}, persistent_allocator)
			if os.is_dir(runtime_path) {
				build_context.ODIN_ROOT = cwd
				return
			}

			// Walk up parent directories to find ODIN_ROOT
			dir := cwd
			for i := 0; i < 10; i += 1 { // Limit depth to avoid infinite loop
				parent := filepath.dir(dir, persistent_allocator)
				if parent == dir || len(parent) == 0 {
					break
				}
				runtime_path = filepath.join({parent, "base", "runtime"}, persistent_allocator)
				if os.is_dir(runtime_path) {
					build_context.ODIN_ROOT = parent
					return
				}
				dir = parent
			}
		}
	}
}

// check_package_from_path is a convenience function that loads and checks a package
// This handles all the setup needed to check real code
check_package_from_path :: proc(path: string, allocator := context.allocator) -> (ok: bool, parse_errors: int, check_errors: int) {
	// Initialize ODIN_ROOT from environment if needed
	init_odin_root_from_env()

	// Initialize error collector FIRST - needed by checker initialization
	init_error_collector(1000)
	defer destroy_error_collector()

	// Create checker
	c := &Checker{}
	init_checker(c, allocator)
	defer destroy_checker(c)

	// Load package and dependencies
	load_result, _ := load_package_with_dependencies(path, &c.info, allocator)
	parse_errors = load_result.parse_errors

	// Collect all files from all packages (even if some failed to parse)
	files := make([dynamic]^ast.File, allocator)
	defer delete(files)

	for pkg in load_result.packages {
		for _, file in pkg.files {
			append(&files, file)
		}
	}

	// Run the checker
	result := check_files(c, files[:])
	check_errors = error_count()

	return result && check_errors == 0 && parse_errors == 0, parse_errors, check_errors
}
