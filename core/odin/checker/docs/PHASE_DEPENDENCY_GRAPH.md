# Phase Dependency Graph - Visual Roadmap

**Date**: 2025-10-02
**Status**: Phase 20-21 Complete → Phases 22-30 Planned

---

## Critical Path Visualization

```
                                    ODIN CHECKER COMPLETION PATH
                                    ═══════════════════════════

START: Phase 20-21 Complete (100%)
│
├─────────────────────────────────────────────────────────────────────────────┐
│  PHASE 22: STRUCTURAL FOUNDATION                                    2 weeks │
│  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━  │
│  Priority: ⭐⭐⭐⭐⭐ CRITICAL BLOCKER                                        │
│  LOC: 125 | Risk: LOW                                                       │
│                                                                              │
│  Tasks:                                                                      │
│  • Add Entity struct fields (50 LOC)                                         │
│  • Add Entity_Nil variant (10 LOC)                                           │
│  • Add required_global_variable_queue (20 LOC)                               │
│  • Fix make_decl_info parent linkage (15 LOC)                                │
│  • Decide variadic reuse fields (30 LOC)                                     │
│                                                                              │
│  Unlocks: Everything (critical blocker removal)                             │
│  Force Multiplier: Enables 1,572 LOC of Phase 19 code                       │
└──────────────────────────────────────────────────────────────┬──────────────┘
                                                               │
                                                               ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│  PHASE 23: HELPER FUNCTIONS & INTEGRATION                           3 weeks │
│  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━  │
│  Priority: ⭐⭐⭐⭐⭐ CRITICAL BLOCKER                                        │
│  LOC: 600 | Risk: MEDIUM                                                    │
│                                                                              │
│  Tasks:                                                                      │
│  • 15 core helpers (check_unpack_arguments, entity_of_node, ...) 180 LOC    │
│  • 5 scope helpers (scope_lookup_parent fix, ...) 80 LOC                     │
│  • 4 error helpers (resolve proc group conflicts, ...) 60 LOC                │
│  • 3 attribute helpers (check_decl_attributes, ...) 120 LOC                  │
│  • 5 type helpers (check_assignment_variable, ...) 80 LOC                    │
│  • 7 misc helpers (check_init_variables, ...) 80 LOC                         │
│                                                                              │
│  Unlocks: Phase 19 integration (1,572 LOC activation)                       │
│  Dependencies: Phase 22 complete                                            │
└──────────────────────────────────────────────────────────────┬──────────────┘
                                                               │
                                                               ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│  PHASE 24: STATEMENT COMPLETION                                     1 week  │
│  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━  │
│  Priority: ⭐⭐⭐⭐ HIGH                                                      │
│  LOC: 450 new + 1,572 activated = 2,022 total | Risk: LOW                   │
│                                                                              │
│  Tasks:                                                                      │
│  • Activate Phase 19 code (1,572 LOC)                                        │
│  • check_range_stmt (150 LOC)                                                │
│  • check_inline_range_stmt (80 LOC)                                          │
│  • check_using_stmt (100 LOC)                                                │
│  • check_foreign_block_decl (50 LOC)                                         │
│  • check_case_clause (20 LOC)                                                │
│  • viral_state_flags (50 LOC)                                                │
│                                                                              │
│  Result: Statement coverage 75% → 100% ✅                                    │
│  Dependencies: Phase 23 complete                                            │
└──────────────┬──────────────────────────────────────────────┬──────────────┘
               │                                              │
               ▼                                              ▼
    ┌──────────────────────┐                    ┌─────────────────────────────┐
    │  PHASE 27: BUILTINS  │                    │  PHASE 25: GLOBAL ENTITIES  │
    │  ══════════════════  │                    │  ═════════════════════════  │
    │  ⭐⭐⭐ MEDIUM        │                    │  ⭐⭐⭐⭐ HIGH               │
    │  2 weeks | 900 LOC   │                    │  3 weeks | 1,500 LOC        │
    │                      │                    │                             │
    │  • SIMD ops (600)    │                    │  • Entity collection (300)  │
    │  • ObjC ops (150)    │                    │  • Import/Export (400)      │
    │  • Reflection (100)  │                    │  • Init order (600)         │
    │  • Atomic (50)       │                    │  • Foreign imports (200)    │
    │                      │                    │                             │
    │  Can run in parallel │                    │  Critical path              │
    │  with Phase 25-26    │                    │                             │
    └──────────┬───────────┘                    └──────────────┬──────────────┘
               │                                               │
               │                                               ▼
               │                               ┌─────────────────────────────────┐
               │                               │  PHASE 26: PROCEDURE BODIES     │
               │                               │  ═══════════════════════════    │
               │                               │  ⭐⭐⭐⭐ HIGH                   │
               │                               │  2 weeks | 1,100 LOC            │
               │                               │                                 │
               │                               │  • Procedure processing (400)   │
               │                               │  • Parallel infra (200)         │
               │                               │  • Proc validation (300)        │
               │                               │  • Deferred checks (200)        │
               │                               │                                 │
               │                               │  Enables: Parallel checking ✅  │
               │                               └─────────────┬───────────────────┘
               │                                             │
               └─────────────┬───────────────────────────────┘
                             ▼
                ┌──────────────────────────────────────────────┐
                │       MVP CHECKPOINT (90% COMPLETE)          │
                │  ════════════════════════════════════════    │
                │  Timeline: 6 weeks from Phase 22 start       │
                │                                              │
                │  Capabilities:                               │
                │  ✅ All expressions (100%)                   │
                │  ✅ All statements (100%)                    │
                │  ✅ Declaration checking (100%)              │
                │  ✅ Global processing (100%)                 │
                │  ✅ Procedure bodies (100%)                  │
                │  ✅ Basic builtins (90%)                     │
                │  ❌ Generics (0%)                            │
                │  ❌ Overloading (0%)                         │
                │  ❌ RTTI (0%)                                │
                └──────────────┬───────────────────────────────┘
                               │
                               ▼
                ┌──────────────────────────────────────────────────────┐
                │  PHASE 28: POLYMORPHIC TYPE SYSTEM          3 weeks  │
                │  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━  │
                │  Priority: ⭐⭐⭐ MEDIUM | LOC: 1,000 | Risk: HIGH    │
                │                                                      │
                │  • Polymorphic type checking (300 LOC)               │
                │  • Polymorphic procedures (400 LOC)                  │
                │  • Polymorphic operands (200 LOC)                    │
                │  • SOA polymorphism (100 LOC)                        │
                │                                                      │
                │  Enables: Generic programming ✅                     │
                └──────────────────────────┬───────────────────────────┘
                                           │
                                           ▼
                ┌──────────────────────────────────────────────────────┐
                │  PHASE 29: PROC GROUPS & RTTI               3 weeks  │
                │  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━  │
                │  Priority: ⭐⭐ LOW | LOC: 1,700 | Risk: VERY HIGH   │
                │                                                      │
                │  • Procedure groups (500 LOC)                        │
                │  • RTTI infrastructure (700 LOC)                     │
                │  • Core runtime init (300 LOC)                       │
                │  • Type assertion runtime (200 LOC)                  │
                │                                                      │
                │  Enables: Overloading + Reflection ✅                │
                └──────────────────────────┬───────────────────────────┘
                                           │
                                           ▼
                ┌──────────────────────────────────────────────────────┐
                │  PHASE 30: FINAL POLISH & TESTING           2 weeks  │
                │  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━  │
                │  Priority: ⭐⭐ LOW | LOC: 1,250 | Risk: LOW         │
                │                                                      │
                │  • Scope usage analysis (200 LOC)                    │
                │  • Error message polish (150 LOC)                    │
                │  • Performance optimization (100 LOC)                │
                │  • Comprehensive testing (300 LOC)                   │
                │  • Documentation (500 LOC)                           │
                │                                                      │
                │  Result: Production ready ✅                         │
                └──────────────────────────┬───────────────────────────┘
                                           │
                                           ▼
                                ┌────────────────────┐
                                │  100% COMPLETION   │
                                │  ══════════════    │
                                │  21 weeks total    │
                                │  5-6 months        │
                                └────────────────────┘
```

