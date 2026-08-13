package p
import "base:intrinsics"
foo :: proc "contextless" (p: ^f32) -> u32 {
	return intrinsics.wasm_memory_atomic_wait32(p, 0, -1)
}
