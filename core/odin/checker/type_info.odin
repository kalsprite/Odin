package checker

/*
Runtime Type Information (RTTI) infrastructure.

This module implements the type information system that powers `type_info_of()`
and `typeid_of()` builtins. It generates compile-time type metadata tables for
runtime reflection.

C++ Reference: checker.cpp:3253-3395
               checker.cpp:2085-2335

*/

import "core:fmt"
import "core:odin/ast"
import "core:slice"
import "core:sync"

// ======================================================================================
// INITIALIZATION
// C++ Reference: checker.cpp:3253-3388
// ======================================================================================

// init_core_type_info initializes the RTTI system
// C++ Reference: checker.cpp:3253-3319
//
// This function:
// 1. Looks up Type_Info struct from core:runtime
// 2. Initializes all Type_Info variant types
// 3. Sets up global type singletons (t_type_info, t_type_info_ptr, etc.)
//
// Must be called before any type_info_of() or typeid_of() usage
init_core_type_info :: proc(c: ^Checker) {
	// Protect initialization with mutex to prevent races when tests run in parallel
	sync.mutex_lock(&runtime_type_globals_mutex)
	defer sync.mutex_unlock(&runtime_type_globals_mutex)

	// Early return if already initialized (C++ line 3254-3256)
	// This check must be inside the mutex to prevent double initialization
	if c.t_type_info != nil {
		return
	}

	// Find Type_Info entity from core:runtime (C++ line 3257)
	type_info_entity := find_core_entity(c, "Type_Info")
	if type_info_entity == nil {
		// Runtime package not loaded - skip type info initialization
		return
	}

	// Ensure the entity's type is checked (C++ line 3259-3261)
	if type_info_entity.type == nil {
		check_single_global_entity(c, type_info_entity, type_info_entity.decl_info)
	}
	// If still nil after check, we have extracted runtime types without full resolution
	if type_info_entity.type == nil {
		return
	}

	// Initialize core type info globals (C++ line 3264-3266)
	c.t_type_info = type_info_entity.type
	c.t_type_info_ptr = alloc_type_pointer(c.t_type_info)

	// Verify Type_Info is a struct (C++ line 3266-3267)
	if !is_type_struct(type_info_entity.type) {
		// Extracted runtime may not have proper type info - skip validation
		return
	}
	tis := base_type(type_info_entity.type).variant.(Type_Struct)

	// Validate Type_Info struct layout (C++ line 3274)
	// Type_Info has 5 fields: id, size, align, flags, variant
	if len(tis.fields) != 5 {
		// Extracted runtime may not have all fields - skip validation
		return
	}

	// Find Type_Info_Enum_Value (C++ line 3269-3272)
	type_info_enum_value := find_core_entity(c, "Type_Info_Enum_Value")
	if type_info_enum_value != nil && type_info_enum_value.type != nil {
		c.t_type_info_enum_value = type_info_enum_value.type
		c.t_type_info_enum_value_ptr = alloc_type_pointer(c.t_type_info_enum_value)
	}

	// Find Type_Info_String_Encoding_Kind (C++ line 3276-3277)
	type_info_string_encoding_kind := find_core_entity(c, "Type_Info_String_Encoding_Kind")
	if type_info_string_encoding_kind != nil {
		c.t_type_info_string_encoding_kind = type_info_string_encoding_kind.type
	}

	// Verify variant field is a union (C++ line 3279-3281)
	type_info_variant := tis.fields[4]
	tiv_type := type_info_variant.type
	if !is_type_union(tiv_type) {
		// Extracted runtime has placeholder field types - skip full initialization
		return
	}

	// Find all Type_Info variant types from core:runtime (C++ line 3283-3319)
	// These are the actual type info structures for different type kinds
	c.t_type_info_named = find_core_type(c, "Type_Info_Named")
	c.t_type_info_integer = find_core_type(c, "Type_Info_Integer")
	c.t_type_info_rune = find_core_type(c, "Type_Info_Rune")
	c.t_type_info_float = find_core_type(c, "Type_Info_Float")
	c.t_type_info_quaternion = find_core_type(c, "Type_Info_Quaternion")
	c.t_type_info_complex = find_core_type(c, "Type_Info_Complex")
	c.t_type_info_string = find_core_type(c, "Type_Info_String")
	c.t_type_info_boolean = find_core_type(c, "Type_Info_Boolean")
	c.t_type_info_any = find_core_type(c, "Type_Info_Any")
	c.t_type_info_typeid = find_core_type(c, "Type_Info_Type_Id")
	c.t_type_info_pointer = find_core_type(c, "Type_Info_Pointer")
	c.t_type_info_multi_pointer = find_core_type(c, "Type_Info_Multi_Pointer")
	c.t_type_info_procedure = find_core_type(c, "Type_Info_Procedure")
	c.t_type_info_array = find_core_type(c, "Type_Info_Array")
	c.t_type_info_enumerated_array = find_core_type(c, "Type_Info_Enumerated_Array")
	c.t_type_info_dynamic_array = find_core_type(c, "Type_Info_Dynamic_Array")
	c.t_type_info_slice = find_core_type(c, "Type_Info_Slice")
	c.t_type_info_parameters = find_core_type(c, "Type_Info_Parameters")
	c.t_type_info_struct = find_core_type(c, "Type_Info_Struct")
	c.t_type_info_union = find_core_type(c, "Type_Info_Union")
	c.t_type_info_enum = find_core_type(c, "Type_Info_Enum")
	c.t_type_info_map = find_core_type(c, "Type_Info_Map")
	c.t_type_info_bit_set = find_core_type(c, "Type_Info_Bit_Set")
	c.t_type_info_simd_vector = find_core_type(c, "Type_Info_Simd_Vector")
	c.t_type_info_matrix = find_core_type(c, "Type_Info_Matrix")
	c.t_type_info_soa_pointer = find_core_type(c, "Type_Info_Soa_Pointer")
	c.t_type_info_bit_field = find_core_type(c, "Type_Info_Bit_Field")

	// LEDGER #577 tail. C++ closes init_core_type_info with exactly this block
	// (checker.cpp init_core_type_info:3539-3566); the port declared all 27 globals, RESET them, and never assigned
	// one -- found by resetaudit.py, not by reading.
	//
	// They have NO reader in this port, and only one in the reference: llvm_backend_stmt.cpp.
	// (Measured: of 29 `t_type_info_*_ptr` occurrences in checker.cpp, all 29 are assignments.)
	// They are carried anyway because they are checker-WRITTEN state that a backend consumer
	// reaches through the model -- mir is a real such consumer -- and because a global that is
	// declared and reset but never written is indistinguishable from a defect until someone
	// re-derives this, which is the cost #577 already paid once.
	c.t_type_info_named_ptr = alloc_type_pointer(c.t_type_info_named)
	c.t_type_info_integer_ptr = alloc_type_pointer(c.t_type_info_integer)
	c.t_type_info_rune_ptr = alloc_type_pointer(c.t_type_info_rune)
	c.t_type_info_float_ptr = alloc_type_pointer(c.t_type_info_float)
	c.t_type_info_quaternion_ptr = alloc_type_pointer(c.t_type_info_quaternion)
	c.t_type_info_complex_ptr = alloc_type_pointer(c.t_type_info_complex)
	c.t_type_info_string_ptr = alloc_type_pointer(c.t_type_info_string)
	c.t_type_info_boolean_ptr = alloc_type_pointer(c.t_type_info_boolean)
	c.t_type_info_any_ptr = alloc_type_pointer(c.t_type_info_any)
	c.t_type_info_typeid_ptr = alloc_type_pointer(c.t_type_info_typeid)
	c.t_type_info_pointer_ptr = alloc_type_pointer(c.t_type_info_pointer)
	c.t_type_info_multi_pointer_ptr = alloc_type_pointer(c.t_type_info_multi_pointer)
	c.t_type_info_procedure_ptr = alloc_type_pointer(c.t_type_info_procedure)
	c.t_type_info_array_ptr = alloc_type_pointer(c.t_type_info_array)
	c.t_type_info_enumerated_array_ptr = alloc_type_pointer(c.t_type_info_enumerated_array)
	c.t_type_info_dynamic_array_ptr = alloc_type_pointer(c.t_type_info_dynamic_array)
	c.t_type_info_slice_ptr = alloc_type_pointer(c.t_type_info_slice)
	c.t_type_info_parameters_ptr = alloc_type_pointer(c.t_type_info_parameters)
	c.t_type_info_struct_ptr = alloc_type_pointer(c.t_type_info_struct)
	c.t_type_info_union_ptr = alloc_type_pointer(c.t_type_info_union)
	c.t_type_info_enum_ptr = alloc_type_pointer(c.t_type_info_enum)
	c.t_type_info_map_ptr = alloc_type_pointer(c.t_type_info_map)
	c.t_type_info_bit_set_ptr = alloc_type_pointer(c.t_type_info_bit_set)
	c.t_type_info_simd_vector_ptr = alloc_type_pointer(c.t_type_info_simd_vector)
	c.t_type_info_matrix_ptr = alloc_type_pointer(c.t_type_info_matrix)
	c.t_type_info_soa_pointer_ptr = alloc_type_pointer(c.t_type_info_soa_pointer)
	c.t_type_info_bit_field_ptr = alloc_type_pointer(c.t_type_info_bit_field)

	// NOT ported, and the absence is CONSISTENT rather than half-done: C++ also resolves
	// Type_Info_Fixed_Capacity_Dynamic_Array here (checker.cpp init_core_type_info:3537) and its pointer (:3566). The
	// port declares NEITHER the base nor the pointer, so there is no dangling half. The type does
	// exist in base/runtime (core.odin:230), so this is a genuine gap rather than a stale C++
	// reference -- it is just an inert one, with no reader on either side of the port. Filed on
	// #577's tail rather than added here, because adding it means a new find_core_type lookup
	// whose failure mode has not been measured.
}