---

## Parallel Work Streams

```
WEEK:  1    2    3    4    5    6    7    8    9   10   11   12   13   14   15   16   17   18   19   20   21
       ─────────────────────────────────────────────────────────────────────────────────────────────────────
STREAM 1 (CRITICAL PATH):
       [22][    23    ][ 24][      25      ][  26  ][      28      ][      29      ][  30  ]
       └─┬─┘└─────┬────┘└─┬─┘└──────┬──────┘└──┬───┘└──────┬──────┘└──────┬──────┘└──┬───┘
         │        │       │         │          │           │              │          │
       STRUCT  HELPERS  STMTS    GLOBAL     PROC      POLYMORPHIC    PROC GROUPS   POLISH
       FOUND.           COMPLETE  ENTITIES   BODIES                  + RTTI

STREAM 2 (BUILTINS):
                              [         27         ]
                              └──────────┬──────────┘
                                         │
                                    SIMD + ObjC
                                    + REFLECTION

STREAM 3 (QUALITY):
                                                                                    [      30      ]
                                                                                    └───────┬──────┘
                                                                                            │
                                                                                         TESTING
                                                                                         + DOCS

KEY:
[##]  = Phase number and duration
═══   = Critical path (cannot parallelize)
───   = Can run in parallel with other streams
```

