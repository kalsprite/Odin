# llvm_backend_expr.cpp: out-of-range float→int conversion emits LLVM poison, contradicting the stated no-poison policy

**File:** `src/llvm_backend_expr.cpp:2557-2578` (`lb_emit_conv`, the float→integer arm)
**Severity:** at `-o:speed`, a converted value that flows into an `any` reads uninitialized
stack — the result varies **between executions of the same binary** and between two uses of
the same expression. Stable at `-o:none`.
**Issue number:** not yet filed.
**Measured on:** `dev-2026-08:4af8f15e3`, LLVM 22.1.8, x86-64 Linux.

## The policy this contradicts

`src/llvm_backend_opt.cpp:19-31`, which is explicit:

> Odin does not allow poison-value based optimizations.
>
> […] This means any outputted IR containing the following flags may cause incorrect
> behaviour:
>
> ```text
> nsw (no signed wrap)
> nuw (no unsigned wrap)
> poison (poison value)
> ```

## The code

The float→integer conversion emits `fptosi` / `fptoui` with no range guard:

```cpp
if (is_type_unsigned(dst)) {
    switch (sz) {
    case 2:
    case 4:
        res.value = LLVMBuildFPToUI(p->builder, value.value, lb_type(m, t_u32), "");
        res.value = LLVMBuildIntCast2(p->builder, res.value, lb_type(m, t), false, "");
        break;
    case 8:
        res.value = LLVMBuildFPToUI(p->builder, value.value, lb_type(m, t_u64), "");
        ...
} else {
    case 2:
    case 4:
        res.value = LLVMBuildFPToSI(p->builder, value.value, lb_type(m, t_i32), "");
        ...
```

Per the LLVM Language Reference, `fptosi` and `fptoui` return **poison** when the source
value cannot be represented in the destination type. Odin reaches these instructions for
any out-of-range conversion, so the compiler emits exactly the value class its own
optimization policy forbids.

## Reproduction

```odin
package main
import "core:fmt"
main :: proc() {
	a: f64 = 1e30            // far outside i32
	fmt.printf("%d 0x%08x\n", i32(a), u32(i32(a)))
}
```

```console
$ odin build min1.odin -file -o:speed && for i in 1 2 3 4; do ./min1; done
32767 0x3c5deae8
32765 0x5e4ff288
32767 0x4556a288
32767 0xd13397a8
```

Two independent defects are visible in each line:

1. **The two arguments disagree.** `%d` and `0x%08x` render the *same expression*
   `i32(a)`, yet `32767` is not `0x3c5deae8`. A single value cannot print as both.
2. **The value is not stable across executions of one binary.** Four runs of the same
   unmodified executable produce four different results.

At `-o:none` and `-o:minimal` the same program is deterministic and prints `0`.

## Controls

Run to bound the claim rather than assume it:

| control | result |
| --- | --- |
| `-o:none`, `-o:minimal` | deterministic `0`; does not reproduce |
| same value made opaque at runtime (`1e30 * f64(len(os.args))`) | deterministic `0` at all three levels |
| value used without `any` — `os.exit(int(i32(a)) & 0xff)` | deterministic `0` at `-o:speed`, 5/5 runs |
| `f64 → i64` (opaque) | deterministic `-9223372036854775808`, i.e. x86 `cvttsd2si` indefinite |
| `@(fast_math)` involvement | **ruled out.** `lb_run_fast_float_math_pass` early-returns unless a procedure carries explicit fast-math flags; the reproducer has none |

So the manifestation requires **`-o:speed` *and* the converted value reaching an `any`**.
Used directly, the poison collapses to a stable `0` in every case tested.

## Mechanism — inferred, not proven

`fptosi` yields poison. Storing poison is a no-op LLVM may elide, so the stack slot backing
the `any`'s `data` pointer is never written, and `fmt` reads whatever the stack held. That
explains all three observations: run-to-run variance (stack contents vary), disagreement
between two uses (each read is independent), and stability when no `any` is involved (the
value is consumed in a register).

This mechanism is **inferred from the observed behaviour and the LLVM semantics**, not
confirmed by reading the generated IR. The behaviour itself is reproduced.

## Why it matters beyond this case

The observable damage is an uninitialized read reaching a formatting routine — but the
same poison flows anywhere an out-of-range conversion's result goes. Any future enabling of
a poison-exploiting pass would widen this from a bad value to a miscompilation of the
surrounding code. `llvm_backend_opt.cpp` already disables GVN, InstCombine, IndVarSimplify,
LoopUnroll, EarlyCSE-MemSSA, DSE, and CorrelatedValuePropagation for exactly this reason;
this site produces the value those exclusions exist to avoid.

## Suggested fix

Odin has no undefined behaviour elsewhere in its integer semantics — overflow wraps, over-wide
shifts are defined, and integer division by zero is a *selectable* policy
(`IntegerDivisionByZero_{Trap,Zero,Self,AllBits}`, `src/main.cpp:1722-1728`). Out-of-range
float→int is the outlier.

Options, in rough order of preference:

1. **Saturate.** Clamp to the destination's range, NaN to `0`. This is what WebAssembly
   (`i32.trunc_sat_f64_s`) and Rust (`as` casts, since 1.45) settled on, and on x86-64 it is a
   short compare-and-select sequence around `cvttsd2si`.
2. **Make it a policy**, mirroring the division-by-zero precedent — saturate / trap / zero —
   which fits the existing design vocabulary.
3. At minimum, **define it as the hardware result** and document it, which is roughly what
   `-o:none` already produces.

Any of the three removes poison from the output. Option 1 is also the cheapest to specify.

## Related sites — swept