// ======================================================================================
// DEPENDENCY TRACKING
// C++ Reference: checker.cpp:871-884, 2085-2335
// ======================================================================================

// add_type_info_dependency tracks that a declaration depends on a type's RTTI
// C++ Reference: checker.cpp:871-884
//
// This is used to track which types need RTTI generation. When a type is used
// in type_info_of() or typeid_of(), we record that dependency for later codegen.
add_type_info_dependency :: proc(info: ^Checker_Info, decl: ^Decl_Info, t: ^Type) {
	if decl == nil || t == nil {
		return
	}

	// Unwrap type aliases to track the underlying type (C++ line 875-880)
	actual_type := t
	if t.kind == .Named {
		named := t.variant.(Type_Named)
		// Check if this is a type alias (not distinct)
		// C++ line 876-878: if (e->TypeName.is_type_alias) { type = type->Named.base; }
		if named.type_name != nil {
			if type_name_entity, ok := &named.type_name.variant.(Entity_Type_Name); ok {
				if type_name_entity.is_type_alias {
					// It's a type alias, unwrap to base type
					actual_type = named.base
				}
			}
		}
	}

	// Thread-safe insertion into type_info_deps (C++ line 881-883)
	// During single-threaded initialization phase, skip locking to avoid issues
	// with recursive calls from add_type_info_type_internal
	// NOTE: the unlock must be deferred from THIS scope, not from inside the `if`. Odin's `defer`
	// is scope-scoped, so a `defer` written inside the `if` fires at that block's closing brace -
	// releasing the lock before the map write below and leaving the critical section empty.
	locked := !in_single_threaded_checker_stage()
	if locked {
		sync.rw_mutex_lock(&decl.type_info_deps_mutex)
	}
	defer if locked {
		sync.rw_mutex_unlock(&decl.type_info_deps_mutex)
	}

	decl.type_info_deps[actual_type] = {}
}

