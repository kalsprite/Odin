package p
import "base:intrinsics"
foo :: proc "contextless" (p: ^u32) {
	intrinsics.wasm_memory_atomic_wait32(p, 0, -1)
}
