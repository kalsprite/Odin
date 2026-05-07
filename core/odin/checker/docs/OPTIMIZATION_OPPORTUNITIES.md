# Checker Optimization Opportunities

**Date:** 2025-10-09
**Context:** Post-Basic_Flags infrastructure implementation

## Recently Completed

### ✅ Basic_Kind Flags System
- **Status:** Complete
- **Impact:** 16 functions optimized O(n) → O(1)
- **Benefits:** 100+ call sites, ~200 LOC eliminated
- **Documentation:** BASIC_FLAGS_IMPLEMENTATION.md

## Potential Future Optimizations

### 1. Entity_Kind Flags System
**Complexity:** Medium
**Impact:** High
**Effort:** 2-3 sessions

**Analysis:**
Similar to Basic_Kind, Entity_Kind enum could benefit from a flag-based categorization system.

**Current State:**
```odin
Entity_Kind :: enum {
	Invalid,
	Constant,
	Variable,
	Type_Name,
	Procedure,
	// ... ~20 more variants
}
```

**Potential Flags:**
- `.Exported` - Entity is exported from package
- `.Builtin` - Built-in entity
- `.Declaration` - Requires declaration checking
- `.Value` - Has runtime value
- `.Type` - Type-related entity
- `.Callable` - Can be called (Procedure, Builtin)

**Benefits:**
- Fast entity category queries
- Simplified permission checks
- Better query composition

**Files Affected:**
- `entity.odin`
- `checker.odin` (Entity_Kind definition)
- Various entity predicate functions

---

### 2. Addressing_Mode Flags
**Complexity:** Low
**Impact:** Medium
**Effort:** 1 session

**Analysis:**
Addressing_Mode enum has ~14 variants with common categories:

**Potential Flags:**
- `.Lvalue` - Can be assigned to
- `.Constant` - Compile-time constant
- `.Typed` - Has concrete type (vs untyped)
- `.Addressable` - Can take address

**Current Pattern:**
```odin
#partial switch operand.mode {
case .Variable, .Variable_Lvalue, .Variable_SOA:
	// Lvalue operations
}
```

**With Flags:**
```odin
if .Lvalue in operand.mode_flags {
	// Lvalue operations
}
```

**Benefits:**
- Clearer intent in operand checks
- Faster mode category queries
- Reduced switch statement complexity

---

### 3. Type_Kind Fast Path Table
**Complexity:** Low
**Impact:** Medium
**Effort:** 1 session

**Analysis:**
Create a lookup table for common Type_Kind queries:

```odin
type_kind_properties := [Type_Kind]Type_Kind_Props {
	.Basic = {
		is_value_type = true,
		has_nil = false,
		is_copyable = true,
		// ...
	},
	// ... etc
}
```

**Benefits:**
- O(1) type property lookups
- Centralized type behavior definitions
- Easier to maintain consistency

**Use Cases:**
- `type_has_nil()` checks
- Copyability checks
- Value vs reference type queries

---

### 4. Scope Lookup Caching
**Complexity:** High
**Impact:** High (hot path)
**Effort:** 3-4 sessions

**Analysis:**
Scope lookups happen frequently during semantic analysis. Adding a simple cache could significantly improve performance.

**Current:**
- Linear search through scope chains
- Repeated lookups for same symbols

**Proposed:**
- Thread-local lookup cache
- Invalidate on scope modifications
- LRU eviction policy

**Risks:**
- Cache invalidation complexity
- Thread-safety concerns
- Memory overhead

**Benefits:**
- Faster repeated lookups (common pattern)
- Reduced scope traversal overhead

---

### 5. Type Equivalence Memoization
**Complexity:** High
**Impact:** High
**Effort:** 3-4 sessions

**Analysis:**
`are_types_identical()` is called frequently and does recursive deep comparisons.

**Proposed:**
- Memoization table for type pairs
- Hash-cons for equivalent types
- Reuse identical type structures

**Challenges:**
- Memory management
- Cache invalidation
- Thread-safety

**Benefits:**
- Avoid redundant deep comparisons
- Faster type checking in generic contexts

---

### 6. String Interning for Identifiers
**Complexity:** Medium
**Impact:** Medium
**Effort:** 2-3 sessions

**Analysis:**
Identifier strings are compared frequently. Interning would enable pointer comparison.

**Current:**
```odin
if name1 == name2 {  // String comparison
```

**With Interning:**
```odin
if intern(name1) == intern(name2) {  // Pointer comparison
```

**Benefits:**
- O(1) string equality checks
- Reduced memory (shared strings)
- Faster symbol lookups

---

### 7. Fast Path for Common Type Checks
**Complexity:** Low
**Impact:** Low-Medium
**Effort:** 1 session

**Analysis:**
Add fast rejection paths for common negative cases:

**Example:**
```odin
is_type_numeric :: proc(t: ^Type) -> bool {
	// Fast rejection for obvious non-numerics
	if t.kind == .Slice || t.kind == .Map {
		return false
	}

	// Existing logic
	// ...
}
```

**Benefits:**
- Early exit for common cases
- Reduced branch mispredictions
- Clearer code intent

---

### 8. Procedure Signature Hashing
**Complexity:** Medium
**Impact:** Medium
**Effort:** 2 sessions

**Analysis:**
Hash procedure signatures for fast comparison in overload resolution.

**Current:**
- Deep comparison of parameter/result types
- Repeated for each overload candidate

**Proposed:**
- Pre-compute signature hashes
- Fast hash comparison + deep compare on collision

**Benefits:**
- Faster overload resolution
- Reduced comparison overhead
- Better scaling with overload count

---

### 9. Bit_Set Operations Optimization
**Complexity:** Low
**Impact:** Low
**Effort:** <1 session

**Analysis:**
Odin's bit_set already efficient, but could add convenience functions:

```odin
// Instead of:
if (flags & MASK) != {} { ... }

// Provide:
flags_match_any :: proc(flags, mask: $T) -> bool {
	return (flags & mask) != {}
}
```

**Benefits:**
- More readable code
- Consistent patterns
- Potential compiler optimization

---

### 10. Entity Dependency Graph Optimization
**Complexity:** Very High
**Impact:** High (build times)
**Effort:** 5+ sessions

**Analysis:**
Current dependency tracking could be optimized with:
- Incremental dependency updates
- Topological sort caching
- Parallel dependency resolution

**Challenges:**
- Complex dependency semantics
- Thread-safety requirements
- Correct ordering guarantees

**Benefits:**
- Faster incremental compilation
- Better parallelization
- Reduced redundant checks

---

## Prioritization Matrix

| Optimization | Complexity | Impact | Effort | Priority |
|--------------|-----------|--------|--------|----------|
| Entity_Kind Flags | Medium | High | 2-3 | **HIGH** |
| Addressing_Mode Flags | Low | Medium | 1 | **MEDIUM** |
| Type_Kind Properties | Low | Medium | 1 | **MEDIUM** |
| Fast Path Type Checks | Low | Low-Med | 1 | **LOW** |
| Bit_Set Helpers | Low | Low | <1 | **LOW** |
| Scope Caching | High | High | 3-4 | **FUTURE** |
| Type Memoization | High | High | 3-4 | **FUTURE** |
| String Interning | Medium | Medium | 2-3 | **FUTURE** |
| Signature Hashing | Medium | Medium | 2 | **FUTURE** |
| Dependency Graph | Very High | High | 5+ | **FUTURE** |

## Recommendations

### Immediate Next Steps (1-2 sessions)
1. **Entity_Kind Flags** - Similar pattern to Basic_Flags, proven approach
2. **Addressing_Mode Flags** - Quick win, clear benefit
3. **Fast Path Optimizations** - Low-hanging fruit

### Medium Term (3-5 sessions)
1. **Type_Kind Properties Table** - Centralize type behavior
2. **String Interning** - Foundational for many optimizations
3. **Signature Hashing** - Improves overload resolution

### Long Term (Future Consideration)
1. **Scope Lookup Caching** - Requires careful design
2. **Type Equivalence Memoization** - Complex but high impact
3. **Dependency Graph Optimization** - Major undertaking

## Implementation Strategy

### Proven Pattern (from Basic_Flags)
1. **Define flag enum** with bit positions
2. **Create lookup table** mapping enum → flags
3. **Update initialization** to populate flags
4. **Convert predicates** to flag checks
5. **Add composite flags** for common queries
6. **Document** thoroughly
7. **Test** standalone before integration

### Success Criteria
- ✅ Measurable performance improvement
- ✅ No functional regressions
- ✅ Code clarity maintained or improved
- ✅ Comprehensive documentation
- ✅ Test coverage for new functionality

## Notes

### Measurement Methodology
Before optimizing:
1. Profile current implementation
2. Identify hotspots
3. Measure baseline performance
4. Set improvement targets

After optimizing:
1. Re-measure performance
2. Verify correctness
3. Document improvements
4. Compare against baseline

### Avoid Premature Optimization
- Focus on high-impact areas first
- Don't optimize without profiling
- Maintain code clarity
- Document trade-offs

## Conclusion

The Basic_Flags system proves that systematic flag-based optimizations can provide significant benefits. The most promising next targets are:

1. **Entity_Kind Flags** - Similar approach, high impact
2. **Addressing_Mode Flags** - Quick win
3. **Type_Kind Properties** - Centralize behavior

These follow the proven pattern and provide clear benefits without excessive complexity.

---

**Document Status:** Living document
**Last Updated:** 2025-10-09
**Next Review:** After next major optimization