// add_type_info_type registers a type for RTTI generation
// C++ Reference: checker.cpp:2086-2102
//
// This is the public entry point for type registration. It:
// 1. Validates the type is eligible for RTTI
// 2. Calls internal registration to handle dependencies
add_type_info_type :: proc(ctx: ^Checker_Context, t: ^Type) {
	// Check for build flag disabling RTTI (C++ line 2087-2089)
	if ctx.info.build_context != nil && ctx.info.build_context.no_rtti {
		return
	}

	if t == nil {
		return
	}

	// If runtime types not initialized, skip RTTI registration
	// This can happen during early checking before init_preload runs
	// C++ doesn't need this check since globals persist for process lifetime
	if ctx.checker.t_type_info == nil {
		return
	}

	// Get default type (handles untyped types) (C++ line 2093)
	actual_type := default_type(t)

	// Skip untyped types (could be nil) (C++ line 2094-2096)
	if is_type_untyped(actual_type) {
		return
	}

	// Skip polymorphic types (C++ line 2097-2099)
	if is_type_polymorphic(actual_type) {
		return
	}

	// Register type and its dependencies (C++ line 2101)
	add_type_info_type_internal(ctx, actual_type)
}

// add_comparison_procedures_for_fields adds runtime dependencies for comparison operations
// C++ Reference: check_expr.cpp:3109-3169
//
// Called from THREE places in C++: its own Struct recursion (3164), check_comparison's accepted
// branch (3278) and add_type_info_type_internal's Struct arm (checker.cpp:2483). All three are
// wired here; the check_comparison one was missing until #547 PART 5.
//
// This function registers runtime procedure dependencies for types that require
// special comparison procedures (complex, quaternion, string types). When a type
// uses these comparison operators, we must ensure the runtime comparison functions
// are linked into the final binary.
//
// Accepts either Checker_Context or Checker as context parameter for flexibility.
add_comparison_procedures_for_fields :: proc {
	add_comparison_procedures_for_fields_ctx,
	add_comparison_procedures_for_fields_checker,
}

// Version that takes Checker_Context (used during type checking)
add_comparison_procedures_for_fields_ctx :: proc(ctx: ^Checker_Context, t: ^Type) {
	if t == nil {
		return
	}
	bt := base_type(t)
	if !is_type_comparable(t) {
		return
	}

	#partial switch bt.kind {
	case .Basic:
		basic := bt.variant.(Type_Basic)
		#partial switch basic.kind {
		case .Complex32:
			add_package_dependency(ctx, "runtime", "complex32_eq")
			add_package_dependency(ctx, "runtime", "complex32_ne")
		case .Complex64:
			add_package_dependency(ctx, "runtime", "complex64_eq")
			add_package_dependency(ctx, "runtime", "complex64_ne")
		case .Complex128:
			add_package_dependency(ctx, "runtime", "complex128_eq")
			add_package_dependency(ctx, "runtime", "complex128_ne")
		case .Quaternion64:
			add_package_dependency(ctx, "runtime", "quaternion64_eq")
			add_package_dependency(ctx, "runtime", "quaternion64_ne")
		case .Quaternion128:
			add_package_dependency(ctx, "runtime", "quaternion128_eq")
			add_package_dependency(ctx, "runtime", "quaternion128_ne")
		case .Quaternion256:
			add_package_dependency(ctx, "runtime", "quaternion256_eq")
			add_package_dependency(ctx, "runtime", "quaternion256_ne")
		case .Cstring:
			add_package_dependency(ctx, "runtime", "cstring_eq")
			add_package_dependency(ctx, "runtime", "cstring_ne")
		case .String:
			add_package_dependency(ctx, "runtime", "string_eq")
			add_package_dependency(ctx, "runtime", "string_ne")
		case .Cstring16:
			add_package_dependency(ctx, "runtime", "cstring16_eq")
			add_package_dependency(ctx, "runtime", "cstring16_ne")
		case .String16:
			add_package_dependency(ctx, "runtime", "string16_eq")
			add_package_dependency(ctx, "runtime", "string16_ne")
		}
	case .Struct:
		struct_type := bt.variant.(Type_Struct)
		for field in struct_type.fields {
			add_comparison_procedures_for_fields_ctx(ctx, field.type)
		}
	}
}

// Version that takes Checker (used during min dep tracking)
add_comparison_procedures_for_fields_checker :: proc(c: ^Checker, t: ^Type) {
	// For the Checker version, we use the builtin_ctx
	add_comparison_procedures_for_fields_ctx(&c.builtin_ctx, t)
}

// add_type_info_type_internal recursively registers types and their dependencies
// C++ Reference: checker.cpp:2104-2335
//
// This function:
// 1. Records the type dependency for the current declaration
// 2. Recursively processes nested types (pointers, arrays, structs, etc.)
// 3. Ensures all transitively required types are registered
add_type_info_type_internal :: proc(ctx: ^Checker_Context, t: ^Type) {
	if t == nil || ctx == nil {
		return
	}

	add_type_info_dependency(ctx.info, ctx.decl, t)

	// THAT IS THE WHOLE LIVE FUNCTION. C++ Reference: checker.cpp:2297-2533.
	//
	// C++ opens `#if 0` on the line AFTER add_type_info_dependency (checker.cpp add_type_info_type:2303) and closes
	// it at :2532 -- the `#endif` is the last line before the function's closing brace. So the
	// type_info_set update, the type_info_map lookup, the entire per-kind recursive walk over
	// Named/Pointer/Slice/.../Generic, and the trailing default GB_PANIC are ALL DEAD.
	//
	// The port previously implemented 269 lines here. Its own comment records the misreading:
	// it took the `#if 0` to cover only the map block and then ported the walk that follows as
	// though it were live. It also added an early return on `t in ctx.decl.type_info_deps`
	// ("avoid infinite recursion") which has no counterpart in the live C++ at all -- an
	// invention needed only to make the dead recursion terminate.
	//
	// Consequence of the old code: every nested type reachable from `t` got a type-info
	// dependency C++ never registers. Deleting it is what makes the port faithful, not a
	// simplification. #23 (BAD ENUM VALUE / use-after-free in this function) was a crash inside
	// code that should never have existed.
}

