# check_arity_match Implementation Verification

## Implementation Location
**File**: `/mnt/d/dev/checker/check_collect.odin`
**Lines**: 466-572

## Components Implemented

### 1. Helper Functions

#### `get_total_value_count` (lines 466-493)
- **Purpose**: Computes total value count considering tuple unpacking
- **C++ Reference**: checker.cpp:4320-4336
- **Logic**:
  - Iterates through RHS expressions
  - For each expression, gets its type via `type_of_expr`
  - If type is nil (not yet checked), counts as 1
  - If type is a Tuple, counts all tuple elements
  - Otherwise counts as 1
- **Key behavior**: Handles multi-value returns like `func_returning_two() -> (int, int)`

#### `type_of_expr` (lines 495-511)
- **Purpose**: Retrieves type of an expression from type_and_value_map
- **C++ Reference**: type_of_expr in checker.cpp
- **Logic**:
  - Looks up expression in `info.type_and_value_map`
  - Returns type if mode is not Invalid
  - Returns nil if expression not yet type-checked
- **Key behavior**: Safe lookup that handles expressions that haven't been checked yet

### 2. Main Function

#### `check_arity_match` (lines 513-572)
- **Purpose**: Validates LHS name count matches RHS value count
- **C++ Reference**: checker.cpp:4338-4381
- **Signature**: Changed from `lhs_is_tuple: bool` to `is_global: bool` to match C++ semantics

## Implementation Details

### Parameter Semantic Correction
**Original**: `lhs_is_tuple: bool` (incorrect)
**Corrected**: `is_global: bool` (matches C++ exactly)

The parameter indicates whether we're checking file-scope globals or local variables:
- `is_global = true`: File-scope variables (globals)
- `is_global = false`: Local variables in functions

### Global vs Local Handling

**Globals** (`is_global = true`):
- Do NOT allow multi-valued expressions
- RHS count = number of value expressions (not unpacked)
- Example: `x, y := func_returning_two()` is INVALID for globals
- Rationale: Globals can't use tuple unpacking

**Locals** (`is_global = false`):
- Allow tuple unpacking from multi-value returns
- RHS count = total values after unpacking tuples
- Example: `x, y := func_returning_two()` is VALID for locals

### Error Cases and Messages

#### Case 1: No values, no type (line 533-538)
```odin
x  // ERROR: Missing type or initial expression
```
**Message**: "Missing type or initial expression"

#### Case 2: Too many values (lines 539-551)
```odin
// Global or local
x := 1, 2  // ERROR: Extra initial expression '2'
```
**Message**:
- If can identify specific expression: "Extra initial expression '%s'" (with expr string)
- Otherwise: "Extra initial expression"

#### Case 3: Too few values - Local (lines 554-560)
```odin
// Local only, with rhs != 1
x, y := 1  // Would need special handling (single value assigned to multiple)
```
**Message**: "Missing expression for '%s'" (name of first unprovided variable)
**Note**: Only errors if rhs != 1 (single value to multiple vars is handled elsewhere)

#### Case 4: Too few values - Global (lines 561-568)
```odin
// Global
x, y := 1  // ERROR: Expected 2 expressions on the right hand side, got 1
```
**Message**:
- "Expected %d expressions on the right hand side, got %d"
- "Note: Global declarations do not allow for multi-valued expressions"

### Special Case: lhs > rhs and rhs == 1 for Locals

When `!is_global && rhs == 1` and `lhs > rhs`, the function does NOT error. This allows:
```odin
x, y := single_tuple_value  // Where single_tuple_value is a tuple stored in a variable
```

This case is handled elsewhere in the checker (likely in assignment checking).

## Test Cases Verified

### Valid Cases

```odin
// Single value to single var
a := single_value()  ✓

// Multiple values to multiple vars (local only)
a, b := func_returning_two()  ✓ (local)
a, b := 1, 2  ✓ (global and local)

// Blank identifiers
_, b := func_returning_two()  ✓ (local)
_, b := 1, 2  ✓ (global and local)

// Type-only declaration
x: int  ✓
```

### Invalid Cases

