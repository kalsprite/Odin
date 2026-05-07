# Odin Built-in Procedures

*Extracted from: src/checker_builtin_procs.hpp*

## Legend

- **Args**: Number of required arguments
- **Variadic**: Whether additional arguments are accepted
- **Kind**: Expr_Expr (returns value) or Expr_Stmt (no return)
- **Diverging**: Procedure never returns (e.g., `unreachable`, `trap`)

---

## 1. Core Built-ins (builtin package)

### 1.1 Length and Capacity

| Name | Args | Variadic | Kind | Description |
|------|------|----------|------|-------------|
| `len` | 1 | No | Expr | Length of array, slice, string, map |
| `cap` | 1 | No | Expr | Capacity of slice, dynamic array, map |

### 1.2 Type Information

| Name | Args | Variadic | Kind | Description |
|------|------|----------|------|-------------|
| `size_of` | 1 | No | Expr | Size in bytes |
| `align_of` | 1 | No | Expr | Alignment in bytes |
| `offset_of` | 1 | Yes | Expr | Field offset in bytes |
| `offset_of_by_string` | 2 | No | Expr | Field offset by string name |
| `type_of` | 1 | No | Expr | Type of expression |
| `type_info_of` | 1 | No | Expr | Type_Info pointer |
| `typeid_of` | 1 | No | Expr | typeid value |

### 1.3 Swizzle

| Name | Args | Variadic | Kind | Description |
|------|------|----------|------|-------------|
| `swizzle` | 1 | Yes | Expr | Reorder vector/array elements |

### 1.4 Complex/Quaternion

| Name | Args | Variadic | Kind | Description |
|------|------|----------|------|-------------|
| `complex` | 2 | No | Expr | Construct complex from real, imag |
| `quaternion` | 4 | No | Expr | Construct quaternion from components |
| `real` | 1 | No | Expr | Real component |
| `imag` | 1 | No | Expr | Imaginary component |
| `jmag` | 1 | No | Expr | J component (quaternion) |
| `kmag` | 1 | No | Expr | K component (quaternion) |
| `conj` | 1 | No | Expr | Complex/quaternion conjugate |

### 1.5 Value Manipulation

| Name | Args | Variadic | Kind | Description |
|------|------|----------|------|-------------|
| `expand_values` | 1 | No | Expr | Expand struct to multiple values |
| `compress_values` | 1 | Yes | Expr | Compress values into struct |

### 1.6 Math

| Name | Args | Variadic | Kind | Description |
|------|------|----------|------|-------------|
| `min` | 1 | Yes | Expr | Minimum of values |
| `max` | 1 | Yes | Expr | Maximum of values |
| `abs` | 1 | No | Expr | Absolute value |
| `clamp` | 3 | No | Expr | Clamp value to range |

### 1.7 SOA Operations

| Name | Args | Variadic | Kind | Description |
|------|------|----------|------|-------------|
| `soa_zip` | 1 | Yes | Expr | Zip SOA slices into AOS iterator |
| `soa_unzip` | 1 | No | Expr | Unzip AOS to SOA |

### 1.8 Control Flow

| Name | Args | Variadic | Kind | Description |
|------|------|----------|------|-------------|
| `unreachable` | 0 | No | Expr | Mark unreachable code (diverging) |

### 1.9 Data Access

| Name | Args | Variadic | Kind | Description |
|------|------|----------|------|-------------|
| `raw_data` | 1 | No | Expr | Get raw pointer from slice/array |

---

## 2. Intrinsics (intrinsics package)

### 2.1 Package/Feature Detection

| Name | Args | Variadic | Kind | Description |
|------|------|----------|------|-------------|
| `is_package_imported` | 1 | No | Expr | Check if package is imported |
| `has_target_feature` | 1 | No | Expr | Check CPU feature availability |

### 2.2 Constant Math

| Name | Args | Variadic | Kind | Description |
|------|------|----------|------|-------------|
| `constant_log2` | 1 | No | Expr | Compile-time log2 |
| `constant_floor` | 1 | No | Expr | Compile-time floor |
| `constant_trunc` | 1 | No | Expr | Compile-time truncate |
| `constant_ceil` | 1 | No | Expr | Compile-time ceiling |
| `constant_round` | 1 | No | Expr | Compile-time round |