// ======================================================================================
// HELPER FUNCTIONS
// ======================================================================================

// get_package_scope retrieves the scope associated with a package
// C++ Reference: parser.hpp:212 - Scope *scope
// NOTE: Cannot use pkg.scope directly because ast.Package.scope has type ^ast.Scope,
// while checker uses ^Scope. External map required until type unification.
get_package_scope :: proc(info: ^Checker_Info, pkg: ^ast.Package) -> ^Scope {
	if pkg == nil {
		return nil
	}
	// Use external map (package_scopes in Checker_Info)
	if scope, found := info.package_scopes[pkg]; found {
		return scope
	}
	return nil
}

// set_package_scope associates a scope with a package
// C++ Reference: parser.hpp:212 - pkg->scope = scope
//
// NOTE: the claim this comment used to make - that pkg.scope could not be written because
// ast.Package.scope is ^ast.Scope while the checker uses its own ^Scope - is no longer true.
// The types are unified: checker.odin:321 declares `Scope :: ast.Scope`. The field is still
// left unwritten, but for an entirely different reason; see the PARITY GAP note in
// create_scope_from_package (scope.odin), which is where C++ writes it and where restoring it
// belongs. Consumers that read pkg.scope rather than this map - check_export_entities is the
// important one - are broken until that happens.
set_package_scope :: proc(info: ^Checker_Info, pkg: ^ast.Package, scope: ^Scope) {
	if pkg == nil {
		return
	}
	// Use external map (package_scopes in Checker_Info)
	info.package_scopes[pkg] = scope
}

// find_core_entity looks up an entity from core:runtime package
// C++ Reference: checker.cpp:3161-3169
// Returns nil if runtime package is not loaded (e.g., in tests without runtime)
find_core_entity :: proc(c: ^Checker, name: string) -> ^Entity {
	// Get runtime package (C++ line 3162)
	runtime_pkg := c.info.runtime_package
	if runtime_pkg == nil {
		return nil // Runtime package not loaded - return nil instead of panic
	}

	// Look up entity in runtime package scope (C++ line 3162)
	// NOTE: ast.Package doesn't have scope field, must get from Checker_Info.package_scopes
	// A runtime package with no scope means create_package_scopes has not run over it yet -
	// i.e. this is a check_files call that never went through Phase 1 with runtime in its file
	// list. That is the same "runtime is not usable here" condition as runtime_pkg being nil,
	// so it gets the same answer rather than taking the host process down with it. C++ can
	// dereference pkg->scope unguarded (checker.cpp:3162) because its runtime package is always
	// both present and scoped by the time init_preload runs.
	runtime_scope := get_package_scope(&c.info, runtime_pkg)
	if runtime_scope == nil {
		return nil
	}

	e := scope_lookup_current(runtime_scope, name)
	// Return nil if entity not found - may happen with extracted runtime types
	// that only include a subset of definitions
	return e
}

// find_core_type looks up a type from core:runtime package and ensures it's checked
// C++ Reference: checker.cpp:3171-3183
// Returns nil if runtime package is not loaded or entity not found
find_core_type :: proc(c: ^Checker, name: string) -> ^Type {
	// Look up entity from runtime package (C++ line 3172)
	e := find_core_entity(c, name)
	if e == nil {
		return nil // Runtime package not loaded or entity not found
	}

	// Check entity if type not yet resolved (C++ lines 3178-3180)
	if e.type == nil {
		check_single_global_entity(c, e, e.decl_info)
	}

	// Verify type was resolved (C++ line 3181)
	assert(e.type != nil, "Type is nil after checking")
	return e.type
}

// find_intrinsics_entity looks up an entity from base:intrinsics package
// C++ Reference: checker.cpp (similar to find_core_entity)
find_intrinsics_entity :: proc(c: ^Checker, name: string) -> ^Entity {
	// Get intrinsics package
	intrinsics_pkg := c.info.intrinsics_package
	if intrinsics_pkg == nil {
		return nil // Intrinsics package may not be loaded
	}

	// Look up entity in intrinsics package scope
	intrinsics_scope := get_package_scope(&c.info, intrinsics_pkg)
	if intrinsics_scope == nil {
		return nil
	}

	return scope_lookup_current(intrinsics_scope, name)
}

// find_intrinsics_type looks up a type from base:intrinsics package and ensures it's checked
// C++ Reference: checker.cpp (similar to find_core_type)
find_intrinsics_type :: proc(c: ^Checker, name: string) -> ^Type {
	e := find_intrinsics_entity(c, name)
	if e == nil {
		return nil
	}

	// Check entity if type not yet resolved
	if e.type == nil && e.decl_info != nil {
		check_single_global_entity(c, e, e.decl_info)
	}

	return e.type
}

// init_objc_types initializes the cached Objective-C types from base:intrinsics
// C++ Reference: checker.cpp (objc type initialization)
init_objc_types :: proc(c: ^Checker) {
	// Initialize objc_object struct type
	objc_object := find_intrinsics_type(c, "objc_object")
	if objc_object != nil {
		c.t_objc_object = objc_object
		c.t_objc_id = alloc_type_pointer(objc_object)
	}

	// Initialize objc_selector struct type
	objc_selector := find_intrinsics_type(c, "objc_selector")
	if objc_selector != nil {
		c.t_objc_selector = objc_selector
		c.t_objc_SEL = alloc_type_pointer(objc_selector)
	}

	// Initialize objc_class struct type
	objc_class := find_intrinsics_type(c, "objc_class")
	if objc_class != nil {
		c.t_objc_class = objc_class
		c.t_objc_Class = alloc_type_pointer(objc_class)
	}
}

