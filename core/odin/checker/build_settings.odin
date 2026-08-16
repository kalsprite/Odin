package checker

import "core:odin/ast"
import "core:strings"

/*
Build configuration and target platform settings for the checker.

This module provides the build context, target metrics, and compiler flags
that affect type checking behavior. Ported from build_settings.cpp.

SCOPE: This file contains ONLY checker-relevant portions of build_settings.cpp.
       Linker settings, LLVM backend config, and command-line parsing are EXCLUDED.

Architecture:
- Target platform identification (OS, architecture, ABI)
- Target metrics (pointer size, alignment, endianness)
- Build context (compiler flags that affect checking)
- VET flags for code quality warnings
- Feature flags for opt-in language features
*/

// C++: build_settings.cpp:11
DEFAULT_MAX_ERROR_COLLECTOR_COUNT :: 36

// C++: build_settings.cpp:13-32
Target_Os_Kind :: enum u16 {
	Invalid,
	Windows,
	Darwin,
	Linux,
	Freebsd,
	Openbsd,
	Netbsd,
	Wasi,
	Js,
	Orca,
	Freestanding,
}

// C++: build_settings.cpp:34-50
target_os_names := [Target_Os_Kind]string {
	.Invalid      = "",
	.Windows      = "windows",
	.Darwin       = "darwin",
	.Linux        = "linux",
	.Freebsd      = "freebsd",
	.Openbsd      = "openbsd",
	.Netbsd       = "netbsd",
	.Wasi         = "wasi",
	.Js           = "js",
	.Orca         = "orca",
	.Freestanding = "freestanding",
}

// C++: build_settings.cpp:52-64
Target_Arch_Kind :: enum u16 {
	Invalid,
	Amd64,
	I386,
	Arm32,
	Arm64,
	Wasm32,
	Wasm64p32,
	Riscv64,
}

// C++: build_settings.cpp:66-75
target_arch_names := [Target_Arch_Kind]string {
	.Invalid   = "",
	.Amd64     = "amd64",
	.I386      = "i386",
	.Arm32     = "arm32",
	.Arm64     = "arm64",
	.Wasm32    = "wasm32",
	.Wasm64p32 = "wasm64p32",
	.Riscv64   = "riscv64",
}

// C++: build_settings.cpp:77-82
Target_Endian_Kind :: enum u8 {
	Little,
	Big,
}

// C++: build_settings.cpp:84-87
target_endian_names := [Target_Endian_Kind]string {
	.Little = "little",
	.Big    = "big",
}

// C++: build_settings.cpp:89-96
Target_ABI_Kind :: enum u16 {
	Default,
	Win64,
	SysV,
}

// C++: build_settings.cpp:98-102
target_abi_names := [Target_ABI_Kind]string {
	.Default = "",
	.Win64   = "win64",
	.SysV    = "sysv",
}

// C++: build_settings.cpp:104-117
Windows_Subsystem :: enum u8 {
	UNKNOWN,
	BOOT_APPLICATION,
	CONSOLE, // Default
	EFI_APPLICATION,
	EFI_BOOT_SERVICE_DRIVER,
	EFI_ROM,
	EFI_RUNTIME_DRIVER,
	NATIVE,
	POSIX,
	WINDOWS,
	WINDOWSCE,
}

// C++: build_settings.cpp:119-131
windows_subsystem_names := [Windows_Subsystem]string {
	.UNKNOWN                 = "",
	.BOOT_APPLICATION        = "BOOT_APPLICATION",
	.CONSOLE                 = "CONSOLE", // Default
	.EFI_APPLICATION         = "EFI_APPLICATION",
	.EFI_BOOT_SERVICE_DRIVER = "EFI_BOOT_SERVICE_DRIVER",
	.EFI_ROM                 = "EFI_ROM",
	.EFI_RUNTIME_DRIVER      = "EFI_RUNTIME_DRIVER",
	.NATIVE                  = "NATIVE",
	.POSIX                   = "POSIX",
	.WINDOWS                 = "WINDOWS",
	.WINDOWSCE               = "WINDOWSCE",
}

// C++: build_settings.cpp:145-153
target_endians := [Target_Arch_Kind]Target_Endian_Kind {
	.Invalid   = .Little,
	.Amd64     = .Little,
	.I386      = .Little,
	.Arm32     = .Little,
	.Arm64     = .Little,
	.Wasm32    = .Little,
	.Wasm64p32 = .Little,
	.Riscv64   = .Little,
}

// C++: build_settings.cpp:161-170
Target_Metrics :: struct {
	os:             Target_Os_Kind,
	arch:           Target_Arch_Kind,
	ptr_size:       int,
	int_size:       int,
	max_align:      int,
	max_simd_align: int,
	target_triplet: string,
	abi:            Target_ABI_Kind,
}

// C++: build_settings.cpp:172-180
Subtarget :: enum u32 {
	Default,
	IPhone,
	IPhoneSimulator,
	Android,
	Invalid,
}

// C++: build_settings.cpp:182-187
subtarget_strings := [Subtarget]string {
	.Default         = "",
	.IPhone          = "iphone",
	.IPhoneSimulator = "iphonesimulator",
	.Android         = "android",
	.Invalid         = "", // Not a real subtarget
}

// C++: build_settings.cpp:190-194
Query_Data_Set_Kind :: enum {
	Invalid,
	Global_Definitions,
	Go_To_Definitions,
}

// C++: build_settings.cpp:196-200
Query_Data_Set_Settings :: struct {
	kind:    Query_Data_Set_Kind,
	ok:      bool,
	compact: bool,
}

// C++: build_settings.cpp:202-211
Build_Mode_Kind :: enum {
	Executable,
	Dynamic_Library,
	Static_Library,
	Object,
	Assembly,
	LLVM_IR,
}

// C++: build_settings.cpp:213-232
Command_Kind :: distinct bit_set[Command_Kind_Bit;u64]
Command_Kind_Bit :: enum {
	Run             = 0,
	Build           = 1,
	Check           = 2,
	Doc             = 3,
	Version         = 4,
	Test            = 5,
	Strip_Semicolon = 6,
	Bug_Report      = 7,
	Bundle_Android  = 8,
	Bundle_Macos    = 9,
	Bundle_Ios      = 10,
	Bundle_Orca     = 11,
}

Command_Does_Check :: Command_Kind{.Run, .Build, .Check, .Doc, .Test, .Strip_Semicolon}
Command_Does_Build :: Command_Kind{.Run, .Build, .Test}

// C++: build_settings.cpp:251-256
Cmd_Doc_Flag :: distinct bit_set[Cmd_Doc_Flag_Bit;u32]
Cmd_Doc_Flag_Bit :: enum {
	Short        = 0,
	All_Packages = 1,
	Doc_Format   = 2,
}

// C++: build_settings.cpp:257-261
Timings_Export_Format :: enum i32 {
	Unspecified = 0,
	Json        = 1,
	CSV         = 2,
}

// C++: build_settings.cpp:263-267
Dependencies_Export_Format :: enum i32 {
	Unspecified = 0,
	Make        = 1,
	Json        = 2,
}

// C++: build_settings.cpp:269-274
Error_Pos_Style :: enum {
	Default, // path(line:column) msg
	Unix, // path:line:column: msg
}

// C++: build_settings.cpp:276-281
Reloc_Mode :: enum u8 {
	Default,
	Static,
	PIC,
	Dynamic_No_PIC,
}

// C++: build_settings.cpp:299-319
Vet_Flag :: distinct bit_set[Vet_Flag_Bit;u64]
Vet_Flag_Bit :: enum {
	Shadowing           = 0,
	Using_Stmt          = 1,
	Using_Param         = 2,
	Style               = 3,
	Semicolon           = 4,
	Unused_Variables    = 5,
	Unused_Imports      = 6,
	Deprecated          = 7,
	Cast                = 8,
	Tabs                = 9,
	Unused_Procedures   = 10,
	Explicit_Allocators = 11,
}

Vet_Flag_Unused :: Vet_Flag{.Unused_Variables, .Unused_Imports}
Vet_Flag_All :: Vet_Flag{.Unused_Variables, .Unused_Imports, .Shadowing, .Using_Stmt, .Deprecated, .Cast}
Vet_Flag_Using :: Vet_Flag{.Using_Stmt, .Using_Param}

// C++: build_settings.cpp:321-350
get_vet_flag_from_name :: proc(name: string) -> Vet_Flag {
	switch name {
	case "unused":
		return Vet_Flag_Unused
	case "unused-variables":
		return {.Unused_Variables}
	case "unused-imports":
		return {.Unused_Imports}
	case "shadowing":
		return {.Shadowing}
	case "using-stmt":
		return {.Using_Stmt}
	case "using-param":
		return {.Using_Param}
	case "style":
		return {.Style}
	case "semicolon":
		return {.Semicolon}
	case "deprecated":
		return {.Deprecated}
	case "cast":
		return {.Cast}
	case "tabs":
		return {.Tabs}
	case "unused-procedures":
		return {.Unused_Procedures}
	case "explicit-allocators":
		return {.Explicit_Allocators}
	}
	return {}
}

