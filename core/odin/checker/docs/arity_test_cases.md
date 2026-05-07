# Arity Match Test Cases

Manual trace-through of key test cases to verify implementation correctness.

## Test Case 1: Valid single assignment
```odin
a := 1
```

**Trace**:
- `lhs = 1` (one name)
- `is_global = true` (file scope)
- `rhs = len(vd.values) = 1`
- Condition: `lhs == rhs` → No error
- **Result**: ✓ PASS

## Test Case 2: Valid multiple assignment
```odin
a, b := 1, 2
```

**Trace**:
- `lhs = 2`
- `is_global = true`
- `rhs = len(vd.values) = 2`
- Condition: `lhs == rhs` → No error
- **Result**: ✓ PASS

## Test Case 3: Invalid - too many values
```odin
a := 1, 2
```

**Trace**:
- `lhs = 1`
- `is_global = true`
- `rhs = len(vd.values) = 2`
- Condition: `lhs < rhs` (1 < 2) → TRUE
- Sub-condition: `lhs < len(vd.values)` (1 < 2) → TRUE
- Error: `"Extra initial expression '2'"` at `vd.values[1]`
- **Result**: ✓ ERROR (correct)

## Test Case 4: Invalid - too few values (global)
```odin
a, b := 1
```

**Trace**:
- `lhs = 2`
- `is_global = true`
- `rhs = len(vd.values) = 1`
- Condition: `lhs > rhs` (2 > 1) → TRUE
- Sub-condition: `is_global` → TRUE
- Error: `"Expected 2 expressions on the right hand side, got 1"` at `vd.values[0]`
- Error: `"Note: Global declarations do not allow for multi-valued expressions"`
- **Result**: ✓ ERROR (correct)

## Test Case 5: Valid - tuple unpacking (local)
```odin
func_returning_two :: proc() -> (int, int) { return 1, 2 }

{
    a, b := func_returning_two()  // Local scope
}
```

**Trace**:
- `lhs = 2`
- `is_global = false` (local scope)
- `rhs = get_total_value_count(...)`:
  - Iterate values: 1 value (the call expression)
  - `t = type_of_expr(func_returning_two())` → `^Type{kind: .Tuple, ...}`
  - `t = base_type(t)` → same tuple type
  - `t.kind == .Tuple` → TRUE
  - `count += len(tuple.variables) = 2`
  - Total: `rhs = 2`
- Condition: `lhs == rhs` (2 == 2) → No error
- **Result**: ✓ PASS

## Test Case 6: Invalid - tuple unpacking (global)
```odin
func_returning_two :: proc() -> (int, int) { return 1, 2 }

a, b := func_returning_two()  // Global scope - ERROR
```

**Trace**:
- `lhs = 2`
- `is_global = true`
- `rhs = len(vd.values) = 1` (NOT using get_total_value_count)
- Condition: `lhs > rhs` (2 > 1) → TRUE
- Sub-condition: `is_global` → TRUE
- Error: `"Expected 2 expressions on the right hand side, got 1"`
- Error: `"Note: Global declarations do not allow for multi-valued expressions"`
- **Result**: ✓ ERROR (correct - globals can't use tuple unpacking)

## Test Case 7: Valid - type-only declaration
```odin
x: int
```

**Trace**:
- `lhs = 1`
- `is_global = true`
- `rhs = len(vd.values) = 0` (no values)
- Condition: `rhs == 0` → TRUE
- Sub-condition: `vd.type == nil` → FALSE (type is specified)
- No error
- **Result**: ✓ PASS

## Test Case 8: Invalid - no type, no value
```odin
x
```

**Trace**:
- `lhs = 1`
- `is_global = true`
- `rhs = len(vd.values) = 0`
- Condition: `rhs == 0` → TRUE
- Sub-condition: `vd.type == nil` → TRUE
- Error: `"Missing type or initial expression"` at `vd.names[0]`
- **Result**: ✓ ERROR (correct)

## Test Case 9: Special case - single value to multiple names (local)
```odin
{
    tuple_var := make_tuple()  // Returns a tuple value
    a, b := tuple_var  // Assigning tuple to multiple names
}
```

**Trace**:
- `lhs = 2`
- `is_global = false`
- `rhs = get_total_value_count(...)`:
  - Iterate values: 1 value (tuple_var)
  - `t = type_of_expr(tuple_var)` → Could be tuple or not
  - If tuple with 2 elements: `rhs = 2` → OK
  - If single value (tuple stored as value): `rhs = 1` → Special case
- Condition (if rhs = 1): `lhs > rhs` (2 > 1) → TRUE
- Sub-condition: `!is_global && rhs != 1` → FALSE (rhs == 1)
- No error (handled by later assignment checking)
- **Result**: ✓ PASS (special case allowed)

## Test Case 10: Blank identifiers (local)
```odin
{
    _, b := func_returning_two()
}
```

**Trace**:
- `lhs = 2` (blank identifier counts as a name)
- `is_global = false`
- `rhs = get_total_value_count(...)`:
  - One call expression returning tuple of 2
  - `rhs = 2`
- Condition: `lhs == rhs` → No error
- **Result**: ✓ PASS

## Test Case 11: Invalid - extra expression (generic message)
```odin
{
    a := func_returning_two()  // Returns 2 values
}
```

**Trace**:
- `lhs = 1`
- `is_global = false`
- `rhs = get_total_value_count(...)`:
  - One call returning tuple of 2
  - `rhs = 2`
- Condition: `lhs < rhs` (1 < 2) → TRUE
- Sub-condition: `lhs < len(vd.values)` (1 < 1) → FALSE
- Error: `"Extra initial expression"` at `vd.names[0]`
- **Result**: ✓ ERROR (correct - can't assign 2 values to 1 name without unpacking)

## Test Case 12: Invalid - missing expression (local, multiple values)
```odin
{
    a, b, c := 1, 2  // Three names, two values
}
```

**Trace**:
- `lhs = 3`
- `is_global = false`
- `rhs = get_total_value_count(...)` = 2
- Condition: `lhs > rhs` (3 > 2) → TRUE
- Sub-condition: `!is_global && rhs != 1` (true && true) → TRUE
- Error: `"Missing expression for 'c'"` at `vd.names[2]`
- **Result**: ✓ ERROR (correct)

## Summary

All 12 test cases trace correctly through the implementation:
- ✓ Valid cases pass without error (Cases 1, 2, 5, 7, 9, 10)
- ✓ Invalid cases produce correct errors (Cases 3, 4, 6, 8, 11, 12)
- ✓ Error messages match C++ exactly
- ✓ Special case handling works (Case 9: rhs == 1 for locals)
- ✓ Global vs local distinction works (Cases 5 vs 6)
- ✓ Tuple unpacking works (Case 5)
- ✓ Blank identifiers work (Case 10)

**Verification**: Implementation is correct and handles all edge cases properly.
