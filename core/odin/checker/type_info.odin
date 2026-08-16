package checker

/*
Runtime Type Information (RTTI) infrastructure.

This module implements the type information system that powers `type_info_of()`
and `typeid_of()` builtins. It generates compile-time type metadata tables for
runtime reflection.

C++ Reference, per procedure. BOTH previous ranges (3253-3395 and 2085-2335, both into
checker.cpp) STRADDLED function boundaries and were therefore stale on their face
(#183): 3253-3395 opened inside generate_entity_dependency_graph and closed inside
find_core_type; 2085-2335 opened inside add_entity_flags_from_file and closed inside
add_type_info_type_internal. Neither named a function, so neither could be checked (#153).

  checker.cpp add_type_info_dependency      checker.cpp type_info_index
  checker.cpp add_type_info_type          checker.cpp add_type_info_type_internal
  checker.cpp add_min_dep_type_info       checker.cpp find_core_entity
  checker.cpp find_core_type              checker.cpp init_core_type_info
  checker.cpp check_single_global_entity
  checker.cpp add_type_info_for_type_definitions
  checker.cpp check_parsed_files -- finalize_minimum_dependency_type_info's counterpart,
              which is INLINE in check_parsed_files and has no C++ function of its own (LEDGER #711)
  check_expr.cpp add_comparison_procedures_for_fields
  types.cpp type_info_flags_of_type
  name_canonicalization.cpp type_info_pair_cmp

*/

import "core:fmt"
import "core:odin/ast"
import "core:slice"
import "core:sync"

// ======================================================================================
// INITIALIZATION
// C++ Reference: checker.cpp init_core_type_info
// ======================================================================================

// init_core_type_info initializes the RTTI system
// C++ Reference: checker.cpp init_core_type_info
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

	// Early return if already initialized (C++ checker.cpp init_core_type_info)
	// This check must be inside the mutex to prevent double initialization
	if c.t_type_info != nil {
		return
	}

	// Find Type_Info entity from core:runtime (C++ checker.cpp init_core_type_info)
	type_info_entity := find_core_entity(c, "Type_Info")
	if type_info_entity == nil {
		// Runtime package not loaded - skip type info initialization
		return
	}

	// Ensure the entity's type is checked (C++ checker.cpp init_core_type_info)
	if type_info_entity.type == nil {
		check_single_global_entity(c, type_info_entity, type_info_entity.decl_info)
	}
	// If still nil after check, we have extracted runtime types without full resolution
	if type_info_entity.type == nil {
		return
	}

	// Initialize core type info globals (C++ checker.cpp init_core_type_info)
	c.t_type_info = type_info_entity.type
	c.t_type_info_ptr = alloc_type_pointer(c.t_type_info)

	// Verify Type_Info is a struct (C++ checker.cpp init_core_type_info)
	if !is_type_struct(type_info_entity.type) {
		// Extracted runtime may not have proper type info - skip validation
		return
	}
	tis := base_type(type_info_entity.type).variant.(Type_Struct)

	// Find Type_Info_Enum_Value (C++ checker.cpp init_core_type_info).
	//
	// ORDERING IS LOAD-BEARING, AND IT MUST STAY ABOVE THE FIELD-COUNT GUARD BELOW (#718b).
	// C++ resolves this entity FIRST and only THEN asserts `tis->fields.count == 5`. This block
	// used to sit AFTER the guard, which inverted that order.
	//
	// The inversion mattered because the guard is not C++'s assert -- it is the [EMBED-3]
	// translation of it (CPP_DEVIATIONS.md): an assertion whose precondition the port's PUBLIC
	// ENTRY POINT can legitimately violate becomes `return nil`/`return`. A caller may hand us an
	// extracted or partial runtime -- every snippet test does -- so a Type_Info without exactly
	// five fields is a reachable, supported input here, not a bug. The early return is CORRECT
	// and stays.
	//
	// But [EMBED-3] exists so the checker keeps WORKING on a partial runtime, and that only holds
	// if we assign everything we can before bailing. Resolving Type_Info_Enum_Value does not read
	// `tis.fields` at all, so leaving it below the guard meant a runtime missing an unrelated
	// Type_Info field silently cost us `t_type_info_enum_value` and its pointer as well.
	// Order of statements was the whole defect (#144).
	type_info_enum_value := find_core_entity(c, "Type_Info_Enum_Value")
	if type_info_enum_value != nil && type_info_enum_value.type != nil {
		c.t_type_info_enum_value = type_info_enum_value.type
		c.t_type_info_enum_value_ptr = alloc_type_pointer(c.t_type_info_enum_value)
	}

	// Validate Type_Info struct layout (C++ checker.cpp init_core_type_info)
	// Type_Info has 5 fields: id, size, align, flags, variant
	if len(tis.fields) != 5 {
		// Extracted runtime may not have all fields - skip validation
		return
	}

	// Find Type_Info_String_Encoding_Kind (C++ checker.cpp init_core_type_info)
	type_info_string_encoding_kind := find_core_entity(c, "Type_Info_String_Encoding_Kind")
	if type_info_string_encoding_kind != nil {
		c.t_type_info_string_encoding_kind = type_info_string_encoding_kind.type
	}

	// Verify variant field is a union (C++ checker.cpp init_core_type_info)
	type_info_variant := tis.fields[4]
	tiv_type := type_info_variant.type
	if !is_type_union(tiv_type) {
		// Extracted runtime has placeholder field types - skip full initialization
		return
	}

	// Find all Type_Info variant types from core:runtime (C++ checker.cpp init_core_type_info)
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
	// (checker.cpp init_core_type_info); the port declared all 27 globals, RESET them, and never assigned
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
	// Type_Info_Fixed_Capacity_Dynamic_Array here (checker.cpp init_core_type_info) and its pointer. The
	// port declares NEITHER the base nor the pointer, so there is no dangling half. The type does
	// exist in base/runtime (core.odin:230), so this is a genuine gap rather than a stale C++
	// reference -- it is just an inert one, with no reader on either side of the port. Filed on
	// #577's tail rather than added here, because adding it means a new find_core_type lookup
	// whose failure mode has not been measured.
}

// ======================================================================================
// DEPENDENCY TRACKING
// C++ Reference: checker.cpp add_type_info_dependency, add_type_info_type
// ======================================================================================

