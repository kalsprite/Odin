# Phase 27 Group 3: Struct Offset Calculation Fix

## Critical Issue Fixed

The `type_offset_of` function was calculating struct field offsets by simply summing field sizes, completely ignoring alignment padding. This produced **incorrect offsets** for most real-world structs.

## Example of the Bug

```odin
Foo :: struct {
    a: u8,   // 1 byte
    b: u32   // 4 bytes, requires 4-byte alignment
}

// OLD BEHAVIOR (WRONG):
offset_of(Foo, b)  // Returns 1 (just sum: 0 + 1)

// NEW BEHAVIOR (CORRECT):
offset_of(Foo, b)  // Returns 4 (aligned to u32's 4-byte requirement)
```

In reality, field `b` cannot be placed at offset 1 because u32 requires 4-byte alignment. The compiler inserts 3 bytes of padding after `a`, placing `b` at offset 4.

## Root Cause Analysis

### C++ Reference Implementation
The original C++ code (types.cpp:4214-4259) uses `type_set_offsets_of` which:
1. Iterates through each field
2. Aligns the current offset to the field's alignment requirement using `align_formula`
3. Records that aligned offset
4. Advances by the field's size

The critical `align_formula` function (common_memory.cpp:12-15):
```cpp
i64 align_formula(i64 size, i64 align) {
    i64 result = size + align - 1;
    return result - (i64)((u64)result % (u64)align);
}
```

This rounds `size` up to the next multiple of `align`.

### Previous Odin Implementation (BROKEN)
```odin
case .Struct:
    struc := t.variant.(Type_Struct)
    offset: i64 = 0
    for i in 0..<index {
        if field := struc.fields[i]; field.kind == .Variable {
            var_field := field.variant.(Entity_Variable)
            offset += i64(type_size_of(var_field.type))  // Just sum sizes!
        }
    }
    return offset
```

This ignored alignment completely, just adding sizes together.

## Fix Implementation

### New Struct Offset Calculation
```odin
case .Struct:
    struc := t.variant.(Type_Struct)
    if index < 0 || index >= i64(len(struc.fields)) {
        return 0
    }

    curr_offset: i64 = 0

    // Process all fields before the target field
    for i in 0..<index {
        if field := struc.fields[i]; field.kind == .Variable {
            var_field := field.variant.(Entity_Variable)

            field_align := i64(type_align_of(var_field.type))
            field_size := i64(type_size_of(var_field.type))

            // CRITICAL: Align offset before placing this field
            if field_align > 0 {
                curr_offset = (curr_offset + field_align - 1) -
                              ((curr_offset + field_align - 1) % field_align)
            }

            curr_offset += field_size
        }
    }

    // Align to the target field's alignment
    if field := struc.fields[index]; field.kind == .Variable {
        var_field := field.variant.(Entity_Variable)
        target_align := i64(type_align_of(var_field.type))
        if target_align > 0 {
            curr_offset = (curr_offset + target_align - 1) -
                          ((curr_offset + target_align - 1) % target_align)
        }
    }

    return curr_offset
```

### Same Fix Applied to Tuples
Tuples have the same issue and received an identical fix since they're essentially anonymous structs.

## Test Cases Demonstrating the Fix

### Test 1: Basic Alignment Padding
```odin
Test1 :: struct {
    a: u8,   // offset 0, size 1
    b: u32   // offset 4 (NOT 1), size 4
}
```

**Calculation for field b (index 1):**
1. Start: curr_offset = 0
2. Process field a (u8):
   - Align to 1: curr_offset = 0
   - Add size 1: curr_offset = 1
3. Align to field b's alignment (4):
   - curr_offset = (1 + 4 - 1) - ((4) % 4) = 4 - 0 = 4
4. Result: offset = 4 ✓

**Old (broken) result: 1** ✗

### Test 2: No Padding Needed
```odin
Test2 :: struct {
    a: u32,  // offset 0, size 4
    b: u32   // offset 4, size 4
}
```

**Calculation for field b (index 1):**
1. Start: curr_offset = 0
2. Process field a (u32):
   - Align to 4: curr_offset = 0
   - Add size 4: curr_offset = 4
3. Align to field b's alignment (4):
   - curr_offset = (4 + 4 - 1) - ((7) % 4) = 7 - 3 = 4
4. Result: offset = 4 ✓

**Old result: 4** ✓ (worked by coincidence)

### Test 3: Complex Multi-Field Alignment
```odin
Test3 :: struct {
    a: u8,   // offset 0, size 1
    b: u64,  // offset 8 (NOT 1), size 8
    c: u16   // offset 16 (NOT 9), size 2
}
```

**Calculation for field b (index 1):**
1. Start: curr_offset = 0
2. Process field a (u8):
   - Align to 1: curr_offset = 0
   - Add size 1: curr_offset = 1
3. Align to field b's alignment (8):
   - curr_offset = (1 + 8 - 1) - ((8) % 8) = 8 - 0 = 8
4. Result: offset = 8 ✓

**Old (broken) result: 1** ✗

**Calculation for field c (index 2):**
1. Start: curr_offset = 0
2. Process field a (u8):
   - Align to 1: curr_offset = 0
   - Add size 1: curr_offset = 1
3. Process field b (u64):
   - Align to 8: curr_offset = 8
   - Add size 8: curr_offset = 16
4. Align to field c's alignment (2):
   - curr_offset = (16 + 2 - 1) - ((17) % 2) = 17 - 1 = 16
5. Result: offset = 16 ✓

**Old (broken) result: 9** ✗

## Alignment Formula Explanation

The formula `(offset + align - 1) - ((offset + align - 1) % align)` rounds offset up to the next multiple of align:

```
Examples:
- offset=1, align=4: (1+4-1) - (4%4) = 4 - 0 = 4
- offset=5, align=8: (5+8-1) - (12%8) = 12 - 4 = 8
- offset=8, align=8: (8+8-1) - (15%8) = 15 - 7 = 8 (already aligned)
- offset=9, align=2: (9+2-1) - (10%2) = 10 - 0 = 10
```

This is mathematically equivalent to the bit-manipulation approach `(offset + align - 1) & ~(align - 1)` when align is a power of 2, but works for any alignment value.

## Files Modified

- `/mnt/d/dev/checker/types.odin` (lines 1370-1447)
  - Fixed `.Struct` case in `type_offset_of`
  - Fixed `.Tuple` case in `type_offset_of`

## Dependencies

This fix relies on `type_align_of` which was already correctly implemented in types.odin (lines 781-813) and returns proper alignment values for all type kinds.

## Impact

This fix is **critical** for correctness. Incorrect offset calculations would cause:
- Wrong offsets reported by `offset_of` intrinsic
- Potential memory corruption if offsets are used for unsafe pointer arithmetic
- Incorrect struct layout analysis
- Mismatched expectations between compiler and runtime

All struct types with fields having different alignments were affected by this bug.
