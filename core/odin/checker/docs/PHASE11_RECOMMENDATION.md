# Phase 11 Recommendation: Built-in Procedures

**Date**: 2025-10-01
**Prepared by**: Implementation Overseer
**Context**: Following successful Phase 10A (Call Expressions)

---

## Executive Summary

After completing Phase 10A (basic procedure calls), the **highest value next step** is implementing built-in procedure support. This enables checking of essential Odin operations like `len()`, `cap()`, `size_of()`, `type_of()`, etc., which are fundamental to most Odin programs.

**Recommendation**: **Phase 11 - Built-in Procedure Calls**

---

## Strategic Analysis

### Current Checker State (Expression Support)

| Expression Type | Status | Phase |
|-----------------|--------|-------|
| Identifiers | ✅ Complete | 1-3 |
| Basic Literals | ✅ Complete | 4 |
| Binary Expressions | ✅ Complete | 5-6 |
| Unary Expressions | ✅ Complete | 7 |
| Type Casts | ✅ Complete | 8 |
| Index/Selector | ✅ Complete | 9 |
| Slice Expressions | ✅ Complete | 9 |
| **Call Expressions** | ✅ **Basic only** | **10A** |
| Built-in Calls | 🔲 **Stubbed** | **11** |
| Compound Literals | ❌ Not started | Future |
| Ternary Expressions | ❌ Not started | Future |
| Type Assertions | ❌ Not started | Future |

**Coverage**: ~85% of basic expression types, but **0% of built-in procedures**

### Impact Analysis

**Without Built-ins** (current state):
```odin
arr := [3]int{1, 2, 3}
n := len(arr)  // ❌ ERROR: "Built-in procedures not yet implemented"

ptr := &my_struct
size := size_of(my_struct)  // ❌ ERROR: "Built-in procedures not yet implemented"

slice := []int{1, 2, 3}
c := cap(slice)  // ❌ ERROR: "Built-in procedures not yet implemented"
```

**With Built-ins** (Phase 11):
```odin
arr := [3]int{1, 2, 3}
n := len(arr)  // ✅ OK: type checks, resolves to constant 3

ptr := &my_struct
size := size_of(my_struct)  // ✅ OK: computes size at compile-time

slice := []int{1, 2, 3}
c := cap(slice)  // ✅ OK: type checks correctly
```

**User Impact**: **CRITICAL** - Most Odin programs cannot be checked without built-ins.

---

## Option Evaluation

### Option A: Built-in Procedures (RECOMMENDED)

**Pros**:
- ✅ Highest impact per LOC
- ✅ Enables checking of real Odin code
- ✅ Natural extension of Phase 10A call infrastructure
- ✅ Moderate complexity (medium-high)
- ✅ Well-defined scope (~20 core built-ins)
- ✅ Builds on existing type system

**Cons**:
- ⚠️ Some built-ins require special handling
- ⚠️ Compile-time evaluation needed for some cases
- ⚠️ 800-1000 LOC estimate (larger phase)

**C++ Reference**: `/mnt/c/odin/src/check_builtin.cpp` (~4,500 LOC total, ~1,000 LOC for core subset)

**Estimated Scope**:
```
Core built-ins (priority order):
1. len()           - array/slice/string/map length
2. cap()           - slice/dynamic array capacity
3. size_of()       - compile-time type size
4. align_of()      - compile-time type alignment
5. offset_of()     - struct field offset
6. type_of()       - reflection type
7. type_info_of()  - runtime type info
8. typeid_of()     - type ID

Memory operations:
9. new()           - allocate single value
10. make()         - allocate container
11. delete()       - free memory
12. free()         - explicit free

Slicing operations:
13. append()       - dynamic array append
14. clear()        - clear container
15. reserve()      - pre-allocate capacity

Optional (defer to Phase 11B):
- min(), max()     - arithmetic (could be regular procs)
- clamp()          - arithmetic (could be regular proc)
- abs()            - arithmetic (could be regular proc)
- panic(), assert()- compiler intrinsics
```

**Phase 11A Scope**: Items 1-8 (~500 LOC)
**Phase 11B Scope**: Items 9-15 (~400 LOC)

**Implementation Strategy**:

```odin
// In check_call_expr, where we currently stub:
if o.mode == .Builtin {
    // Dispatch to builtin checker
    if !check_builtin_procedure(ctx, o, call, o.builtin_id, type_hint) {
        o.mode = .Invalid
        o.type = t_invalid
    }
    o.expr = node
    return builtin_procs[o.builtin_id].kind  // Expr or Stmt
}

// New file: check_builtin.odin
check_builtin_procedure :: proc(
    ctx: ^Checker_Context,
    operand: ^Operand,
    call: ^ast.Node,
    builtin_id: Builtin_Proc_Id,
    type_hint: ^Type,
) -> bool {
    switch builtin_id {
    case .Len:
        return check_builtin_len(ctx, operand, call)
    case .Cap:
        return check_builtin_cap(ctx, operand, call)
    case .Size_Of:
        return check_builtin_size_of(ctx, operand, call)
    // ... etc
    }
}
```

### Option B: Compound Literals

**Pros**:
- ✅ Enables struct/array initialization
- ✅ Medium complexity
- ✅ Common pattern in Odin

**Cons**:
- ⚠️ Medium impact (less critical than built-ins)
- ⚠️ Can be deferred - type checking works without it
- ⚠️ Requires more aggregate type infrastructure

**C++ Reference**: `/mnt/c/odin/src/check_expr.cpp` compound literal section

**Estimated Scope**: 400-600 LOC

**Rationale for Deferral**: While useful, programs can work around missing compound literal checking more easily than missing built-ins.

### Option C: Named Arguments (Phase 10B)

**Pros**:
- ✅ Completes call expression feature set
- ✅ Moderate complexity
- ✅ Ergonomic improvement

**Cons**:
- ⚠️ Lower impact (optional feature)
- ⚠️ Requires parameter name tracking infrastructure
- ⚠️ Positional args sufficient for most cases

**Estimated Scope**: 150-200 LOC

**Rationale for Deferral**: Nice-to-have but not blocking for basic program checking.

---

## Recommendation: Phase 11 - Built-in Procedures

### Justification

1. **Critical Path Item**: Built-ins are in nearly every Odin program
2. **Immediate Value**: Enables checking of real-world code
3. **Natural Progression**: Builds directly on Phase 10A infrastructure
4. **Well-Scoped**: Clear boundary of ~20 core built-ins
5. **Moderate Risk**: Medium-high complexity, but well-understood patterns

### Implementation Plan

**Phase 11A**: Core Built-ins (Priority 1)
- Duration: ~3-4 hours
- LOC: ~500
- Features: len, cap, size_of, align_of, offset_of, type_of, type_info_of, typeid_of

**Phase 11B**: Memory & Container Built-ins (Priority 2)
- Duration: ~2-3 hours
- LOC: ~400
- Features: new, make, delete, free, append, clear, reserve

**Phase 11C**: Miscellaneous Built-ins (Priority 3)
- Duration: ~1-2 hours
- LOC: ~200
- Features: min, max, clamp, abs, etc. (if not made regular procedures)

### Success Criteria

Phase 11A is complete when:
1. ✅ All 8 core built-ins type-check correctly
2. ✅ Compile-time constant evaluation works for size_of, align_of, offset_of
3. ✅ Error messages are clear for argument type mismatches
4. ✅ All advanced built-ins (11B, 11C) are stubbed with TODOs
5. ✅ Compiles cleanly with no warnings
6. ✅ Zero technical debt

### Risk Mitigation

**Risk 1**: Constant evaluation complexity
- **Mitigation**: Start with simple cases, stub complex evaluation

**Risk 2**: Type introspection requirements (type_of, type_info_of)
- **Mitigation**: Defer these to Phase 11B if infrastructure not ready

**Risk 3**: Scope creep (too many built-ins)
- **Mitigation**: Strict Phase 11A/11B/11C separation, only 8 for Phase 11A

---

## Alternative Paths (Not Recommended)

### Why NOT Compound Literals First

**Reasoning**:
- Built-ins are more fundamental
- Compound literals can be worked around
- Built-ins are needed to check even simple array/slice code
- Better value-to-effort ratio with built-ins

**Future Timing**: After Phase 11 or 12

### Why NOT Named Arguments First

**Reasoning**:
- Positional arguments work for MVP
- Named args are ergonomic, not functional requirement
- Built-ins enable more code to be checked
- Can be done as Phase 10B anytime

**Future Timing**: After Phase 11 and other critical features

### Why NOT Polymorphic Procedures

**Reasoning**:
- Way too complex (500+ LOC, very high risk)
- Requires full generic infrastructure
- Defer until type system is more complete
- Built-ins are simpler and higher impact

**Future Timing**: Phase 15+ (after type system maturity)

---

## Expected Deliverables (Phase 11A)

