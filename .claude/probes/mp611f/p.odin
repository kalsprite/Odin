package p
import "base:intrinsics"
// One bad operand per call: C++ returns after the first failure, so each call fires exactly one message.
a :: proc "contextless" (p: ^u32, e: f32) -> u32 { return intrinsics.wasm_memory_atomic_wait32(p, e, -1) }
b :: proc "contextless" (p: ^u32, t: f32) -> u32 { return intrinsics.wasm_memory_atomic_wait32(p, 0, t) }
c :: proc "contextless" (p: ^u32, w: f32) -> u32 { return intrinsics.wasm_memory_atomic_notify32(p, w) }
d :: proc "contextless" (q: ^f32, w: u32) -> u32 { return intrinsics.wasm_memory_atomic_notify32(q, w) }
