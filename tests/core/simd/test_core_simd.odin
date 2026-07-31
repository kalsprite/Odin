package test_core_simd

import "base:intrinsics"
import "core:simd"
import "core:testing"

// True when the build will hit the lane-local x86 pshufb hardware path for
// 32-byte 8-bit swizzles. Otherwise the emulation path runs and is cross-lane.
@private
X86_HW_32 :: (ODIN_ARCH == .amd64 || ODIN_ARCH == .i386) &&
             intrinsics.has_target_feature("ssse3") &&
             intrinsics.has_target_feature("avx2")

// Same for 64-byte swizzles via AVX-512 pshufb.b.512.
@private
X86_HW_64 :: (ODIN_ARCH == .amd64 || ODIN_ARCH == .i386) &&
             intrinsics.has_target_feature("ssse3") &&
             intrinsics.has_target_feature("avx2") &&
             intrinsics.has_target_feature("avx512f") &&
             intrinsics.has_target_feature("avx512bw")

// ---------------------------------------------------------------------------
// Generic comparison helper. Converts the SIMD result to a fixed array so the
// usual testing.expect_value can render a nice diff on failure.
// ---------------------------------------------------------------------------

@private
expect_swizzle :: proc(t: ^testing.T, got: #simd[$LANES]$E, want: [LANES]E, loc := #caller_location) {
	arr := simd.to_array(got)
	testing.expect_value(t, arr, want, loc = loc)
}

// ---------------------------------------------------------------------------
// 1. Portable in-range tests (must pass on every backend: x86 pshufb, ARM tbl,
//    WASM swizzle, and the scalar emulation fallback).
//
//    Inputs are crafted so that lane-local (x86 32B/64B) and cross-lane (ARM,
//    emulation) implementations produce the same answer. Concretely: every
//    index addresses an element inside the same 16-byte lane as the output
//    position. Cases that intentionally diverge live in section 3.
// ---------------------------------------------------------------------------

@test
test_runtime_swizzle_u8x16_identity :: proc(t: ^testing.T) {
	table   := simd.from_array([16]u8{10,20,30,40,50,60,70,80,90,100,110,120,130,140,150,160})
	indices := simd.from_array([16]u8{0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15})
	got := simd.runtime_swizzle(table, indices)
	expect_swizzle(t, got, [16]u8{10,20,30,40,50,60,70,80,90,100,110,120,130,140,150,160})
}

@test
test_runtime_swizzle_u8x16_reverse :: proc(t: ^testing.T) {
	table   := simd.from_array([16]u8{10,20,30,40,50,60,70,80,90,100,110,120,130,140,150,160})
	indices := simd.from_array([16]u8{15,14,13,12,11,10,9,8,7,6,5,4,3,2,1,0})
	got := simd.runtime_swizzle(table, indices)
	expect_swizzle(t, got, [16]u8{160,150,140,130,120,110,100,90,80,70,60,50,40,30,20,10})
}

@test
test_runtime_swizzle_u8x16_broadcast_first :: proc(t: ^testing.T) {
	table   := simd.from_array([16]u8{99,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15})
	indices: simd.u8x16  // all zeros
	got := simd.runtime_swizzle(table, indices)
	expect_swizzle(t, got, [16]u8{99,99,99,99,99,99,99,99,99,99,99,99,99,99,99,99})
}

@test
test_runtime_swizzle_u8x16_broadcast_last :: proc(t: ^testing.T) {
	table   := simd.from_array([16]u8{0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,77})
	indices := simd.from_array([16]u8{15,15,15,15,15,15,15,15,15,15,15,15,15,15,15,15})
	got := simd.runtime_swizzle(table, indices)
	expect_swizzle(t, got, [16]u8{77,77,77,77,77,77,77,77,77,77,77,77,77,77,77,77})
}

@test
test_runtime_swizzle_u8x16_arbitrary :: proc(t: ^testing.T) {
	table   := simd.from_array([16]u8{0xA0,0xA1,0xA2,0xA3,0xA4,0xA5,0xA6,0xA7,0xA8,0xA9,0xAA,0xAB,0xAC,0xAD,0xAE,0xAF})
	indices := simd.from_array([16]u8{7,3,11,0,15,8,2,14,5,1,9,13,4,12,6,10})
	got := simd.runtime_swizzle(table, indices)
	expect_swizzle(t, got, [16]u8{0xA7,0xA3,0xAB,0xA0,0xAF,0xA8,0xA2,0xAE,0xA5,0xA1,0xA9,0xAD,0xA4,0xAC,0xA6,0xAA})
}

