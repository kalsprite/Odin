package checker

/*
Performance profiling and timing infrastructure for the checker.

This module provides high-resolution timing and performance profiling for compiler phases.
It supports platform-specific timing mechanisms and provides detailed timing reports.

C++ Reference: /mnt/c/odin/src/timings.cpp
*/

import "core:fmt"
import "core:mem"
import "core:time"

// ======================================================================================
// CORE TIMING STRUCTURES
// C++ Reference: timings.cpp:1-12
// ======================================================================================

// C++: timings.cpp:1
Time_Stamp :: struct {
	start:  time.Tick, // High-resolution start time (C++ u64 start)
	finish: time.Tick, // High-resolution finish time (C++ u64 finish)
	label:  string, // Section label (C++ String label)
}

// C++: timings.cpp:7
Timings :: struct {
	total:              Time_Stamp, // Total timing from start to finish (C++ line 8)
	sections:           [dynamic]Time_Stamp, // Individual timing sections (C++ Array<TimeStamp> sections, line 9)
	freq:               u64, // Timer frequency (C++ line 10)
	total_time_seconds: f64, // Total time in seconds (C++ line 11)
}

// ======================================================================================
// PLATFORM-SPECIFIC TIMING IMPLEMENTATIONS
// C++ Reference: timings.cpp:15-106
// ======================================================================================

// NOTE: Odin's core:time package provides cross-platform high-resolution timing
// that abstracts away the platform-specific details. The C++ implementation uses:
// - Windows: QueryPerformanceCounter/QueryPerformanceFrequency
// - macOS: mach_absolute_time/mach_timebase_info
// - Unix/Linux: clock_gettime(CLOCK_MONOTONIC)
//
// Odin's time.tick_now() provides equivalent functionality across all platforms.

// C++: timings.cpp:84
// Platform-agnostic wrapper for high-resolution time stamp
time_stamp_time_now :: proc() -> time.Tick {
	// C++ uses different implementations based on platform:
	// - Windows: win32_time_stamp_time_now (line 16-20)
	// - macOS: osx_time_stamp_time_now (line 46-48)
	// - Unix: unix_time_stamp_time_now (line 59-64)
	// Odin abstracts this via core:time
	return time.tick_now()
}

// C++: timings.cpp:96
// Returns the timer frequency for converting ticks to time units
time_stamp__freq :: proc() -> u64 {
	// C++ uses different implementations based on platform:
	// - Windows: win32_time_stamp__freq (line 22-30)
	// - macOS: osx_time_stamp__freq (line 50-53)
	// - Unix: unix_time_stamp__freq (line 66-76)
	// Odin's time.Tick is already in nanoseconds, so freq is 1e9
	return 1_000_000_000 // nanoseconds per second
}

// ======================================================================================
// TIME STAMP CREATION AND MANAGEMENT
// C++ Reference: timings.cpp:108-134
// ======================================================================================

// C++: timings.cpp:108
// Creates a new time stamp with the given label and starts timing
make_time_stamp :: proc(label: string) -> Time_Stamp {
	// C++ line 109-112
	ts := Time_Stamp{}
	ts.start = time_stamp_time_now()
	ts.label = label
	return ts
}

// C++: timings.cpp:115
// Initializes a Timings structure with the given label and buffer size
timings_init :: proc(t: ^Timings, label: string, buffer_size: int, allocator := context.allocator) {
	// C++ line 116-118
	t.sections = make([dynamic]Time_Stamp, 0, buffer_size, allocator)
	t.total = make_time_stamp(label)
	t.freq = time_stamp__freq()
}

// C++: timings.cpp:121
// Destroys a Timings structure and frees its memory
timings_destroy :: proc(t: ^Timings) {
	// C++ line 122
	delete(t.sections)
}

// C++: timings.cpp:125
// Stops the current timing section if one is active
timings__stop_current_section :: proc(t: ^Timings) {
	// C++ line 126-128
	if len(t.sections) > 0 {
		t.sections[len(t.sections) - 1].finish = time_stamp_time_now()
	}
}

// C++: timings.cpp:131
// Starts a new timing section with the given label
timings_start_section :: proc(t: ^Timings, label: string) {
	// C++ line 132-133
	timings__stop_current_section(t)
	append(&t.sections, make_time_stamp(label))
}

// ======================================================================================
// TIME CONVERSION UTILITIES
// C++ Reference: timings.cpp:136-172
// ======================================================================================