// C++: build_settings.cpp:352-369
Opt_In_Feature_Flag :: distinct bit_set[Opt_In_Feature_Flag_Bit;u64]
Opt_In_Feature_Flag_Bit :: enum {
	Dynamic_Literals                  = 0,
	Global_Context                    = 1,
	Integer_Division_By_Zero_Trap     = 2,
	Integer_Division_By_Zero_Zero     = 3,
	Integer_Division_By_Zero_Self     = 4,
	Integer_Division_By_Zero_All_Bits = 5,
	// C++ build_settings.cpp:377-378. Both were MISSING from this enum, so neither guard
	// could be expressed -- `using` as a statement was accepted unconditionally where C++
	// rejects it unless the file opts in (LEDGER task 242).
	Force_Type_Assert                 = 6,
	Using_Stmt                        = 7,
}

Opt_In_Feature_Flag_Integer_Division_By_Zero_All :: Opt_In_Feature_Flag{.Integer_Division_By_Zero_Trap, .Integer_Division_By_Zero_Zero, .Integer_Division_By_Zero_Self, .Integer_Division_By_Zero_All_Bits}

// C++: build_settings.cpp:371-393
get_feature_flag_from_name :: proc(name: string) -> Opt_In_Feature_Flag {
	switch name {
	case "dynamic-literals":
		return {.Dynamic_Literals}
	case "integer-division-by-zero:trap":
		return {.Integer_Division_By_Zero_Trap}
	case "integer-division-by-zero:zero":
		return {.Integer_Division_By_Zero_Zero}
	case "integer-division-by-zero:self":
		return {.Integer_Division_By_Zero_Self}
	case "integer-division-by-zero:all-bits":
		return {.Integer_Division_By_Zero_All_Bits}
	case "global-context":
		return {.Global_Context}
	case "using-stmt":
		return {.Using_Stmt}
	case "force-type-assert":
		return {.Force_Type_Assert}
	}
	return {}
}

// C++: build_settings.cpp get_feature_flag_from_name
Sanitizer_Flag :: distinct bit_set[Sanitizer_Flag_Bit;u32]
Sanitizer_Flag_Bit :: enum {
	Address = 0,
	Memory  = 1,
	Thread  = 2,
}

// C++: build_settings.cpp:426-431
Source_Code_Location_Info :: enum u8 {
	Normal     = 0,
	Obfuscated = 1,
	Filename   = 2,
	None       = 3,
}

// C++: build_settings.cpp:440-445
Integer_Division_By_Zero_Kind :: enum u8 {
	Trap,
	Zero,
	Self,
	All_Bits,
}

// This stores the information for the specific architecture of this build
// C++: build_settings.cpp:448-619
Build_Context :: struct {
	// Constants
	ODIN_OS:                            string, // Target operating system
	ODIN_ARCH:                          string, // Target architecture
	ODIN_VENDOR:                        string, // Compiler vendor
	ODIN_VERSION:                       string, // Compiler version
	ODIN_ROOT:                          string, // Odin ROOT
	ODIN_BUILD_PROJECT_NAME:            string, // Odin main/initial package's directory name
	ODIN_WINDOWS_SUBSYSTEM:             Windows_Subsystem, // .Console, .Windows
	ODIN_DEBUG:                         bool, // Odin in debug mode
	ODIN_DISABLE_ASSERT:                bool, // Whether the default 'assert' et al is disabled in code or not
	ODIN_DEFAULT_TO_NIL_ALLOCATOR:      bool, // Whether the default allocator is a "nil" allocator or not (i.e. it does nothing)
	ODIN_DEFAULT_TO_PANIC_ALLOCATOR:    bool, // Whether the default allocator is a "panic" allocator or not (i.e. panics on any call to it)
	ODIN_FOREIGN_ERROR_PROCEDURES:      bool,
	ODIN_VALGRIND_SUPPORT:              bool,
	ODIN_ERROR_POS_STYLE:               Error_Pos_Style,
	endian_kind:                        Target_Endian_Kind,

	// C++: build_settings.cpp:622 - `-bedrock`. Drops 128-bit integers from the universe
	// scope and disallows `map`.
	bedrock:                            bool,
	// C++: build_settings.cpp:624 - `-disable-init-fini`. Read at check_decl.cpp:1337 to reject
	// any @(init)/@(fini) declaration outright.
	disable_init_fini:                  bool,
	// C++: build_settings.cpp:579. Backend-only in effect, but ODIN_USE_SEPARATE_MODULES is
	// visible to checked code, so init_build_context derives it exactly as C++ does.
	use_separate_modules:               bool,
	use_single_module:                  bool,
	// C++ keeps the selected subtarget in the global `selected_subtarget`
	// (build_settings.cpp:941) rather than in BuildContext; the port stores it here so that
	// ODIN_PLATFORM_SUBTARGET has a source.
	subtarget:                          Subtarget,
	// C++: build_settings.cpp - `-minimum-os-version`, normalized in init_build_context.
	minimum_os_version_string:          string,
	// C++: build_settings.cpp - `-microarch`. Empty means "use the target default".
	microarch:                          string,

	// In bytes
	ptr_size:                           i64, // Size of a pointer, must be >= 4
	int_size:                           i64, // Size of a int/uint, must be >= 4
	max_align:                          i64, // max alignment, must be >= 1 (and typically >= ptr_size)
	max_simd_align:                     i64, // max alignment, must be >= 1 (and typically >= ptr_size)
	command_kind:                       Command_Kind,
	command:                            string,
	metrics:                            Target_Metrics,

	// Checker-relevant flags
	vet_flags:                          Vet_Flag,
	vet_packages:                       map[string]struct {}, // StringSet of packages to vet
	sanitizer_flags:                    Sanitizer_Flag,
	build_mode:                         Build_Mode_Kind,
	custom_optimization_level:          bool,
	optimization_level:                 i32,
	ignore_unknown_attributes:          bool,
	// Names accepted as attributes despite matching no built-in attribute, from C++'s
	// `-custom-attribute:<name>`. Populated by the host, like the rest of Build_Context.
	// C++ Reference: build_settings.cpp `StringSet custom_attributes`, guarded at
	// checker.cpp:4628.
	custom_attributes:                  map[string]bool,
	no_bounds_check:                    bool,
	// `-webkit-switch-workaround`: clear the top bit of every `typeid`.
	//
	// C++ Reference: build_settings.cpp:551, main.cpp:656/1352.
	//
	// WebKit's B3/OMG wasm JIT computes a switch's value range as a SIGNED i64
	// (max - min). A type switch over `any` -- core:fmt has several -- spans the
	// typeid space, and a span >= 2^63 overflows that subtraction, so the JIT
	// builds a pathologically-sized jump table and OOM-crashes the tab.
	// Constraining typeids to [1, 2^63) keeps the span representable.
	//
	// WebKit bug: https://bugs.webkit.org/show_bug.cgi?id=317022
	// Odin issue:  https://github.com/odin-lang/Odin/issues/6810
	webkit_switch_workaround:           bool,
	no_type_assert:                     bool,
	dynamic_literals:                   bool, // Opt-in to `#+feature dynamic-literals` project-wide.
	no_crt:                             bool,
	no_entry_point:                     bool,
	no_thread_local:                    bool,
	cross_compiling:                    bool,
	different_os:                       bool,
	disallow_do:                        bool,
	integer_division_by_zero_behaviour: Integer_Division_By_Zero_Kind,
	strict_style:                       bool,
	ignore_warnings:                    bool,
	warnings_as_errors:                 bool,
	hide_error_line:                    bool,
	terse_errors:                       bool,
	json_errors:                        bool,
	has_ansi_terminal_colours:          bool,
	ignore_lazy:                        bool,
	// dynamic_map_calls selects which runtime helpers a map get/set registers.
	// C++: build_settings.cpp:603, set ONLY by -dynamic-map-calls (main.cpp:1589), so the DEFAULT
	// (false) is the branch that uses map_desired_position / __dynamic_map_check_grow etc.
	dynamic_map_calls:                  bool,
	no_threaded_checker:                bool,
	no_rtti:                            bool,
	source_code_location_info:          Source_Code_Location_Info,
	max_error_count:                    int,

	// Target features (CPU feature sets)
	strict_target_features:             bool,
	minimum_os_version_string_given:    bool,

	// #591 STAGE A. The `-target-features:` INPUT and its RESOLVED result.
	//
	// C++ has TWO writers of build_context.target_features_set and the port had NEITHER as an
	// input -- `enabled_target_features()` recomputed the microarch defaults from scratch at each
	// of its call sites and there was no way to feed a user feature list in at all:
	//   1. main.cpp:4199-4207 seeds the set from get_default_features(), i.e. the microarch.
	//   2. main.cpp:4222-4281 merges `-target-features:` on top, per item: strip the sign to
	//      VALIDATE, then re-add with '+' defaulted, REMOVING the opposite-signed entry first so
	//      a later `-f` overrides an earlier `+f`.
	// `target_features_string` is writer 2's input; `target_features_set` is the resolved answer
	// both writers produce, and is what every consumer must read. Resolution happens ONCE, at
	// C++'s placement, rather than being recomputed per query -- that is the "authoritative
	// resolved read-back" the task asks for, and it is also what makes the two writers composable:
	// a per-call recomputation can only ever see writer 1.
	target_features_string:             string,
	target_features_set:                string,
	target_features_resolved:           bool,
	// The INPUTS the cached set was resolved from, so a later change to either invalidates it.
	// See resolve_target_features for why this exists -- it is not defensive, it is a bug I hit.
	target_features_resolved_march:     string,
	target_features_resolved_input:     string,

	// Debug flags
	// C++: build_settings.cpp:567
	show_debug_messages:                bool,
	show_more_timings:                  bool,

	// Documentation generation flags
	// C++: build_settings.cpp:588
	cmd_doc_flags:                      Cmd_Doc_Flag,

	// User-defined config values (from -define:NAME=VALUE command line)
	// C++: build_settings.cpp:599
	defined_values:                     map[string]ast.Exact_Value,

	// PORT-ONLY, NOT IN C++ (LEDGER #418). When non-empty, the checker writes a canonical dump
	// of its semantic model to this path just before the Checker is destroyed.
	//
	// This exists because parity.sh compares DIAGNOSTICS -- what the checker says is wrong -- and
	// that does not prove the two checkers built the same TYPES. modelcmp.sh reaches part of the
	// model, but only through the error-message channel, so it can express nothing that is not an
	// array length; entity sets and scopes are unreachable that way. #416 (bit_field align 8 for
	// every backing width) was exactly this blind spot: invisible to 323 packages of diagnostic
	// parity because it produced no wrong message.
	//
	// It is a FLAG rather than an accessor on Package_Check_Result deliberately. That result
	// cannot hand back the model: check_package_from_path holds the Checker as a stack local and
	// destroys it with `defer`, so any escaping pointer would be a use-after-free -- the #19 /
	// #218 / #358 class. Emitting from inside, while the model is alive, has no such hazard.
	dump_model_path:                    string,

	// LEDGER #480. -dump-doc:<path> writes the DOC-OUTPUT FLAG BITS per entity. Same lifetime
	// reasoning as dump_model_path: the Checker is a stack local in check_package_from_path, so
	// this cannot be an accessor handed back to the caller.
	dump_doc_path:                      string,
}

