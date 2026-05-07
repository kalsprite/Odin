# Phase 28 Group 1: Polymorphic Type Checking Implementation

**Status**: Partially Implemented
**Date**: 2025-10-03
**Estimated LOC**: 300 lines
**Actual Status**: Core infrastructure exists, advanced functions needed

## Overview

This phase implements generic type parameter support and polymorphic type checking for the native Odin checker. The implementation follows the C++ checker logic from `/mnt/c/odin/src/check_expr.cpp` and `/mnt/c/odin/src/check_type.cpp`.

## Current State Assessment

### Already Implemented ✓

1. **is_type_polymorphic** (lines 655-817 in `/mnt/d/dev/checker/check_type.odin`)
   - C++ Reference: types.cpp:2333-2480
   - Status: ✓ IMPLEMENTED
   - Handles all type kinds: Generic, Named, Pointer, Array, Struct, Union, Proc, etc.
   - **BUG FOUND**: Line 671 references `named.type_of` but should be `named.base`

2. **Type_Generic Structure** (lines 811-816 in `/mnt/d/dev/checker/checker.odin`)
   ```odin
   Type_Generic :: struct {
       name:        string,
       specialized: ^Type,
       entity:      ^Entity,
       scope:       ^Scope,
   }
   ```
   - Status: ✓ IMPLEMENTED
   - Supports polymorphic type parameters ($T)

3. **Polymorphic Support in Type_Struct** (lines 716-743)
   ```odin
   Type_Struct :: struct {
       // ... fields ...
       is_polymorphic:          bool,
       is_poly_specialized:     bool,
       polymorphic_params:      ^Type,
       polymorphic_parent:      ^Type,
       //... more fields...
   }
   ```
   - Status: ✓ IMPLEMENTED

4. **Polymorphic Support in Type_Union** (lines 745-762)
   - Similar to Type_Struct
   - Status: ✓ IMPLEMENTED

5. **Polymorphic Support in Type_Proc** (lines 783-804)
   ```odin
   is_polymorphic:       bool,
   is_poly_specialized:  bool,
   specialization_count: int,
   ```
   - Status: ✓ IMPLEMENTED

### Missing Implementation ❌

The following functions need to be implemented:

## 1. is_polymorphic_type_assignable (80 LOC)

**C++ Reference**: `/mnt/c/odin/src/check_expr.cpp:1352-1670`
**Target File**: `/mnt/d/dev/checker/check_type.odin`
**Priority**: HIGH

### Function Signature
```odin
// is_polymorphic_type_assignable checks if poly type can be assigned from source
// with optional type modification for generic type parameter binding
is_polymorphic_type_assignable :: proc(
    ctx: ^Checker_Context,
    poly: ^Type,           // Polymorphic type (may contain $T)
    source: ^Type,         // Concrete source type
    compound: bool,        // True for compound types (requires identical match)
    modify_type: bool,     // True to actually bind type parameters
) -> bool
```

### Key Implementation Points

1. **Type_Basic** (C++ lines 1356-1358):
   - If compound, require identical types
   - Otherwise use `check_is_assignable_to`

2. **Type_Named** (C++ lines 1360-1368):
   - Call `check_type_specialization_to` first
   - Fall back to identity or assignment check

3. **Type_Generic** (C++ lines 1370-1382):
   - Check specialized constraint if exists
   - If modify_type, memcpy source into poly (binds $T)
   - Always return true (generic accepts any type)

4. **Type_Pointer** (C++ lines 1383-1397):
   - Handle Pointer → Pointer
   - Handle MultiPointer → Pointer (with subtype check)
   - Recursively check element types

5. **Type_MultiPointer** (C++ lines 1399-1413):
   - Similar to Pointer
   - Bidirectional with Pointer type

6. **Type_Array** (C++ lines 1414-1459):
   - Call `polymorphic_assign_index` for generic count
   - Handle Array → Array with matching counts
   - Handle EnumeratedArray → Array (special transformation)