1. **New File**: `/mnt/d/dev/checker/check_builtin.odin` (~500 LOC)
   - `check_builtin_procedure()` dispatcher
   - `check_builtin_len()` implementation
   - `check_builtin_cap()` implementation
   - `check_builtin_size_of()` implementation
   - `check_builtin_align_of()` implementation
   - `check_builtin_offset_of()` implementation
   - `check_builtin_type_of()` implementation
   - `check_builtin_type_info_of()` implementation
   - `check_builtin_typeid_of()` implementation

2. **Modified**: `/mnt/d/dev/checker/check_expr.odin`
   - Remove stub from `.Builtin` case
   - Add call to `check_builtin_procedure()`

3. **Modified**: `/mnt/d/dev/checker/checker.odin` (if needed)
   - Add `Builtin_Proc_Id` enum (may already exist)
   - Built-in procedure metadata

4. **Documentation**: `/mnt/d/dev/checker/11_STATUS.md`
   - Implementation report
   - Coverage analysis
   - Phase 11B/11C stub documentation

---

## C++ Source Mapping (Phase 11A)

Primary reference: `/mnt/c/odin/src/check_builtin.cpp`

Key functions to port:
- `check_builtin_procedure()` (lines ~400-500)
- `check_builtin_len()` (lines ~600-700)
- `check_builtin_cap()` (lines ~700-800)
- `check_builtin_size_of()` (lines ~1200-1300)
- `check_builtin_align_of()` (lines ~1300-1400)
- `check_builtin_offset_of()` (lines ~1400-1600)
- `check_builtin_type_of()` (lines ~2000-2100)
- Helper functions for constant evaluation

**Total C++ LOC**: ~4,500 (full file)
**Phase 11A Target**: ~1,000 LOC (subset)
**Estimated Odin LOC**: ~500 (50% of C++ due to simplifications)

---

## Quality Standards (Same as Phase 10A)

All Phase 11A deliverables must meet:

1. ✅ **Zero Technical Debt**: All deferred features clearly stubbed
2. ✅ **Clean Compilation**: No errors, no warnings
3. ✅ **Comprehensive TODOs**: All Phase 11B/11C stubs documented
4. ✅ **C++ References**: Every function has source line references
5. ✅ **Error Messages**: Clear, informative errors for all cases
6. ✅ **Type Safety**: Proper type checking and validation
7. ✅ **Defensive Code**: Nil checks, mode validation, assertions

---

## Timeline Estimate

**Phase 11A** (8 core built-ins):
- Analysis & Planning: 1 hour
- Implementation: 2.5 hours
- Testing & Verification: 0.5 hours
- **Total**: ~4 hours

**Phase 11B** (7 memory/container built-ins):
- Implementation: 2 hours
- Testing & Verification: 0.5 hours
- **Total**: ~2.5 hours

**Phase 11C** (remaining built-ins):
- Implementation: 1.5 hours
- **Total**: ~1.5 hours

**Full Built-in Support**: ~8 hours total

---

## Success Metrics

After Phase 11A, the checker will support:

**Expression Types**:
- ✅ 100% of basic expressions (idents, literals, binary, unary)
- ✅ 100% of accessors (index, slice, selector)
- ✅ 100% of basic calls
- ✅ 40% of built-in procedures (8/20 core ones)

**Real Code Coverage**:
- Estimated: **60-70% of typical Odin programs** can be type-checked
- Up from: **20-30%** (current state)

**User Benefit**:
- ✅ Can check programs with arrays, slices, strings
- ✅ Can check programs with basic allocation
- ✅ Can check programs with type introspection
- ✅ Can check programs with struct field access

---

## Conclusion

**RECOMMENDATION**: Proceed with **Phase 11A - Core Built-in Procedures**

**Rationale**:
1. Highest impact on real-world Odin code checking
2. Natural extension of completed Phase 10A
3. Well-scoped and achievable (~4 hours)
4. Clear success criteria
5. Manageable complexity

**Next Steps**:
1. Create Phase 11A implementation specification
2. Analyze C++ built-in procedure implementations
3. Implement 8 core built-ins with proper stubs for 11B/11C
4. Verify compilation and quality standards
5. Document in 11_STATUS.md

**Alternatives**: Defer Compound Literals, Named Arguments, and Polymorphic Procedures until after built-ins are complete.

---

**Approved for Implementation**: ✅ YES
**Priority**: **HIGH**
**Risk Level**: **MEDIUM-HIGH** (manageable)
**Expected Value**: **VERY HIGH**

**Prepared by**: Implementation Overseer
**Date**: 2025-10-01