// init_c_va_list_types initializes the cached C variadic types from base:intrinsics
//
// C++ builds `c_va_list` as a synthetic, platform-specific struct in init_universal
// (checker.cpp:1528-1591) and registers it into base:intrinsics itself. The port sources
// it from the package's own `c_va_list :: struct{...}` declaration instead, the same way
// init_objc_types sources objc_object; only its identity matters to the checker, since no
// field of it is ever named by user code.
init_c_va_list_types :: proc(c: ^Checker) {
	c_va_list := find_intrinsics_type(c, "c_va_list")
	if c_va_list != nil {
		c.t_c_va_list = c_va_list
		c.t_c_va_list_ptr = alloc_type_pointer(c_va_list)
	}
}

// check_single_global_entity ensures a global entity is fully checked
// C++ Reference: checker.cpp:4938-4969
//
// This function validates and type-checks a single global entity.
// Used for on-demand checking of entities from core:runtime during RTTI initialization.
check_single_global_entity :: proc(c: ^Checker, e: ^Entity, d: ^Decl_Info) {
	// Validate inputs (C++ lines 4939-4940)
	assert(e != nil, "Entity must not be nil")
	assert(d != nil, "DeclInfo must not be nil")

	// Verify entity belongs to the declaration scope (C++ lines 4942-4944)
	if d.scope != e.scope {
		return
	}

	// Already resolved - nothing to do (C++ lines 4945-4947)
	if e.state == .Resolved {
		return
	}

	// Create checker context (C++ line 4949)
	ctx := make_checker_context(c)
	defer destroy_checker_context(&ctx)

	// Set up file and package context (C++ lines 4951-4954)
	assert(d.scope.flags & {.File} != {}, "Scope must be file-level")
	file := d.scope.file

	// Set context from file (equivalent to add_curr_ast_file, C++ lines 1526-1531)
	pkg := file.pkg
	ctx.file = file
	ctx.pkg = pkg
	ctx.scope = d.scope // Use the file-level scope from the declaration
	// NOTE: ast.Package doesn't have decl_info field in Odin
	// C++ stores this on the package, but we don't need it here since we override with d below
	// ctx.decl = pkg.decl_info  // Removed - not needed

	// Override with declaration-specific scope and decl (C++ lines 4958-4960)
	ctx.decl = d
	ctx.scope = d.scope

	// Validate package state (C++ lines 4956-4957)
	assert(ctx.pkg != nil, "Context package must be set")
	assert(e.pkg != nil, "Entity package must be set")

	// Check for 'main' reserved name in init package (C++ lines 4961-4966)
	if pkg.kind == .Init {
		if e.kind != .Procedure && e.token.text == "main" {
			error(e.token, "'main' is reserved as the entry point procedure in the initial scope")
			return
		}
	}

	// Type check the entity declaration (C++ line 4968)
	check_entity_decl(&ctx, e, d, nil)
}

// ======================================================================================
// MINIMUM DEPENDENCY TYPE INFO TRACKING
// C++ Reference: checker.cpp:2378-2600
// ======================================================================================

