package p
import "base:intrinsics"
bad :: proc "contextless" () {
	intrinsics.wasm_memory_atomic_wait32(1, 0, -1)
}