// add_type_info_dependency tracks that a declaration depends on a type's RTTI
// C++ Reference: checker.cpp add_type_info_dependency
//
// This is used to track which types need RTTI generation. When a type is used
// in type_info_of() or typeid_of(), we record that dependency for later codegen.
add_type_info_dependency :: proc(info: ^Checker_Info, decl: ^Decl_Info, t: ^Type) {
	if decl == nil || t == nil {
		return
	}

	// Unwrap type aliases to track the underlying type
	// (C++ checker.cpp add_type_info_dependency)
	actual_type := t
	if t.kind == .Named {
		named := t.variant.(Type_Named)
		// Check if this is a type alias (not distinct)
		// C++ checker.cpp add_type_info_dependency:
		// if (e->TypeName.is_type_alias) { type = type->Named.base; }
		if named.type_name != nil {
			if type_name_entity, ok := &named.type_name.variant.(Entity_Type_Name); ok {
				if type_name_entity.is_type_alias {
					// It's a type alias, unwrap to base type
					actual_type = named.base
				}
			}
		}
	}

	// Thread-safe insertion into type_info_deps
	// (C++ checker.cpp add_type_info_dependency)
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

	// C++ Reference: checker.cpp add_type_info_dependency `type_set_add(&d->type_info_deps, type)`.
	// (LINE NUMBER WAS ALREADY CORRECT -- anchored only, deliberately NOT renumbered. Its five
	//  neighbours above were stale by +12; this one was not. A block can hold TWO EPOCHS, #171.)
	// type_set_add slots by
	// type_hash_canonical_type and RETURNS the incumbent when the hash is already present -- it does
	// not replace it. The `not_in` guard reproduces that: first writer wins, so a second
	// structurally identical Type object neither adds an entry nor displaces the representative.
	h := type_hash_canonical_type(actual_type)
	if h not_in decl.type_info_deps {
		decl.type_info_deps[h] = actual_type
	}
}

// add_basic_type_information registers type info for every basic type.
// C++ Reference: checker.cpp check_parsed_files, TIME_SECTION("add basic type
// information"):
//
//     for (isize i = 0; i < Basic_COUNT; i++) {
//         Type *t = &basic_types[i];
//         if (t->Basic.size > 0 && (t->Basic.flags & BasicFlag_LLVM) == 0) {
//             if (build_context.bedrock) {
//                 if ((t->Basic.flags & BasicFlag_Integer) != 0 && t->Basic.size == 16) {
//                     continue;   // disallow 128-bit integers
//                 }
//             }
//             add_type_info_type(&c->builtin_ctx, t);
//         }
//     }
//
// WHY THIS EXISTS AT ALL, since no diagnostic reads the roster: the roster is CHECKER OUTPUT
// CONSUMED BY A BACKEND. In C++ the only callers of type_info_index are llvm_backend.cpp:3299 and
// llvm_backend_type.cpp:9/24. Without this phase the port's roster held only the types the
// min-dep walk happened to REACH (add_min_dep_type_info, the sole writer), so it was a strict
// SUBSET of C++'s -- and a backend asking for the type info of any unreached basic type would not
// find it. That it is invisible to every text-comparing gate is a fact about the gates, not
// evidence the phase is optional. LEDGER #637.
//
// NOTE ON THE GATES: modelsweep reading 0 and depnames reading missing=0 did NOT clear this.
// Given a genuine subset, their green means neither COVERS the basic-type roster -- the #483
// shape, where a gate reads clean because it cannot see the thing it is supposed to measure.
add_basic_type_information :: proc(c: ^Checker) {
	bedrock := c.info.build_context != nil && c.info.build_context.bedrock

	for t in basic_type_singletons {
		if t == nil {
			continue
		}
		basic, is_basic := t.variant.(Type_Basic)
		if !is_basic {
			continue
		}

		// C++ line 7732-7733: size > 0 skips Basic_Invalid and the untyped kinds; the LLVM
		// flag skips llvm_bool, which has no runtime type info.
		if basic.size <= 0 || .LLVM in basic.flags {
			continue
		}

		// C++ line 7734-7741: `-bedrock` drops the 128-bit integers. The six types this
		// selects (i128, u128, i128le, u128le, i128be, u128be) were verified against C++'s
		// table rather than assumed -- see checker_lifecycle.odin's universe registration,
		// which gates the same six. complex128 is also 16 bytes but carries .Complex rather
		// than .Integer, so the flag test correctly leaves it in.
		if bedrock && .Integer in basic.flags && basic.size == 16 {
			continue
		}

		add_type_info_type(&c.builtin_ctx, t)
	}
}

// add_type_info_type registers a type for RTTI generation
// C++ Reference: checker.cpp add_type_info_type
//
// This is the public entry point for type registration. It:
// 1. Validates the type is eligible for RTTI
// 2. Calls internal registration to handle dependencies
// (STRANDED above a different procedure until #734 -- another procedure was inserted between
//  this doc comment and the definition it documents.)
add_type_info_type :: proc(ctx: ^Checker_Context, t: ^Type) {
	// Check for build flag disabling RTTI (C++ checker.cpp add_type_info_type)
	if ctx.info.build_context != nil && ctx.info.build_context.no_rtti {
		return
	}

	if t == nil {
		return
	}

	// NO t_type_info GUARD HERE. C++ Reference: checker.cpp add_type_info_type -- the
	// whole function is no_rtti / nil / default_type / untyped / polymorphic and then the internal
	// call. There is no runtime-type precondition, and there cannot be one: the only live work
	// downstream is add_type_info_dependency (checker.cpp:883-896), which inserts into
	// `decl->type_info_deps` and never reads a runtime type.
	//
	// The port had `if ctx.checker.t_type_info == nil { return }` here, described as harmless
	// because "globals persist for process lifetime" in C++. It was not harmless. FILE-SCOPE
	// declarations -- global variables, constants, and type declarations -- are checked before
	// t_type_info is populated, so the guard silently DROPPED every registration made from one.
	// Measured: `E :: enum{A,B}` with `G := E.A` at file scope registers the enum on the reference
	// and nothing on the port, while the identical expression inside a procedure body registers on
	// both (instrumented directly -- the file-scope call arrived with t_type_info still nil). The
	// same swallowed the six `memory_order_*` constants in core/c/libc and the auto_cast enum
	// members of core/sys/linux's Eventfd_Flags_Bits.
	//
	// The guard is most likely a leftover from the 269 lines of dead recursion #562 deleted from
	// add_type_info_type_internal: THAT code walked runtime types and did need them present.
	// With the walk gone there is nothing left to protect. LEDGER #690.
	//
	// CITEMONO DISPOSITION (#713): the `add_type_info_type` above is a WHOLE-FUNCTION
	// span cited from mid-body, so citemono scores it as an inversion against the arm-level
	// citation preceding it. That is legitimate -- a span, not a step -- and expected to persist.
	// (This block used to carry two epochs of drift archaeology -- a corrected range and a uniform
	// +201 that had landed five arm citations inside the wrong functions. Both described numbers
	// #892 removed, so only the disposition itself is kept. #167.)

	// Get default type (handles untyped types) (C++ checker.cpp add_type_info_type)
	actual_type := default_type(t)

	// Skip untyped types (could be nil) (C++ checker.cpp add_type_info_type)
	if is_type_untyped(actual_type) {
		return
	}

	// Skip polymorphic types (C++ checker.cpp add_type_info_type)
	if is_type_polymorphic(actual_type) {
		return
	}

	// Register type and its dependencies (C++ checker.cpp add_type_info_type)
	add_type_info_type_internal(ctx, actual_type)
}