@test
test_runtime_swizzle_i8x16_in_range :: proc(t: ^testing.T) {
	table   := simd.from_array([16]i8{-100,-80,-60,-40,-20,0,20,40,60,80,100,120,-128,127,-1,1})
	indices := simd.from_array([16]i8{15,14,13,12,11,10,9,8,7,6,5,4,3,2,1,0})
	got := simd.runtime_swizzle(table, indices)
	expect_swizzle(t, got, [16]i8{1,-1,127,-128,120,100,80,60,40,20,0,-20,-40,-60,-80,-100})
}

@test
test_runtime_swizzle_u8x32_identity :: proc(t: ^testing.T) {
	// Identity is portable: position i with index i reads table[i] under both
	// cross-lane (table[i]) and lane-local (lane_base + (i & 15) = i) semantics.
	tbl: [32]u8
	for i in 0..<32 { tbl[i] = u8(i*2 + 1) }
	idx: [32]u8
	for i in 0..<32 { idx[i] = u8(i) }
	got := simd.runtime_swizzle(simd.from_array(tbl), simd.from_array(idx))
	expect_swizzle(t, got, tbl)
}

@test
test_runtime_swizzle_u8x32_within_lane_reverse :: proc(t: ^testing.T) {
	// Reverse INSIDE each 16-byte lane (low half reversed independently of
	// high half). Portable across lane-local and cross-lane backends.
	tbl: [32]u8
	for i in 0..<32 { tbl[i] = u8(i*2 + 1) }
	idx: [32]u8
	for i in 0..<16 { idx[i]    = u8(15 - i) }
	for i in 0..<16 { idx[16+i] = u8(31 - i) }
	want: [32]u8
	for i in 0..<16 { want[i]    = tbl[15 - i] }
	for i in 0..<16 { want[16+i] = tbl[31 - i] }
	got := simd.runtime_swizzle(simd.from_array(tbl), simd.from_array(idx))
	expect_swizzle(t, got, want)
}

@test
test_runtime_swizzle_u8x32_per_lane_broadcast :: proc(t: ^testing.T) {
	// Broadcast the first element of each 16-byte lane within that lane.
	tbl: [32]u8
	for i in 0..<32 { tbl[i] = u8(i + 1) }
	idx: [32]u8  // low half all 0, high half all 16
	for i in 0..<16 { idx[16+i] = 16 }
	want: [32]u8
	for i in 0..<16 { want[i]    = tbl[0]  }
	for i in 0..<16 { want[16+i] = tbl[16] }
	got := simd.runtime_swizzle(simd.from_array(tbl), simd.from_array(idx))
	expect_swizzle(t, got, want)
}

@test
test_runtime_swizzle_u8x64_identity :: proc(t: ^testing.T) {
	tbl: [64]u8
	for i in 0..<64 { tbl[i] = u8(i*3 + 7) }
	idx: [64]u8
	for i in 0..<64 { idx[i] = u8(i) }
	got := simd.runtime_swizzle(simd.from_array(tbl), simd.from_array(idx))
	expect_swizzle(t, got, tbl)
}

@test
test_runtime_swizzle_u8x64_within_lane_reverse :: proc(t: ^testing.T) {
	tbl: [64]u8
	for i in 0..<64 { tbl[i] = u8(i*3 + 7) }
	idx: [64]u8
	for lane in 0..<4 {
		base := lane * 16
		for i in 0..<16 { idx[base + i] = u8(base + (15 - i)) }
	}
	want: [64]u8
	for lane in 0..<4 {
		base := lane * 16
		for i in 0..<16 { want[base + i] = tbl[base + (15 - i)] }
	}
	got := simd.runtime_swizzle(simd.from_array(tbl), simd.from_array(idx))
	expect_swizzle(t, got, want)
}

// ---------------------------------------------------------------------------
// 2. Emulation-path coverage. Non-byte element types never hit the hardware
//    tbl/pshufb paths, so these tests exercise the emulation fallback on
//    every platform — including the `& (N-1)` modular wrap for out-of-range
//    indices that the docstring documents.
// ---------------------------------------------------------------------------

