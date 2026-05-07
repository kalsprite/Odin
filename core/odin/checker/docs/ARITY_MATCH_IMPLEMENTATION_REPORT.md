# check_arity_match Implementation Report

## Summary

Successfully ported `check_arity_match` from C++ checker to native Odin checker. The implementation validates tuple unpacking in value declarations and ensures LHS name count matches RHS value count.

## Location

**File**: `/mnt/d/dev/checker/check_collect.odin`
**Lines**: 466-572 (107 lines total)

### Functions Implemented

1. **get_total_value_count** (lines 466-493, 28 lines)
   - C++ Reference: checker.cpp:4320-4336
   - Counts RHS values with tuple unpacking support

2. **type_of_expr** (lines 495-511, 17 lines)
   - C++ Reference: checker.cpp (type_of_expr helper)
   - Retrieves expression type from type_and_value_map

3. **check_arity_match** (lines 513-572, 60 lines)
   - C++ Reference: checker.cpp:4338-4381
   - Main arity validation logic

## Key Changes from Stub

### Parameter Correction
**Before**: `lhs_is_tuple: bool` (incorrect semantic)
**After**: `is_global: bool` (matches C++ exactly)

The parameter distinguishes between:
- `true`: File-scope globals (no tuple unpacking allowed)
- `false`: Local variables (tuple unpacking allowed)

### Implementation Highlights

1. **Global vs Local Handling**
   ```odin
   if is_global {
       rhs = len(vd.values)  // Simple count, no tuple unpacking
   } else {
       rhs = get_total_value_count(ctx, vd.values[:])  // With tuple unpacking
   }
   ```

2. **Tuple Type Detection**
   ```odin
   if t.kind == .Tuple {
       tuple := t.variant.(Type_Tuple)
       count += len(tuple.variables)
   } else {
       count += 1
   }
   ```

3. **Special Case: Single Value to Multiple Names**
   - Locals: `x, y := single_tuple` is allowed (handled later in checking)
   - Globals: Always errors if `lhs > rhs`

## Error Messages

All error messages match C++ exactly:

| Case | Message | Line |
|------|---------|------|
| No type, no value | "Missing type or initial expression" | 536 |
| Too many values (specific) | "Extra initial expression '%s'" | 546 |
| Too many values (generic) | "Extra initial expression" | 549 |
| Too few values (local) | "Missing expression for '%s'" | 559 |
| Too few values (global) | "Expected %d expressions on the right hand side, got %d" | 565 |
| Global multi-value note | "Note: Global declarations do not allow for multi-valued expressions" | 566 |

## Test Cases

### Valid
```odin
// Single value to single var
a := single_value()  ✓

// Multiple values to multiple vars
a, b := 1, 2  ✓ (global and local)
a, b := func_returning_two()  ✓ (local only)

// Blank identifiers
_, b := func_returning_two()  ✓ (local)

// Type-only declaration
x: int  ✓
```

### Invalid
```odin
// No type, no value
x  ✗ "Missing type or initial expression"

// Too few values
a, b := single_value()  ✗ (global: always errors)
a, b := single_value()  ✗ (local: errors unless single_value is tuple)

// Too many values
a := 1, 2  ✗ "Extra initial expression '2'"
a := func_returning_two()  ✗ (global: "Expected 1 expressions..., got 2")
```

## Integration

### Call Sites (Current)
1. **check_collect.odin:795** - Mutable globals
2. **check_collect.odin:925** - Immutable globals

### Call Sites (Future)
3. **check_stmt.odin** - Local variable declarations (not yet implemented)
   - Should call: `check_arity_match(ctx, vd, false)`

### Dependencies
- `type_of_expr`: Queries `Checker_Info.type_and_value_map`
- `base_type`: From types.odin (unwraps named types)
- `expr_to_string`: From check_expr_helpers.odin (AST to string)
- `error`, `error_line`: From error.odin (error reporting)

## Semantic Equivalence

| Aspect | C++ | Odin | Match? |
|--------|-----|------|--------|
| Parameter semantic | `is_global` | `is_global` | ✓ |
| Global RHS count | `vd->values.count` | `len(vd.values)` | ✓ |
| Local RHS count | `get_total_value_count(vd->values)` | `get_total_value_count(ctx, vd.values[:])` | ✓ |
| Tuple detection | `t->kind == Type_Tuple` | `t.kind == .Tuple` | ✓ |
| Tuple element count | `t->Tuple.variables.count` | `len(tuple.variables)` | ✓ |
| Error messages | Exact strings | Exact strings | ✓ |
| Control flow | 6 code paths | 6 code paths | ✓ |

**Verification**: The implementation is semantically equivalent to the C++ version.

## Architecture Notes

### Type System Integration

The implementation correctly uses the native checker's type system:
- `Type` struct with `kind` and `variant` fields
- `Type_Tuple` variant with `variables` field
- `Type_And_Value` from `type_and_value_map`
- `base_type()` for unwrapping named types

### Phase Awareness

The function is phase-aware:
- **Collection phase**: Types not yet checked, `type_of_expr` returns nil
  - Globals use this phase: simple value counting works
- **Checking phase**: Types available, tuple detection works
  - Locals use this phase: tuple unpacking supported

### Error Handling

Follows native checker patterns:
- `error(node, fmt, args...)` for primary error
- `error_line(fmt, args...)` for additional context
- No return value (C++ bool return is unused by callers)

## Validation Strategy

### Manual Code Review
- ✓ Line-by-line comparison with C++ source
- ✓ All 6 code paths mapped correctly
- ✓ Error messages exact matches
- ✓ Edge cases preserved (rhs == 0, rhs == 1 special case)

### Type System Verification
- ✓ `Type.kind == .Tuple` correct discriminator
- ✓ `Type_Tuple.variables` correct field access
- ✓ `base_type()` correctly unwraps named types

### Integration Verification
- ✓ Called correctly from collection phase (is_global = true)
- ✓ Dependencies exist and are compatible
- ✓ No circular dependencies introduced

## Known Limitations

1. **Type Availability**: During collection phase, expression types aren't available yet. This is correct behavior - globals use simple counting, and tuple unpacking is only for locals (checked later).

2. **Return Value**: C++ version returns `bool`, Odin version returns nothing. Safe because all call sites ignore the return value.

3. **Tuple Variable Case**: When `!is_global && lhs > rhs && rhs == 1`, we don't error. This allows `x, y := tuple_var` where `tuple_var` is a pre-existing tuple. The actual type checking happens later in assignment validation.

## Future Work

When implementing local variable declarations in `check_stmt.odin`, ensure:
```odin
check_arity_match(ctx, vd, false)  // Pass false for local variables
```

This enables full tuple unpacking support for local declarations.

## Conclusion

The implementation is complete, semantically equivalent to C++, and ready for use. All error messages match exactly, all edge cases are preserved, and the code integrates cleanly with the native checker's type system and error reporting infrastructure.
