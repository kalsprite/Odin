package p
import "base:intrinsics"
bad :: proc "contextless" (p: ^f32, w: f32) {
	intrinsics.wasm_memory_atomic_wait32(p, 0, -1)
	intrinsics.wasm_memory_atomic_notify32(p, w)
}