// add_min_dep_type_info registers a type for minimum dependency RTTI generation
// C++ Reference: checker.cpp:2378-2600
//
// This function tracks the minimal set of types that actually need RTTI in the final binary.
// Unlike add_type_info_type_internal which tracks per-declaration dependencies,
// this builds the global minimum set by tracking only types referenced through
// type_info_of() and typeid_of() calls and their transitive dependencies.
//
// The minimum dependency system works in two phases:
// 1. Collection: add_min_dep_type_info tracks types during checking
// 2. Finalization: After checking, the set is sorted and indexed (checker.cpp:7467-7517)
//
// Thread-safety: Uses RW mutex for concurrent access during parallel checking
add_min_dep_type_info :: proc(c: ^Checker, t: ^Type) {
	// Early validation (C++ lines 2379-2388)
	if t == nil {
		return
	}

	// Get default type (handles untyped literals) (C++ line 2382)
	actual_type := default_type(t)

	// Skip untyped types (C++ lines 2383-2385)
	if is_type_untyped(actual_type) {
		return // Could be nil
	}

	// Skip polymorphic types (C++ lines 2386-2388)
	if is_type_polymorphic(base_type(actual_type)) {
		return
	}

	// Thread-safe insert into minimum dependency set (C++ line 2390)
	// If type already exists in set, early return (update returns true if existed)
	hash := type_hash_canonical_type(actual_type)
	pair := Type_Info_Pair {
		type = actual_type,
		hash = hash,
	}

	sync.rw_mutex_lock(&c.info.min_dep_type_info_set_mutex)
	if _, exists := c.info.min_dep_type_info_set[hash]; exists {
		sync.rw_mutex_unlock(&c.info.min_dep_type_info_set_mutex)
		return // Already processed
	}
	c.info.min_dep_type_info_set[hash] = pair
	sync.rw_mutex_unlock(&c.info.min_dep_type_info_set_mutex)

	// Add nested types recursively (C++ lines 2394-2599)

	// Handle named types - register base type (C++ lines 2395-2399)
	if actual_type.kind == .Named {
		named := actual_type.variant.(Type_Named)
		add_min_dep_type_info(c, named.base)
		return
	}

	// Get base type and register it (C++ lines 2401-2402)
	bt := base_type(actual_type)
	add_min_dep_type_info(c, bt)

	// Recursively register nested types based on base type kind (C++ lines 2404-2599)
	#partial switch bt.kind {
	case .Invalid:
	// Nothing to do (C++ line 2405)

	case .Basic:
		// Register component types for composite basics (C++ lines 2407-2435)
		basic := bt.variant.(Type_Basic)
		#partial switch basic.kind {
		case .String:
			// string is {^u8, int} (C++ lines 2409-2412)
			add_min_dep_type_info(c, t_u8_ptr)
			add_min_dep_type_info(c, t_int)

		case .Any:
			// any is {rawptr, typeid} (C++ lines 2413-2416)
			add_min_dep_type_info(c, t_rawptr)
			add_min_dep_type_info(c, t_typeid)

		case .Complex64:
			// complex64 is {float32, float32} (C++ lines 2418-2421)
			add_min_dep_type_info(c, c.t_type_info_float)
			add_min_dep_type_info(c, t_f32)

		case .Complex128:
			// complex128 is {float64, float64} (C++ lines 2422-2425)
			add_min_dep_type_info(c, c.t_type_info_float)
			add_min_dep_type_info(c, t_f64)

		case .Quaternion128:
			// quaternion128 components (C++ lines 2426-2429)
			add_min_dep_type_info(c, c.t_type_info_float)
			add_min_dep_type_info(c, t_f32)

		case .Quaternion256:
			// quaternion256 components (C++ lines 2430-2433)
			add_min_dep_type_info(c, c.t_type_info_float)
			add_min_dep_type_info(c, t_f64)
		}

	case .Bit_Set:
		// Register element and underlying types (C++ lines 2437-2440)
		bs := bt.variant.(Type_Bit_Set)
		add_min_dep_type_info(c, bs.elem)
		add_min_dep_type_info(c, bs.underlying)

	case .Pointer:
		// Register pointer element type (C++ lines 2442-2444)
		pointer := bt.variant.(Type_Pointer)
		add_min_dep_type_info(c, pointer.elem)

	case .Multi_Pointer:
		// Register multi-pointer element type (C++ lines 2446-2448)
		multi_ptr := bt.variant.(Type_Multi_Pointer)
		add_min_dep_type_info(c, multi_ptr.elem)

	case .Array:
		// Register array element and related types (C++ lines 2450-2454)
		array := bt.variant.(Type_Array)
		add_min_dep_type_info(c, array.elem)
		add_min_dep_type_info(c, alloc_type_pointer(array.elem))
		add_min_dep_type_info(c, t_int)

	case .Enumerated_Array:
		// Register enumerated array types (C++ lines 2455-2460)
		enum_array := bt.variant.(Type_Enumerated_Array)
		add_min_dep_type_info(c, enum_array.index)
		add_min_dep_type_info(c, t_int)
		add_min_dep_type_info(c, enum_array.elem)
		add_min_dep_type_info(c, alloc_type_pointer(enum_array.elem))

	case .Dynamic_Array:
		// Register dynamic array element and allocator (C++ lines 2462-2467)
		dyn_array := bt.variant.(Type_Dynamic_Array)
		add_min_dep_type_info(c, dyn_array.elem)
		add_min_dep_type_info(c, alloc_type_pointer(dyn_array.elem))
		add_min_dep_type_info(c, t_int)
		add_min_dep_type_info(c, c.t_allocator)

	case .Slice:
		// Register slice element type (C++ lines 2468-2472)
		slice := bt.variant.(Type_Slice)
		add_min_dep_type_info(c, slice.elem)
		add_min_dep_type_info(c, alloc_type_pointer(slice.elem))
		add_min_dep_type_info(c, t_int)

	case .Enum:
		// Register enum base type (C++ lines 2474-2476)
		enum_type := bt.variant.(Type_Enum)
		add_min_dep_type_info(c, enum_type.base_type)

	case .Union:
		// Register union tag and variant types (C++ lines 2478-2507)
		union_type := bt.variant.(Type_Union)

		// Register tag type (C++ lines 2479-2483)
		if union_tag_size(actual_type) > 0 {
			add_min_dep_type_info(c, union_tag_type(actual_type))
		} else {
			add_min_dep_type_info(c, c.t_type_info_ptr)
		}

		// Register polymorphic params (C++ line 2484)
		if union_type.polymorphic_params != nil {
			add_min_dep_type_info(c, union_type.polymorphic_params)
		}

		// Register all variant types (C++ lines 2485-2487)
		for variant in union_type.variants {
			add_min_dep_type_info(c, variant)
		}

	// Note: C++ lines 2488-2507 register scope entities, but this is for
	// SOA structs only, not regular unions. Omitted for minimal dependency.

	case .Struct:
		// Register struct field types (C++ lines 2509-2540)
		struct_type := bt.variant.(Type_Struct)

		// Register scope entities for SOA types (C++ lines 2510-2531)
		if struct_type.scope != nil {
			for _, e in struct_type.scope.elements {
				#partial switch struct_type.soa_kind {
				case .Dynamic:
					// StructSoa_Dynamic (C++ lines 2514-2517)
					add_min_dep_type_info(c, c.t_type_info_ptr) // append_soa
					add_min_dep_type_info(c, c.t_allocator)
					fallthrough
				case .Slice:
					// StructSoa_Slice (C++ lines 2518-2521)
					add_min_dep_type_info(c, t_int)
					add_min_dep_type_info(c, t_uint)
					fallthrough
				case .Fixed:
					// StructSoa_Fixed (C++ lines 2522-2524)
					add_min_dep_type_info(c, alloc_type_pointer(e.type))
				case .None:
					// StructSoa_None (default case, C++ lines 2525-2527)
					add_min_dep_type_info(c, e.type)
				}
			}
		}

		// Register polymorphic params (C++ line 2532)
		if struct_type.polymorphic_params != nil {
			add_min_dep_type_info(c, struct_type.polymorphic_params)
		}

		// Register field types (C++ lines 2533-2536)
		for field in struct_type.fields {
			add_min_dep_type_info(c, field.type)
		}

		// NO comparison-procedure registration here either, and this one was INVENTED outright:
		// the cited "C++ line 2537-2538" is not in add_min_dep_type_info at all (that function
		// starts at checker.cpp:2576) -- it points into the `#if 0` block of a DIFFERENT
		// function. The live add_min_dep_type_info Struct arm registers field types and
		// polymorphic params and stops. Removed in #547 PART 5; same over-marking as above.

	case .Map:
		// Register map key, value, and allocator types (C++ lines 2542-2548)
		map_type := bt.variant.(Type_Map)
		init_map_internal_types(c, bt)
		add_min_dep_type_info(c, map_type.key)
		add_min_dep_type_info(c, map_type.value)
		add_min_dep_type_info(c, t_uintptr) // hash value
		add_min_dep_type_info(c, c.t_allocator)

	case .Tuple:
		// Register tuple element types (C++ lines 2550-2554)
		tuple := bt.variant.(Type_Tuple)
		for var in tuple.variables {
			add_min_dep_type_info(c, var.type)
		}

	case .Proc:
		// Register procedure params and results (C++ lines 2556-2559)
		proc_type := bt.variant.(Type_Proc)
		add_min_dep_type_info(c, proc_type.params)
		add_min_dep_type_info(c, proc_type.results)

	case .Simd_Vector:
		// Register SIMD element type (C++ lines 2561-2563)
		simd := bt.variant.(Type_Simd_Vector)
		add_min_dep_type_info(c, simd.elem)

	case .Matrix:
		// Register matrix element type (C++ lines 2565-2567)
		mat := bt.variant.(Type_Matrix)
		add_min_dep_type_info(c, mat.elem)

	case .Soa_Pointer:
		// Register SOA pointer element type (C++ lines 2569-2571)
		soa_ptr := bt.variant.(Type_Soa_Pointer)
		add_min_dep_type_info(c, soa_ptr.elem)

	case .Bit_Field:
		// Register bit field backing type and field types (C++ lines 2573-2577)
		bf := bt.variant.(Type_Bit_Field)
		add_min_dep_type_info(c, bf.backing_type)
		for field in bf.fields {
			add_min_dep_type_info(c, field.type)
		}

	case:
		// Unhandled type kind (C++ line 2579)
		panic("add_min_dep_type_info: unhandled type kind")
	}
}

