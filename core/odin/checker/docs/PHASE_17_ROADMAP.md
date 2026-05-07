# Phase 17: Quick Wins Sprint - Detailed Roadmap

**Status**: READY TO BEGIN
**Estimated Time**: 40 hours (1 week full-time)
**Risk Level**: LOW
**Expected ROI**: EXTREME (270 LOC → 15+ features unblocked)

---

## Mission Statement

Implement high-value, low-complexity infrastructure to unblock maximum features with minimal code. Focus on type predicates, expression helpers, and field lookup completion.

---

## Phase 17 Task Breakdown

### Task 1: Type Predicate Library (4 hours, 50 LOC)

**Objective**: Implement all missing type predicates to unblock type-specific validations

**Files to Modify**: `/mnt/d/dev/checker/types.odin`

**Functions to Implement**:

#### 1.1: is_type_polymorphic (10 LOC, 30 min)
```odin
is_type_polymorphic :: proc(t: ^Type) -> bool {
    if t == nil do return false
    t := base_type(t)
    #partial switch v in t.variant {
    case Type_Struct:
        return v.is_polymorphic
    case Type_Union:
        return v.is_polymorphic
    case Type_Proc:
        return v.is_polymorphic
    }
    return false
}
```

**Reference**: `/mnt/c/odin/src/types.cpp:2098-2115`

**Unblocks**:
- check_expr.odin:4312 (type assertion polymorphic check)
- check_expr.odin:4485 (polymorphic type distance)
- check_expr.odin:4594 (polymorphic assignment)
- check_type.odin:37, 179, 184 (polymorphic type checking)

---

#### 1.2: is_type_typeid (5 LOC, 15 min)
```odin
is_type_typeid :: proc(t: ^Type) -> bool {
    if t == nil do return false
    t := base_type(t)
    if bt, ok := t.variant.(Type_Basic); ok {
        return bt.kind == .Typeid
    }
    return false
}
```

**Reference**: `/mnt/c/odin/src/types.cpp:1850-1857`

**Unblocks**:
- check_expr.odin:1324 (type mode to typeid assignment)
- check_expr.odin:3775 (typeid constant folding)

---

#### 1.3: is_type_u8_array (5 LOC, 15 min)
```odin
is_type_u8_array :: proc(t: ^Type) -> bool {
    if t == nil do return false
    if arr, ok := base_type(t).variant.(Type_Array); ok {
        if bt, ok := base_type(arr.elem).variant.(Type_Basic); ok {
            return bt.kind == .U8
        }
    }
    return false
}
```

**Reference**: `/mnt/c/odin/src/types.cpp:2147-2156`

**Unblocks**:
- check_expr.odin:3941 (string to byte array conversion)

---

#### 1.4: is_type_rune_array (5 LOC, 15 min)
```odin
is_type_rune_array :: proc(t: ^Type) -> bool {
    if t == nil do return false
    if arr, ok := base_type(t).variant.(Type_Array); ok {
        return is_type_rune(arr.elem)
    }
    return false
}
```

**Reference**: `/mnt/c/odin/src/types.cpp:2158-2167`

**Unblocks**:
- check_expr.odin:3941 (string to rune array conversion)

---

#### 1.5: is_type_u8_slice (5 LOC, 15 min)
```odin
is_type_u8_slice :: proc(t: ^Type) -> bool {
    if t == nil do return false
    if slice, ok := base_type(t).variant.(Type_Slice); ok {
        if bt, ok := base_type(slice.elem).variant.(Type_Basic); ok {
            return bt.kind == .U8
        }
    }
    return false
}
```

**Reference**: `/mnt/c/odin/src/types.cpp:2169-2178`

**Unblocks**:
- check_expr.odin:4057 (cstring to slice conversion)

---

#### 1.6: is_type_uintptr (5 LOC, 15 min)
```odin
is_type_uintptr :: proc(t: ^Type) -> bool {
    if t == nil do return false
    t := base_type(t)
    if bt, ok := t.variant.(Type_Basic); ok {
        return bt.kind == .Uintptr
    }
    return false
}
```

**Reference**: `/mnt/c/odin/src/types.cpp:1909-1916`

**Unblocks**:
- check_expr.odin:4042 (pointer to uintptr cast)

---

#### 1.7: is_type_soa_struct (10 LOC, 30 min)
```odin
is_type_soa_struct :: proc(t: ^Type) -> bool {
    if t == nil do return false
    t := base_type(t)
    if st, ok := t.variant.(Type_Struct); ok {
        return st.soa_kind != .None  // or check for specific SOA flag
    }
    return false
}
```