// add_comparison_procedures_for_fields adds runtime dependencies for comparison operations
// C++ Reference: check_expr.cpp add_comparison_procedures_for_fields
//
// The C++ SOURCE contains three calls, but only TWO are LIVE, and the old comment here was wrong
// about both halves of that (#91, #721). It said "All three are wired here"; the port wires two,
// and two is the correct number.
//
// LIVE, and wired here:
//   1. its own Struct recursion            -- check_expr.cpp:3186 (the loop at the bottom of this
//                                             procedure's Struct arm)
//   2. check_comparison's accepted branch  -- check_expr.cpp:3300, wired at check_expr.odin:2026
//                                             (missing until #547 PART 5)
// DEAD, and deliberately NOT wired:
//   3. add_type_info_type_internal's Struct arm -- checker.cpp:2491, which lies inside the `#if 0`
//      spanning checker.cpp:2311-2540. The port deleted that whole dead walk (#562); see the note
//      in add_type_info_type_internal below. Wiring this would register comparison procedures C++
//      never registers.
//
// All three old line numbers were stale by a uniform -22 into check_expr.cpp (3109/3164/3278 vs
// 3131/3186/3300) except the checker.cpp one, which was stale by -8 (2483 vs 2491) -- and 2483
// PASSED the straddle screen because it lands inside the right function. An anchored citation is
// not a verified one (#167); drift inside one comment block is not uniform (#171).
//
// This function registers runtime procedure dependencies for types that require
// special comparison procedures (complex, quaternion, string types). When a type
// uses these comparison operators, we must ensure the runtime comparison functions
// are linked into the final binary.
//
// There is ONE version, taking a Checker_Context, because C++ has one signature:
// `add_comparison_procedures_for_fields(CheckerContext *c, Type *t)` (declared checker.cpp:13,
// defined check_expr.cpp:3131) and all three C++ call sites pass a CheckerContext.
//
// A second `_checker` overload taking ^Checker existed here and was INVENTED (#170): it had ZERO
// callers tree-wide, and C++ has no Checker-taking overload to model. Deleted with the two-member
// proc group that only existed to hold it; LEDGER #740.
add_comparison_procedures_for_fields :: proc(ctx: ^Checker_Context, t: ^Type) {
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
			add_comparison_procedures_for_fields(ctx, field.type)
		}
	}
}