// Global build context instance
// C++: build_settings.cpp:621
build_context: Build_Context

// C++: build_settings.cpp:1017-1020
Library_Collection :: struct {
	name: string,
	path: string,
}

// C++: build_settings.cpp:1022
library_collections: [dynamic]Library_Collection

// C++: build_settings.cpp:1024-1027
add_library_collection :: proc(name: string, path: string) {
	lc := Library_Collection {
		name = name,
		path = strings.trim_space(path),
	}
	append(&library_collections, lc)
}

// C++: build_settings.cpp:1029-1036
find_library_collection_path :: proc(name: string) -> (path: string, found: bool) {
	for &lc in library_collections {
		if lc.name == name {
			return lc.path, true
		}
	}
	return "", false
}

// C++: build_settings.cpp:623-625
IS_ODIN_DEBUG :: proc() -> bool {
	return build_context.ODIN_DEBUG
}

// C++: build_settings.cpp:628-630
global_warnings_as_errors :: proc() -> bool {
	return build_context.warnings_as_errors
}

// C++: build_settings.cpp:631-633
global_ignore_warnings :: proc() -> bool {
	return build_context.ignore_warnings
}

// C++: build_settings.cpp:635-640
MAX_ERROR_COLLECTOR_COUNT :: proc() -> int {
	if build_context.max_error_count <= 0 {
		return DEFAULT_MAX_ERROR_COLLECTOR_COUNT
	}
	return build_context.max_error_count
}

// NOTE: AMD64 targets had their alignment on 128 bit ints bumped from 8 to 16 (undocumented of course).
// C++: build_settings.cpp:642-653
// These constants are LLVM version dependent:
// For LLVM 18+: AMD64_MAX_ALIGNMENT = 16, I386_MAX_ALIGNMENT = 16
// For LLVM <18: AMD64_MAX_ALIGNMENT = 8,  I386_MAX_ALIGNMENT = 4
// Using LLVM 18+ values (matching current Odin compiler)
AMD64_MAX_ALIGNMENT :: 16
I386_MAX_ALIGNMENT :: 16

// Target Metrics Tables
// C++: build_settings.cpp:655-857

target_windows_i386 := Target_Metrics {
	os             = .Windows,
	arch           = .I386,
	ptr_size       = 4,
	int_size       = 4,
	max_align      = I386_MAX_ALIGNMENT,
	max_simd_align = 16,
	target_triplet = "i386-pc-windows-msvc",
}

target_windows_amd64 := Target_Metrics {
	os             = .Windows,
	arch           = .Amd64,
	ptr_size       = 8,
	int_size       = 8,
	max_align      = AMD64_MAX_ALIGNMENT,
	max_simd_align = 32,
	target_triplet = "x86_64-pc-windows-msvc",
}

target_linux_i386 := Target_Metrics {
	os             = .Linux,
	arch           = .I386,
	ptr_size       = 4,
	int_size       = 4,
	max_align      = I386_MAX_ALIGNMENT,
	max_simd_align = 16,
	target_triplet = "i386-pc-linux-gnu",
}

target_linux_amd64 := Target_Metrics {
	os             = .Linux,
	arch           = .Amd64,
	ptr_size       = 8,
	int_size       = 8,
	max_align      = AMD64_MAX_ALIGNMENT,
	max_simd_align = 32,
	target_triplet = "x86_64-pc-linux-gnu",
}

target_linux_arm64 := Target_Metrics {
	os             = .Linux,
	arch           = .Arm64,
	ptr_size       = 8,
	int_size       = 8,
	max_align      = 16,
	max_simd_align = 32,
	target_triplet = "aarch64-linux-elf",
}

target_linux_arm32 := Target_Metrics {
	os             = .Linux,
	arch           = .Arm32,
	ptr_size       = 4,
	int_size       = 4,
	max_align      = 8,
	max_simd_align = 16,
	target_triplet = "arm-unknown-linux-gnueabihf",
}

target_linux_riscv64 := Target_Metrics {
	os             = .Linux,
	arch           = .Riscv64,
	ptr_size       = 8,
	int_size       = 8,
	max_align      = 16,
	max_simd_align = 32,
	target_triplet = "riscv64-linux-gnu",
}

target_darwin_amd64 := Target_Metrics {
	os             = .Darwin,
	arch           = .Amd64,
	ptr_size       = 8,
	int_size       = 8,
	max_align      = AMD64_MAX_ALIGNMENT,
	max_simd_align = 32,
	target_triplet = "x86_64-apple-macosx", // NOTE: Changes during initialization based on build flags.
}

target_darwin_arm64 := Target_Metrics {
	os             = .Darwin,
	arch           = .Arm64,
	ptr_size       = 8,
	int_size       = 8,
	max_align      = 16,
	max_simd_align = 32,
	target_triplet = "arm64-apple-macosx", // NOTE: Changes during initialization based on build flags.
}

target_freebsd_i386 := Target_Metrics {
	os             = .Freebsd,
	arch           = .I386,
	ptr_size       = 4,
	int_size       = 4,
	max_align      = I386_MAX_ALIGNMENT,
	max_simd_align = 16,
	target_triplet = "i386-unknown-freebsd-elf",
}

target_freebsd_amd64 := Target_Metrics {
	os             = .Freebsd,
	arch           = .Amd64,
	ptr_size       = 8,
	int_size       = 8,
	max_align      = AMD64_MAX_ALIGNMENT,
	max_simd_align = 32,
	target_triplet = "x86_64-unknown-freebsd-elf",
}

target_freebsd_arm64 := Target_Metrics {
	os             = .Freebsd,
	arch           = .Arm64,
	ptr_size       = 8,
	int_size       = 8,
	max_align      = 16,
	max_simd_align = 32,
	target_triplet = "aarch64-unknown-freebsd-elf",
}

target_openbsd_amd64 := Target_Metrics {
	os             = .Openbsd,
	arch           = .Amd64,
	ptr_size       = 8,
	int_size       = 8,
	max_align      = AMD64_MAX_ALIGNMENT,
	max_simd_align = 32,
	target_triplet = "x86_64-unknown-openbsd-elf",
}

target_netbsd_amd64 := Target_Metrics {
	os             = .Netbsd,
	arch           = .Amd64,
	ptr_size       = 8,
	int_size       = 8,
	max_align      = AMD64_MAX_ALIGNMENT,
	max_simd_align = 32,
	target_triplet = "x86_64-unknown-netbsd-elf",
}

target_netbsd_arm64 := Target_Metrics {
	os             = .Netbsd,
	arch           = .Arm64,
	ptr_size       = 8,
	int_size       = 8,
	max_align      = 16,
	max_simd_align = 32,
	target_triplet = "aarch64-unknown-netbsd-elf",
}



target_freestanding_wasm32 := Target_Metrics {
	os             = .Freestanding,
	arch           = .Wasm32,
	ptr_size       = 4,
	int_size       = 4,
	max_align      = 8,
	max_simd_align = 16,
	target_triplet = "wasm32-freestanding-js",
}

target_js_wasm32 := Target_Metrics {
	os             = .Js,
	arch           = .Wasm32,
	ptr_size       = 4,
	int_size       = 4,
	max_align      = 8,
	max_simd_align = 16,
	target_triplet = "wasm32-js-js",
}