**Reference**: `/mnt/c/odin/src/types.cpp:2235-2243`

**Note**: Requires Soa_Kind enum in Type_Struct (may need to add field first)

**Unblocks**:
- check_expr.odin:2472 (SOA slicing)
- check_compound_lit.odin:211, 224, 265 (SOA literals)

---

#### 1.8: is_type_cstring16 (5 LOC, 15 min)
```odin
is_type_cstring16 :: proc(t: ^Type) -> bool {
    if t == nil do return false
    t := base_type(t)
    if bt, ok := t.variant.(Type_Basic); ok {
        return bt.kind == .Cstring16  // Add to Basic_Kind if missing
    }
    return false
}
```

**Reference**: `/mnt/c/odin/src/types.cpp:1876-1883`

**Note**: May need to add Basic_Kind.Cstring16 if not present

**Unblocks**:
- String16 handling throughout checker

---

**Task 1 Acceptance Criteria**:
- [ ] All 8 type predicates implemented
- [ ] Each predicate has C++ reference comment
- [ ] Each predicate follows existing pattern (nil check, base_type, variant match)
- [ ] Zero compilation errors
- [ ] Predicates used at blocker sites

**Task 1 Testing**:
```odin
// Add to types_test.odin (if test infrastructure exists)
test_type_predicates :: proc() {
    // Create test types
    poly_struct := alloc_type_struct(/* polymorphic */)
    assert(is_type_polymorphic(poly_struct))

    typeid_type := /* get typeid type */
    assert(is_type_typeid(typeid_type))

    // etc.
}
```

---

### Task 2: unparen_expr Helper (1 hour, 20 LOC)

**Objective**: Implement expression unwrapping to improve error messages

**File to Modify**: `/mnt/d/dev/checker/check_expr.odin`

**Function to Implement**:

```odin
// Removes parentheses from expression to get the underlying expression.
// Reference: /mnt/c/odin/src/parser.cpp:1879-1889
unparen_expr :: proc(expr: ^ast.Expr) -> ^ast.Expr {
    e := expr
    for {
        if pe, ok := e.derived.(^ast.Paren_Expr); ok {
            e = pe.expr
        } else {
            break
        }
    }
    return e
}
```

**Use Sites** (update these locations):
1. check_expr.odin:1673 - error_operand_no_value
2. check_expr.odin:4605 - check_cast_internal
3. check_expr.odin:1705 - check_selector (TODO comment)
4. All error message sites showing expressions

**Acceptance Criteria**:
- [ ] unparen_expr implemented with C++ reference
- [ ] Used in error_operand_no_value
- [ ] Used in check_cast_internal
- [ ] Compilation succeeds
- [ ] Error messages improved (manual testing)

---

### Task 3: Field Lookup Advanced Cases (16 hours, 200 LOC)

**Objective**: Complete lookup_field_with_selection to support advanced struct features

**File to Modify**: `/mnt/d/dev/checker/types.odin`

**Current State**: Lines 717-911 (partial implementation)

**Sub-Tasks**:

#### 3.1: 'using' Field Traversal (8 hours, 100 LOC)
**Location**: Line 894 stub
**Reference**: `/mnt/c/odin/src/types.cpp:3520-3650`

**Algorithm**:
1. For each struct field marked with 'using'
2. Recursively lookup in embedded field's type
3. Build selection path with indices
4. Handle indirection for pointer embedding
5. Detect ambiguous 'using' paths

**Pseudo-code**:
```odin
// In lookup_field_with_selection after direct field check fails:
if !found && !is_type {
    // Check 'using' fields
    for field, i in struct_type.fields {
        if field.flags & EntityFlag_Using != 0 {
            // Recursive lookup in embedded type
            embedded_sel := lookup_field_with_selection(
                field.type,
                name,
                operand_mode,
                is_type
            )
            if embedded_sel.entity != nil {
                // Found via 'using' - build path
                sel = make_selection(embedded_sel.entity, {i, ...embedded_sel.index})
                sel.indirect = embedded_sel.indirect
                return sel
            }
        }
    }
}
```

**Unblocks**:
- Field embedding semantics
- Nested struct access
- Advanced selector expressions

---

#### 3.2: SOA Field Mapping (4 hours, 50 LOC)
**Location**: Line 916 stub
**Reference**: `/mnt/c/odin/src/types.cpp:3488-3505`

**Algorithm**:
1. Detect SOA struct types (use is_type_soa_struct)
2. Map field names to SOA array indices
3. Return special SOA selection variant