### 2.3 Matrix Operations

| Name | Args | Variadic | Kind | Description |
|------|------|----------|------|-------------|
| `transpose` | 1 | No | Expr | Matrix transpose |
| `outer_product` | 2 | No | Expr | Vector outer product |
| `hadamard_product` | 2 | No | Expr | Element-wise multiply |
| `matrix_flatten` | 1 | No | Expr | Flatten matrix to array |

### 2.4 SOA Type Construction

| Name | Args | Variadic | Kind | Description |
|------|------|----------|------|-------------|
| `soa_struct` | 2 | No | Expr | Create SOA struct type |

### 2.5 Array Operations

| Name | Args | Variadic | Kind | Description |
|------|------|----------|------|-------------|
| `concatenate` | 2 | Yes | Expr | Concatenate arrays |

### 2.6 Low-Level Runtime

| Name | Args | Variadic | Kind | Description |
|------|------|----------|------|-------------|
| `alloca` | 2 | No | Expr | Stack allocation |
| `cpu_relax` | 0 | No | Stmt | CPU pause hint |
| `trap` | 0 | No | Expr | Trigger trap (diverging) |
| `debug_trap` | 0 | No | Stmt | Debug breakpoint |
| `read_cycle_counter` | 0 | No | Expr | Read CPU cycle counter |
| `read_cycle_counter_frequency` | 0 | No | Expr | Cycle counter frequency |

### 2.7 Bit Manipulation

| Name | Args | Variadic | Kind | Description |
|------|------|----------|------|-------------|
| `count_ones` | 1 | No | Expr | Population count |
| `count_zeros` | 1 | No | Expr | Count zero bits |
| `count_trailing_zeros` | 1 | No | Expr | Trailing zero count |
| `count_leading_zeros` | 1 | No | Expr | Leading zero count |
| `reverse_bits` | 1 | No | Expr | Reverse bit order |
| `byte_swap` | 1 | No | Expr | Swap byte order |

### 2.8 Overflow Arithmetic

| Name | Args | Variadic | Kind | Description |
|------|------|----------|------|-------------|
| `overflow_add` | 2 | No | Expr | Add with overflow flag |
| `overflow_sub` | 2 | No | Expr | Subtract with overflow flag |
| `overflow_mul` | 2 | No | Expr | Multiply with overflow flag |

### 2.9 Saturating Arithmetic

| Name | Args | Variadic | Kind | Description |
|------|------|----------|------|-------------|
| `saturating_add` | 2 | No | Expr | Saturating add |
| `saturating_sub` | 2 | No | Expr | Saturating subtract |

### 2.10 Floating Point

| Name | Args | Variadic | Kind | Description |
|------|------|----------|------|-------------|
| `sqrt` | 1 | No | Expr | Square root |
| `fused_mul_add` | 3 | No | Expr | Fused multiply-add |

### 2.11 Memory Operations

| Name | Args | Variadic | Kind | Description |
|------|------|----------|------|-------------|
| `mem_copy` | 3 | No | Stmt | Copy memory (may overlap) |
| `mem_copy_non_overlapping` | 3 | No | Stmt | Copy non-overlapping memory |
| `mem_zero` | 2 | No | Stmt | Zero memory |
| `mem_zero_volatile` | 2 | No | Stmt | Zero memory (volatile) |

### 2.12 Pointer Arithmetic

| Name | Args | Variadic | Kind | Description |
|------|------|----------|------|-------------|
| `ptr_offset` | 2 | No | Expr | Offset pointer |
| `ptr_sub` | 2 | No | Expr | Pointer difference |

### 2.13 Volatile/Unaligned Access

| Name | Args | Variadic | Kind | Description |
|------|------|----------|------|-------------|
| `volatile_store` | 2 | No | Stmt | Volatile store |
| `volatile_load` | 1 | No | Expr | Volatile load |
| `unaligned_store` | 2 | No | Stmt | Unaligned store |
| `unaligned_load` | 1 | No | Expr | Unaligned load |
| `non_temporal_store` | 2 | No | Stmt | Non-temporal store |
| `non_temporal_load` | 1 | No | Expr | Non-temporal load |

### 2.14 Prefetch