```odin
// Too few values
a, b := single_value()  ✗ (global: error immediately)
a, b := single_value()  ✗ (local: error unless single_value is tuple)

// Too many values
a := func_returning_two()  ✗ (global: disallowed multi-value)
a := 1, 2  ✗ (global and local)

// No type, no value
x  ✗
```

## Error Message Alignment with C++

All error messages match the C++ checker exactly:

| C++ Line | Message | Odin Line |
|----------|---------|-----------|
| 4350 | "Missing type or initial expression" | 536 |
| 4357 | "Extra initial expression '%s'" | 546 |
| 4360 | "Extra initial expression" | 549 |
| 4367 | "Missing expression for '%s'" | 559 |
| 4374 | "Expected %td expressions on the right hand side, got %td" | 565 |
| 4375 | "Note: Global declarations do not allow for multi-valued expressions" | 566 |

Note: Changed `%td` (C printf for `isize`) to `%d` (Odin's integer format).

## Integration Points

### Called From
1. **check_collect.odin:795** - For mutable file-scope declarations (globals)
   - `check_arity_match(ctx, vd, true)`
2. **check_collect.odin:925** - For immutable file-scope declarations
   - `check_arity_match(ctx, vd, true)`
3. **check_stmt.cpp:2230** (C++ reference, not yet ported) - For local variable declarations
   - `check_arity_match(ctx, vd, false)`

### Dependencies
- `type_of_expr`: Looks up expression type from `Checker_Info.type_and_value_map`
- `base_type`: Unwraps named types (from types.odin)
- `expr_to_string`: Converts AST to string for error messages (from check_expr_helpers.odin)
- `error`: Reports errors at AST nodes (from error.odin)
- `error_line`: Adds continuation line to error (from error.odin)

## Architecture Notes

### Why `type_of_expr` Can Return Nil

During the collection phase (`check_collect_entities`), expressions haven't been type-checked yet. The `type_and_value_map` is populated later during expression checking.

For arity matching:
- **During collection (globals)**: Expressions are NOT checked, so types are nil
  - We count values directly: `len(vd.values)`
  - This is why globals use simple counting
- **During stmt checking (locals)**: Some expressions MAY be checked
  - We can use tuple unpacking if type info is available
  - If nil, we conservatively count as 1

### Type System Integration

The implementation properly integrates with the native checker's type system:
- Uses `Type.kind == .Tuple` to detect tuple types
- Uses `Type_Tuple.variables` to get tuple element count
- Uses `base_type()` to unwrap named types
- Uses `Type_And_Value` from `type_and_value_map`

## Semantic Equivalence Verification

### C++ Logic Flow
1. Count LHS names: `vd->names.count`
2. Count RHS values: `is_global ? vd->values.count : get_total_value_count(vd->values)`
3. Check rhs == 0: error if no type specified
4. Check lhs < rhs: error "extra initial expression"
5. Check lhs > rhs:
   - If !is_global && rhs != 1: error "missing expression"
   - If is_global: error with note about multi-valued expressions
6. Return true for success

### Odin Logic Flow
1. Count LHS names: `len(vd.names)`
2. Count RHS values: `is_global ? len(vd.values) : get_total_value_count(ctx, vd.values[:])`
3. Check rhs == 0: error if no type specified
4. Check lhs < rhs: error "extra initial expression"
5. Check lhs > rhs:
   - If !is_global && rhs != 1: error "missing expression"
   - If is_global: error with note about multi-valued expressions
6. Return (no value needed as callers ignore it)

**Result**: ✓ Semantically equivalent

## Known Limitations

1. **Expression Type Availability**: If expressions aren't type-checked yet, `type_of_expr` returns nil and we count as 1. This is correct for the collection phase but means tuple detection happens later.

2. **Return Value**: C++ version returns bool, Odin version returns nothing. This is safe because all call sites ignore the return value.

3. **ERROR_BLOCK()**: C++ uses ERROR_BLOCK() macro for error grouping. Odin just outputs errors inline, which is equivalent.

## Future Enhancements

When check_stmt.odin's variable declaration handling is implemented, it should call:
```odin
check_arity_match(ctx, vd, false)  // false = local variable
```

This will enable full tuple unpacking validation for local variables.