**Stub Implementation** (simplified for MVP):
```odin
if is_type_soa_struct(t) {
    // TODO(Phase 17): Full SOA field mapping
    // For MVP: Return error
    return empty_selection
}
```

**Defer to Phase 18**: Full SOA support requires more infrastructure

---

#### 3.3: Bit Field Lookup (2 hours, 30 LOC)
**Location**: Line 922 stub
**Reference**: `/mnt/c/odin/src/types.cpp:3507-3518`

**Algorithm**:
1. Check if type is bit_field
2. Match field name against bit field names
3. Return selection with is_bit_field flag set

**Implementation**:
```odin
if is_type_bit_field(t) {
    if bf, ok := t.variant.(Type_Bit_Field); ok {
        // Search bit field names
        for name_expr, i in bf.names {
            if ident, ok := name_expr.derived.(^ast.Ident); ok {
                if ident.name == name {
                    // Found bit field
                    sel := make_selection(/* create bit field entity */, {i})
                    sel.is_bit_field = true
                    return sel
                }
            }
        }
    }
}
```

**Unblocks**:
- Bit field struct support
- Low-level programming features

---

#### 3.4: Polymorphic Type Handling (2 hours, 20 LOC)
**Location**: Line 866 stub
**Reference**: `/mnt/c/odin/src/types.cpp:3460-3475`

**Implementation**:
```odin
// Early in lookup_field_with_selection
if is_type_polymorphic(t) {
    // TODO(Phase 17): For MVP, reject polymorphic field access
    // Full implementation requires type specialization
    return empty_selection
}
```

**Note**: Full support deferred to polymorphic type phase

---

**Task 3 Acceptance Criteria**:
- [ ] 'using' field traversal fully implemented
- [ ] Bit field lookup implemented
- [ ] SOA stub with clear TODO (defer to Phase 18)
- [ ] Polymorphic stub with clear TODO
- [ ] Recursive 'using' paths work correctly
- [ ] Ambiguous 'using' detection implemented
- [ ] offset_of builtin works for embedded fields
- [ ] Zero compilation errors
- [ ] Manual testing with nested structs

**Task 3 Testing**:
```odin
// Test case
Point :: struct { x, y: int }
Entity :: struct {
    using pos: Point,  // Embedded with 'using'
    name: string,
}

e: Entity
// e.x should resolve via 'using pos' field
```

---

### Task 4: expr_to_string Basic Implementation (12 hours, 100 LOC)

**Objective**: Convert AST expressions to string representations for error messages

**File to Modify**: `/mnt/d/dev/checker/check_expr_helpers.odin` (or new file)

**Function Signature**:
```odin
// Convert AST expression to string for error messages
// Reference: /mnt/c/odin/src/checker.cpp (various locations)
expr_to_string :: proc(expr: ^ast.Expr, allocator := context.allocator) -> string {
    // ... implementation
}
```

**Sub-Tasks**:

#### 4.1: Basic Expression Types (4 hours, 40 LOC)
**Handle**:
- Identifiers: `foo`
- Literals: `42`, `"hello"`, `true`
- Binary expressions: `a + b`
- Unary expressions: `-x`, `!flag`
- Parentheses: `(expr)`

```odin
expr_to_string :: proc(expr: ^ast.Expr, allocator := context.allocator) -> string {
    if expr == nil do return "<nil>"

    #partial switch e in expr.derived {
    case ^ast.Ident:
        return strings.clone(e.name, allocator)

    case ^ast.Basic_Lit:
        return strings.clone(e.tok.text, allocator)

    case ^ast.Binary_Expr:
        left := expr_to_string(e.left, allocator)
        right := expr_to_string(e.right, allocator)
        defer delete(left, allocator)
        defer delete(right, allocator)
        return fmt.aprintf("%s %s %s", left, token_to_string(e.op), right)

    case ^ast.Unary_Expr:
        operand := expr_to_string(e.expr, allocator)
        defer delete(operand, allocator)
        return fmt.aprintf("%s%s", token_to_string(e.op), operand)

    case ^ast.Paren_Expr:
        inner := expr_to_string(e.expr, allocator)
        defer delete(inner, allocator)
        return fmt.aprintf("(%s)", inner)

    case:
        return "<expression>"  // Fallback
    }
}
```

---

#### 4.2: Selector and Index Expressions (4 hours, 30 LOC)
**Handle**:
- Selectors: `obj.field`
- Indexing: `arr[i]`
- Slicing: `arr[1:10]`

