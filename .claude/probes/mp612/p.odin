package p
import "base:intrinsics"
// wasm32 default microarch is `generic`, whose real feature list has bulk-memory and NOT sse2.
// Before #612 the port returned the x86-64 `generic` list here, inverting BOTH answers.
#assert(intrinsics.has_target_feature("bulk-memory"))
#assert(intrinsics.has_target_feature("sse2"))