// add_type_info_type_internal recursively registers types and their dependencies
// C++ Reference: checker.cpp add_type_info_type_internal
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

	// THAT IS THE WHOLE LIVE FUNCTION. C++ Reference: checker.cpp add_type_info_type_internal.
	//
	// C++ opens `#if 0` on the line AFTER add_type_info_dependency -- checker.cpp:2311, inside
	// add_type_info_type_internal, NOT inside add_type_info_type as this note used to say -- and
	// closes it with the `#endif` that is the last line before that function's closing brace.
	// (An earlier version of this note named the wrong enclosing function. #721.) So the
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
// C++ Reference: parser.hpp:213 - `Scope *   scope;` in AstPackage.
// (The field above it is exported_entity_queue. This is a STRUCT FIELD, so citefn
//  reports it as `outside-any-function` -- which is CORRECT and expected, not a defect. #724.)
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
// C++ Reference: parser.hpp:213 - `Scope *   scope;` in AstPackage (the field this writes).
// (Off by one, and a STRUCT FIELD -- see the note on get_package_scope above. #724.)
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
// C++ Reference: checker.cpp find_core_entity
// Returns nil if runtime package is not loaded (e.g., in tests without runtime)
find_core_entity :: proc(c: ^Checker, name: string) -> ^Entity {
	// Get runtime package (C++ checker.cpp find_core_entity)
	runtime_pkg := c.info.runtime_package
	if runtime_pkg == nil {
		return nil // Runtime package not loaded - return nil instead of panic
	}

	// Look up entity in runtime package scope (C++ checker.cpp find_core_entity)
	// NOTE: ast.Package doesn't have scope field, must get from Checker_Info.package_scopes
	// A runtime package with no scope means create_package_scopes has not run over it yet -
	// i.e. this is a check_files call that never went through Phase 1 with runtime in its file
	// list. That is the same "runtime is not usable here" condition as runtime_pkg being nil,
	// so it gets the same answer rather than taking the host process down with it. C++ can
	// dereference pkg->scope unguarded (checker.cpp find_core_entity) because its runtime package is always
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
// C++ Reference: checker.cpp find_core_type
// Returns nil if runtime package is not loaded or entity not found
find_core_type :: proc(c: ^Checker, name: string) -> ^Type {
	// Look up entity from runtime package (C++ checker.cpp find_core_type -- C++ DUPLICATES the lookup body here
	// rather than calling find_core_entity; the port factors it into the call)
	e := find_core_entity(c, name)
	if e == nil {
		return nil // Runtime package not loaded or entity not found
	}

	// Check entity if type not yet resolved (C++ checker.cpp find_core_type)
	if e.type == nil {
		check_single_global_entity(c, e, e.decl_info)
	}

	// Verify type was resolved (C++ checker.cpp find_core_type)
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
// (checker.cpp init_universal -- the c_va_list block) and registers it into base:intrinsics
// itself.
//
// STALE-COMMENT CORRECTED (#713). This block used to claim "the port sources it from the
// package's own `c_va_list :: struct{...}` declaration instead, the same way init_objc_types
// sources objc_object". That is FALSE and was already known to be false: #39 established that
// base:intrinsics is a RESERVED package whose source is never parsed, so this lookup was
// PERMANENTLY nil and every `va_list :: intrinsics.c_va_list` failed. The fix synthesises the
// type in checker_lifecycle.odin `init_c_va_list_type` (singular) instead -- see its comment at
// checker_lifecycle.odin:525-536, which contradicted this one verbatim.
//
// THIS PROCEDURE IS THEREFORE SUPERSEDED AND REDUNDANT, not a fallback. By the time it runs,
// the lifecycle has already synthesised and registered the name, so the lookup now SUCCEEDS and
// merely re-derives what is already set. It is INERT, verified rather than assumed:
// `alloc_type_pointer` does NOT intern (types.odin:2681 -- fresh allocation per call), so the
// re-derivation does hand `t_c_va_list_ptr`/`t_objc_id`/`t_objc_SEL`/`t_objc_Class` NEW pointer
// instances that differ by identity from the lifecycle's. Every reader of those four compares
// STRUCTURALLY (`check_is_assignable_to` and `are_types_identical`, three sites in
// check_builtin.odin). The one identity comparison in the checker, `o.type == t_objc_instancetype`
// (check_expr.odin:11496), reads a global these procedures never write, and whose alias backing
// is the lifecycle's original `t_objc_id`. Left in place rather than deleted: deletion is a code
// change needing full gates, and the redundancy costs nothing measurable. LEDGER #170.
init_c_va_list_types :: proc(c: ^Checker) {
	c_va_list := find_intrinsics_type(c, "c_va_list")
	if c_va_list != nil {
		c.t_c_va_list = c_va_list
		c.t_c_va_list_ptr = alloc_type_pointer(c_va_list)
	}
}

// check_single_global_entity ensures a global entity is fully checked
// C++ Reference: checker.cpp check_single_global_entity
//
// This function validates and type-checks a single global entity.
// Used for on-demand checking of entities from core:runtime during RTTI initialization.
check_single_global_entity :: proc(c: ^Checker, e: ^Entity, d: ^Decl_Info) {
	// Validate inputs (C++ checker.cpp check_single_global_entity)
	assert(e != nil, "Entity must not be nil")
	assert(d != nil, "DeclInfo must not be nil")

	// Verify entity belongs to the declaration scope (C++ checker.cpp check_single_global_entity)
	if d.scope != e.scope {
		return
	}

	// Already resolved - nothing to do (C++ checker.cpp check_single_global_entity)
	if e.state == .Resolved {
		return
	}

	// Create checker context (C++ checker.cpp check_single_global_entity)
	ctx := make_checker_context(c)
	defer destroy_checker_context(&ctx)

	// Set up file and package context (C++ checker.cpp check_single_global_entity)
	assert(d.scope.flags & {.File} != {}, "Scope must be file-level")
	file := d.scope.file

	// Set context from file (equivalent to C++ checker.cpp add_curr_ast_file,
	// which returns bool; called from checker.cpp check_single_global_entity)
	pkg := file.pkg
	ctx.file = file
	ctx.pkg = pkg
	ctx.scope = d.scope // Use the file-level scope from the declaration
	// NOTE: ast.Package doesn't have decl_info field in Odin
	// C++ stores this on the package, but we don't need it here since we override with d below
	// ctx.decl = pkg.decl_info  // Removed - not needed

	// Override with declaration-specific scope and decl (C++ checker.cpp check_single_global_entity).
	//
	// ORDERING DEVIATION, DISPOSITIONED AS INERT: C++ asserts `ctx->pkg`/`e->pkg` and THEN sets
	// decl/scope. The port does the reverse, so the decl/scope assignment physically PRECEDES the
	// asserts below. Behaviourally irrelevant --
	// neither assert reads `decl` or `scope`. Recorded so this is not mistaken for #144's class.
	ctx.decl = d
	ctx.scope = d.scope

	// Validate package state (C++ checker.cpp check_single_global_entity) -- see the ordering note above
	assert(ctx.pkg != nil, "Context package must be set")
	assert(e.pkg != nil, "Entity package must be set")

	// Check for 'main' reserved name in init package (C++ checker.cpp check_single_global_entity)
	if pkg.kind == .Init {
		if e.kind != .Procedure && e.token.text == "main" {
			error(e.token, "'main' is reserved as the entry point procedure in the initial scope")
			return
		}
	}

	// Type check the entity declaration (C++ checker.cpp check_single_global_entity)
	check_entity_decl(&ctx, e, d, nil)
}

// ======================================================================================
// MINIMUM DEPENDENCY TYPE INFO TRACKING
// C++ Reference: checker.cpp add_min_dep_type_info
// ======================================================================================

// add_min_dep_type_info registers a type for minimum dependency RTTI generation
// C++ Reference: checker.cpp add_min_dep_type_info
//
// This function tracks the minimal set of types that actually need RTTI in the final binary.
// Unlike add_type_info_type_internal which tracks per-declaration dependencies,
// this builds the global minimum set by tracking only types referenced through
// type_info_of() and typeid_of() calls and their transitive dependencies.
//
// The minimum dependency system works in two phases:
// 1. Collection: add_min_dep_type_info tracks types during checking
// 2. Finalization: After checking, the set is sorted and indexed (checker.cpp
//    check_parsed_files, under TIME_SECTION("initialize and check for collisions in
//    type info array"). The old citation -- 7467-7517, into checker.cpp -- is init_procedures_cmp, an
//    entirely unrelated function -- same defect LEDGER #711 fixed one site of; this was another.)
//
// Thread-safety: Uses RW mutex for concurrent access during parallel checking
add_min_dep_type_info :: proc(c: ^Checker, t: ^Type) {
	// Early validation (C++ checker.cpp add_min_dep_type_info)
	if t == nil {
		return
	}

	// Get default type (handles untyped literals) (C++ checker.cpp add_min_dep_type_info)
	actual_type := default_type(t)

	// Skip untyped types (C++ checker.cpp add_min_dep_type_info)
	if is_type_untyped(actual_type) {
		return // Could be nil
	}

	// Skip polymorphic types (C++ checker.cpp add_min_dep_type_info)
	if is_type_polymorphic(base_type(actual_type)) {
		return
	}

	// Thread-safe insert into minimum dependency set (C++ checker.cpp add_min_dep_type_info)
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

	// Add nested types recursively (C++ checker.cpp add_min_dep_type_info)

	// Handle named types - register base type (C++ checker.cpp add_min_dep_type_info)
	if actual_type.kind == .Named {
		named := actual_type.variant.(Type_Named)
		add_min_dep_type_info(c, named.base)
		return
	}

	// Get base type and register it (C++ checker.cpp add_min_dep_type_info)
	bt := base_type(actual_type)
	add_min_dep_type_info(c, bt)

	// Recursively register nested types based on base type kind (C++ checker.cpp add_min_dep_type_info)
	#partial switch bt.kind {
	case .Invalid:
	// Nothing to do (C++ checker.cpp add_min_dep_type_info)

	case .Basic:
		// Register component types for composite basics (C++ checker.cpp add_min_dep_type_info)
		basic := bt.variant.(Type_Basic)
		#partial switch basic.kind {
		case .String:
			// string is {^u8, int} (C++ checker.cpp add_min_dep_type_info)
			add_min_dep_type_info(c, t_u8_ptr)
			add_min_dep_type_info(c, t_int)

		case .Any:
			// any is {rawptr, typeid} (C++ checker.cpp add_min_dep_type_info)
			add_min_dep_type_info(c, t_rawptr)
			add_min_dep_type_info(c, t_typeid)

		case .Complex64:
			// complex64 is {float32, float32} (C++ checker.cpp add_min_dep_type_info)
			add_min_dep_type_info(c, c.t_type_info_float)
			add_min_dep_type_info(c, t_f32)

		case .Complex128:
			// complex128 is {float64, float64} (C++ checker.cpp add_min_dep_type_info)
			add_min_dep_type_info(c, c.t_type_info_float)
			add_min_dep_type_info(c, t_f64)

		case .Quaternion128:
			// quaternion128 components (C++ checker.cpp add_min_dep_type_info)
			add_min_dep_type_info(c, c.t_type_info_float)
			add_min_dep_type_info(c, t_f32)

		case .Quaternion256:
			// quaternion256 components (C++ checker.cpp add_min_dep_type_info)
			add_min_dep_type_info(c, c.t_type_info_float)
			add_min_dep_type_info(c, t_f64)
		}

	case .Bit_Set:
		// Register element and underlying types (C++ checker.cpp add_min_dep_type_info)
		bs := bt.variant.(Type_Bit_Set)
		add_min_dep_type_info(c, bs.elem)
		add_min_dep_type_info(c, bs.underlying)

	case .Pointer:
		// Register pointer element type (C++ checker.cpp add_min_dep_type_info)
		pointer := bt.variant.(Type_Pointer)
		add_min_dep_type_info(c, pointer.elem)

	case .Multi_Pointer:
		// Register multi-pointer element type (C++ checker.cpp add_min_dep_type_info)
		multi_ptr := bt.variant.(Type_Multi_Pointer)
		add_min_dep_type_info(c, multi_ptr.elem)

	case .Array:
		// Register array element and related types (C++ checker.cpp add_min_dep_type_info)
		array := bt.variant.(Type_Array)
		add_min_dep_type_info(c, array.elem)
		add_min_dep_type_info(c, alloc_type_pointer(array.elem))
		add_min_dep_type_info(c, t_int)

	case .Enumerated_Array:
		// Register enumerated array types (C++ checker.cpp add_min_dep_type_info)
		enum_array := bt.variant.(Type_Enumerated_Array)
		add_min_dep_type_info(c, enum_array.index)
		add_min_dep_type_info(c, t_int)
		add_min_dep_type_info(c, enum_array.elem)
		add_min_dep_type_info(c, alloc_type_pointer(enum_array.elem))

	case .Dynamic_Array:
		// Register dynamic array element and allocator (C++ checker.cpp add_min_dep_type_info)
		dyn_array := bt.variant.(Type_Dynamic_Array)
		add_min_dep_type_info(c, dyn_array.elem)
		add_min_dep_type_info(c, alloc_type_pointer(dyn_array.elem))
		add_min_dep_type_info(c, t_int)
		add_min_dep_type_info(c, c.t_allocator)

	case .Slice:
		// Register slice element type (C++ checker.cpp add_min_dep_type_info)
		slice := bt.variant.(Type_Slice)
		add_min_dep_type_info(c, slice.elem)
		add_min_dep_type_info(c, alloc_type_pointer(slice.elem))
		add_min_dep_type_info(c, t_int)

	case .Fixed_Capacity_Dynamic_Array:
		// C++ Reference: checker.cpp add_min_dep_type_info. `[dynamic; N]T` registers
		// its element, a pointer to the element, the backing `[N]T` array, and `int`.
		//
		// LEDGER #709: the port had NO arm here at all -- `.Slice` was followed directly by
		// `.Enum` -- so a fixed-capacity dynamic array contributed NOTHING to the min-dep roster,
		// making the port's roster a strict SUBSET of C++'s for this type kind. Found by diffing
		// the two switches' ARM SETS (#154), not by reading citations; line arithmetic would have
		// walked straight past it. This is #515's family: the same type kind was already missing
		// from `type_size_of` AND `type_align_of`, which measured it as size 0.
		//
		// NOT MEASURABLE BY ANY CURRENT GATE, and that is a fact about the gates. The roster is
		// checker OUTPUT consumed by a backend (see the note above `add_basic_type_information`,
		// LEDGER #637): no diagnostic reads it, `dump_model.odin` EXCLUDES min-dep from
		// DUMP_MODEL_SCHEMA by design, and `finalize_minimum_dependency_type_info` currently has
		// zero callers here. modeldiff returns MODEL-MATCH on a `[dynamic; 8]i32` probe both with
		// and without this arm -- it has no column for the property (LEDGER #155). Landed on the
		// same reasoning #637 was landed on: invisibility to text-comparing gates is not evidence
		// the registration is optional.
		//
		// C++'s arm has NO `break;` and falls through into `case Type_Enum:`, running
		// `add_min_dep_type_info(c, bt->Enum.base_type)` on a non-active union member -- an
		// upstream defect filed as LEDGER #710. That is DELIBERATELY NOT reproduced: this arm
		// terminates normally.
		fcda := bt.variant.(Type_Fixed_Capacity_Dynamic_Array)
		add_min_dep_type_info(c, fcda.elem)
		add_min_dep_type_info(c, alloc_type_pointer(fcda.elem))
		add_min_dep_type_info(c, alloc_type_array(fcda.elem, fcda.capacity))
		add_min_dep_type_info(c, t_int)

	case .Enum:
		// Register enum base type (C++ checker.cpp add_min_dep_type_info)
		enum_type := bt.variant.(Type_Enum)
		add_min_dep_type_info(c, enum_type.base_type)

	case .Union:
		// Register union tag and variant types (C++ checker.cpp add_min_dep_type_info)
		union_type := bt.variant.(Type_Union)

		// Register tag type (C++ checker.cpp add_min_dep_type_info)
		if union_tag_size(actual_type) > 0 {
			add_min_dep_type_info(c, union_tag_type(actual_type))
		} else {
			add_min_dep_type_info(c, c.t_type_info_ptr)
		}

		// Register polymorphic params (C++ checker.cpp add_min_dep_type_info)
		if union_type.polymorphic_params != nil {
			add_min_dep_type_info(c, union_type.polymorphic_params)
		}

		// Register all variant types (C++ checker.cpp add_min_dep_type_info)
		for variant in union_type.variants {
			add_min_dep_type_info(c, variant)
		}

	// Note: C++ registers scope entities in add_min_dep_type_info's Struct arm only
	// (checker.cpp add_min_dep_type_info, the arm immediately below), and that loop
	// exists for SOA structs; the Union arm has no such loop. So there is nothing to
	// port here -- this is a faithful absence, not an omission "for minimal dependency".
	//
	// The old citation was `C++ lines 2488-2507`, which is inside the `#if 0` dead region of
	// add_type_info_type_internal AND is that function's Map/Tuple arms -- it has nothing to do
	// with scope entities in either respect (#721).

	case .Struct:
		// Register struct field types (C++ checker.cpp add_min_dep_type_info)
		struct_type := bt.variant.(Type_Struct)

		// Register scope entities for SOA types (C++ checker.cpp add_min_dep_type_info)
		if struct_type.scope != nil {
			for _, e in struct_type.scope.elements {
				#partial switch struct_type.soa_kind {
				case .Dynamic:
					// StructSoa_Dynamic (C++ checker.cpp add_min_dep_type_info)
					add_min_dep_type_info(c, c.t_type_info_ptr) // append_soa
					add_min_dep_type_info(c, c.t_allocator)
					fallthrough
				case .Slice:
					// StructSoa_Slice (C++ checker.cpp add_min_dep_type_info)
					add_min_dep_type_info(c, t_int)
					add_min_dep_type_info(c, t_uint)
					fallthrough
				case .Fixed:
					// StructSoa_Fixed (C++ checker.cpp add_min_dep_type_info)
					add_min_dep_type_info(c, alloc_type_pointer(e.type))
				case .None:
					// StructSoa_None (C++ checker.cpp add_min_dep_type_info, the switch's
					// `default:` arm. Was cited as 2525-2527, which is inside the `#if 0` dead
					// region of add_type_info_type_internal -- #721.)
					add_min_dep_type_info(c, e.type)
				}
			}
		}

		// Register polymorphic params (C++ checker.cpp add_min_dep_type_info)
		if struct_type.polymorphic_params != nil {
			add_min_dep_type_info(c, struct_type.polymorphic_params)
		}

		// Register field types (C++ checker.cpp add_min_dep_type_info)
		for field in struct_type.fields {
			add_min_dep_type_info(c, field.type)
		}

		// NO comparison-procedure registration here either, and this one was INVENTED outright:
		// the cited "C++ line 2537-2538" is not in add_min_dep_type_info at all (that function
		// starts at checker.cpp:2584 -- 2576 is inside check_procedure_later) -- it points into the `#if 0` block of a DIFFERENT
		// function. The live add_min_dep_type_info Struct arm registers field types and
		// polymorphic params and stops. Removed in #547 PART 5; same over-marking as above.

	case .Map:
		// Register map key, value, and allocator types (C++ checker.cpp add_min_dep_type_info)
		map_type := bt.variant.(Type_Map)
		init_map_internal_types(c, bt)
		add_min_dep_type_info(c, map_type.key)
		add_min_dep_type_info(c, map_type.value)
		add_min_dep_type_info(c, t_uintptr) // hash value
		add_min_dep_type_info(c, c.t_allocator)

	case .Tuple:
		// Register tuple element types (C++ checker.cpp add_min_dep_type_info)
		tuple := bt.variant.(Type_Tuple)
		for var in tuple.variables {
			add_min_dep_type_info(c, var.type)
		}

	case .Proc:
		// Register procedure params and results (C++ checker.cpp add_min_dep_type_info)
		proc_type := bt.variant.(Type_Proc)
		add_min_dep_type_info(c, proc_type.params)
		add_min_dep_type_info(c, proc_type.results)

	case .Simd_Vector:
		// Register SIMD element type (C++ checker.cpp add_min_dep_type_info)
		simd := bt.variant.(Type_Simd_Vector)
		add_min_dep_type_info(c, simd.elem)

	case .Matrix:
		// Register matrix element type (C++ checker.cpp add_min_dep_type_info)
		mat := bt.variant.(Type_Matrix)
		add_min_dep_type_info(c, mat.elem)

	case .Soa_Pointer:
		// Register SOA pointer element type (C++ checker.cpp add_min_dep_type_info)
		soa_ptr := bt.variant.(Type_Soa_Pointer)
		add_min_dep_type_info(c, soa_ptr.elem)

	case .Bit_Field:
		// Register bit field backing type and field types (C++ checker.cpp add_min_dep_type_info)
		bf := bt.variant.(Type_Bit_Field)
		add_min_dep_type_info(c, bf.backing_type)
		for field in bf.fields {
			add_min_dep_type_info(c, field.type)
		}

	case:
		// Unhandled type kind (C++ checker.cpp add_min_dep_type_info)
		panic("add_min_dep_type_info: unhandled type kind")
	}
}