target_wasi_wasm32 := Target_Metrics {
	os             = .Wasi,
	arch           = .Wasm32,
	ptr_size       = 4,
	int_size       = 4,
	max_align      = 8,
	max_simd_align = 16,
	target_triplet = "wasm32-wasi-js",
}

target_orca_wasm32 := Target_Metrics {
	os             = .Orca,
	arch           = .Wasm32,
	ptr_size       = 4,
	int_size       = 4,
	max_align      = 8,
	max_simd_align = 16,
	target_triplet = "wasm32-wasi-js",
}

target_freestanding_wasm64p32 := Target_Metrics {
	os             = .Freestanding,
	arch           = .Wasm64p32,
	ptr_size       = 4,
	int_size       = 8,
	max_align      = 8,
	max_simd_align = 16,
	target_triplet = "wasm32-freestanding-js",
}

target_js_wasm64p32 := Target_Metrics {
	os             = .Js,
	arch           = .Wasm64p32,
	ptr_size       = 4,
	int_size       = 8,
	max_align      = 8,
	max_simd_align = 16,
	target_triplet = "wasm32-js-js",
}

target_wasi_wasm64p32 := Target_Metrics {
	os             = .Wasi,
	arch           = .Wasm32, // NOTE: C++ has Wasm32 here, not Wasm64p32
	ptr_size       = 4,
	int_size       = 8,
	max_align      = 8,
	max_simd_align = 16,
	target_triplet = "wasm32-wasi-js",
}

target_freestanding_amd64_sysv := Target_Metrics {
	os             = .Freestanding,
	arch           = .Amd64,
	ptr_size       = 8,
	int_size       = 8,
	max_align      = AMD64_MAX_ALIGNMENT,
	max_simd_align = 32,
	target_triplet = "x86_64-pc-none-gnu",
	abi            = .SysV,
}

target_freestanding_amd64_win64 := Target_Metrics {
	os             = .Freestanding,
	arch           = .Amd64,
	ptr_size       = 8,
	int_size       = 8,
	max_align      = AMD64_MAX_ALIGNMENT,
	max_simd_align = 32,
	// #961: was "x86_64-pc-none-msvc". C++ build_settings.cpp gives this target
	// "x86_64-pc-windows-msvc" -- the vendor/OS component is `windows`, not `none`, even though
	// the Odin-level OS is Freestanding. Found by field-comparing the metrics tables, which
	// rule_engine findings/079 explicitly left unchecked ("checked for symbol pairing, not for
	// field-by-field equality").
	target_triplet = "x86_64-pc-windows-msvc",
	abi            = .Win64,
}

// C++ Reference: build_settings.cpp `target_freestanding_amd64_mingw`.
//
// #961, rule_engine findings/079: THE PORT HAD NO SUCH TARGET -- `named_targets` listed 27 where
// C++ lists 28, and `get_target_metrics_from_name("freestanding_amd64_mingw")` returned nil for a
// target the reference accepts (measured: the compiler reaches the ordinary cross-link limitation
// rather than "Unknown target", so the name resolves).
//
// It is NOT a duplicate of freestanding_amd64_win64 above: same OS, arch, sizes and ABI, but the
// LLVM TRIPLE differs -- `windows-gnu` against `windows-msvc`. Dropping it removed the only way to
// name the GNU toolchain triple for a freestanding amd64 build.
target_freestanding_amd64_mingw := Target_Metrics {
	os             = .Freestanding,
	arch           = .Amd64,
	ptr_size       = 8,
	int_size       = 8,
	max_align      = AMD64_MAX_ALIGNMENT,
	max_simd_align = 32,
	target_triplet = "x86_64-pc-windows-gnu",
	abi            = .Win64,
}

target_freestanding_arm64 := Target_Metrics {
	os             = .Freestanding,
	arch           = .Arm64,
	ptr_size       = 8,
	int_size       = 8,
	max_align      = 16,
	max_simd_align = 32,
	target_triplet = "aarch64-none-elf",
}

target_freestanding_arm32 := Target_Metrics {
	os             = .Freestanding,
	arch           = .Arm32,
	ptr_size       = 4,
	int_size       = 4,
	max_align      = 8,
	max_simd_align = 16,
	// #961: was "arm-unknown-unknown-gnueabihf". C++ gives this target "arm-none-eabihf" -- three
	// components, not four. Same field-comparison as the win64 triple above.
	target_triplet = "arm-none-eabihf",
}

target_freestanding_riscv64 := Target_Metrics {
	os             = .Freestanding,
	arch           = .Riscv64,
	ptr_size       = 8,
	int_size       = 8,
	max_align      = 16,
	max_simd_align = 32,
	target_triplet = "riscv64-unknown-gnu",
}

// ======================================================================================
// NAMED TARGET LOOKUP TABLE
// C++: build_settings.cpp:863-909
// ======================================================================================

// Named_Target_Metrics maps a string name to a target metrics pointer
// C++: build_settings.cpp:863-866
Named_Target_Metrics :: struct {
	name:    string,
	metrics: ^Target_Metrics,
}

// Lookup table for all supported targets
// C++: build_settings.cpp:868-909
named_targets := []Named_Target_Metrics {
	{"darwin_amd64", &target_darwin_amd64},
	{"darwin_arm64", &target_darwin_arm64},

	{"linux_i386", &target_linux_i386},
	{"linux_amd64", &target_linux_amd64},
	{"linux_arm64", &target_linux_arm64},
	{"linux_arm32", &target_linux_arm32},
	{"linux_riscv64", &target_linux_riscv64},

	{"windows_i386", &target_windows_i386},
	{"windows_amd64", &target_windows_amd64},

	{"freebsd_i386", &target_freebsd_i386},
	{"freebsd_amd64", &target_freebsd_amd64},
	{"freebsd_arm64", &target_freebsd_arm64},

	{"netbsd_amd64", &target_netbsd_amd64},
	{"netbsd_arm64", &target_netbsd_arm64},

	{"openbsd_amd64", &target_openbsd_amd64},

	{"freestanding_wasm32", &target_freestanding_wasm32},
	{"wasi_wasm32", &target_wasi_wasm32},
	{"js_wasm32", &target_js_wasm32},
	{"orca_wasm32", &target_orca_wasm32},

	{"freestanding_wasm64p32", &target_freestanding_wasm64p32},
	{"js_wasm64p32", &target_js_wasm64p32},
	{"wasi_wasm64p32", &target_wasi_wasm64p32},

	{"freestanding_amd64_sysv", &target_freestanding_amd64_sysv},
	{"freestanding_amd64_win64", &target_freestanding_amd64_win64},
	// #961: placed HERE, matching C++'s row order (build_settings.cpp lists mingw immediately after
	// win64). Its absence also made `get_all_target_names` advertise 27 targets where the reference
	// honours 28, so a consumer building a suggestion list from the port under-reported.
	{"freestanding_amd64_mingw", &target_freestanding_amd64_mingw},

	{"freestanding_arm64", &target_freestanding_arm64},
	{"freestanding_arm32", &target_freestanding_arm32},

	{"freestanding_riscv64", &target_freestanding_riscv64},
}

// Get target metrics by name
// C++: main.cpp:1093-1130 (target lookup logic)
// Returns nil if not found
get_target_metrics_from_name :: proc(name: string) -> ^Target_Metrics {
	for &nt in named_targets {
		if strings_eq_ignore_case(nt.name, name) {
			return nt.metrics
		}
	}
	return nil
}

// Get all target names (for error messages/suggestions)
get_all_target_names :: proc() -> []string {
	result := make([]string, len(named_targets))
	for nt, i in named_targets {
		result[i] = nt.name
	}
	return result
}

// ======================================================================================
// BUILD CONTEXT INITIALIZATION
// C++: build_settings.cpp:1706-2025
// ======================================================================================

// HOST_TARGET_NAME names the platform the checker itself was built for, in the same
// "<os>_<arch>" form as the entries of named_targets.
//
// C++ picks the host with a block of #ifdefs (build_settings.cpp:1750-1802). ODIN_OS_STRING and
// ODIN_ARCH_STRING are that same information in the same form - constants of the tool, fixed
// when it was compiled - so this is a translation of that block, not a hardcoded target: it is
// only ever consulted when no cross target was requested.
HOST_TARGET_NAME :: ODIN_OS_STRING + "_" + ODIN_ARCH_STRING

// default_target_metrics returns the metrics for the host platform.
//
// Falls back to linux_amd64 for a host that has no entry in named_targets, which can only
// happen for a platform the checker cannot be built for anyway.
default_target_metrics :: proc() -> ^Target_Metrics {
	if metrics := get_target_metrics_from_name(HOST_TARGET_NAME); metrics != nil {
		return metrics
	}
	return &target_linux_amd64
}

// ensure_build_context_initialized gives build_context a target if it does not already have one.
//
// Nothing in init_checker sets a target up, so without this the build context reaches the
// package loader zeroed - metrics.os == .Invalid - and every platform-suffixed and every
// `#+build`-tagged file in the tree would be judged as belonging to some other platform and
// dropped. Guarded on metrics.os so that an embedder that has already chosen a target (the
// cross-checking case) keeps it.
ensure_build_context_initialized :: proc() {
	if build_context.metrics.os == .Invalid {
		init_build_context()
	}
}