Found by asking which LLVM operations are defined as poison-producing, then checking
whether `src/` emits them unguarded. `fptosi`/`fptoui` is the only confirmed defect.

| construct | LLVM semantics | status in `src/` |
| --- | --- | --- |
| `add`/`sub`/`mul`/`shl` with `nsw`/`nuw` | poison on overflow | **clean** — no occurrence of `NSW`, `NUW`, `NoSignedWrap`, or `NoUnsignedWrap` anywhere in `src/*.cpp` |
| `udiv`/`sdiv` with `exact` | poison if remainder ≠ 0 | **clean** — no `BuildExactSDiv`/`BuildExactUDiv`/`SetExact` |
| `shl`/`lshr`/`ashr`, amount ≥ bit width | poison | **correctly guarded** — see below |
| `fptosi`/`fptoui`, out of range | poison | **DEFECT** — this report |
| `sdiv` `INT_MIN / -1` | **undefined behaviour** | latent — see below |
| `getelementptr inbounds` | poison if out of bounds | **clean** — see below |
| `extractelement`/`insertelement`, index out of range | poison | **latent + missing bounds check** — see below |

### Shifts are handled correctly (`llvm_backend_expr.cpp:1964-1999`)

Recorded because it is the pattern the defective site should follow.

`Token_Shl` and unsigned `Token_Shr` compute the raw shift and select it away:

```cpp
LLVMValueRef width_test = LLVMBuildICmp(p->builder, LLVMIntULT, bits, bit_size, "");
res.value = LLVMBuildShl(p->builder, lhsval, bits, "");        // poison if bits >= width
res.value = LLVMBuildSelect(p->builder, width_test, res.value, zero, "");
```

This is sound: `select` does not propagate poison from the *unselected* operand, so the
out-of-range result is neutralized. Signed `Token_Shr` is better still — it clamps the
operand so no poison is ever created:

```cpp
bits = LLVMBuildSelect(p->builder, width_test, bits, bit_size_minus_one, "");
res.value = LLVMBuildAShr(p->builder, lhsval, bits, "");
```

The asymmetry is worth noting only because the clamping form generates no poison at all,
which is what the policy in `llvm_backend_opt.cpp` asks for. Both are correct today.

### `getelementptr` — clean

Dynamic user indexing does **not** use `inbounds`. `lb_emit_array_ep`
(`llvm_backend_utility.cpp:1637-1657`) emits plain `LLVMBuildGEP2` / `LLVMConstGEP2`, so
an out-of-range index yields a well-defined out-of-range pointer rather than poison.

All four `LLVMBuildInBoundsGEP2` sites are compiler-constructed accesses with indices the
compiler already knows are in range — constant array data (`llvm_backend_const.cpp:1050`),
matrix row/column destinations (`llvm_backend_expr.cpp:1010,1096`), and global data
(`llvm_backend_proc.cpp:4617`). Ratio across `src/`: 10 plain GEPs to 4 `inbounds`.

That is the correct pattern — `inbounds` asserted only where it has been *earned*.

### `intrinsics.simd_extract` accepts an unchecked runtime index

**This one may warrant its own issue.** It is a missing bounds check rather than a
miscompilation, and it is inconsistent with how Odin treats every other index.

A **constant** out-of-range index is correctly rejected:

```odin
v: #simd[4]i32 = {10, 20, 30, 40}
intrinsics.simd_extract(v, 8)
```

```text
Error: Index '8' is out of bounds range 0..<4, got 8
```

A **runtime** index is accepted with no compile-time error and no runtime check:

```odin
package main
import "core:fmt"
import "core:os"
import "base:intrinsics"
main :: proc() {
	v: #simd[4]i32 = {10, 20, 30, 40}
	i := len(os.args) + 7          // == 8, out of range for a 4-lane vector
	fmt.println(intrinsics.simd_extract(v, i))
}
```

Compiles clean; prints `10` (lane 0). `check_builtin.cpp:1295` calls `check_index_value`,
which validates only the constant case; a non-constant index falls through unvalidated to
`llvm_backend_proc.cpp:1772`, which emits `extractelement` with that index. LLVM defines
out-of-range `extractelement` as **poison**.

**No misbehaviour observed.** Stable `10` at both `-o:none` and `-o:speed`, 6 runs each.
The claim is the missing check and the poison-producing IR, not a wrong result.

The inconsistency is the substance: Odin bounds-checks array and slice indexing by default
and rejects the constant form here, but the runtime form is unchecked in both phases. The
matching `simd_insert` path (`llvm_backend_proc.cpp`, `LLVMBuildInsertElement` with
`arg1.value`) has the same shape and was not separately tested.

### `sdiv INT_MIN / -1` — latent, not a reproduced defect

LLVM's language reference makes signed-division *overflow* undefined behaviour, distinct
from the division-by-zero case that `IntegerDivisionByZero_*` policies cover.

Measured: `i32(-2147483648) / i32(-1)` with both operands opaque at runtime raises SIGFPE
(exit 136) deterministically at `-o:none` and `-o:speed`. That is x86 `idiv` raising `#DE`
on quotient overflow, and it is reasonable behaviour.

**No misbehaviour is claimed.** The exposure is that nothing guarantees it: the trap is a
property of the hardware, not of the emitted IR, and an optimizer entitled to assume the
UB never happens would be within its rights to do something else. It is the same class as
the `fptosi` defect with no observed damage, and it is not covered by any existing policy
setting. Recorded so it is a decision rather than an accident.

## Note on scope

This was found while specifying a native backend against Odin's semantics, not by fuzzing.
The sweep above covers scalar arithmetic and conversion; aggregate, vector, and pointer
paths were not audited.