7. **Type_EnumeratedArray** (C++ lines 1460-1481):
   - Match enumeration operations
   - Check min/max values
   - Recursively check index and element types

8. **Type_Slice** (C++ lines 1488-1492):
   - Simple element type recursion

9. **Type_DynamicArray** (C++ lines 1483-1487):
   - Simple element type recursion

10. **Type_BitSet** (C++ lines 1497-1521):
    - Check element type
    - Auto-fill upper/lower bounds from source
    - Check underlying type

11. **Type_Union** (C++ lines 1523-1538):
    - Match variant counts
    - Recursively check all variants

12. **Type_Struct** (C++ lines 1540-1576):
    - Handle SOA structs (Fixed, Slice, Dynamic)
    - Rebuild SOA type if modify_type

13. **Type_Proc** (C++ lines 1587-1622):
    - Match calling convention
    - Match c_vararg and variadic flags
    - Match param/result counts
    - Recursively check all params and results

14. **Type_Map** (C++ lines 1623-1633):
    - Check both key and value types
    - Reinitialize map internal types if modified

15. **Type_Matrix** (C++ lines 1635-1654):
    - Handle generic row/column counts
    - Match dimensions

16. **Type_SimdVector** (C++ lines 1656-1667):
    - Handle generic count
    - Match vector size

### Helper Functions Needed

```odin
// polymorphic_assign_index binds a generic count parameter to a concrete value
// C++ Reference: check_expr.cpp:1323-1350
polymorphic_assign_index :: proc(
    gt: ^^Type,         // Generic type (Type_Generic)
    dst_count: ^i64,    // Destination count to set
    source_count: i64,  // Source count value
) -> bool {
    // 1. Lookup entity in gt.Generic.scope by gt.Generic.name
    // 2. If Entity_TypeName: convert to Entity_Constant with source_count value
    // 3. If Entity_Constant: verify count matches source_count
    // 4. Set dst_count = source_count
    // 5. Clear gt to nil
}
```

## 2. check_type_specialization_to (150 LOC)

**C++ Reference**: `/mnt/c/odin/src/check_type.cpp:1438-1570`
**Target File**: `/mnt/d/dev/checker/check_type.odin`
**Priority**: HIGH

### Function Signature
```odin
// check_type_specialization_to checks if specialization type matches concrete type
// for polymorphic struct/union instances
check_type_specialization_to :: proc(
    ctx: ^Checker_Context,
    specialization: ^Type,  // Polymorphic parent type (e.g., Array($T))
    type: ^Type,            // Concrete type (e.g., Array(i32))
    compound: bool,
    modify_type: bool,
) -> bool
```

### Key Implementation Points

1. **Struct Specialization** (C++ lines 1459-1511):
   - Check if same polymorphic parent
   - Get polymorphic params tuple for both types
   - For each param pair:
     - If Generic + Constant: override constant value
     - Otherwise: call is_polymorphic_type_assignable
   - If modify_type: memcpy type into specialization

2. **Union Specialization** (C++ lines 1512-1558):
   - Same logic as Struct

3. **Fallback** (C++ lines 1561-1569):
   - Check Named type mismatch
   - Call is_polymorphic_type_assignable on base types

## 3. evaluate_where_clauses (60 LOC)

**C++ Reference**: `/mnt/c/odin/src/check_expr.cpp:6717-6796`
**Target File**: `/mnt/d/dev/checker/check_expr.odin`
**Priority**: MEDIUM

### Function Signature
```odin
// evaluate_where_clauses checks where clause constraints
evaluate_where_clauses :: proc(
    ctx: ^Checker_Context,
    call_expr: ^ast.Expr,        // Call site for error reporting
    scope: ^Scope,               // Scope with type parameter bindings
    clauses: []^ast.Expr,        // Where clause expressions
    print_err: bool,             // Whether to print errors
) -> bool
```

### Key Implementation Points