```odin
    case ^ast.Selector_Expr:
        base := expr_to_string(e.expr, allocator)
        selector := expr_to_string(e.field, allocator)
        defer delete(base, allocator)
        defer delete(selector, allocator)
        return fmt.aprintf("%s.%s", base, selector)

    case ^ast.Index_Expr:
        base := expr_to_string(e.expr, allocator)
        index := expr_to_string(e.index, allocator)
        defer delete(base, allocator)
        defer delete(index, allocator)
        return fmt.aprintf("%s[%s]", base, index)

    case ^ast.Slice_Expr:
        base := expr_to_string(e.expr, allocator)
        defer delete(base, allocator)
        low := e.low != nil ? expr_to_string(e.low, allocator) : ""
        high := e.high != nil ? expr_to_string(e.high, allocator) : ""
        defer if low != "" do delete(low, allocator)
        defer if high != "" do delete(high, allocator)
        return fmt.aprintf("%s[%s:%s]", base, low, high)
```

---

#### 4.3: Call and Type Expressions (4 hours, 30 LOC)
**Handle**:
- Calls: `func(a, b)`
- Casts: `cast(T)value`
- Type assertions: `value.(Type)`

```odin
    case ^ast.Call_Expr:
        callee := expr_to_string(e.expr, allocator)
        defer delete(callee, allocator)

        // Build argument list
        args := make([dynamic]string, allocator)
        defer delete(args)
        for arg in e.args {
            append(&args, expr_to_string(arg, allocator))
        }
        defer for arg in args do delete(arg, allocator)

        args_str := strings.join(args[:], ", ", allocator)
        defer delete(args_str, allocator)

        return fmt.aprintf("%s(%s)", callee, args_str)

    case ^ast.Type_Cast:
        type_str := expr_to_string(e.type, allocator)
        expr_str := expr_to_string(e.expr, allocator)
        defer delete(type_str, allocator)
        defer delete(expr_str, allocator)
        return fmt.aprintf("cast(%s)%s", type_str, expr_str)
```

---

**Task 4 Acceptance Criteria**:
- [ ] expr_to_string handles 15+ expression types
- [ ] Fallback for unhandled types: `"<expression>"`
- [ ] Memory management correct (no leaks)
- [ ] Used in error messages at 10+ sites
- [ ] Error messages significantly improved
- [ ] Zero compilation errors

**Use Sites to Update**:
1. check_expr.odin:1662 - error_operand_not_expression
2. check_expr.odin:2146 - index bounds error
3. check_expr.odin:2299 - not indexable error
4. check_expr.odin:2440 - not sliceable error
5. check_expr.odin:3810 - type not found error
6. check_expr.odin:4127 - cast error
7. All other error message sites showing expression context

---

### Task 5: Integration and Testing (7 hours)

**Objectives**:
1. Ensure all new functions compile
2. Update blocker sites to use new infrastructure
3. Test offset_of builtin
4. Verify error messages improved
5. Update documentation

**Sub-Tasks**:

#### 5.1: Compilation Verification (1 hour)
```bash
cd /mnt/d/dev/checker
odin check . -no-entry-point -build-mode:obj
```

**Fix any**:
- Missing imports
- Type mismatches
- Undefined references

---

#### 5.2: Update Blocker Sites (3 hours)

**For each TODO site**:
1. Remove stub comment
2. Call new function
3. Handle result correctly
4. Verify logic matches C++

**Example - check_expr.odin:4312**:
```odin
// Before (stub):
// TODO: Polymorphic type check
if false {  // Stub
    error(...)
}

// After (using is_type_polymorphic):
if is_type_polymorphic(operand.type) {
    error_node(node, "Cannot auto cast polymorphic type")
    return .Expr
}
```

---

#### 5.3: offset_of Builtin Testing (2 hours)

**Test Cases**:
```odin
// Direct field access
Point :: struct { x, y: int }
offset := offset_of(Point, x)  // Should work

// Embedded field access (using)
Entity :: struct {
    using pos: Point,
    name: string,
}
offset := offset_of(Entity, x)  // Should work via 'using'

// Nested field access
offset := offset_of(Entity, pos.x)  // Should work with field path
```

**Verify**:
- [ ] Direct field offset works
- [ ] 'using' field offset works
- [ ] Nested field paths work
- [ ] Unknown fields error correctly
- [ ] Non-struct types error correctly

---

#### 5.4: Error Message Verification (1 hour)

**Before/After Comparison**:

**Before**:
```
Error: Cannot index expression
```