// ======================================================================================
// TYPE INFO FLAGS
// C++ Reference: types.cpp TypeInfoFlag + type_info_flags_of_type
// ======================================================================================

// Type_Info_Flag represents runtime type info flags
// C++ Reference: types.cpp TypeInfoFlag
// IMPORTANT: Must match core:runtime.Type_Info_Flags
Type_Info_Flag :: enum u32 {
	Comparable     = 0, // Type supports == and != (C++ types.cpp TypeInfoFlag)
	Simple_Compare = 1, // Type supports memcmp for comparison (C++ types.cpp TypeInfoFlag)
}

Type_Info_Flags :: bit_set[Type_Info_Flag;u32]

// type_info_flags_of_type computes the runtime type info flags for a type
// C++ Reference: types.cpp type_info_flags_of_type
//
// Returns flags indicating type capabilities:
// - Comparable: Type supports == and != operators
// - Simple_Compare: Type can be compared with memcmp
//
// RETRACTED CLAIM (#714). This comment used to read: "The C++ implementation has a bug on line
// 412 where it sets TypeInfoFlag_Comparable instead of TypeInfoFlag_Simple_Compare. We fix that
// here." THAT IS WRONG, AND THE "FIX" WAS THE DIVERGENCE. C++ (types.cpp:426) writes
//     flags |= TypeInfoFlag_Comparable|TypeInfoFlag_Simple_Compare;
// -- it sets BOTH, deliberately, because simple-comparable is meant to imply comparable in the
// emitted runtime type info. The port set only Simple_Compare, so any type where
// is_type_simple_compare is TRUE and is_type_comparable is FALSE lost the Comparable bit.
//
// That set is NOT empty: `is_type_comparable` returns false outright for a struct with
// `soa_kind != StructSoa_None` (types.cpp), while `is_type_simple_compare` walks the SoA struct's
// fields -- plain arrays of a simple element -- and returns true. So `#soa[4]P` is exactly the
// case the OR exists for. (Two other candidates were checked and are NOT divergent:
// Type_SimdVector is comparable=true unconditionally, and Type_BitField defers to its integer
// backing type, which is always comparable.)
//
// Restored to C++'s behaviour. NOTE the two predicates also unwrap differently -- is_type_comparable
// uses base_type, is_type_simple_compare uses core_type -- which is faithful in C++ and must stay.
type_info_flags_of_type :: proc(t: ^Type) -> Type_Info_Flags {
	if t == nil {
		return {}
	}

	flags: Type_Info_Flags

	// Check if type is comparable (C++ types.cpp type_info_flags_of_type)
	if is_type_comparable(t) {
		flags += {.Comparable}
	}

	// Check if type supports simple comparison (C++ types.cpp type_info_flags_of_type).
	// Sets BOTH bits, as C++ does at types.cpp:426 -- see the retraction above (#714).
	if is_type_simple_compare(t) {
		flags += {.Comparable, .Simple_Compare}
	}

	return flags
}