**Parallelization Benefits**:
- **Sequential Time**: 21 weeks
- **Parallel Time**: ~18 weeks (with 3 agents)
- **Time Saved**: 3 weeks (14% reduction)

---

## Dependency Matrix

| Phase | Depends On | Enables | Blocks If Delayed |
|-------|------------|---------|-------------------|
| **22** | Nothing | 23, 24 (indirectly) | Everything |
| **23** | 22 | 24, 25 (indirectly) | Statement completion, global processing |
| **24** | 23 | 25, 26, 27 | Global entities, proc bodies, builtins |
| **25** | 24 | 26, 28 | Procedure bodies, polymorphic types |
| **26** | 25 | 28, 29 | Polymorphic types, proc groups |
| **27** | 24 | - | Nothing (independent) |
| **28** | 25, 26 | 29 | Procedure groups, RTTI |
| **29** | 28 | 30 | Final polish |
| **30** | 26 (partial), 29 (full) | - | Production release |

**Critical Dependencies**:
- 22 → 23 → 24 (sequential, cannot parallelize)
- 24 → 25 → 26 (sequential, cannot parallelize)
- 26 → 28 → 29 (sequential, cannot parallelize)

**Independent Work**:
- 27 can run anytime after 24
- 30 can partially run after 26

---

## Milestone Dependencies

### Milestone 1: MVP (90% Complete)
**Required Phases**: 22, 23, 24, 25, 26
**Timeline**: 12 weeks sequential, ~10 weeks with parallelization
**Blockers**: None (can start immediately)

```
22 ──→ 23 ──→ 24 ──→ 25 ──→ 26
 └──────┴──────┴───────┴─────┴─→ MVP ACHIEVED
```

### Milestone 2: Production (95% Complete)
**Required Phases**: 22-27
**Timeline**: 13 weeks sequential, ~11 weeks with parallelization
**Blockers**: None (27 runs parallel to 25-26)

```
22 ──→ 23 ──→ 24 ──┬──→ 25 ──→ 26
                    └──→ 27
                    └────┴─────┴─→ PRODUCTION READY
```

### Milestone 3: Full Parity (100% Complete)
**Required Phases**: 22-30
**Timeline**: 21 weeks sequential, ~18 weeks with parallelization
**Blockers**: Polymorphic (28) and RTTI (29) are high-risk