1. **Clause Evaluation** (C++ lines 6719-6778):
   - For each clause:
     - check_expr to evaluate
     - Require Addressing_Constant mode
     - Require bool exact value
     - If value is false, report error with scope definitions

2. **Error Reporting** (C++ lines 6731-6775):
   - Print "where clause evaluated to false"
   - Print type parameter definitions from scope
   - Print constant parameter values
   - Show call location

3. **Style Check** (C++ lines 6780-6791):
   - Warn if using && instead of comma separation

## 4. Type Parameter Inference (60 LOC)

**C++ Reference**: Inferred from usage in check_expr.cpp:8366-8426
**Target File**: `/mnt/d/dev/checker/check_expr.odin`
**Priority**: MEDIUM

### Function Signature
```odin
// infer_type_parameters infers generic type parameters from call arguments
infer_type_parameters :: proc(
    ctx: ^Checker_Context,
    proc_type: ^Type,            // Polymorphic procedure type
    args: []Operand,             // Call arguments
    poly_context: ^Poly_Context, // Output: inferred type parameters
) -> bool
```

### Key Implementation Points

1. **Argument Matching**:
   - Iterate over procedure parameters
   - For each Type_Generic parameter:
     - Extract type from corresponding argument
     - Add to poly_context.type_params map

2. **Conflict Detection**:
   - If same type parameter appears multiple times
   - Verify all inferences agree
   - Report error if conflict

3. **Constraint Checking**:
   - If Generic.specialized exists, verify argument matches constraint

## Data Structures Needed

### Poly_Context (New)
```odin
// Poly_Context tracks type parameter bindings during polymorphic instantiation
Poly_Context :: struct {
    type_params: map[string]^Type,      // Type parameter name → inferred type
    constraints: [dynamic]^ast.Expr,    // Where clause constraints
    parent:      ^Poly_Context,         // Nested context support
}
```

### Checker_Context Extensions (Check existing)
```odin
// In Checker_Context struct
polymorphic_scope:                  ^Scope,   // Scope for polymorphic type parameters
allow_polymorphic_types:            bool,     // Allow Type_Generic creation
in_polymorphic_specialization:      bool,     // Currently specializing polymorphic type
no_polymorphic_errors:              bool,     // Suppress polymorphic errors
hide_polymorphic_errors:            bool,     // Hide polymorphic error details
disallow_polymorphic_return_types:  bool,     // Disallow new poly vars in return types
```

## Integration Points

### 1. check_expr.odin
- Add evaluate_where_clauses
- Add infer_type_parameters
- Call is_polymorphic_type_assignable during type checking

### 2. check_type.odin
- Add is_polymorphic_type_assignable
- Add check_type_specialization_to
- Add polymorphic_assign_index
- **FIX BUG**: Line 671 - change `named.type_of` to `named.base`

### 3. checker.odin
- Verify Poly_Context is added if not present
- Verify Checker_Context has polymorphic fields

## Testing Strategy

### Test 1: Simple Type Parameter
```odin
identity :: proc(x: $T) -> T { return x }
a := identity(42)  // T = i32
```
**Validates**: Type_Generic binding, basic inference

### Test 2: Polymorphic Struct
```odin
Array :: struct($T: typeid) {
    data: ^T,
    len: int,
}
arr: Array(i32)
```
**Validates**: check_type_specialization_to, struct polymorphism

### Test 3: Where Clause
```odin
add :: proc(x: $T, y: T) -> T where intrinsics.type_is_numeric(T) {
    return x + y
}
result := add(1, 2)        // OK: i32 is numeric
//result := add("a", "b")  // ERROR: string not numeric
```
**Validates**: evaluate_where_clauses, constraint checking

### Test 4: Type Inference
```odin
swap :: proc(x: ^$T, y: ^T) {
    tmp := x^
    x^ = y^
    y^ = tmp
}
a, b: i32
swap(&a, &b)  // Infers T = i32
```
**Validates**: infer_type_parameters, multi-argument unification

