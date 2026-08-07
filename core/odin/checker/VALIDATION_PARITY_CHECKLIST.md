# Odin Checker Validation Parity Checklist

**Status:** `[x]` Done | `[~]` Partial | `[ ]` Missing
**Coverage:** ~560 of ~560 C++ functions have an Odin counterpart *by name*.
**Last updated:** 2026-08-06

For implementation details, see [CPP_PARITY_GAPS.md](CPP_PARITY_GAPS.md).

> **What `[x]` does and does not assert.** It asserts that a counterpart EXISTS and its body
> was read against C++. It does **not** assert that the function is CALLED from the same places,
> or called at all. That gap is not hypothetical — it is where the two largest recent defects
> lived:
>
> * `add_comparison_procedures_for_fields` was `[x]` with a faithful body while the live C++
>   call site in `check_comparison` had never been wired, and two port-only call sites existed
>   that C++ does not have (one of them modelling a `#if 0` block, one invented with a
>   fabricated citation). #547 PART 5.
> * `check_binary_expr_dependency` was `[x]` and did not exist at all. #547 PART 1.
> * `add_map_*_dependencies` was `[x]` "(2 implemented)" while one of the two was dead code,
>   a third helper was missing, and both took the wrong branch of a build-context test. #564.
>
> So: a row being `[x]` is not evidence. Before relying on one, check the call sites on BOTH
> sides — `grep -rn '<name>' src/` against the port — and remember that a C++ occurrence inside
> `#if 0` is not a call site. Rows corrected by measurement carry their task number.

---

## 1. Expression Checking (check_expr.cpp → check_expr.odin)

### 1.1 Core Infrastructure
| St | Function | Odin Location |
|----|----------|---------------|
| [x] | check_expr | check_expr.odin:2491 |
| [x] | check_multi_expr | check_expr.odin:2656 |
| [x] | check_multi_expr_or_type | check_expr.odin:2591 |
| [x] | check_expr_or_type | check_expr.odin:2525 |
| [x] | check_expr_base | check_expr.odin:4378 |
| [x] | check_expr_with_type_hint | check_expr.odin:2656 |
| [x] | check_not_tuple | check_expr.odin:2542 |

### 1.2 Operand Handling
| St | Function | Odin Location |
|----|----------|---------------|
| [x] | is_operand_value | check_expr.odin:5790 |
| [x] | is_operand_nil | check_expr.odin:1230 |
| [x] | is_operand_uninit | check_expr.odin:1241 |
| [x] | error_operand_not_expression | check_expr.odin:3006 |
| [x] | error_operand_no_value | check_expr.odin:2622 |

### 1.3 Type Conversion & Assignment
| St | Function | Odin Location |
|----|----------|---------------|
| [x] | convert_to_typed | check_expr.odin:2193 |
| [x] | check_is_assignable_to | check_equivalence.odin:830 |
| [x] | check_is_assignable_to_with_score | check_proc_group.odin:261 |
| [x] | check_distance_between_types | check_equivalence.odin:491 |
| [x] | assign_score_function | check_proc_group.odin:156 |
| [x] | check_assignment | check_expr.odin:4707 |
| [x] | check_assignment_error_suggestion | check_expr_helpers.odin:1270 |
| [x] | convert_untyped_error | check_expr.odin:2212 |
| [x] | convert_exact_value_for_type | check_expr_helpers.odin:828 |

### 1.4 Identifier & Selector
| St | Function | Odin Location |
|----|----------|---------------|
| [x] | check_ident | check_expr.odin:203 |
| [x] | check_selector | check_expr.odin:2623 |
| [x] | check_entity_from_ident_or_selector | check_decl.odin:877 |
| [x] | is_entity_declared_for_selector | entity_helpers.odin:1269 |
| [x] | entity_from_expr | entity_helpers.odin:153 |
| [x] | check_identifier_exists | entity_helpers.odin:417 (inline in add_entity_with_name) |