**After**:
```
Error: Cannot index expression 'x + y' of type 'int'
```

**Test Cases**:
- Invalid index expression
- Type mismatch in assignment
- Unknown field access
- Invalid cast

**Verify**:
- [ ] Expression text appears in errors
- [ ] Type names appear in errors
- [ ] Messages are clearer than before

---

#### 5.5: Documentation Update (30 min)

**Update Files**:
1. `/mnt/d/dev/checker/17_STATUS.md` - Create phase status document
2. `/mnt/d/dev/checker/LIMITING_FACTOR_ANALYSIS.md` - Mark blockers resolved
3. Add comments to all new functions with C++ references

**Template for 17_STATUS.md**:
```markdown
# Phase 17 Status: Quick Wins Sprint

**Date**: 2025-10-02
**Status**: ✅ Complete
**LOC Added**: 270

## Completed Tasks
1. Type Predicates (50 LOC)
2. unparen_expr (20 LOC)
3. Field Lookup Advanced (200 LOC)
4. expr_to_string Basic (100 LOC)

## Features Unblocked
- [List all unblocked features]

## Testing Results
- [Compilation status]
- [Manual test results]

## Next Steps
- Phase 18: Constant Evaluation Infrastructure
```

---

## Phase 17 Success Metrics

### Quantitative Metrics
- [ ] 270 LOC added
- [ ] 8 type predicates implemented
- [ ] 15+ blocker sites updated
- [ ] 0 compilation errors
- [ ] 0 new warnings
- [ ] offset_of builtin functional

### Qualitative Metrics
- [ ] Error messages significantly improved
- [ ] Code follows existing patterns
- [ ] All functions have C++ references
- [ ] TODOs are clear for deferred work
- [ ] Documentation is complete

---

## Risk Mitigation

### Risk 1: SOA Field Implementation Complexity
**Mitigation**: Stub SOA with clear TODO, defer to Phase 18
**Fallback**: Return empty_selection for SOA types

### Risk 2: 'using' Field Ambiguity Detection
**Mitigation**: Implement simple duplicate detection first
**Fallback**: Skip ambiguity check, document as Phase 18 task

### Risk 3: expr_to_string Memory Leaks
**Mitigation**: Use defer for all allocated strings
**Testing**: Manual review of allocator usage
**Fallback**: Simplify implementation to static strings

---

## Timeline (40 hours)

| Task | Hours | Days (8hr) | Dependencies |
|------|-------|------------|--------------|
| Type Predicates | 4 | 0.5 | None |
| unparen_expr | 1 | 0.125 | None |
| Field Lookup | 16 | 2 | Type predicates |
| expr_to_string | 12 | 1.5 | unparen_expr |
| Integration & Testing | 7 | 0.875 | All above |
| **Total** | **40** | **5** | |

**Recommended Schedule**:
- Day 1: Type predicates + unparen_expr (complete)
- Days 2-3: Field lookup advanced cases
- Days 4-5: expr_to_string + integration/testing

---

## Deliverables Checklist

- [ ] types.odin: +50 LOC (8 type predicates)
- [ ] check_expr.odin: +20 LOC (unparen_expr)
- [ ] types.odin: +200 LOC (field lookup advanced)
- [ ] check_expr_helpers.odin: +100 LOC (expr_to_string)
- [ ] 15+ blocker sites updated
- [ ] 17_STATUS.md created
- [ ] LIMITING_FACTOR_ANALYSIS.md updated
- [ ] All code compiles cleanly
- [ ] offset_of builtin tested and working
- [ ] Error messages demonstrably improved

---

## Post-Phase 17 State

### Expected Completion
- **Expression Coverage**: 96% (unchanged)
- **Statement Coverage**: 75% (unchanged)
- **Infrastructure Coverage**: 70% → 80% (+10%)
- **Error Message Quality**: 60% → 85% (+25%)

### Unblocked Features
1. offset_of builtin (fully functional)
2. Polymorphic type checks (partial)
3. String to array conversions
4. Pointer to uintptr casts
5. Bit field access
6. Embedded field access via 'using'
7. Better error messages (40+ sites)
8. Type-specific validations (15+ sites)

### Remaining Blockers for Phase 18+
1. add_type_and_value (constant evaluation)
2. Range loop infrastructure
3. Declaration checking
4. Polymorphic type resolution (full)
5. RTTI system

---

**Phase 17 Ready to Begin**: ✅
**Approval Required**: Implementation Overseer sign-off
**Next Phase Planning**: Schedule Phase 18 after Phase 17 completion