// Initialize build context with target metrics
// C++: build_settings.cpp:1706-2025
// This function sets up the build context from the provided target metrics.
// For the checker, we skip linker configuration and path resolution.
//
// Parameters:
//   cross_target: Target metrics to use (nil = use host platform default)
//   subtarget: Optional subtarget modifier (iPhone, Android, etc.)
init_build_context :: proc(cross_target: ^Target_Metrics = nil, subtarget: Subtarget = .Default) {
	bc := &build_context

	// C++: build_settings.cpp:1714-1715
	bc.ODIN_VENDOR = "odin"
	bc.ODIN_VERSION = "" // Set by compiler, not checker

	// C++: build_settings.cpp:1718-1720
	if bc.max_error_count <= 0 {
		bc.max_error_count = DEFAULT_MAX_ERROR_COLLECTOR_COUNT
	}

	// Default host platform detection
	// C++: build_settings.cpp init_build_context
	metrics := cross_target
	if metrics == nil {
		metrics = default_target_metrics()
	}

	// Check for cross-compilation
	// C++: build_settings.cpp init_build_context
	if cross_target != nil {
		// For checker, we can't detect host platform at runtime like C++
		// so we assume cross_compiling if a target was explicitly provided
		bc.cross_compiling = true
	}

	// Validate metrics
	// C++: build_settings.cpp init_build_context
	assert(metrics.os != .Invalid, "init_build_context: Invalid target OS")
	assert(metrics.arch != .Invalid, "init_build_context: Invalid target arch")
	assert(metrics.ptr_size > 1, "init_build_context: Invalid ptr_size")
	assert(metrics.int_size > 1, "init_build_context: Invalid int_size")
	assert(metrics.max_align > 1, "init_build_context: Invalid max_align")
	assert(metrics.max_simd_align > 1, "init_build_context: Invalid max_simd_align")
	assert(metrics.int_size >= metrics.ptr_size, "init_build_context: int_size must be >= ptr_size")
	if metrics.int_size > metrics.ptr_size {
		assert(metrics.int_size == 2 * metrics.ptr_size, "init_build_context: int_size must be ptr_size or 2*ptr_size")
	}

	// Copy metrics into build context
	// C++: build_settings.cpp init_build_context
	bc.metrics = metrics^
	bc.ODIN_OS = target_os_names[metrics.os]
	bc.ODIN_ARCH = target_arch_names[metrics.arch]
	bc.endian_kind = target_endians[metrics.arch]
	bc.ptr_size = i64(metrics.ptr_size)
	bc.int_size = i64(metrics.int_size)
	bc.max_align = i64(metrics.max_align)
	bc.max_simd_align = i64(metrics.max_simd_align)

	// Freestanding defaults
	// C++: build_settings.cpp init_build_context
	if metrics.os == .Freestanding {
		bc.no_entry_point = true
	}

	// Default Windows subsystem
	// C++: build_settings.cpp init_build_context
	if bc.ODIN_WINDOWS_SUBSYSTEM == .UNKNOWN && metrics.os == .Windows {
		bc.ODIN_WINDOWS_SUBSYSTEM = .CONSOLE
	}

	// Handle subtargets (iPhone, iPhoneSimulator, Android)
	// C++: build_settings.cpp init_build_context
	if metrics.os == .Darwin {
		#partial switch subtarget {
		case .IPhone:
			#partial switch metrics.arch {
			case .Arm64:
				bc.metrics.target_triplet = "arm64-apple-ios"
			case:
				panic("Unknown architecture for subtarget:iphone")
			}
		case .IPhoneSimulator:
			#partial switch metrics.arch {
			case .Arm64:
				bc.metrics.target_triplet = "arm64-apple-ios-simulator"
			case .Amd64:
				bc.metrics.target_triplet = "x86_64-apple-ios-simulator"
			case:
				panic("Unknown architecture for subtarget:iphonesimulator")
			}
		}
	} else if metrics.os == .Linux && subtarget == .Android {
		#partial switch metrics.arch {
		case .Arm64:
			bc.metrics.target_triplet = "aarch64-none-linux-android"
		case:
			panic("Unknown architecture for subtarget:android")
		}
	}

	// C++ records the selected subtarget in a global (build_settings.cpp:941); the port keeps
	// it on the build context so ODIN_PLATFORM_SUBTARGET can be derived from it.
	bc.subtarget = subtarget

	// Minimum OS version defaults.
	// C++: build_settings.cpp init_build_context. Only darwin has a default; every other target
	// leaves the string empty, which init_universal turns into ODIN_MINIMUM_OS_VERSION == 0.
	if metrics.os == .Darwin && !bc.minimum_os_version_string_given {
		switch subtarget {
		case .IPhone, .IPhoneSimulator:
			// NOTE(harold) in C++: 17.4 is when os_sync_wait_on_address was added.
			bc.minimum_os_version_string = "17.4.0"
		case .Default, .Android, .Invalid:
			bc.minimum_os_version_string = "11.0.0"
		}
	}

	// Optimization level defaults.
	// C++: build_settings.cpp init_build_context
	if !bc.custom_optimization_level {
		// C++: when building with `-debug` but no explicit optimization level, default to
		// `-o:none` to improve debug symbol generation.
		bc.optimization_level = bc.ODIN_DEBUG ? -1 : 0
	}
	bc.optimization_level = clamp(bc.optimization_level, -1, 3)

	// Separate modules.
	// C++: build_settings.cpp init_build_context (wasm forces it off), 2083-2085 (-o:none/-o:minimal turn
	// it on for non-wasm), 2087-2089 (`-use-single-module` turns it back off).
	// The port has no LTO support, so the `-lto:thin` branch (C++ 2091-2110) is not ported.
	if is_arch_wasm() {
		bc.use_separate_modules = false
	} else if bc.optimization_level <= 0 {
		bc.use_separate_modules = true
	}
	if bc.use_single_module {
		bc.use_separate_modules = false
	}

	// C++: build_settings.cpp init_build_context
	bc.ODIN_VALGRIND_SUPPORT = false
	if bc.metrics.os != .Windows && bc.metrics.arch == .Amd64 {
		bc.ODIN_VALGRIND_SUPPORT = true
	}

	// C++: build_settings.cpp init_build_context
	if bc.metrics.os == .Freestanding {
		bc.ODIN_DEFAULT_TO_NIL_ALLOCATOR = !bc.ODIN_DEFAULT_TO_PANIC_ALLOCATOR
	}

	// #591 STAGE A: resolve the target-feature set HERE, once the target is final.
	//
	// Placement is forced by a data dependency, not by taste: resolve_target_features reads
	// bc.metrics.arch (to pick the validity table) and get_final_microarchitecture(), so it cannot
	// run before this procedure has chosen them. C++ has the same ordering -- its seeding at
	// main.cpp:4199 runs after init_build_context.
	//
	// This is INERT for every existing caller: with an empty target_features_string the resolved
	// set is exactly microarch_default_features(get_final_microarchitecture()), which is precisely
	// what enabled_target_features() returned before. The behaviour only changes for a caller that
	// actually supplies the input.
	//
	// The error is deliberately DROPPED here rather than reported: init_build_context has no error
	// collector (it runs before one exists) and a checker library must not exit its host process
	// (#12). An embedder that supplies target_features_string should call resolve_target_features
	// ITSELF and inspect the returned invalid-feature name -- it is idempotent and safe to re-run,
	// which is also how a context whose features are set AFTER init gets a correct set.
	_, _ = resolve_target_features()
}

// get_default_microarchitecture returns the microarchitecture used when none was requested.
// C++: llvm_backend.cpp get_default_microarchitecture
get_default_microarchitecture :: proc() -> string {
	#partial switch build_context.metrics.arch {
	case .Amd64:
		// NOTE(bill) in C++: x86-64-v2 is more than enough for everyone.
		if build_context.metrics.os == .Freestanding {
			return "x86-64"
		}
		return "x86-64-v2"
	case .Riscv64:
		return "generic-rv64"
	}
	return "generic"
}

// get_final_microarchitecture resolves ODIN_MICROARCH_STRING.
// C++: llvm_backend.cpp get_final_microarchitecture
//
// DEVIATION: C++ resolves the literal string "native" through LLVMGetHostCPUName(). The
// checker does not link LLVM, so "native" is returned verbatim. It can only be reached by an
// embedder that sets build_context.microarch itself, since the checker parses no flags.
get_final_microarchitecture :: proc() -> string {
	if len(build_context.microarch) == 0 {
		return get_default_microarchitecture()
	}
	return build_context.microarch
}

// Initialize build context from target name string
// This is a convenience wrapper that looks up the target by name first.
// Returns false if the target name is not found.
init_build_context_from_string :: proc(target_name: string, subtarget: Subtarget = .Default) -> bool {
	metrics := get_target_metrics_from_name(target_name)
	if metrics == nil {
		return false
	}
	init_build_context(metrics, subtarget)
	return true
}

// Helper functions for target platform queries
// C++: build_settings.cpp:1036-1043
is_arch_wasm :: proc() -> bool {
	#partial switch build_context.metrics.arch {
	case .Wasm32, .Wasm64p32:
		return true
	}
	return false
}