```
22 ──→ 23 ──→ 24 ──┬──→ 25 ──→ 26 ──→ 28 ──→ 29 ──→ 30
                    └──→ 27
                    └────┴──────┴─────┴──────┴─────┴─→ 100% COMPLETE
```

---

## Risk Dependency Graph

```
                    LOW RISK                      MEDIUM RISK                    HIGH RISK
                    ────────                      ───────────                    ─────────

Phase 22 ─────┐                         Phase 23 ─────┐                  Phase 28 ─────┐
(Structural)  │                         (Helpers)     │                  (Polymorphic) │
              │                                       │                                │
              ├─→ Phase 24 ─────┐                     ├─→ Phase 25 ─────┐              ├─→ Phase 29
              │   (Statements)  │                     │   (Global)      │              │   (Proc Groups
              │                 │                     │                 │              │    + RTTI)
Phase 27 ─────┘                 ├─→ Phase 26 ─────────┘                 └──────────────┘
(Builtins)                      │   (Procedures)
                                │
Phase 30 ───────────────────────┘
(Polish)

RISK MITIGATION STRATEGY:
• Low-risk phases (22, 24, 27, 30): Allocate 1 porter each
• Medium-risk phases (23, 25, 26): Allocate 1 porter + 1 verifier
• High-risk phases (28, 29): Allocate 2 porters + 2 verifiers + architect oversight
```

---

## Blocker Cascade Analysis

```
IF Phase 22 is delayed by 1 week:
  ↓ Phase 23 delayed by 1 week
  ↓ Phase 24 delayed by 1 week
  ↓ Phase 25 delayed by 1 week
  ↓ Phase 26 delayed by 1 week
  ↓ Phase 27 delayed by 1 week (parallel, but waits for 24)
  ↓ Phase 28 delayed by 1 week
  ↓ Phase 29 delayed by 1 week
  ↓ Phase 30 delayed by 1 week
  ═══════════════════════════════
  TOTAL DELAY: 1 week (cascades to all phases)

IF Phase 23 is delayed by 1 week:
  ↓ Phase 24 delayed by 1 week
  ↓ Phases 25, 26, 27 delayed by 1 week
  ↓ Phases 28, 29, 30 delayed by 1 week
  ═══════════════════════════════
  TOTAL DELAY: 1 week (cascades to 7 phases)

IF Phase 27 is delayed by 1 week:
  ↓ No impact (independent)
  ═══════════════════════════════
  TOTAL DELAY: 0 weeks (no cascade)

IF Phase 28 is delayed by 1 week:
  ↓ Phase 29 delayed by 1 week
  ↓ Phase 30 delayed by 1 week
  ═══════════════════════════════
  TOTAL DELAY: 1 week (cascades to 2 phases)
```

**Critical Insight**: Phases 22 and 23 have **maximum cascade impact**. Any delay here affects all subsequent phases. Priority should be on completing these on time.

---

## Force Multiplier Visualization

```
                    EFFORT vs. VALUE ANALYSIS

      HIGH VALUE
           ▲
           │
           │           ● Phase 22
           │          (125 LOC unlocks 1,572 LOC)
           │           ROI: 12.6x
           │
           │                    ● Phase 23
           │                   (600 LOC unlocks 1,572 LOC)
           │                    ROI: 2.6x
           │
           │     ● Phase 24
           │    (450 LOC + 1,572 activated)
           │     ROI: 4.5x
           │
           │                         ● Phase 25
           │                        (1,500 LOC global processing)
           │                         ROI: 1.2x
           │
           │                              ● Phase 28
           │                             (1,000 LOC polymorphic)
           │                              ROI: 0.8x
           │
           │              ● Phase 27           ● Phase 29
           │             (900 LOC builtins)   (1,700 LOC RTTI)
           │              ROI: 1.0x            ROI: 0.6x
           │
           │                    ● Phase 26         ● Phase 30
           │                   (1,100 LOC)        (1,250 LOC)
           │                    ROI: 0.9x          ROI: 0.5x
      LOW VALUE
           └────────────────────────────────────────────────────▶
                LOW EFFORT                              HIGH EFFORT

KEY INSIGHT: Phases 22-24 are in the "High Value, Low-Medium Effort" quadrant.
These are the **quick wins** that should be prioritized.
```