| Name | Args | Variadic | Kind | Description |
|------|------|----------|------|-------------|
| `prefetch_read_instruction` | 2 | No | Stmt | Prefetch for instruction read |
| `prefetch_read_data` | 2 | No | Stmt | Prefetch for data read |
| `prefetch_write_instruction` | 2 | No | Stmt | Prefetch for instruction write |
| `prefetch_write_data` | 2 | No | Stmt | Prefetch for data write |

### 2.15 Atomic Operations

| Name | Args | Variadic | Kind | Description |
|------|------|----------|------|-------------|
| `atomic_type_is_lock_free` | 1 | No | Expr | Check if type is lock-free |
| `atomic_thread_fence` | 1 | No | Stmt | Thread memory fence |
| `atomic_signal_fence` | 1 | No | Stmt | Signal handler fence |
| `atomic_store` | 2 | No | Stmt | Atomic store |
| `atomic_store_explicit` | 3 | No | Stmt | Atomic store with ordering |
| `atomic_load` | 1 | No | Expr | Atomic load |
| `atomic_load_explicit` | 2 | No | Expr | Atomic load with ordering |
| `atomic_add` | 2 | No | Expr | Atomic add, returns old |
| `atomic_add_explicit` | 3 | No | Expr | Atomic add with ordering |
| `atomic_sub` | 2 | No | Expr | Atomic subtract, returns old |
| `atomic_sub_explicit` | 3 | No | Expr | Atomic subtract with ordering |
| `atomic_and` | 2 | No | Expr | Atomic AND, returns old |
| `atomic_and_explicit` | 3 | No | Expr | Atomic AND with ordering |
| `atomic_nand` | 2 | No | Expr | Atomic NAND, returns old |
| `atomic_nand_explicit` | 3 | No | Expr | Atomic NAND with ordering |
| `atomic_or` | 2 | No | Expr | Atomic OR, returns old |
| `atomic_or_explicit` | 3 | No | Expr | Atomic OR with ordering |
| `atomic_xor` | 2 | No | Expr | Atomic XOR, returns old |
| `atomic_xor_explicit` | 3 | No | Expr | Atomic XOR with ordering |
| `atomic_exchange` | 2 | No | Expr | Atomic exchange |
| `atomic_exchange_explicit` | 3 | No | Expr | Atomic exchange with ordering |
| `atomic_compare_exchange_strong` | 3 | No | Expr | Strong CAS |
| `atomic_compare_exchange_strong_explicit` | 5 | No | Expr | Strong CAS with ordering |
| `atomic_compare_exchange_weak` | 3 | No | Expr | Weak CAS |
| `atomic_compare_exchange_weak_explicit` | 5 | No | Expr | Weak CAS with ordering |

### 2.16 Fixed Point

| Name | Args | Variadic | Kind | Description |
|------|------|----------|------|-------------|
| `fixed_point_mul` | 3 | No | Expr | Fixed-point multiply |
| `fixed_point_div` | 3 | No | Expr | Fixed-point divide |
| `fixed_point_mul_sat` | 3 | No | Expr | Saturating fixed-point multiply |
| `fixed_point_div_sat` | 3 | No | Expr | Saturating fixed-point divide |

### 2.17 Optimization Hints

| Name | Args | Variadic | Kind | Description |
|------|------|----------|------|-------------|
| `expect` | 2 | No | Expr | Branch prediction hint |

---

## 3. SIMD Intrinsics

### 3.1 Arithmetic

| Name | Args | Variadic | Kind | Description |
|------|------|----------|------|-------------|
| `simd_add` | 2 | No | Expr | Vector add |
| `simd_sub` | 2 | No | Expr | Vector subtract |
| `simd_mul` | 2 | No | Expr | Vector multiply |
| `simd_div` | 2 | No | Expr | Vector divide |
| `simd_rem` | 2 | No | Expr | Vector remainder |
| `simd_neg` | 1 | No | Expr | Vector negate |
| `simd_abs` | 1 | No | Expr | Vector absolute value |

### 3.2 Saturating Arithmetic

| Name | Args | Variadic | Kind | Description |
|------|------|----------|------|-------------|
| `simd_saturating_add` | 2 | No | Expr | Saturating vector add |
| `simd_saturating_sub` | 2 | No | Expr | Saturating vector subtract |