// C++: build_settings.cpp:1045-1052
is_arch_x86 :: proc() -> bool {
	#partial switch build_context.metrics.arch {
	case .I386, .Amd64:
		return true
	}
	return false
}

// C++: build_settings.cpp:912-953
// Parses a target OS string (e.g., "linux", "windows:generic", "darwin:iphone")
// Optionally extracts subtarget information (e.g., "iphone", "android")
get_target_os_from_string :: proc(str: string) -> (kind: Target_Os_Kind, subtarget: Subtarget) {
	os_name := str
	subtarget_str := ""

	// Check for subtarget separator ":"
	if colon_idx := 0; true {
		found := false
		for ch, i in str {
			if ch == ':' {
				colon_idx = i
				found = true
				break
			}
		}
		if found {
			os_name = str[:colon_idx]
			subtarget_str = str[colon_idx + 1:]
		}
	}

	kind = .Invalid
	for os_kind in Target_Os_Kind.Invalid ..= Target_Os_Kind.Freestanding {
		if strings_eq_ignore_case(target_os_names[os_kind], os_name) {
			kind = os_kind
			break
		}
	}

	// Parse subtarget
	subtarget = .Default
	if len(subtarget_str) != 0 {
		if strings_eq_ignore_case(subtarget_str, "generic") || strings_eq_ignore_case(subtarget_str, "default") {
			subtarget = .Default
		} else {
			subtarget = .Invalid
			for st in Subtarget.IPhone ..= Subtarget.Android {
				if strings_eq_ignore_case(subtarget_strings[st], subtarget_str) {
					subtarget = st
					break
				}
			}
		}
	}

	return kind, subtarget
}

// C++: build_settings.cpp:955-962
get_target_arch_from_string :: proc(str: string) -> Target_Arch_Kind {
	for arch_kind in Target_Arch_Kind.Invalid ..= Target_Arch_Kind.Riscv64 {
		if strings_eq_ignore_case(target_arch_names[arch_kind], str) {
			return arch_kind
		}
	}
	return .Invalid
}

// Helper to compare strings case-insensitively
// This is a minimal implementation for the functions above
// C++: Uses str_eq_ignore_case from string.cpp
strings_eq_ignore_case :: proc(a, b: string) -> bool {
	if len(a) != len(b) {
		return false
	}
	for i in 0 ..< len(a) {
		ac := a[i]
		bc := b[i]
		// Convert to lowercase
		if ac >= 'A' && ac <= 'Z' {
			ac += 'a' - 'A'
		}
		if bc >= 'A' && bc <= 'Z' {
			bc += 'a' - 'A'
		}
		if ac != bc {
			return false
		}
	}
	return true
}

// C++: build_settings.cpp:964-1011
// Checks if a filename should be excluded based on target OS/arch suffixes
// Example: "foo_linux.odin" is excluded when targeting Windows
//          "bar_amd64.odin" is excluded when targeting ARM
is_excluded_target_filename :: proc(name: string) -> bool {
	// Remove extension.
	//
	// C++: remove_extension_from_path (src/path.cpp:8) leaves a name whose *last* character is
	// a '.' untouched, rather than stripping an empty extension off it. The guard is reproduced
	// here so "foo." keeps its dot in both implementations.
	name_no_ext := name
	if !(len(name) != 0 && name[len(name) - 1] == '.') {
		dot_idx := 0
		found := false
		for i := len(name) - 1; i >= 0; i -= 1 {
			if name[i] == '.' {
				dot_idx = i
				found = true
				break
			}
		}
		if found {
			name_no_ext = name[:dot_idx]
		}
	}

	// Ignore hidden files (starting with '.')
	if len(name_no_ext) > 0 && name_no_ext[0] == '.' {
		return true
	}

	// Extract suffix after last underscore
	str1 := name_no_ext
	n := len(str1)
	for i := len(str1) - 1; i >= 0 && str1[i] != '_'; i -= 1 {
		n -= 1
	}
	str1 = str1[n:]

	// Extract second-to-last suffix
	str2 := name_no_ext[:max(n - 1, 0)]
	n = len(str2)
	for i := len(str2) - 1; i >= 0 && str2[i] != '_'; i -= 1 {
		n -= 1
	}
	str2 = str2[n:]

	// If no underscores found, not a target-specific file
	if str1 == name_no_ext {
		return false
	}

	// Check if suffixes match OS or arch
	os1, _ := get_target_os_from_string(str1)
	arch1 := get_target_arch_from_string(str1)
	os2, _ := get_target_os_from_string(str2)
	arch2 := get_target_arch_from_string(str2)

	// Exclude if OS or arch doesn't match current target
	if os1 != .Invalid && arch2 != .Invalid {
		return os1 != build_context.metrics.os || arch2 != build_context.metrics.arch
	} else if arch1 != .Invalid && os2 != .Invalid {
		return arch1 != build_context.metrics.arch || os2 != build_context.metrics.os
	} else if os1 != .Invalid {
		return os1 != build_context.metrics.os
	} else if arch1 != .Invalid {
		return arch1 != build_context.metrics.arch
	}

	return false
}

// C++: build_settings.cpp:1573-1575
show_error_line :: proc() -> bool {
	return !build_context.hide_error_line && !build_context.json_errors
}

// C++: build_settings.cpp:1577-1578
terse_errors :: proc() -> bool {
	return build_context.terse_errors
}

// C++: build_settings.cpp:1580-1581
json_errors :: proc() -> bool {
	return build_context.json_errors
}

// C++: build_settings.cpp:1583-1585
has_ansi_terminal_colours :: proc() -> bool {
	return build_context.has_ansi_terminal_colours && !json_errors()
}

// ======================================================================================
// TARGET FEATURE VALIDATION
// C++: build_settings_microarch.cpp and build_settings.cpp:2052-2092
// ======================================================================================

// target_features_list -- the per-architecture set of feature names LLVM accepts -- now lives in
// build_settings_microarch.odin, GENERATED from src/build_settings_microarch.cpp by
// .claude/tools/gen_microarch.py.
//
// #612: the hand-copied table that used to sit here was stale against LLVM 22 on ALL SEVEN real
// architectures, in BOTH directions at once -- it rejected 34 arm64 and 55 riscv64 feature names
// C++ accepts, while accepting `tme`, `zcz`, `nacl-trap` and `amx-transpose`, which C++ rejects.
// Hand-maintaining a 200 KB generated table IS the defect; do not paste rows back in here.

// ---------------------------------------------------------------------------------------------
// TARGET FEATURE ENABLEMENT (LEDGER #543)
//
// C++ Reference: src/build_settings.cpp:2200 check_target_feature_is_enabled, and the
// target_features_set that init_build_paths seeds from get_default_features()
// (src/llvm_backend.cpp:66) via get_final_microarchitecture().
//
// WHY THIS EXISTS. check_builtin_has_target_feature returned a hardcoded `false` with the comment
// "The actual value would be determined by checking target features". That is not a wrong ANSWER,
// it is no answer, and it is invisible to every diagnostic gate: code guarded by
// `when intrinsics.has_target_feature("sse2")` simply is not checked, and unchecked-but-correct
// code is indistinguishable from checked-and-clean. It surfaced only through the model comparison
// (#542), as three entities missing from core/hash/xxhash.

// microarch_default_features returns the features LLVM enables by default for the CURRENT TARGET's
// microarchitecture -- i.e. exactly what C++ seeds build_context.target_features_set from.
//
// C++ Reference: llvm_backend.cpp get_default_features
//
// It reads build_context.metrics.arch because C++ reads build_context, and because the arch is
// LOAD-BEARING, not incidental: the same microarch NAME denotes different feature sets on different
// architectures. Both amd64 and wasm32 define `generic`, and the port's default microarch is `generic`
// for every arch except amd64 and riscv64 (get_default_microarchitecture above). The previous
// implementation was a flat `switch microarch`, so wasm32, wasm64p32, arm32, arm64 and i386 were all
// told they had the x86-64 feature set -- sse2, x87 and all. That was #612.
microarch_default_features :: proc(microarch: string) -> string {
	arch := build_context.metrics.arch

	// C++ Reference: llvm_backend.cpp get_default_features
	// DIVERGENCE, deliberate and recorded: `-microarch:native` asks LLVM for the HOST's feature string
	// via LLVMGetHostCPUFeatures. The checker does not link LLVM, so no faithful answer exists here.
	// "" means has_target_feature answers false for everything under -microarch:native. Matches the
	// existing "native" deviation documented on get_final_microarchitecture.
	if microarch == "native" {
		return ""
	}

	// C++ Reference: llvm_backend.cpp get_default_features
	// riscv64's generic-rv64 is OVERRIDDEN rather than read from the table -- C++'s own note says this
	// is to avoid defaulting to "a potato feature set". The table row for generic-rv64 is NOT this
	// string, so reading the table here would be wrong.
	if arch == .Riscv64 && microarch == "generic-rv64" {
		return "64bit,a,c,d,f,m,relax,zicsr,zifencei"
	}

	// C++ Reference: llvm_backend.cpp get_default_features -- sum the counts of every arch
	// BEFORE this one to find where this arch's slice of the flat table begins.
	off := 0
	for a in Target_Arch_Kind {
		if a == arch {
			break
		}
		off += target_microarch_counts[a]
	}

	// C++ Reference: llvm_backend.cpp get_default_features -- match the name WITHIN this
	// arch's slice only. Matching across the whole table by name is the #612 defect.
	for i in off ..< off + target_microarch_counts[arch] {
		if microarch_features_list[i].microarch == microarch {
			return microarch_features_list[i].features
		}
	}

	// C++ Reference: llvm_backend.cpp get_default_features -- C++ reaches GB_PANIC("unknown
	// microarch") here.
	// DIVERGENCE, deliberate: the checker is a LIBRARY and must not abort its host, which is the whole
	// point of #12 (the error cap used to call os.exit and killed the calling process). An unknown
	// microarch can only arrive from an embedder setting build_context.microarch to a name LLVM does
	// not have, since the checker parses no flags. It yields "" -- has_target_feature answers false --
	// rather than taking the process down.
	return ""
}