// ======================================================================================
// TYPE INFO FLAGS
// C++ Reference: types.cpp:400-414
// ======================================================================================

// Type_Info_Flag represents runtime type info flags
// C++ Reference: types.cpp:400-403
// IMPORTANT: Must match core:runtime.Type_Info_Flags
Type_Info_Flag :: enum u32 {
	Comparable     = 0, // Type supports == and != (C++ line 402)
	Simple_Compare = 1, // Type supports memcmp for comparison (C++ line 403)
}

Type_Info_Flags :: bit_set[Type_Info_Flag;u32]

// type_info_flags_of_type computes the runtime type info flags for a type
// C++ Reference: types.cpp:404-414
//
// Returns flags indicating type capabilities:
// - Comparable: Type supports == and != operators
// - Simple_Compare: Type can be compared with memcmp
//
// Note: The C++ implementation has a bug on line 412 where it sets
// TypeInfoFlag_Comparable instead of TypeInfoFlag_Simple_Compare.
// We fix that here.
type_info_flags_of_type :: proc(t: ^Type) -> Type_Info_Flags {
	if t == nil {
		return {}
	}

	flags: Type_Info_Flags

	// Check if type is comparable (C++ lines 408-410)
	if is_type_comparable(t) {
		flags += {.Comparable}
	}

	// Check if type supports simple comparison (C++ lines 411-413)
	// BUG FIX: C++ incorrectly sets TypeInfoFlag_Comparable here
	if is_type_simple_compare(t) {
		flags += {.Simple_Compare}
	}

	return flags
}

// ======================================================================================
// TYPE INFO INDEX LOOKUP
// C++ Reference: checker.cpp:1726-1752
// ======================================================================================

// type_info_index returns the index of a type in the final type info table
// C++ Reference: checker.cpp:1726-1752
//
// This function looks up the index of a type in the minimum dependency type info set.
// The index is used for:
// 1. typeid_of() builtin - embeds the index in the typeid value
// 2. type_info_of() builtin - indexes into the global type_info array
// 3. Codegen - generates references to the type info data
//
// IMPORTANT: Only call after checking is complete and the index map has been built
// (see checker.cpp:7467-7517 for index map construction)
//
// Parameters:
//   - info: Checker info containing the index map
//   - pair: Type and its canonical hash
//   - error_on_failure: If true, panics when type not found
//
// Returns: Index (>= 0) if found, -1 if not found and error_on_failure is false
type_info_index_pair :: proc(info: ^Checker_Info, pair: Type_Info_Pair, error_on_failure: bool) -> i64 {
	// Thread-safe lookup in index map (C++ lines 1727-1735)
	sync.rw_mutex_shared_lock(&info.minimum_dependency_type_info_mutex)
	defer sync.rw_mutex_shared_unlock(&info.minimum_dependency_type_info_mutex)

	entry_index: i64 = -1
	if found, exists := info.min_dep_type_info_index_map[pair.hash]; exists {
		entry_index = found
	}

	// Error handling (C++ lines 1737-1740)
	if error_on_failure && entry_index < 0 {
		type_str := type_to_string(pair.type)
		panic(fmt.tprintf("Type_Info for '%s' could not be found", type_str))
	}

	return entry_index
}

// type_info_index returns the index of a type in the final type info table
// C++ Reference: checker.cpp:1744-1752
//
// Convenience wrapper that computes the canonical hash and calls type_info_index_pair
type_info_index :: proc(info: ^Checker_Info, t: ^Type, error_on_failure: bool) -> i64 {
	// Normalize type (C++ lines 1745-1748)
	actual_type := default_type(t)
	// Note: C++ also handles t_llvm_bool -> t_bool conversion, but we don't have LLVM types yet

	// Compute canonical hash and lookup (C++ lines 1750-1751)
	hash := type_hash_canonical_type(actual_type)
	return type_info_index_pair(info, Type_Info_Pair{type = actual_type, hash = hash}, error_on_failure)
}

// ======================================================================================
// NOTE: Type identity checking functions are implemented in check_equivalence.odin
// - are_types_identical_unique_tuples: C++ types.cpp:2924-2951
// - are_types_identical_internal: C++ types.cpp:2745-2921
// ======================================================================================

// ====================================================================================
// TYPE INFO SORTING AND COMPARISON
// C++ Reference: name_canonicalization.cpp type_info_pair_cmp:3-10
// ======================================================================================