// ======================================================================================
// TYPE INFO INDEX LOOKUP
// C++ Reference: checker.cpp type_info_index -- C++ has TWO overloads of this name:
// the TypeInfoPair one and the Type* wrapper.
// ======================================================================================

// type_info_index returns the index of a type in the final type info table
// C++ Reference: checker.cpp type_info_index -- C++ has TWO overloads of this name:
// the TypeInfoPair one and the Type* wrapper.
//
// This function looks up the index of a type in the minimum dependency type info set.
// The index is used for:
// 1. typeid_of() builtin - embeds the index in the typeid value
// 2. type_info_of() builtin - indexes into the global type_info array
// 3. Codegen - generates references to the type info data
//
// IMPORTANT: Only call after checking is complete and the index map has been built
// (see checker.cpp check_parsed_files for index map construction -- the old citation
//  7467-7517 into checker.cpp is init_procedures_cmp, an unrelated function; LEDGER #711, #721)
//
// Parameters:
//   - info: Checker info containing the index map
//   - pair: Type and its canonical hash
//   - error_on_failure: If true, panics when type not found
//
// Returns: Index (>= 0) if found, -1 if not found and error_on_failure is false
type_info_index_pair :: proc(info: ^Checker_Info, pair: Type_Info_Pair, error_on_failure: bool) -> i64 {
	// Thread-safe lookup in index map (C++ checker.cpp type_info_index)
	sync.rw_mutex_shared_lock(&info.minimum_dependency_type_info_mutex)
	defer sync.rw_mutex_shared_unlock(&info.minimum_dependency_type_info_mutex)

	entry_index: i64 = -1
	if found, exists := info.min_dep_type_info_index_map[pair.hash]; exists {
		entry_index = found
	}

	// Error handling (C++ checker.cpp type_info_index)
	if error_on_failure && entry_index < 0 {
		type_str := type_to_string(pair.type)
		panic(fmt.tprintf("Type_Info for '%s' could not be found", type_str))
	}

	return entry_index
}