### 1.5 Unary & Binary Operators
| St | Function | Odin Location |
|----|----------|---------------|
| [x] | check_unary_op | check_expr.odin:1130 |
| [x] | check_unary_expr | check_expr.odin:1067 |
| [x] | check_binary_op | check_expr.odin:837 |
| [x] | check_binary_expr | check_expr.odin:933 |
| [x] | check_binary_matrix | check_expr.odin:905 |
| [x] | check_binary_array_expr | check_expr.odin:1039 |
| [x] | check_comparison | check_expr.odin:899 |
| [x] | check_shift | check_expr.odin:1112 |
| [x] | check_binary_expr_dependency | check_decl_helpers.odin:1150 (via add_entity_use->add_declaration_dependency) |

### 1.6 Casting & Transmute
| St | Function | Odin Location |
|----|----------|---------------|
| [x] | check_is_castable_to | check_expr.odin:5401 |
| [x] | check_cast_internal | check_expr.odin:5629 |
| [x] | check_cast | check_expr.odin:5557 |
| [x] | check_cast_error_suggestion | check_expr_helpers.odin:1352 |
| [x] | check_transmute | check_expr.odin:5620 |

### 1.7 Constant Handling
| St | Function | Odin Location |
|----|----------|---------------|
| [x] | check_init_constant | check_decl.odin:662 |
| [x] | check_representable_as_constant | check_expr.odin:1636 |
| [x] | check_is_expressible | check_expr.odin:2175 |
| [x] | check_integer_exceed_suggestion | check_expr_helpers.odin:1392 |
| [x] | get_constant_field | check_expr.odin:3068 (get_constant_field_value) |
| [x] | get_constant_field_single | check_expr.odin:3166 |
| [x] | is_exact_value_zero | exact_value.odin:298 |
| [x] | check_for_integer_division_by_zero | check_expr.odin:1262 (inline in check_binary_expr) |

### 1.8 Indexing & Slicing
| St | Function | Odin Location |
|----|----------|---------------|
| [x] | check_index_expr | check_expr.odin:3225 |
| [x] | check_index_value | check_expr.odin:3157 |
| [x] | check_set_index_data | check_expr.odin:3030 |
| [x] | check_slice_expr | check_expr.odin:3374 |
| [x] | check_matrix_index_expr | check_expr.odin:3833 |
| [x] | check_range | check_expr_helpers.odin:1071 |

### 1.9 Call Expressions
| St | Function | Odin Location |
|----|----------|---------------|
| [x] | check_call_expr | check_expr.odin:5764 |
| [x] | check_call_arguments | check_expr.odin:5965 |
| [x] | check_call_arguments_internal | check_proc_group.odin:510 |
| [x] | check_call_arguments_proc_group | check_proc_group.odin:823 |
| [x] | check_call_arguments_single | check_proc_group.odin:684 |
| [x] | check_call_parameter_mixture | check_proc_group.odin:526 |
| [x] | check_call_expr_as_type_cast | check_expr.odin:7118 (inline in check_call_expr) |
| [x] | check_named_arguments | check_proc_group.odin:340 |
| [x] | check_unpack_arguments | check_decl_helpers.odin:108 |
| [x] | check_assignment_arguments | check_stmt.odin:929 |
| [x] | is_call_expr_field_value | check_expr_helpers.odin:1236 |
| [x] | populate_proc_parameter_list | check_type.odin:3176 (check_get_params) |
| [x] | get_procedure_param_count_excluding_defaults | check_proc_group.odin:184 |
| [x] | lookup_procedure_parameter | check_proc_group.odin:301 |