### Test 5: Polymorphic Array
```odin
make_array :: proc($T: typeid, $N: int) -> [N]T {
    return [N]T{}
}
arr := make_array(i32, 10)  // Creates [10]i32
```
**Validates**: polymorphic_assign_index, count parameters

## C++ to Odin Mapping

| C++ Function | C++ Lines | Odin Function | Target File | Status |
|--------------|-----------|---------------|-------------|--------|
| is_polymorphic_type_assignable | check_expr.cpp:1352-1670 | is_polymorphic_type_assignable | check_type.odin | ❌ TODO |
| check_type_specialization_to | check_type.cpp:1438-1570 | check_type_specialization_to | check_type.odin | ❌ TODO |
| evaluate_where_clauses | check_expr.cpp:6717-6796 | evaluate_where_clauses | check_expr.odin | ❌ TODO |
| polymorphic_assign_index | check_expr.cpp:1323-1350 | polymorphic_assign_index | check_type.odin | ❌ TODO |
| (inferred from usage) | check_expr.cpp:8366-8426 | infer_type_parameters | check_expr.odin | ❌ TODO |
| is_type_polymorphic | types.cpp:2333-2480 | is_type_polymorphic | check_type.odin | ✓ DONE (with bug) |

## Known Limitations

1. **Nested Polymorphism**: Polymorphic types within polymorphic types may need additional recursion guards
2. **Circular Dependencies**: Type parameter inference with circular references needs cycle detection
3. **Default Values**: Polymorphic parameters with default values require Parameter_Value integration
4. **Variadics**: Variadic polymorphic parameters need special handling
5. **Type Constraints**: Complex where clauses with multiple type parameters need careful scope management

## Bug Fixes Required

### Critical
1. **check_type.odin:671** - `named.type_of` should be `named.base`
   ```odin
   // BEFORE (WRONG):
   return is_type_polymorphic(named.type_of, or_specialized)

   // AFTER (CORRECT):
   return is_type_polymorphic(named.base, or_specialized)
   ```

## Implementation Priority

1. **HIGH PRIORITY** (Core functionality):
   - Fix is_type_polymorphic bug (1 line)
   - Implement polymorphic_assign_index (30 LOC)
   - Implement is_polymorphic_type_assignable (80 LOC)
   - Implement check_type_specialization_to (150 LOC)

2. **MEDIUM PRIORITY** (Validation):
   - Implement evaluate_where_clauses (60 LOC)
   - Implement infer_type_parameters (60 LOC)

3. **LOW PRIORITY** (Edge cases):
   - Add Poly_Context if missing
   - Add polymorphic context fields to Checker_Context
   - Add recursion guards for is_type_polymorphic

## Estimated Completion

- **Core Implementation**: 260 lines (polymorphic_assign_index + is_polymorphic_type_assignable + check_type_specialization_to)
- **Validation**: 120 lines (evaluate_where_clauses + infer_type_parameters)
- **Infrastructure**: 20 lines (bug fix + Poly_Context)
- **Total**: ~400 lines (33% over estimate due to infrastructure needs)

## Next Steps

1. Fix `is_type_polymorphic` bug on line 671
2. Implement `polymorphic_assign_index` helper
3. Implement `is_polymorphic_type_assignable` (largest function)
4. Implement `check_type_specialization_to`
5. Implement `evaluate_where_clauses`
6. Implement `infer_type_parameters`
7. Add comprehensive tests

## Cross-References

- **Phase 22**: Entity system (provides Entity_Constant, Entity_TypeName)
- **Phase 23**: Scope management (provides scope_lookup)
- **Phase 24**: Type checking infrastructure (provides check_expr, Operand)
- **Phase 25**: Assignment checking (provides check_is_assignable_to)
- **Phase 26**: Type identity (provides are_types_identical)
- **Phase 27**: Advanced types (provides SOA, Matrix, SIMD)

---

**Generated**: 2025-10-03
**Checker**: Claude Code (Phase 28 Group 1 Analysis)