### 3.3 Shifts

| Name | Args | Variadic | Kind | Description |
|------|------|----------|------|-------------|
| `simd_shl` | 2 | No | Expr | Shift left (Odin semantics) |
| `simd_shr` | 2 | No | Expr | Shift right (Odin semantics) |
| `simd_shl_masked` | 2 | No | Expr | Shift left (C semantics) |
| `simd_shr_masked` | 2 | No | Expr | Shift right (C semantics) |

### 3.4 Bitwise

| Name | Args | Variadic | Kind | Description |
|------|------|----------|------|-------------|
| `simd_bit_and` | 2 | No | Expr | Vector AND |
| `simd_bit_or` | 2 | No | Expr | Vector OR |
| `simd_bit_xor` | 2 | No | Expr | Vector XOR |
| `simd_bit_and_not` | 2 | No | Expr | Vector AND NOT |

### 3.5 Comparisons

| Name | Args | Variadic | Kind | Description |
|------|------|----------|------|-------------|
| `simd_lanes_eq` | 2 | No | Expr | Lane-wise equal |
| `simd_lanes_ne` | 2 | No | Expr | Lane-wise not equal |
| `simd_lanes_lt` | 2 | No | Expr | Lane-wise less than |
| `simd_lanes_le` | 2 | No | Expr | Lane-wise less or equal |
| `simd_lanes_gt` | 2 | No | Expr | Lane-wise greater than |
| `simd_lanes_ge` | 2 | No | Expr | Lane-wise greater or equal |

### 3.6 Min/Max/Clamp

| Name | Args | Variadic | Kind | Description |
|------|------|----------|------|-------------|
| `simd_min` | 2 | No | Expr | Lane-wise minimum |
| `simd_max` | 2 | No | Expr | Lane-wise maximum |
| `simd_clamp` | 3 | No | Expr | Lane-wise clamp |

### 3.7 Lane Access

| Name | Args | Variadic | Kind | Description |
|------|------|----------|------|-------------|
| `simd_extract` | 2 | No | Expr | Extract single lane |
| `simd_replace` | 3 | No | Expr | Replace single lane |

### 3.8 Reductions

| Name | Args | Variadic | Kind | Description |
|------|------|----------|------|-------------|
| `simd_reduce_add_bisect` | 1 | No | Expr | Sum (bisection) |
| `simd_reduce_mul_bisect` | 1 | No | Expr | Product (bisection) |
| `simd_reduce_add_ordered` | 1 | No | Expr | Sum (ordered) |
| `simd_reduce_mul_ordered` | 1 | No | Expr | Product (ordered) |
| `simd_reduce_add_pairs` | 1 | No | Expr | Pairwise sum |
| `simd_reduce_mul_pairs` | 1 | No | Expr | Pairwise product |
| `simd_reduce_min` | 1 | No | Expr | Reduce to minimum |
| `simd_reduce_max` | 1 | No | Expr | Reduce to maximum |
| `simd_reduce_and` | 1 | No | Expr | Reduce with AND |
| `simd_reduce_or` | 1 | No | Expr | Reduce with OR |
| `simd_reduce_xor` | 1 | No | Expr | Reduce with XOR |
| `simd_reduce_any` | 1 | No | Expr | Any lane true |
| `simd_reduce_all` | 1 | No | Expr | All lanes true |

### 3.9 Bit Extraction

| Name | Args | Variadic | Kind | Description |
|------|------|----------|------|-------------|
| `simd_extract_lsbs` | 1 | No | Expr | Extract LSBs from lanes |
| `simd_extract_msbs` | 1 | No | Expr | Extract MSBs from lanes |

### 3.10 Shuffles and Permutations

| Name | Args | Variadic | Kind | Description |
|------|------|----------|------|-------------|
| `simd_shuffle` | 2 | Yes | Expr | Compile-time shuffle |
| `simd_select` | 3 | No | Expr | Select between vectors |
| `simd_runtime_swizzle` | 2 | No | Expr | Runtime swizzle |

### 3.11 Rounding

| Name | Args | Variadic | Kind | Description |
|------|------|----------|------|-------------|
| `simd_ceil` | 1 | No | Expr | Lane-wise ceiling |
| `simd_floor` | 1 | No | Expr | Lane-wise floor |
| `simd_trunc` | 1 | No | Expr | Lane-wise truncate |
| `simd_nearest` | 1 | No | Expr | Lane-wise round nearest |