// target_feature_is_enabled ports check_target_feature_is_enabled (build_settings.cpp check_target_feature_is_enabled)
// line for line, including the two details that are easy to drop:
//   - a leading '+' or '-' inverts what the caller is ASKING (want_enabled), it does not merely
//     decorate the name
//   - "feature" and "+feature" are ALWAYS equivalent in the enabled set, and a "-feature" entry
//     overrides both. C++'s own note explains the ordering.
// ALL comma-separated features must hold; the first that does not short-circuits to false.
target_feature_is_enabled :: proc(features: string, enabled: string) -> bool {
	// split_iterator MUTATES its argument, and Odin parameters are immutable -- take a local copy.
	rest := features
	for entry in strings.split_iterator(&rest, ",") {
		feature_str := entry
		want_enabled := true
		if len(feature_str) > 0 && (feature_str[0] == '+' || feature_str[0] == '-') {
			want_enabled = feature_str[0] == '+'
			feature_str = feature_str[1:]
		}
		if len(feature_str) == 0 {
			break
		}

		// C++ does three string_set_exists lookups against feature/+feature/-feature. One pass over
		// the enabled set answers all three, and comparing the prefix in place avoids the
		// concatenation C++'s set lookup needs.
		has_raw, has_plus, has_minus := false, false, false
		set := enabled
		for have in strings.split_iterator(&set, ",") {
			if have == feature_str {
				has_raw = true
			} else if len(have) > 0 && have[1:] == feature_str {
				if have[0] == '+' {
					has_plus = true
				} else if have[0] == '-' {
					has_minus = true
				}
			}
		}

		is_enabled := (has_plus || has_raw) && !has_minus
		if want_enabled != is_enabled {
			return false
		}
	}
	return true
}

// enabled_target_features returns the feature set active for the current build target, i.e. what
// C++ seeds build_context.target_features_set with at init_build_paths (build_settings.cpp:2284).
enabled_target_features :: proc() -> string {
	// #591 STAGE A: READ THE RESOLVED SET, do not recompute. Before this, every call recomputed
	// the microarch defaults, which structurally could not see the `-target-features:` input --
	// so the flag had nowhere to land even once it existed. resolve_target_features() is the
	// single writer; this is the authoritative read-back.
	// The cache is keyed on the INPUTS, and this is a bug I actually shipped and crosstarget.sh
	// caught: resolving at the end of init_build_context looked right, but `-microarch:` is applied
	// to build_context AFTER init_build_context returns, so the cached set was computed from the
	// DEFAULT microarch and then never updated. Every `-microarch:bleeding-edge` probe regressed --
	// the port claimed `atomics` was unavailable on a target where it is. C++ does not have this
	// problem because it seeds at main.cpp:4199, AFTER all flag parsing; the port has no single
	// such point, so the cache must invalidate itself instead of trusting placement.
	if build_context.target_features_resolved &&
	   build_context.target_features_resolved_march == get_final_microarchitecture() &&
	   build_context.target_features_resolved_input == build_context.target_features_string {
		return build_context.target_features_set
	}
	// NOT-YET-RESOLVED FALLBACK, deliberately identical to the old behaviour. Callers that build a
	// build_context by hand (probes, tests, the triage harnesses) never call the resolver, and
	// silently returning "" there would DISABLE every feature and read as a checker regression
	// rather than as an unresolved context. Falling back to the microarch defaults keeps those
	// paths exactly as they were, so this change is inert unless the resolver actually ran.
	// get_final_microarchitecture (ported from llvm_backend.cpp:54) already applies the
	// "empty means default" rule. An earlier draft reintroduced that as a second copy of
	// get_default_microarchitecture; deleted -- one implementation, not two.
	return microarch_default_features(get_final_microarchitecture())
}

// #591 STAGE B (#764): the `-define:NAME=VALUE` INPUT.
//
// `build_context.defined_values` was DECLARED and READ -- populate_config_package_scope (wired into
// init_checker in #667) turns each entry into a constant in the config package scope, which is what
// `#config(NAME, default)` resolves against -- but it had ZERO WRITERS. The whole override path was
// therefore correct and unreachable: every `#config` in the tree silently took its default and no
// input could say otherwise. These three procedures are the missing writer.
//
// Errors are RETURNED, never printed or fatal. C++ sets `bad_flags = true` and main() exits; a
// checker library must not exit its host process (#12), and the caller is the only party that knows
// whether a bad define should be fatal.
Define_Error :: enum {
	None,
	Malformed,        // no '=', or an empty name or value  -> "Expected 'name=value', got '%s'"
	Not_Identifier,   // -> "Defined constant name '%s' must be a valid identifier"
	Underscore,       // -> "Defined constant name cannot be an underscore"
	Already_Exists,   // -> "Defined constant '%s' already exists"
	Invalid_Value,    // -> "Invalid define constant value: '%s'. ..."
}

// build_param_looks_like_float decides float-vs-integer for a `-define` value.
// C++ Reference: main.cpp build_param_looks_like_float.
//
// The middle test is the one that is easy to drop and changes behaviour: a leading `0` followed by
// a NON-DIGIT returns false immediately, so `0x1e` is an INTEGER even though it contains an `e`.
// Without it the trailing scan would see that `e` and route a hex literal to the float parser.
build_param_looks_like_float :: proc(param: string) -> bool {
	if strings.contains_rune(param, '.') {
		return true
	}
	i := 0
	if len(param) > 0 && (param[0] == '-' || param[0] == '+') {
		i = 1
	}
	if len(param) > i + 1 && param[i] == '0' && !(param[i + 1] >= '0' && param[i + 1] <= '9') {
		return false
	}
	for ; i < len(param); i += 1 {
		if param[i] == 'e' || param[i] == 'E' {
			return true
		}
	}
	return false
}

// build_param_to_exact_value parses a `-define` VALUE, in C++'s order.
// C++ Reference: main.cpp build_param_to_exact_value.
//
// Order is load-bearing: bools are tested BEFORE numbers, and the numeric attempt FALLS THROUGH to
// the string arm when the parse fails rather than erroring, so `-define:X=1abc` is the string
// "1abc" and not an error. The single-quote form is the documented escape hatch for forcing `true`
// or `123` to be a string, and the quotes are stripped only when BOTH ends carry one.
build_param_to_exact_value :: proc(param: string) -> Exact_Value {
	if len(param) == 0 {
		return nil
	}

	// C++ 575-580: case-INSENSITIVE, and `t`/`f` are accepted as well as the full words.
	if strings.equal_fold(param, "t") || strings.equal_fold(param, "true") {
		return exact_value_bool(true)
	}
	if strings.equal_fold(param, "f") || strings.equal_fold(param, "false") {
		return exact_value_bool(false)
	}

	// C++ 585-594.
	if param[0] == '-' || param[0] == '+' || (param[0] >= '0' && param[0] <= '9') {
		value: Exact_Value
		if build_param_looks_like_float(param) {
			value = exact_value_float_from_string(param)
		} else {
			value = exact_value_integer_from_string(param)
		}
		if value != nil {
			return value
		}
		// Deliberately NOT an error: fall through to the string arm, as C++ does.
	}

	// C++ 600-607.
	if len(param) > 1 && param[0] == '\'' && param[len(param) - 1] == '\'' {
		return exact_value_string(param[1:len(param) - 1])
	}
	return exact_value_string(param)
}

// add_defined_value applies one `-define:NAME=VALUE` argument to build_context.defined_values.
// C++ Reference: main.cpp BuildFlag_Define.
//
// SIX validations in C++'s ORDER, and the order is observable because each one `break`s: only the
// FIRST failure is reported for a given argument. `detail` carries whatever the corresponding C++
// message interpolates -- note that the malformed case interpolates the WHOLE argument, not the
// post-`=` remainder, which is why it is returned rather than reconstructed by the caller.
add_defined_value :: proc(arg: string, allocator := context.allocator) -> (err: Define_Error, detail: string) {
	eq := strings.index_byte(arg, '=')
	if eq < 0 {
		return .Malformed, arg
	}
	name  := arg[:eq]
	value := arg[eq + 1:]
	if len(name) == 0 || len(value) == 0 {
		return .Malformed, arg
	}
	if !is_string_an_identifier(name) {
		return .Not_Identifier, name
	}
	if name == "_" {
		return .Underscore, name
	}
	if _, exists := build_context.defined_values[name]; exists {
		return .Already_Exists, name
	}

	v := build_param_to_exact_value(value)
	if v == nil {
		return .Invalid_Value, value
	}

	if build_context.defined_values == nil {
		build_context.defined_values = make(map[string]ast.Exact_Value, 16, allocator)
	}
	build_context.defined_values[strings.clone(name, allocator)] = v
	return .None, ""
}