// type_info_index returns the index of a type in the final type info table
// C++ Reference: checker.cpp type_info_index (the Type* overload)
//
// Convenience wrapper that computes the canonical hash and calls type_info_index_pair
type_info_index :: proc(info: ^Checker_Info, t: ^Type, error_on_failure: bool) -> i64 {
	// Normalize type (C++ checker.cpp type_info_index)
	actual_type := default_type(t)
	// Note: C++ also handles t_llvm_bool -> t_bool conversion, but we don't have LLVM types yet

	// Compute canonical hash and lookup (C++ checker.cpp type_info_index)
	hash := type_hash_canonical_type(actual_type)
	return type_info_index_pair(info, Type_Info_Pair{type = actual_type, hash = hash}, error_on_failure)
}

// ======================================================================================
// NOTE: Type identity checking functions are implemented in check_equivalence.odin
// - are_types_identical_unique_tuples: C++ types.cpp are_types_identical_unique_tuples
// - are_types_identical_internal:      C++ types.cpp are_types_identical_internal
//   (the entry point is types.cpp are_types_identical)
// Both were stale AND straddling, by +230 and by ~+450 respectively -- NON-uniform drift inside two
// adjacent lines (#171). The old 2924-2951 spanned is_type_simple_compare/is_type_nearly_simple_compare
// and 2745-2921 spanned six unrelated predicates. #724.
// ======================================================================================

// ====================================================================================
// TYPE INFO SORTING AND COMPARISON
// C++ Reference: name_canonicalization.cpp type_info_pair_cmp
// ======================================================================================

// type_info_pair_cmp compares two Type_Info_Pair values by their hash
// C++ Reference: name_canonicalization.cpp type_info_pair_cmp
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
	// C++ name_canonicalization.cpp type_info_pair_cmp -- simple hash comparison.
	// (The bare "lines 6-9" was CORRECT but unqualified: it points at a DIFFERENT FILE, not
	//  checker.cpp, which is why it looked malformed. File qualifier added -- #153.)
	if x.hash == y.hash {
		return 0
	}
	return x.hash < y.hash ? -1 : +1
}

// ======================================================================================
// TYPE INFO FINALIZATION
// C++ Reference: checker.cpp check_parsed_files
// ======================================================================================