### 3.12 Conversions

| Name | Args | Variadic | Kind | Description |
|------|------|----------|------|-------------|
| `simd_to_bits` | 1 | No | Expr | Convert to bit representation |

### 3.13 Lane Manipulation

| Name | Args | Variadic | Kind | Description |
|------|------|----------|------|-------------|
| `simd_lanes_reverse` | 1 | No | Expr | Reverse lane order |
| `simd_lanes_rotate_left` | 2 | No | Expr | Rotate lanes left |
| `simd_lanes_rotate_right` | 2 | No | Expr | Rotate lanes right |

### 3.14 Memory Operations

| Name | Args | Variadic | Kind | Description |
|------|------|----------|------|-------------|
| `simd_gather` | 3 | No | Expr | Gather from memory |
| `simd_scatter` | 3 | No | Stmt | Scatter to memory |
| `simd_masked_load` | 3 | No | Expr | Masked load |
| `simd_masked_store` | 3 | No | Stmt | Masked store |
| `simd_masked_expand_load` | 3 | No | Expr | Masked expand load |
| `simd_masked_compress_store` | 3 | No | Stmt | Masked compress store |

### 3.15 Utility

| Name | Args | Variadic | Kind | Description |
|------|------|----------|------|-------------|
| `simd_indices` | 1 | No | Expr | Generate index vector |

### 3.16 Platform-Specific

| Name | Args | Variadic | Kind | Description |
|------|------|----------|------|-------------|
| `simd_x86__MM_SHUFFLE` | 4 | No | Expr | x86 shuffle constant |

---

## 4. Type Introspection

### 4.1 Type Transformations

| Name | Args | Variadic | Kind | Description |
|------|------|----------|------|-------------|
| `type_base_type` | 1 | No | Expr | Get base type (strip distinct) |
| `type_core_type` | 1 | No | Expr | Get core type (fully unwrap) |
| `type_elem_type` | 1 | No | Expr | Get element type |
| `type_convert_variants_to_pointers` | 1 | No | Expr | Union variants as pointers |
| `type_merge` | 2 | No | Expr | Merge two types |
| `type_integer_to_unsigned` | 1 | No | Expr | Convert to unsigned |
| `type_integer_to_signed` | 1 | No | Expr | Convert to signed |

### 4.2 Type Category Tests

| Name | Args | Kind | Returns `true` if... |
|------|------|------|---------------------|
| `type_is_boolean` | 1 | Expr | Type is boolean |
| `type_is_bit_field` | 1 | Expr | Type is bit_field |
| `type_is_integer` | 1 | Expr | Type is integer |
| `type_is_rune` | 1 | Expr | Type is rune |
| `type_is_float` | 1 | Expr | Type is floating point |
| `type_is_complex` | 1 | Expr | Type is complex |
| `type_is_quaternion` | 1 | Expr | Type is quaternion |
| `type_is_string` | 1 | Expr | Type is string |
| `type_is_string16` | 1 | Expr | Type is string16 |
| `type_is_cstring` | 1 | Expr | Type is cstring |
| `type_is_cstring16` | 1 | Expr | Type is cstring16 |
| `type_is_typeid` | 1 | Expr | Type is typeid |
| `type_is_any` | 1 | Expr | Type is any |

### 4.3 Endianness Tests

| Name | Args | Kind | Returns `true` if... |
|------|------|------|---------------------|
| `type_is_endian_platform` | 1 | Expr | Native endian |
| `type_is_endian_little` | 1 | Expr | Little endian |
| `type_is_endian_big` | 1 | Expr | Big endian |

### 4.4 Property Tests