// type_info_pair_cmp compares two Type_Info_Pair values by their hash
// C++ Reference: name_canonicalization.cpp type_info_pair_cmp:3-10
//
// This comparison function is used to sort the type info array by hash value.
// The sorted array enables efficient lookup and collision detection.
//
// Parameters:
//   - x, y: Type info pairs to compare
//
// Returns:
//   - negative if x.hash < y.hash
//   - zero if x.hash == y.hash
//   - positive if x.hash > y.hash
type_info_pair_cmp :: proc(x, y: Type_Info_Pair) -> int {
	// C++ lines 6-9: Simple hash comparison
	if x.hash == y.hash {
		return 0
	}
	return x.hash < y.hash ? -1 : +1
}

// ======================================================================================
// TYPE INFO FINALIZATION
// C++ Reference: checker.cpp:7467-7517
// ======================================================================================

// finalize_minimum_dependency_type_info builds the final type info index
// C++ Reference: checker.cpp:7467-7517
//
// This function is called after type checking completes. It:
// 1. Extracts all types from min_dep_type_info_set
// 2. Sorts them by canonical hash for consistent ordering
// 3. Builds a hash map for O(1) lookup
// 4. Creates an index map from hash to array position
// 5. Detects hash collisions and reports errors
//
// This must be called before any type_info_index() lookups.
finalize_minimum_dependency_type_info :: proc(c: ^Checker) {
	info := c.info

	// Extract all type info pairs from the set (C++ lines 7471-7476)
	type_info_types := make([dynamic]Type_Info_Pair, 0, len(info.min_dep_type_info_set))
	defer delete(type_info_types)

	for _, pair in info.min_dep_type_info_set {
		append(&type_info_types, pair)
	}

	// Sort by hash for consistent ordering (C++ line 7477)
	slice.sort_by(type_info_types[:], proc(i, j: Type_Info_Pair) -> bool {
		return type_info_pair_cmp(i, j) < 0
	})

	// Initialize hash map and index map (C++ lines 7479-7480)
	// Hash map size is 2*count+1 for open addressing with low collision rate
	hash_map_len := len(type_info_types) * 2 + 1
	resize(&info.type_info_types_hash_map, hash_map_len)
	reserve(&info.min_dep_type_info_index_map, len(type_info_types))

	// Zero-initialize hash map (required for collision detection)
	for i in 0 ..< hash_map_len {
		info.type_info_types_hash_map[i] = Type_Info_Pair {
			type = nil,
			hash = 0,
		}
	}

	// Insert each type into hash map using linear probing (C++ lines 7483-7513)
	for tt in type_info_types {
		// Find insertion slot using linear probing (C++ lines 7484-7493)
		index := int(tt.hash % u64(hash_map_len))

		// Linear probing: skip slot 0 and occupied slots
		for {
			if index == 0 || info.type_info_types_hash_map[index].hash != 0 {
				index = (index + 1) % hash_map_len
				continue
			}
			break
		}

		// Insert into hash map
		info.type_info_types_hash_map[index] = tt

		// Add to index map, checking for collisions (C++ lines 7496-7512)
		if existing_index, exists := info.min_dep_type_info_index_map[tt.hash]; exists {
			// Hash collision detected - verify types are truly different
			other := info.type_info_types_hash_map[existing_index]

			// If types are identical (unique tuples), this is ok - same type, same hash
			if are_types_identical_unique_tuples(tt.type, other.type) {
				continue
			}

			// Real hash collision - different types with same hash
			// This is a critical error that indicates a hash function bug
			// C++ lines 7506-7510: panic with diagnostic info
			t_str := type_to_string(tt.type)
			o_str := type_to_string(other.type)
			t_canonical := type_to_canonical_string(tt.type)
			o_canonical := type_to_canonical_string(other.type)
			panic(fmt.tprintf("Type info hash collision:\n  %s (%s) hash=%llu\n  vs\n  %s (%s) hash=%llu", t_str, t_canonical, tt.hash, o_str, o_canonical, other.hash))
		} else {
			// First time seeing this hash - record the index
			info.min_dep_type_info_index_map[tt.hash] = i64(index)
		}
	}

	// Sanity check (C++ line 7516)
	assert(len(info.min_dep_type_info_index_map) <= len(type_info_types), "Index map should not exceed type count")
}

// ======================================================================================
// TYPE INFO COLLECTION FOR DEFINITIONS
// C++ Reference: checker.cpp:7136-7151
// ======================================================================================

// add_type_info_for_type_definitions registers RTTI for all defined types
// C++ Reference: checker.cpp:7136-7151
//
// This function is called after type checking to collect all type definitions
// that need RTTI. A type definition needs RTTI if:
// 1. It's a named type (Entity_TypeName)
// 2. The type is fully resolved (not nil, typed)
// 3. The type has minimum dependencies (min_dep_count > 0)
//
// The min_dep_count indicates how many other entities reference this type,
// meaning it's actually used and needs runtime reflection data.
add_type_info_for_type_definitions :: proc(c: ^Checker) {
	// Iterate all type definitions (C++ line 7137)
	for e in c.info.definitions {
		// Filter for type names (C++ line 7138)
		if e.kind != .Type_Name {
			continue
		}

		// Ensure type is resolved and typed (C++ line 7138)
		if e.type == nil || !is_type_typed(e.type) {
			continue
		}

		// Check if type has dependencies (C++ lines 7145-7146)
		// Note: C++ has an #if 0 block with an additional align check that's disabled
		// We implement the active code path only
		if e.min_dep_count <= 0 {
			continue
		}

		// Register type for RTTI generation (C++ line 7146)
		add_type_info_type(&c.builtin_ctx, e.type)
	}
}

// ======================================================================================
// TYPE CANONICALIZATION
// ======================================================================================

// NOTE: type_hash_canonical_type and type_to_canonical_string are implemented
// in name_canonicalization.odin.
// C++ Reference: name_canonicalization.cpp:372-399