### 1.10 Polymorphic Procedures
| St | Function | Odin Location |
|----|----------|---------------|
| [x] | find_or_generate_polymorphic_procedure | check_poly_proc.odin:98 |
| [x] | find_or_generate_polymorphic_procedure_from_parameters | check_poly_proc.odin:76 |
| [x] | check_polymorphic_procedure_assignment | check_poly_proc.odin:41 |
| [x] | check_type_specialization_to | check_type.odin:3827 |
| [x] | is_polymorphic_type_assignable | check_type.odin:4041 |
| [x] | polymorphic_assign_index | check_type.odin:3751 |
| [x] | find_polymorphic_record_entity | check_type.odin:1540 |
| [x] | check_polymorphic_record_type | check_type.odin:1647 |
| [x] | lookup_polymorphic_record_parameter | check_type.odin:1629 |

### 1.11 Compound Literals
| St | Function | Odin Location |
|----|----------|---------------|
| [x] | check_compound_literal | check_compound_lit.odin:264 |
| [x] | check_compound_literal_field_values | check_compound_lit.odin:21 |
| [x] | check_is_operand_compound_lit_constant | check_expr_helpers.odin:97 |
| [x] | check_for_dynamic_literals | check_expr_helpers.odin:1248 |
| [x] | is_expr_inferred_fixed_array | check_expr.odin:39 |

### 1.12 Type Assertion & Optional
| St | Function | Odin Location |
|----|----------|---------------|
| [x] | check_type_assertion | check_expr.odin:3701 |
| [x] | check_promote_optional_ok | check_expr.odin:4065 |
| [x] | make_optional_ok_type | types.odin:2161 |

### 1.13 Special Expressions
| St | Function | Odin Location |
|----|----------|---------------|
| [x] | check_ternary_if_expr | check_expr.odin:3558 |
| [x] | check_ternary_when_expr | check_expr.odin:3656 |
| [x] | check_or_else_expr | check_expr.odin:4073 |
| [x] | check_or_return_expr | check_expr.odin:4166 |
| [x] | check_or_branch_expr | check_expr.odin:4257 |
| [x] | check_or_else_right_type | check_expr.odin:4164 |
| [x] | check_or_else_split_types | check_expr.odin:4202 |
| [x] | check_or_return_split_types | check_expr.odin:4237 |
| [x] | check_or_else_expr_no_value_error | check_expr.odin:5062 |
| [x] | check_implicit_selector_expr | check_expr.odin:3993 |
| [x] | attempt_implicit_selector_expr | check_expr.odin:3960 |
| [x] | check_selector_call_expr | check_expr.odin:5545 (inline) |
| [x] | check_basic_directive_expr | check_expr.odin:5004 |