// resolve_target_features computes build_context.target_features_set ONCE, reproducing C++'s two
// writers in C++'s order. Idempotent: re-resolving with the same inputs yields the same set, and
// the `resolved` flag is what enabled_target_features() keys off.
//
// C++ REFERENCE, in order:
//   main.cpp:4199-4207  seed from get_default_features() -- the microarch defaults, UNSIGNED
//                       (e.g. "sse2"), added one comma-separated item at a time.
//   main.cpp:4222-4281  for each comma-separated item of `-target-features:`:
//                         - strip a leading '+'/'-' to get the name to VALIDATE
//                         - an unrecognised name is FATAL in C++ (it prints the valid list and
//                           exits 1); here it is reported through `invalid` and the caller decides,
//                           because a checker library must not exit its host process (#12).
//                         - re-attach the sign, defaulting to '+'
//                         - REMOVE the opposite-signed entry, then ADD this one
// The removal is the subtle part and is why a set, not an append, is required: `+f` then `-f` must
// leave ONLY `-f`. target_feature_is_enabled already reads signs correctly (it is a line-for-line
// port of check_target_feature_is_enabled), so the resolved set can hold signed entries directly.
//
// ONE DELIBERATE REPRESENTATIONAL DIFFERENCE, stated with its equivalence argument rather than
// left implicit (#758: a divergence's EXTENT is part of its claim). C++ removes only the
// OPPOSITE-signed entry, so seeding `sse2` and then passing `-sse2` leaves the set holding BOTH
// `sse2` and `-sse2`. This keeps at most ONE entry per feature name -- the last one specified.
// The two are observably identical because the only consumer, check_target_feature_is_enabled,
// answers `(has_plus || has_raw) && !has_minus`:
//   C++ {sse2, -sse2} -> has_raw && has_minus -> false;  here {-sse2} -> has_minus -> false.
//   C++ {sse2, +sse2} -> true;                           here {+sse2} -> true.
//   last-wins holds in both, because a later item always removes what it contradicts.
// If a future consumer ever inspects the set's MEMBERSHIP rather than asking this predicate, the
// difference becomes visible and this note is where to start.
resolve_target_features :: proc(allocator := context.allocator) -> (invalid_feature: string, ok: bool) {
	base := microarch_default_features(get_final_microarchitecture())

	entries: [dynamic]string
	defer delete(entries)

	rest := base
	for item in strings.split_iterator(&rest, ",") {
		if len(item) == 0 {
			continue
		}
		append(&entries, item)
	}

	if len(build_context.target_features_string) > 0 {
		feature_list := target_features_list[build_context.metrics.arch]
		user := build_context.target_features_string
		for item in strings.split_iterator(&user, ",") {
			// C++ 4226: `if (item == "") break;` -- an empty item ENDS the walk rather than being
			// skipped, so "sse2,,aes" drops `aes`. Kept, because it is observable.
			if len(item) == 0 {
				break
			}

			stripped := item
			if stripped[0] == '+' || stripped[0] == '-' {
				stripped = stripped[1:]
			}

			// C++ 4234-4245: `help` and `?` are query forms, not features, and are exempted from
			// validation there. A checker has no list to print, so they are simply not features.
			if stripped != "help" && stripped != "?" {
				if !check_single_target_feature_is_valid(feature_list, stripped) {
					return stripped, false
				}
			}

			signed_item := item
			if item[0] != '+' && item[0] != '-' {
				signed_item = strings.concatenate({"+", item}, allocator)
			}

			// Remove the opposite-signed entry, then add this one (C++ 4269-4279).
			opposite_rest := signed_item[1:]
			for i := 0; i < len(entries); {
				e := entries[i]
				bare := e
				if len(bare) > 0 && (bare[0] == '+' || bare[0] == '-') {
					bare = bare[1:]
				}
				if bare == opposite_rest {
					ordered_remove(&entries, i)
				} else {
					i += 1
				}
			}
			append(&entries, signed_item)
		}
	}

	build_context.target_features_set = strings.join(entries[:], ",", allocator)
	build_context.target_features_resolved = true
	build_context.target_features_resolved_march = get_final_microarchitecture()
	build_context.target_features_resolved_input = build_context.target_features_string
	return "", true
}

// check_target_feature_is_superset_of asks whether every feature in `of` also appears in `superset`,
// reporting the FIRST one that does not.
//
// C++ Reference: build_settings.cpp check_target_feature_is_superset_of
//
// #613: this had no port counterpart at all, which is why the `#force_inline` half of the call-site
// target-feature check could not be ported. C++ needs it because LLVM cannot inline a call whose callee
// enables a SUPERSET of the caller's features -- see check_expr.cpp:9023.
//
// Note it delegates to check_single_target_feature_is_valid, i.e. plain membership. The +/- sign
// handling of target_feature_is_enabled deliberately does NOT apply here: C++ asks the same question.
check_target_feature_is_superset_of :: proc(superset: string, of: string) -> (ok: bool, missing: string) {
	rest := of
	for feature in strings.split_iterator(&rest, ",") {
		if len(feature) == 0 {
			continue
		}
		if !check_single_target_feature_is_valid(superset, feature) {
			return false, feature
		}
	}
	return true, ""
}

// check_single_target_feature_is_valid checks if a single feature is in the feature list
// C++: build_settings.cpp:2038-2050
check_single_target_feature_is_valid :: proc(feature_list: string, feature: string) -> bool {
	if len(feature) == 0 {
		return false
	}

	// Handle +/- prefix
	check_feature := feature
	if len(check_feature) > 0 && (check_feature[0] == '+' || check_feature[0] == '-') {
		check_feature = check_feature[1:]
	}

	// Search in comma-separated list
	pos := 0
	for pos < len(feature_list) {
		// Find next comma or end
		end := pos
		for end < len(feature_list) && feature_list[end] != ',' {
			end += 1
		}

		// Compare feature
		if end - pos == len(check_feature) {
			match := true
			for i := 0; i < len(check_feature); i += 1 {
				if feature_list[pos + i] != check_feature[i] {
					match = false
					break
				}
			}
			if match {
				return true
			}
		}

		// Move to next feature
		pos = end + 1
	}

	return false
}

// check_target_feature_is_valid checks if all features in a comma-separated string are valid for an architecture
// C++: build_settings.cpp:2052-2065
check_target_feature_is_valid :: proc(feature: string, arch: Target_Arch_Kind) -> (valid: bool, invalid_feature: string) {
	feature_list := target_features_list[arch]

	// Split by comma and check each
	pos := 0
	for pos < len(feature) {
		// Find next comma or end
		end := pos
		for end < len(feature) && feature[end] != ',' {
			end += 1
		}

		// Get single feature
		single := feature[pos:end]
		if len(single) > 0 && !check_single_target_feature_is_valid(feature_list, single) {
			return false, single
		}

		// Move to next
		pos = end + 1
	}

	return true, ""
}

// check_target_feature_is_valid_for_target_arch validates features against current build target
// C++: build_settings.cpp:2090-2092
check_target_feature_is_valid_for_target_arch :: proc(feature: string) -> (valid: bool, invalid_feature: string) {
	return check_target_feature_is_valid(feature, build_context.metrics.arch)
}

// check_target_feature_is_valid_globally checks if a feature is valid for ANY architecture
// C++: build_settings.cpp:2067-2088
check_target_feature_is_valid_globally :: proc(feature: string) -> (valid: bool, invalid_feature: string) {
	// Split by comma and check each
	pos := 0
	for pos < len(feature) {
		// Find next comma or end
		end := pos
		for end < len(feature) && feature[end] != ',' {
			end += 1
		}

		// Get single feature
		single := feature[pos:end]
		if len(single) > 0 {
			// Check if valid in any architecture
			valid_somewhere := false
			for arch in Target_Arch_Kind {
				if arch == .Invalid do continue
				if check_single_target_feature_is_valid(target_features_list[arch], single) {
					valid_somewhere = true
					break
				}
			}
			if !valid_somewhere {
				return false, single
			}
		}

		// Move to next
		pos = end + 1
	}

	return true, ""
}

// #611: a note here used to claim "check_target_feature_is_enabled is not implemented here because it
// requires target_features_set ... not available in standalone checker. The backend/LLVM will validate
// enabled features." Every clause of that was false, and it was load-bearing -- it is why the wasm
// atomics gate was never ported. The counterpart IS implemented, as target_feature_is_enabled above
// (C++: build_settings.cpp check_target_feature_is_enabled); the enabled set IS derivable, via
// enabled_target_features(); and deferring to the backend is not available to a CHECKER, whose whole job
// is to reject the program before a backend ever runs.
//
// Compose the two to answer C++'s check_target_feature_is_enabled(feature, nullptr):
//     target_feature_is_enabled("atomics", enabled_target_features())