| Name | Args | Kind | Returns `true` if... |
|------|------|------|---------------------|
| `type_is_unsigned` | 1 | Expr | Unsigned integer |
| `type_is_numeric` | 1 | Expr | Numeric type |
| `type_is_ordered` | 1 | Expr | Supports ordering |
| `type_is_ordered_numeric` | 1 | Expr | Ordered numeric |
| `type_is_indexable` | 1 | Expr | Can be indexed |
| `type_is_sliceable` | 1 | Expr | Can be sliced |
| `type_is_comparable` | 1 | Expr | Supports comparison |
| `type_is_simple_compare` | 1 | Expr | Memcmp-comparable |
| `type_is_nearly_simple_compare` | 1 | Expr | Nearly memcmp-comparable |
| `type_is_dereferenceable` | 1 | Expr | Can be dereferenced |
| `type_is_valid_map_key` | 1 | Expr | Valid as map key |
| `type_is_valid_matrix_elements` | 1 | Expr | Valid matrix element |

### 4.5 Composite Type Tests

| Name | Args | Kind | Returns `true` if... |
|------|------|------|---------------------|
| `type_is_named` | 1 | Expr | Has a name |
| `type_is_pointer` | 1 | Expr | Is pointer |
| `type_is_multi_pointer` | 1 | Expr | Is multi-pointer |
| `type_is_array` | 1 | Expr | Is array |
| `type_is_enumerated_array` | 1 | Expr | Is enumerated array |
| `type_is_slice` | 1 | Expr | Is slice |
| `type_is_dynamic_array` | 1 | Expr | Is dynamic array |
| `type_is_map` | 1 | Expr | Is map |
| `type_is_struct` | 1 | Expr | Is struct |
| `type_is_union` | 1 | Expr | Is union |
| `type_is_enum` | 1 | Expr | Is enum |
| `type_is_proc` | 1 | Expr | Is procedure |
| `type_is_bit_set` | 1 | Expr | Is bit_set |
| `type_is_simd_vector` | 1 | Expr | Is SIMD vector |
| `type_is_matrix` | 1 | Expr | Is matrix |
| `type_is_raw_union` | 1 | Expr | Is raw union |

### 4.6 Polymorphism Tests

| Name | Args | Kind | Returns `true` if... |
|------|------|------|---------------------|
| `type_is_specialized_polymorphic_record` | 1 | Expr | Specialized polymorphic |
| `type_is_unspecialized_polymorphic_record` | 1 | Expr | Unspecialized polymorphic |
| `type_has_nil` | 1 | Expr | Type has nil value |

### 4.7 Matrix Properties

| Name | Args | Kind | Description |
|------|------|------|-------------|
| `type_is_matrix_row_major` | 1 | Expr | Is row-major matrix |
| `type_is_matrix_column_major` | 1 | Expr | Is column-major matrix |

### 4.8 Field Operations

| Name | Args | Kind | Description |
|------|------|------|-------------|
| `type_has_field` | 2 | Expr | Check field existence |
| `type_field_type` | 2 | Expr | Get field type |
| `type_field_index_of` | 2 | Expr | Get field index |

### 4.9 Specialization

| Name | Args | Kind | Description |
|------|------|------|-------------|
| `type_is_specialization_of` | 2 | Expr | Check specialization |

### 4.10 Union Introspection

| Name | Args | Kind | Description |
|------|------|------|-------------|
| `type_is_variant_of` | 2 | Expr | Check variant membership |
| `type_union_tag_type` | 1 | Expr | Get tag type |
| `type_union_tag_offset` | 1 | Expr | Get tag offset |
| `type_union_base_tag_value` | 1 | Expr | Get base tag value |
| `type_union_variant_count` | 1 | Expr | Count variants |
| `type_variant_type_of` | 2 | Expr | Get variant type by index |
| `type_variant_index_of` | 2 | Expr | Get variant index by type |

### 4.11 Bit Set Introspection

| Name | Args | Kind | Description |
|------|------|------|-------------|
| `type_bit_set_elem_type` | 1 | Expr | Get element type |
| `type_bit_set_underlying_type` | 1 | Expr | Get underlying type |
| `type_bit_set_backing_type` | 1 | Expr | Get backing type |

### 4.12 Struct Introspection

| Name | Args | Kind | Description |
|------|------|------|-------------|
| `type_struct_field_count` | 1 | Expr | Count fields |
| `type_struct_has_implicit_padding` | 1 | Expr | Has implicit padding |

### 4.13 Procedure Introspection

| Name | Args | Kind | Description |
|------|------|------|-------------|
| `type_proc_parameter_count` | 1 | Expr | Count parameters |
| `type_proc_return_count` | 1 | Expr | Count returns |
| `type_proc_parameter_type` | 2 | Expr | Get parameter type |
| `type_proc_return_type` | 2 | Expr | Get return type |