@test
test_runtime_swizzle_emul_u16x8_in_range :: proc(t: ^testing.T) {
	table   := simd.from_array([8]u16{0x1000,0x1100,0x1200,0x1300,0x1400,0x1500,0x1600,0x1700})
	indices := simd.from_array([8]u16{7,6,5,4,3,2,1,0})
	got := simd.runtime_swizzle(table, indices)
	expect_swizzle(t, got, [8]u16{0x1700,0x1600,0x1500,0x1400,0x1300,0x1200,0x1100,0x1000})
}

@test
test_runtime_swizzle_emul_u32x4_in_range :: proc(t: ^testing.T) {
	table   := simd.from_array([4]u32{0xDEAD0001,0xDEAD0002,0xDEAD0003,0xDEAD0004})
	indices := simd.from_array([4]u32{3,2,1,0})
	got := simd.runtime_swizzle(table, indices)
	expect_swizzle(t, got, [4]u32{0xDEAD0004,0xDEAD0003,0xDEAD0002,0xDEAD0001})
}

@test
test_runtime_swizzle_emul_u64x2_in_range :: proc(t: ^testing.T) {
	table   := simd.from_array([2]u64{0xCAFEBABE_00000001,0xCAFEBABE_00000002})
	indices := simd.from_array([2]u64{1,0})
	got := simd.runtime_swizzle(table, indices)
	expect_swizzle(t, got, [2]u64{0xCAFEBABE_00000002,0xCAFEBABE_00000001})
}

@test
test_runtime_swizzle_emul_i16x8_in_range :: proc(t: ^testing.T) {
	table   := simd.from_array([8]i16{-1000,-500,-1,0,1,500,1000,32000})
	indices := simd.from_array([8]i16{4,5,6,7,3,2,1,0})
	got := simd.runtime_swizzle(table, indices)
	expect_swizzle(t, got, [8]i16{1,500,1000,32000,0,-1,-500,-1000})
}

@test
test_runtime_swizzle_emul_i32x4_in_range :: proc(t: ^testing.T) {
	table   := simd.from_array([4]i32{-1,0,1,2})
	indices := simd.from_array([4]i32{2,0,3,1})
	got := simd.runtime_swizzle(table, indices)
	expect_swizzle(t, got, [4]i32{1,-1,2,0})
}

@test
test_runtime_swizzle_emul_wrap_u16 :: proc(t: ^testing.T) {
	// Out-of-range indices on the emulation path wrap modulo N (& (N-1)).
	// N=8 here, so 8→0, 9→1, 15→7, 0xFFFF→7.
	table   := simd.from_array([8]u16{100,101,102,103,104,105,106,107})
	indices := simd.from_array([8]u16{0,8,9,15,16,0xFFFE,0xFFFF,7})
	got := simd.runtime_swizzle(table, indices)
	expect_swizzle(t, got, [8]u16{100,100,101,107,100,106,107,107})
}

@test
test_runtime_swizzle_emul_wrap_u32 :: proc(t: ^testing.T) {
	table   := simd.from_array([4]u32{10,20,30,40})
	indices := simd.from_array([4]u32{4,5,6,7})       // each wraps to its low 2 bits
	got := simd.runtime_swizzle(table, indices)
	expect_swizzle(t, got, [4]u32{10,20,30,40})
}

@test
test_runtime_swizzle_emul_wrap_i32_negative :: proc(t: ^testing.T) {
	// Negative i32 indices: emulation does the AND in element type, so the
	// two's-complement bits are preserved. -1 & 3 = 3, -4 & 3 = 0.
	table   := simd.from_array([4]i32{10,20,30,40})
	indices := simd.from_array([4]i32{-1,-2,-3,-4})
	got := simd.runtime_swizzle(table, indices)
	expect_swizzle(t, got, [4]i32{40,30,20,10})
}

@test
test_runtime_swizzle_emul_broadcast_u32 :: proc(t: ^testing.T) {
	table   := simd.from_array([4]u32{0xAA,0xBB,0xCC,0xDD})
	indices: simd.u32x4  // all zero
	got := simd.runtime_swizzle(table, indices)
	expect_swizzle(t, got, [4]u32{0xAA,0xAA,0xAA,0xAA})
}