// C++: timings.cpp:136
// Converts a TimeStamp to seconds
time_stamp_as_s :: proc(ts: Time_Stamp, freq: u64) -> f64 {
	// C++ line 137-138
	duration := time.tick_diff(ts.start, ts.finish)
	assert(duration >= 0, fmt.tprintf("time_stamp_as_s - %s", ts.label))
	return time.duration_seconds(duration)
}

// C++: timings.cpp:141
// Converts a TimeStamp to milliseconds
time_stamp_as_ms :: proc(ts: Time_Stamp, freq: u64) -> f64 {
	// C++ line 142
	return 1000.0 * time_stamp_as_s(ts, freq)
}

// C++: timings.cpp:145
// Converts a TimeStamp to microseconds
time_stamp_as_us :: proc(ts: Time_Stamp, freq: u64) -> f64 {
	// C++ line 146
	return 1_000_000.0 * time_stamp_as_s(ts, freq)
}

// C++: timings.cpp:155
// Timing unit for display
Timing_Unit :: enum {
	Second, // C++ TimingUnit_Second (line 156)
	Millisecond, // C++ TimingUnit_Millisecond (line 157)
	Microsecond, // C++ TimingUnit_Microsecond (line 158)
}

// C++: timings.cpp:163
TIMING_UNIT_STRINGS := [Timing_Unit]string {
	.Second      = "s", // C++ line 163
	.Millisecond = "ms", // C++ line 163
	.Microsecond = "us", // C++ line 163
}

// C++: timings.cpp:165
// Converts a TimeStamp to the specified unit
time_stamp :: proc(ts: Time_Stamp, freq: u64, unit: Timing_Unit) -> f64 {
	// C++ line 166-171
	switch unit {
	case .Millisecond:
		return time_stamp_as_ms(ts, freq) // C++ line 167
	case .Microsecond:
		return time_stamp_as_us(ts, freq) // C++ line 168
	case .Second:
		return time_stamp_as_s(ts, freq) // C++ line 170
	}
	return time_stamp_as_s(ts, freq)
}

// ======================================================================================
// TIMING REPORT OUTPUT
// C++ Reference: timings.cpp:174-217
// ======================================================================================

// C++: timings.cpp:174
// Prints all timing sections with formatted output
timings_print_all :: proc(t: ^Timings, unit := Timing_Unit.Millisecond, timings_are_finalized := false) {
	// C++ line 175-177
	SPACES_LEN :: 256
	spaces: [SPACES_LEN + 1]byte
	mem.set(&spaces[0], ' ', SPACES_LEN)

	// C++ line 179-186: Stop the clock once if not finalized
	// NOTE(C++): Whether we call timings_print_all(), then timings_export_all(),
	// the other way around, or just one of them, we only need to stop the clock once.
	if !timings_are_finalized {
		timings__stop_current_section(t)
		t.total.finish = time_stamp_time_now()
	}

	// C++ line 188-192: Calculate maximum label length for formatting
	max_len := min(36, len(t.total.label))
	for ts in t.sections {
		max_len = max(max_len, len(ts.label))
	}

	// C++ line 194
	assert(max_len <= SPACES_LEN)

	// C++ line 196
	t.total_time_seconds = time_stamp_as_s(t.total, t.freq)

	// C++ line 198
	total_time := time_stamp(t.total, t.freq, unit)

	// C++ line 200-205: Print total timing
	padding_len := max_len - len(t.total.label)
	padding := string(spaces[:padding_len])
	fmt.eprintf("%s%s - % 9.3f %s - %6.2f%%\n", t.total.label, padding, total_time, TIMING_UNIT_STRINGS[unit], f64(100.0))

	// C++ line 207-216: Print individual sections
	for ts in t.sections {
		section_time := time_stamp(ts, t.freq, unit)
		padding_len2 := max_len - len(ts.label)
		padding2 := string(spaces[:padding_len2])
		fmt.eprintf("%s%s - % 9.3f %s - %6.2f%%\n", ts.label, padding2, section_time, TIMING_UNIT_STRINGS[unit], 100.0 * section_time / total_time)
	}
}

// ======================================================================================
// TIMING MACROS (converted to procedures)
// C++ Reference: timings.cpp:149-152
// ======================================================================================

// NOTE: C++ macros converted to procedures
// The C++ code uses macros for:
// - MAIN_TIME_SECTION(str) - line 149
// - MAIN_TIME_SECTION_WITH_LEN(str, len) - line 150
// - TIME_SECTION(str) - line 151
// - TIME_SECTION_WITH_LEN(str, len) - line 152
//
// These would be used like:
// main_time_section(&global_timings, "Parse Files")
// time_section(&global_timings, "Type Check", show_more_timings)
//
// In Odin, these would typically be called directly:
// timings_start_section(&global_timings, "Parse Files")