---

## Completion Velocity Chart

```
COMPLETION PERCENTAGE OVER TIME

100% ┤                                                           ●────● 100%
     │                                                      ●────┘
 95% ┤                                              ●──────┘
     │                                        ●─────┘
 90% ┤                                ●──────┘ (MVP REACHED)
     │                        ●───────┘
 85% ┤                  ●─────┘
     │            ●─────┘
 80% ┤      ●─────┘
     │ ●────┘
 75% ┤●┘ (CURRENT STATE - Phase 20-21 Complete)
     │
     └─┬──┬──┬──┬──┬──┬──┬──┬──┬──┬──┬──┬──┬──┬──┬──┬──┬──┬──┬──┬──┬──
      0  1  2  3  4  5  6  7  8  9 10 11 12 13 14 15 16 17 18 19 20 21
                              WEEKS FROM START

PHASE MARKERS:
Week 2:  Phase 22 complete (77%)
Week 5:  Phase 23 complete (82%)
Week 6:  Phase 24 complete (90% - MVP)
Week 9:  Phase 25 complete (93%)
Week 11: Phase 26 complete (95%)
Week 13: Phase 27 complete (96%)
Week 16: Phase 28 complete (98%)
Week 19: Phase 29 complete (99%)
Week 21: Phase 30 complete (100%)

VELOCITY INSIGHTS:
• Fastest growth: Weeks 4-6 (Phase 23-24 activation)
• Steady growth: Weeks 6-11 (global + procedure processing)
• Slowest growth: Weeks 16-21 (complex polymorphic + RTTI)
```

---

## Summary: The Critical Path

**Shortest Path to 100%**:
```
1. Phase 22 (2 weeks)  ← CRITICAL BLOCKER
2. Phase 23 (3 weeks)  ← CRITICAL BLOCKER
3. Phase 24 (1 week)   ← ACTIVATION POINT
4. Phase 25 (3 weeks)  ← CORE FUNCTIONALITY
5. Phase 26 (2 weeks)  ← CORE FUNCTIONALITY
6. Phase 27 (2 weeks)  ← CAN PARALLELIZE
7. Phase 28 (3 weeks)  ← ADVANCED FEATURES
8. Phase 29 (3 weeks)  ← ADVANCED FEATURES
9. Phase 30 (2 weeks)  ← POLISH

Total: 21 weeks sequential, ~18 weeks with parallelization
```

**Key Dependencies**:
- 22 → 23 → 24: **Must be sequential** (6 weeks)
- 24 → 25 → 26: **Must be sequential** (6 weeks)
- 26 → 28 → 29: **Must be sequential** (6 weeks)
- 27 and partial 30: **Can run in parallel** (saves 3 weeks)

**Risk Concentration**:
- **Low Risk**: 22, 24, 27, 30 (8 weeks)
- **Medium Risk**: 23, 25, 26 (8 weeks)
- **High Risk**: 28, 29 (6 weeks)

**Strategic Recommendation**:
1. **Focus all resources on Phase 22-23** (5 weeks) - Remove blockers
2. **Quick activation in Phase 24** (1 week) - Achieve MVP
3. **Parallel streams for 25-27** (3 weeks) - Maximize velocity
4. **Careful execution of 28-29** (6 weeks) - High-risk phases
5. **Polish in Phase 30** (2 weeks) - Production ready

**Expected Timeline**: 5-6 months to 100% completion with realistic risk buffer.

---

**See Also**:
- `/mnt/d/dev/checker/COMPLETION_ROADMAP.md` - Detailed phase specifications
- `/mnt/d/dev/checker/IMPLEMENTATION_SUMMARY.md` - Executive summary
- `/mnt/d/dev/checker/dependency_graph.txt` - Original dependency analysis