### 1.14-1.29 Utilities & Support
| St | Function | Odin Location |
|----|----------|---------------|
| [x] | determine_swizzle_array_type | types.odin:2335 |
| [x] | exact_bit_set_all_set_mask | check_expr_helpers.odin:973 |
| [x] | make_soa_struct_* | check_type.odin:273-291 |
| [ ] | add_map_*_dependencies | entity_helpers.odin:776,785 — **NOT DONE, see #564**. Both helpers take the `build_context.dynamic_map_calls` TRUE branch unconditionally; the default build takes the FALSE branch. add_map_set_dependencies has zero call sites. add_map_reserve_dependencies does not exist and its name is registered from the set-helper instead. |
| [x] | add_comparison_procedures_for_fields | type_info.odin:234 — body faithful. **Call sites were the defect (#547 PART 5)**: the live C++ site in check_comparison (check_expr.cpp:3278) was never wired, and the port had two sites with no live C++ counterpart (one modelling `#if 0` code, one invented). Now: check_expr.odin comparison site + own Struct recursion, matching C++'s two live sites. |
| [x] | compare_exact_values_compound_lit | exact_value.odin:1386 |
| [x] | expr_to_string | check_expr_helpers.odin:142 |
| [x] | write_expr_to_string | check_expr_helpers.odin:167 |
| [x] | update_untyped_expr_type | check_expr.odin:1439 |
| [x] | update_untyped_expr_value | check_expr.odin:1580 |
| [x] | make_operand_from_node | check_expr_helpers.odin:805 |
| [x] | is_diverging_expr | check_stmt.odin:21 |
| [x] | check_cycle | entity_helpers.odin:1206 |
| [x] | check_get/set/remove_expr_info | check_expr.odin:1249-1298 |
| [x] | check_is_not_addressable | check_expr_helpers.odin:887 |
| [x] | is_type_valid_atomic_type | types.odin:2955 |
| [x] | add_constant_switch_case | check_stmt.odin:1756 (inline in check_switch_stmt) |
| [x] | evaluate_where_clauses | check_proc.odin:808 |
| [x] | check_did_you_mean_type | error.odin:1314 |
| [x] | check_did_you_mean_scope | error.odin:1355 |

---

## 2. Statement Checking (check_stmt.cpp → check_stmt.odin)

| St | Function | Odin Location |
|----|----------|---------------|
| [x] | check_stmt | check_stmt.odin:603-615 |
| [x] | check_stmt_internal | check_stmt.odin:617-696 |
| [x] | check_stmt_list | check_stmt.odin:497-601 |
| [x] | check_is_terminating | check_stmt.odin:398-493 |
| [x] | check_is_terminating_list | check_stmt.odin:240-262 |
| [x] | check_has_break | check_stmt.odin:302-396 |
| [x] | check_has_break_list | check_stmt.odin:264-273 |
| [x] | check_has_break_expr | check_stmt.odin:275-289 |
| [x] | is_diverging_expr | check_stmt.odin:21-75 |
| [x] | is_diverging_stmt | check_stmt.odin:77-85 |
| [x] | contains_deferred_call | check_stmt.odin:87-129 |
| [x] | check_label | check_stmt.odin:148-217 |
| [x] | label_string | check_stmt.odin:219-236 |
| [x] | check_block_stmt_for_errors | check_stmt.odin:531 |
| [x] | check_unsafe_return | check_stmt.odin:1094 |
| [x] | check_init_variable | check_stmt.odin:26-163 |
| [x] | error_var_decl_identifier | entity_helpers.odin:561 (inline) |
| [x] | check_if_stmt | check_stmt.odin |
| [x] | check_when_stmt | check_stmt.odin |
| [x] | check_for_stmt | check_stmt.odin |
| [x] | check_range_stmt | check_stmt.odin |
| [x] | check_unroll_range_stmt | check_stmt.odin |
| [x] | check_switch_stmt | check_stmt.odin |
| [x] | check_type_switch_stmt | check_stmt.odin |
| [x] | check_return_stmt | check_stmt.odin |
| [x] | check_defer_stmt | check_stmt.odin |
| [x] | check_branch_stmt | check_stmt.odin |
| [x] | check_using_stmt | check_stmt.odin:3019 |
| [x] | check_assign_stmt | check_stmt.odin |
| [x] | check_expr_stmt | check_stmt.odin:698-778 |

---

## 3. Type Checking (check_type.cpp → check_type.odin)

| St | Function | Odin Location |
|----|----------|---------------|
| [x] | check_type_internal | check_type.odin:17-186 |
| [x] | check_poly_type | check_type.odin:241-313 |
| [x] | check_pointer_type | check_type.odin:316-320 |
| [x] | check_multi_pointer_type | check_type.odin:323-339 |
| [x] | check_array_type_internal | check_type.odin:341-506 |
| [x] | check_dynamic_array_type | check_type.odin:508-513 |
| [x] | check_struct_type | check_type.odin:535-655 |
| [x] | check_struct_fields | check_type.odin:657-831 |
| [x] | check_custom_align | check_type.odin:837-902 |
| [x] | check_record_polymorphic_params | check_type.odin:904-1101 |
| [x] | ensure_polymorphic_record_entity_has_gen_types | check_type.odin:1157 |
| [x] | add_polymorphic_record_entity | check_type.odin:1178-1256 |
| [x] | is_type_polymorphic | check_type.odin:1260-1447 |
| [x] | get_record_polymorphic_params | check_type.odin:1449-1483 |
| [x] | type_deref | check_type.odin:1503-1537 |
| [x] | populate_using_entity_scope | check_type.odin:1606 |
| [x] | check_bit_set_type | check_type.odin:2058 |
| [x] | check_map_type_expr | check_type.odin:2320 |
| [x] | check_procedure_type | check_type.odin:2346 |
| [x] | check_get_params | check_type.odin:2841 |
| [x] | check_get_results | check_type.odin:3476 |
| [x] | check_procedure_param_polymorphic_type | check_type.odin:3637 |
| [x] | handle_parameter_value | check_type.odin:2714 |
| [x] | check_type_specialization_to | check_type.odin:3827 |
| [x] | is_valid_bit_field_backing_type | types.odin:3666 |
| [x] | init_map_internal_types | types.odin:2180 |
| [x] | check_bit_field_type | check_type.odin:2368 |
| [x] | check_matrix_type | check_type.odin:2545 |
| [x] | complete_soa_type | check_type.odin:4928 |
| [x] | map_cell_size_and_len | types.odin:2204 |
| [x] | get_map_cell_type | types.odin:2234 |
| [x] | init_map_internal_debug_types | types.odin:2247 |
| [x] | add_map_key_type_dependencies | entity_helpers.odin:745 |

---

## 4. Declaration Checking (check_decl.cpp → check_decl.odin)

| St | Function | Odin Location |
|----|----------|---------------|
| [x] | check_init_variable | check_decl.odin:26-163 |
| [x] | check_init_variables | check_decl.odin:166-195 |
| [x] | override_entity_in_scope | check_decl.odin:376-415 |
| [x] | check_global_variable_decl | check_decl.odin:198-373 |
| [x] | check_entity_decl | check_decl.odin |
| [x] | check_const_decl | check_decl.odin:716 |
| [x] | check_type_decl | check_decl_helpers.odin:1267 |
| [x] | check_collect_entities | check_collect.odin:724 |
| [x] | check_collect_value_decl | check_collect.odin:840 |
| [x] | check_proc_body | check_proc.odin:1479 |
| [x] | evaluate_where_clauses | check_proc.odin:808 |
| [x] | check_scope_usage | check_proc.odin:1094 |
| [x] | check_proc_group_decl | check_proc_group.odin |
| [x] | are_proc_types_overload_safe | check_proc_group.odin:62 |
| [x] | check_delayed_file_import_entity | check_collect.odin:1306 (process_delayed_import_decls) |
| [x] | check_objc_methods | check_decl_helpers.odin:1629 |
| [x] | add_deps_from_child_to_parent | check_proc.odin:1050 |

---

## 5. Builtin Checking (check_builtin.cpp → check_builtin.odin)

**Summary:** 240/248 implemented (97%)

| Category | Implemented | Total |
|----------|-------------|-------|
| Core Builtins | 27 | 27 |
| Atomic Builtins | 19 | 19 |
| Objective-C | 8 | 8 |
| SIMD | 62 | 62 |
| Type Intrinsics | 60 | 60 |
| Math/Bit Intrinsics | 17 | 17 |
| Memory Intrinsics | 20 | 20 |
| Miscellaneous Intrinsics | 6 | 6 |
| WebAssembly Intrinsics | 4 | 4 |
| Matrix Operations | 4 | 4 |
| Constant Operations | 6 | 6 |
| Platform-Specific | 4 | 4 |
| Additional Core | 3 | 3 |

**Newly Implemented Core Builtins:**
- quaternion (check_builtin.odin:2886)
- jmag, kmag (check_builtin.odin:2943)
- expand_values, compress_values (check_builtin.odin:2984, 3020)
- soa_zip, soa_unzip (check_builtin.odin:3077, 3107)
- unreachable, raw_data (check_builtin.odin:3134, 3151)

**Newly Implemented Memory Intrinsics (check_builtin.odin:4607-4969):**
- alloca, cpu_relax, trap, debug_trap
- mem_copy, mem_copy_non_overlapping, mem_zero, mem_zero_volatile
- ptr_offset, ptr_sub
- volatile_store, volatile_load, unaligned_store, unaligned_load
- non_temporal_store, non_temporal_load
- prefetch_read_instruction, prefetch_read_data, prefetch_write_instruction, prefetch_write_data

**Newly Implemented Atomic Intrinsics:**
- atomic_type_is_lock_free (check_builtin.odin:811)

**Newly Implemented Objective-C Builtins:**
- objc_block (check_builtin.odin:1371) - partial implementation
- objc_super (check_builtin.odin:1479) - partial implementation

**Newly Implemented Miscellaneous Intrinsics (check_builtin.odin:5198-5330):**
- is_package_imported, read_cycle_counter, read_cycle_counter_frequency
- expect, syscall, syscall_bsd

**Newly Implemented WebAssembly Intrinsics (check_builtin.odin:5332-5516):**
- wasm_memory_grow, wasm_memory_size
- wasm_memory_atomic_wait32, wasm_memory_atomic_notify32

**Newly Implemented Matrix Operations (check_builtin.odin:5564-5726):**
- hadamard_product, matrix_flatten, outer_product, transpose

**Newly Implemented Constant Operations (check_builtin.odin:5729-5870):**
- constant_ceil, constant_floor, constant_round, constant_trunc
- constant_log2, constant_utf16_cstring

**Newly Implemented Platform-Specific Intrinsics (check_builtin.odin:5873-6009):**
- x86_cpuid, x86_xgetbv, valgrind_client_request, has_target_feature

**Newly Implemented Additional Core Builtins (check_builtin.odin:6011-6162):**
- concatenate, soa_struct, procedure_of

See CPP_PARITY_GAPS.md for full list of missing builtins.

---

## 6. Checker Core (checker.cpp)

**Summary:** 51/69 implemented (74%)

| Category | Done | Partial | Missing |
|----------|------|---------|---------|
| Scope Management | 14 | 2 | 0 |
| Vetting | 7 | 1 | 0 |
| Global Entity | 2 | 0 | 0 |
| Imports/Exports | 4 | 2 | 0 |
| Procedure Processing | 7 | 2 | 1 |
| Entity Graphs | 3 | 1 | 0 |
| Cycle & Order | 4 | 0 | 0 |
| Threading | 0 | ~20 | 0 |

### Checker Core Functions
| St | Function | Location |
|----|----------|----------|
| [x] | check_for_type_cycles | check_files.odin:330 |
| [x] | check_for_inline_cycles | check_files.odin:352 |
| [x] | check_files (check_parsed_files) | check_files.odin:37 |
| [x] | check_scope_decls | check_stmt.odin:92 |
| [x] | check_unique_package_names | check_files.odin:433 |

---

## Progress Summary

| File | Functions | Status |
|------|-----------|--------|
| check_expr | ~185 | 71% verified |
| check_stmt | ~30 | 93% implemented |
| check_type | ~30 | 80% implemented |
| check_decl | ~20 | 85% implemented |
| check_builtin | ~231 | 82% implemented |
| checker core | ~69 | 72% implemented |
| **Total** | **~560** | **83% verified** |

---

## Critical Gaps (P0)

1. ~~**check_bit_field_type** - 208 lines C++~~ ✅ DONE (check_type.odin:2368)
2. ~~**check_matrix_type** - 52 lines C++~~ ✅ DONE (check_type.odin:2545)
3. ~~**Type intrinsics** - ~55 missing builtins~~ ✅ DONE (check_builtin.odin:3216-4176, 60 intrinsics)
4. ~~**Math/Bit intrinsics** - ~20 missing builtins~~ ✅ DONE (check_builtin.odin:4206-4559, 17 intrinsics)
5. **Memory intrinsics** - ~38 missing builtins
6. **SOA completion** - Threading dependent

See [CPP_PARITY_GAPS.md](CPP_PARITY_GAPS.md) for implementation details.