### 4.14 Polymorphic Record Introspection

| Name | Args | Kind | Description |
|------|------|------|-------------|
| `type_polymorphic_record_parameter_count` | 1 | Expr | Count type params |
| `type_polymorphic_record_parameter_value` | 2 | Expr | Get param value |

### 4.15 Subtype/Superset Tests

| Name | Args | Kind | Description |
|------|------|------|-------------|
| `type_is_subtype_of` | 2 | Expr | Check subtype |
| `type_is_superset_of` | 2 | Expr | Check superset |

### 4.16 Enum Introspection

| Name | Args | Kind | Description |
|------|------|------|-------------|
| `type_enum_is_contiguous` | 1 | Expr | Values are contiguous |

### 4.17 Map/Hash Support

| Name | Args | Kind | Description |
|------|------|------|-------------|
| `type_equal_proc` | 1 | Expr | Get equality procedure |
| `type_hasher_proc` | 1 | Expr | Get hasher procedure |
| `type_map_info` | 1 | Expr | Get map info |
| `type_map_cell_info` | 1 | Expr | Get map cell info |

### 4.18 Shared Fields

| Name | Args | Kind | Description |
|------|------|------|-------------|
| `type_has_shared_fields` | 2 | Expr | Check shared fields |

### 4.19 Name

| Name | Args | Kind | Description |
|------|------|------|-------------|
| `type_canonical_name` | 1 | Expr | Get canonical type name |

---

## 5. Platform-Specific Intrinsics

### 5.1 System Calls

| Name | Args | Variadic | Kind | Description |
|------|------|----------|------|-------------|
| `syscall` | 1 | Yes | Expr | Linux/Windows syscall |
| `syscall_bsd` | 1 | Yes | Expr | BSD syscall |

### 5.2 x86

| Name | Args | Variadic | Kind | Description |
|------|------|----------|------|-------------|
| `x86_cpuid` | 2 | No | Expr | CPUID instruction |
| `x86_xgetbv` | 1 | No | Expr | XGETBV instruction |

### 5.3 Objective-C

| Name | Args | Variadic | Kind | Description |
|------|------|----------|------|-------------|
| `objc_send` | 3 | Yes | Expr | Send ObjC message |
| `objc_find_selector` | 1 | No | Expr | Find selector |
| `objc_find_class` | 1 | No | Expr | Find class |
| `objc_register_selector` | 1 | No | Expr | Register selector |
| `objc_register_class` | 1 | No | Expr | Register class |
| `objc_ivar_get` | 1 | No | Expr | Get instance variable |
| `objc_block` | 1 | Yes | Expr | Create ObjC block |
| `objc_super` | 1 | Yes | Expr | Super call |

### 5.4 WebAssembly

| Name | Args | Variadic | Kind | Description |
|------|------|----------|------|-------------|
| `wasm_memory_grow` | 2 | No | Expr | Grow WASM memory |
| `wasm_memory_size` | 1 | No | Expr | Get WASM memory size |
| `wasm_memory_atomic_wait32` | 3 | No | Expr | Atomic wait |
| `wasm_memory_atomic_notify32` | 2 | No | Expr | Atomic notify |

### 5.5 Debugging

| Name | Args | Variadic | Kind | Description |
|------|------|----------|------|-------------|
| `valgrind_client_request` | 7 | No | Expr | Valgrind client request |

---

## 6. Miscellaneous

| Name | Args | Variadic | Kind | Description |
|------|------|----------|------|-------------|
| `procedure_of` | 1 | No | Expr | Get procedure from call |
| `__entry_point` | 0 | No | Stmt | Program entry point marker |
| `constant_utf16_cstring` | 1 | No | Expr | UTF-16 C string constant |

---

## Summary

| Category | Count |
|----------|-------|
| Core Built-ins | 28 |
| General Intrinsics | 75 |
| SIMD Intrinsics | 64 |
| Type Introspection | 90 |
| Platform-Specific | 18 |
| Miscellaneous | 3 |
| **Total** | **278** |

*Note: Some enum entries are placeholders (empty names) for grouping purposes.*