// finalize_minimum_dependency_type_info builds the final type info index
// C++ Reference: checker.cpp check_parsed_files, the block under
// TIME_SECTION("initialize and check for collisions in type info array").
//
// LEDGER #711: the previous citation on this procedure was 7467-7517 into checker.cpp, which is
// `init_procedures_cmp` -- an entirely unrelated function. Another #153: a citation with no
// function name is unverifiable, and this one was simply wrong. The real counterpart is inline
// inside `check_parsed_files`, which is also why the call was never written (#158).
//
// `package_names_are_unique` is C++'s local from check_parsed_files; it gates the collision
// panic.
//
// This function is called after type checking completes. It:
// 1. Extracts all types from min_dep_type_info_set
// 2. Sorts them by canonical hash for consistent ordering
// 3. Builds a hash map for O(1) lookup
// 4. Creates an index map from hash to array position
// 5. Detects hash collisions and reports errors
//
// This must be called before any type_info_index() lookups.
finalize_minimum_dependency_type_info :: proc(c: ^Checker, package_names_are_unique: bool) {
	// #931: **`&c.info`, NOT `c.info`.** `Checker.info` is a VALUE of type `Checker_Info`
	// (checker.odin), so `info := c.info` COPIES THE WHOLE STRUCT and every write below lands in
	// the copy and is DISCARDED WHEN THIS PROCEDURE RETURNS. C++ has no local binding here at all
	// -- checker.cpp check_parsed_files spells out `c->info.type_info_types_hash_map` and
	// `c->info.min_dep_type_info_index_map` on every one of its nine lines.
	//
	// MEASURED BY THE mirc BACKEND, reading `sess.checker.info` after checking a program that
	// imports core:strings/testing/fmt: `TI set=179 hashmap=0 indexmap=0`. The SET is right
	// because `add_type_info_type` writes through `c.info.min_dep_type_info_set` directly
	// (type_info.odin) -- it never took the copy. The two maps this procedure fills were both
	// zero. Consequence downstream: mirc emitted `runtime::type_table` as a nil, zero-length slice
	// and every reflection call SIGILL'd on `len(type_table) == 0`.
	//
	// The report explicitly did not claim a cause and listed three candidates -- that check_files
	// never reaches the call, that the session returns a different Checker, or that the session
	// path skips the phase. It is none of those: the phase RUNS, on the right Checker, and throws
	// its own output away.
	info := &c.info

	// Extract all type info pairs from the set (C++ checker.cpp check_parsed_files)
	type_info_types := make([dynamic]Type_Info_Pair, 0, len(info.min_dep_type_info_set))
	defer delete(type_info_types)

	for _, pair in info.min_dep_type_info_set {
		append(&type_info_types, pair)
	}

	// Sort by hash for consistent ordering (C++ checker.cpp check_parsed_files)
	slice.sort_by(type_info_types[:], proc(i, j: Type_Info_Pair) -> bool {
		return type_info_pair_cmp(i, j) < 0
	})

	// Initialize hash map and index map (C++ checker.cpp check_parsed_files)
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

	// Insert each type into hash map using linear probing (C++ checker.cpp check_parsed_files)
	for tt in type_info_types {
		// Find insertion slot using linear probing (C++ checker.cpp check_parsed_files)
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

		// Add to index map, checking for collisions (C++ checker.cpp check_parsed_files)
		if existing_index, exists := info.min_dep_type_info_index_map[tt.hash]; exists {
			// C++ checker.cpp check_parsed_files: `if (package_names_are_unique && exists)`.
			// Its own comment: "Because we've already written a nice error about a duplicate
			// package declaration, skip this panic if the package names aren't unique."
			// LEDGER #711: the port had NO such gate, so it would have aborted on input where C++
			// deliberately stays quiet. Note the map WRITE is unconditional in both (C++'s
			// map_set_if_not_previously_exists runs before the gate); only the panic is gated.
			if !package_names_are_unique {
				continue
			}

			// Hash collision detected - verify types are truly different
			other := info.type_info_types_hash_map[existing_index]

			// If types are identical (unique tuples), this is ok - same type, same hash
			if are_types_identical_unique_tuples(tt.type, other.type) {
				continue
			}

			// Real hash collision - different types with same hash
			// This is a critical error that indicates a hash function bug
			// C++ checker.cpp check_parsed_files: GB_PANIC with canonical strings
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

	// Sanity check (C++ checker.cpp check_parsed_files)
	assert(len(info.min_dep_type_info_index_map) <= len(type_info_types), "Index map should not exceed type count")
}

// ======================================================================================
// TYPE INFO COLLECTION FOR DEFINITIONS
// C++ Reference: checker.cpp add_type_info_for_type_definitions
// ======================================================================================

// add_type_info_for_type_definitions registers RTTI for all defined types
// C++ Reference: checker.cpp add_type_info_for_type_definitions
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
	// Iterate all type definitions
	// (C++ checker.cpp add_type_info_for_type_definitions)
	for e in c.info.definitions {
		// Filter for type names (C++ checker.cpp add_type_info_for_type_definitions -- ONE C++ `if` performs
		// both this check and the sibling one below, which is why both cite the same line)
		if e.kind != .Type_Name {
			continue
		}

		// Ensure type is resolved and typed (C++ checker.cpp add_type_info_for_type_definitions -- ONE C++ `if` performs
		// both this check and the sibling one below, which is why both cite the same line)
		if e.type == nil || !is_type_typed(e.type) {
			continue
		}

		// Check if type has dependencies
		// (C++ checker.cpp add_type_info_for_type_definitions)
		// Note: C++ has an #if 0 block with an additional align check that's disabled
		// We implement the active code path only
		if e.min_dep_count <= 0 {
			continue
		}

		// Register type for RTTI generation
		// (C++ checker.cpp add_type_info_for_type_definitions)
		add_type_info_type(&c.builtin_ctx, e.type)
	}
}

// ======================================================================================
// TYPE CANONICALIZATION
// ======================================================================================

// NOTE: type_hash_canonical_type and type_to_canonical_string are implemented
// in name_canonicalization.odin.
// C++ Reference: name_canonicalization.cpp type_hash_canonical_type
//                name_canonicalization.cpp type_to_canonical_string
// (One range was cited for BOTH procedures, and it covered neither: 372-399 lands in the
//  type_writer_append* helpers. Two procedures need two citations -- #724.)