// ---------------------------------------------------------------------------
// 3. Lane-locality assertions. The docstring promises:
//      - x86 wide vectors are lane-local within each 128-bit half
//      - ARM tbl and the emulation fallback are cross-lane
//
//    Each test below picks the expected output at compile time based on
//    which backend will actually be selected (via has_target_feature for
//    x86 hardware availability). So the same test exercises both the
//    lane-local and cross-lane contracts depending on where it runs.
// ---------------------------------------------------------------------------

@test
test_runtime_swizzle_index_zero_broadcast_32 :: proc(t: ^testing.T) {
	// indices all 0:
	//   - lane-local (x86 vpshufb): each 16-byte output lane reads the first
	//     byte of its own table slice → low half = table[0], high half = table[16]
	//   - cross-lane (ARM tbl, emulation): every position reads table[0]
	tbl: [32]u8
	for i in 0..<32 { tbl[i] = u8(i + 1) }
	idx: simd.u8x32
	got := simd.runtime_swizzle(simd.from_array(tbl), idx)
	want: [32]u8
	when X86_HW_32 {
		for i in 0..<16 { want[i]    = tbl[0]  }
		for i in 0..<16 { want[16+i] = tbl[16] }
	} else {
		for i in 0..<32 { want[i] = tbl[0] }
	}
	expect_swizzle(t, got, want)
}

@test
test_runtime_swizzle_index_zero_broadcast_64 :: proc(t: ^testing.T) {
	tbl: [64]u8
	for i in 0..<64 { tbl[i] = u8(i + 1) }
	idx: simd.u8x64
	got := simd.runtime_swizzle(simd.from_array(tbl), idx)
	want: [64]u8
	when X86_HW_64 {
		for lane in 0..<4 {
			base := lane * 16
			for i in 0..<16 { want[base + i] = tbl[base] }
		}
	} else {
		for i in 0..<64 { want[i] = tbl[0] }
	}
	expect_swizzle(t, got, want)
}

@test
test_runtime_swizzle_lane_swap_32 :: proc(t: ^testing.T) {
	// Low half asks for high-half entries, high half asks for low-half entries.
	//   - cross-lane: the table halves are actually swapped
	//   - lane-local (x86 hw): low 4 bits of each index drive the lane-local
	//     selection, so the apparent swap collapses — low half reads table[0..15],
	//     high half reads table[16..31] (an identity)
	tbl: [32]u8
	for i in 0..<32 { tbl[i] = u8(i + 1) }
	idx: [32]u8
	for i in 0..<16 { idx[i]    = u8(16 + i) }
	for i in 0..<16 { idx[16+i] = u8(i) }
	got := simd.runtime_swizzle(simd.from_array(tbl), simd.from_array(idx))
	want: [32]u8
	when X86_HW_32 {
		// vpshufb: index 16 in low lane masks to 0 → table[0]; index 0 in
		// high lane → table[16]. Effective identity.
		for i in 0..<32 { want[i] = tbl[i] }
	} else {
		for i in 0..<16 { want[i]    = tbl[16 + i] }
		for i in 0..<16 { want[16+i] = tbl[i]      }
	}
	expect_swizzle(t, got, want)
}

@test
test_runtime_swizzle_full_reverse_32 :: proc(t: ^testing.T) {
	// indices[i] = 31 - i, the "full reverse" pattern.
	//   - cross-lane: result is the table reversed
	//   - lane-local (x86 hw): each lane reverses within itself only
	tbl: [32]u8
	for i in 0..<32 { tbl[i] = u8(i + 1) }
	idx: [32]u8
	for i in 0..<32 { idx[i] = u8(31 - i) }
	got := simd.runtime_swizzle(simd.from_array(tbl), simd.from_array(idx))
	want: [32]u8
	when X86_HW_32 {
		for i in 0..<16 { want[i]    = tbl[15 - i] }     // low lane: low 4 bits of (31-i) = 15-i
		for i in 0..<16 { want[16+i] = tbl[16 + (15 - i)] } // high lane: low 4 bits of (31 - (16+i)) = 15-i
	} else {
		for i in 0..<32 { want[i] = tbl[31 - i] }
	}
	expect_swizzle(t, got, want)
}
