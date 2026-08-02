package checker

import "core:odin/ast"
import "core:strings"

/*
Build configuration and target platform settings for the checker.

This module provides the build context, target metrics, and compiler flags
that affect type checking behavior. Ported from /mnt/c/odin/src/build_settings.cpp.

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

// C++: build_settings.cpp:396-401
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
	no_threaded_checker:                bool,
	no_rtti:                            bool,
	source_code_location_info:          Source_Code_Location_Info,
	max_error_count:                    int,

	// Target features (CPU feature sets)
	strict_target_features:             bool,
	minimum_os_version_string_given:    bool,

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
	target_triplet = "x86_64-pc-none-msvc",
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
	target_triplet = "arm-unknown-unknown-gnueabihf",
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
	// C++: build_settings.cpp:1750-1802
	metrics := cross_target
	if metrics == nil {
		metrics = default_target_metrics()
	}

	// Check for cross-compilation
	// C++: build_settings.cpp:1804-1808
	if cross_target != nil {
		// For checker, we can't detect host platform at runtime like C++
		// so we assume cross_compiling if a target was explicitly provided
		bc.cross_compiling = true
	}

	// Validate metrics
	// C++: build_settings.cpp:1810-1820
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
	// C++: build_settings.cpp:1822-1830
	bc.metrics = metrics^
	bc.ODIN_OS = target_os_names[metrics.os]
	bc.ODIN_ARCH = target_arch_names[metrics.arch]
	bc.endian_kind = target_endians[metrics.arch]
	bc.ptr_size = i64(metrics.ptr_size)
	bc.int_size = i64(metrics.int_size)
	bc.max_align = i64(metrics.max_align)
	bc.max_simd_align = i64(metrics.max_simd_align)

	// Freestanding defaults
	// C++: build_settings.cpp:1844-1846
	if metrics.os == .Freestanding {
		bc.no_entry_point = true
	}

	// Default Windows subsystem
	// C++: build_settings.cpp:1854-1856
	if bc.ODIN_WINDOWS_SUBSYSTEM == .UNKNOWN && metrics.os == .Windows {
		bc.ODIN_WINDOWS_SUBSYSTEM = .CONSOLE
	}

	// Handle subtargets (iPhone, iPhoneSimulator, Android)
	// C++: build_settings.cpp:1882-1915
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
	// C++: build_settings.cpp:2041-2053. Only darwin has a default; every other target
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
	// C++: build_settings.cpp:2070-2081
	if !bc.custom_optimization_level {
		// C++: when building with `-debug` but no explicit optimization level, default to
		// `-o:none` to improve debug symbol generation.
		bc.optimization_level = bc.ODIN_DEBUG ? -1 : 0
	}
	bc.optimization_level = clamp(bc.optimization_level, -1, 3)

	// Separate modules.
	// C++: build_settings.cpp:2027 (wasm forces it off), 2083-2085 (-o:none/-o:minimal turn
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

	// C++: build_settings.cpp:2114-2121
	bc.ODIN_VALGRIND_SUPPORT = false
	if bc.metrics.os != .Windows && bc.metrics.arch == .Amd64 {
		bc.ODIN_VALGRIND_SUPPORT = true
	}

	// C++: build_settings.cpp:2123-2125
	if bc.metrics.os == .Freestanding {
		bc.ODIN_DEFAULT_TO_NIL_ALLOCATOR = !bc.ODIN_DEFAULT_TO_PANIC_ALLOCATOR
	}
}

// get_default_microarchitecture returns the microarchitecture used when none was requested.
// C++: llvm_backend.cpp:33-52
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
// C++: llvm_backend.cpp:54-63
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

// Target features list per architecture
// Generated from LLVM target features - see misc/featuregen in C++ source
// C++: build_settings_microarch.cpp:27-44
target_features_list := [Target_Arch_Kind]string {
	.Invalid  = "",
	.Amd64    = "16bit-mode,32bit-mode,64bit,64bit-mode,adx,aes,allow-light-256-bit,amx-avx512,amx-bf16,amx-complex,amx-fp16,amx-fp8,amx-int8,amx-movrs,amx-tf32,amx-tile,amx-transpose,avx,avx10.1-256,avx10.1-512,avx10.2-256,avx10.2-512,avx2,avx512bf16,avx512bitalg,avx512bw,avx512cd,avx512dq,avx512f,avx512fp16,avx512ifma,avx512vbmi,avx512vbmi2,avx512vl,avx512vnni,avx512vp2intersect,avx512vpopcntdq,avxifma,avxneconvert,avxvnni,avxvnniint16,avxvnniint8,bmi,bmi2,branch-hint,branchfusion,ccmp,cf,cldemote,clflushopt,clwb,clzero,cmov,cmpccxadd,crc32,cx16,cx8,egpr,enqcmd,ermsb,evex512,f16c,false-deps-getmant,false-deps-lzcnt-tzcnt,false-deps-mulc,false-deps-mullq,false-deps-perm,false-deps-popcnt,false-deps-range,fast-11bytenop,fast-15bytenop,fast-7bytenop,fast-bextr,fast-dpwssd,fast-gather,fast-hops,fast-imm16,fast-lzcnt,fast-movbe,fast-scalar-fsqrt,fast-scalar-shift-masks,fast-shld-rotate,fast-variable-crosslane-shuffle,fast-variable-perlane-shuffle,fast-vector-fsqrt,fast-vector-shift-masks,faster-shift-than-shuffle,fma,fma4,fsgsbase,fsrm,fxsr,gfni,harden-sls-ijmp,harden-sls-ret,hreset,idivl-to-divb,idivq-to-divl,inline-asm-use-gpr32,invpcid,kl,lea-sp,lea-uses-ag,lvi-cfi,lvi-load-hardening,lwp,lzcnt,macrofusion,mmx,movbe,movdir64b,movdiri,movrs,mwaitx,ndd,nf,no-bypass-delay,no-bypass-delay-blend,no-bypass-delay-mov,no-bypass-delay-shuffle,nopl,pad-short-functions,pclmul,pconfig,pku,popcnt,ppx,prefer-128-bit,prefer-256-bit,prefer-mask-registers,prefer-movmsk-over-vtest,prefer-no-gather,prefer-no-scatter,prefetchi,prfchw,ptwrite,push2pop2,raoint,rdpid,rdpru,rdrnd,rdseed,retpoline,retpoline-external-thunk,retpoline-indirect-branches,retpoline-indirect-calls,rtm,sahf,sbb-dep-breaking,serialize,seses,sgx,sha,sha512,shstk,slow-3ops-lea,slow-incdec,slow-lea,slow-pmaddwd,slow-pmulld,slow-shld,slow-two-mem-ops,slow-unaligned-mem-16,slow-unaligned-mem-32,sm3,sm4,soft-float,sse,sse-unaligned-mem,sse2,sse3,sse4.1,sse4.2,sse4a,ssse3,tagged-globals,tbm,tsxldtrk,tuning-fast-imm-vector-shift,uintr,use-glm-div-sqrt-costs,use-slm-arith-costs,usermsr,vaes,vpclmulqdq,vzeroupper,waitpkg,wbnoinvd,widekl,x87,xop,xsave,xsavec,xsaveopt,xsaves,zu",
	.I386     = "16bit-mode,32bit-mode,64bit,64bit-mode,adx,aes,allow-light-256-bit,amx-avx512,amx-bf16,amx-complex,amx-fp16,amx-fp8,amx-int8,amx-movrs,amx-tf32,amx-tile,amx-transpose,avx,avx10.1-256,avx10.1-512,avx10.2-256,avx10.2-512,avx2,avx512bf16,avx512bitalg,avx512bw,avx512cd,avx512dq,avx512f,avx512fp16,avx512ifma,avx512vbmi,avx512vbmi2,avx512vl,avx512vnni,avx512vp2intersect,avx512vpopcntdq,avxifma,avxneconvert,avxvnni,avxvnniint16,avxvnniint8,bmi,bmi2,branch-hint,branchfusion,ccmp,cf,cldemote,clflushopt,clwb,clzero,cmov,cmpccxadd,crc32,cx16,cx8,egpr,enqcmd,ermsb,evex512,f16c,false-deps-getmant,false-deps-lzcnt-tzcnt,false-deps-mulc,false-deps-mullq,false-deps-perm,false-deps-popcnt,false-deps-range,fast-11bytenop,fast-15bytenop,fast-7bytenop,fast-bextr,fast-dpwssd,fast-gather,fast-hops,fast-imm16,fast-lzcnt,fast-movbe,fast-scalar-fsqrt,fast-scalar-shift-masks,fast-shld-rotate,fast-variable-crosslane-shuffle,fast-variable-perlane-shuffle,fast-vector-fsqrt,fast-vector-shift-masks,faster-shift-than-shuffle,fma,fma4,fsgsbase,fsrm,fxsr,gfni,harden-sls-ijmp,harden-sls-ret,hreset,idivl-to-divb,idivq-to-divl,inline-asm-use-gpr32,invpcid,kl,lea-sp,lea-uses-ag,lvi-cfi,lvi-load-hardening,lwp,lzcnt,macrofusion,mmx,movbe,movdir64b,movdiri,movrs,mwaitx,ndd,nf,no-bypass-delay,no-bypass-delay-blend,no-bypass-delay-mov,no-bypass-delay-shuffle,nopl,pad-short-functions,pclmul,pconfig,pku,popcnt,ppx,prefer-128-bit,prefer-256-bit,prefer-mask-registers,prefer-movmsk-over-vtest,prefer-no-gather,prefer-no-scatter,prefetchi,prfchw,ptwrite,push2pop2,raoint,rdpid,rdpru,rdrnd,rdseed,retpoline,retpoline-external-thunk,retpoline-indirect-branches,retpoline-indirect-calls,rtm,sahf,sbb-dep-breaking,serialize,seses,sgx,sha,sha512,shstk,slow-3ops-lea,slow-incdec,slow-lea,slow-pmaddwd,slow-pmulld,slow-shld,slow-two-mem-ops,slow-unaligned-mem-16,slow-unaligned-mem-32,sm3,sm4,soft-float,sse,sse-unaligned-mem,sse2,sse3,sse4.1,sse4.2,sse4a,ssse3,tagged-globals,tbm,tsxldtrk,tuning-fast-imm-vector-shift,uintr,use-glm-div-sqrt-costs,use-slm-arith-costs,usermsr,vaes,vpclmulqdq,vzeroupper,waitpkg,wbnoinvd,widekl,x87,xop,xsave,xsavec,xsaveopt,xsaves,zu",
	.Arm32    = "32bit,8msecext,a12,a15,a17,a32,a35,a5,a53,a55,a57,a7,a72,a73,a75,a76,a77,a78c,a8,a9,aapcs-frame-chain,aclass,acquire-release,aes,armv4,armv4t,armv5t,armv5te,armv5tej,armv6,armv6-m,armv6j,armv6k,armv6kz,armv6s-m,armv6t2,armv7-a,armv7-m,armv7-r,armv7e-m,armv7k,armv7s,armv7ve,armv8-a,armv8-m.base,armv8-m.main,armv8-r,armv8.1-a,armv8.1-m.main,armv8.2-a,armv8.3-a,armv8.4-a,armv8.5-a,armv8.6-a,armv8.7-a,armv8.8-a,armv8.9-a,armv9-a,armv9.1-a,armv9.2-a,armv9.3-a,armv9.4-a,armv9.5-a,armv9.6-a,atomics-32,avoid-movs-shop,avoid-muls,avoid-partial-cpsr,bf16,big-endian-instructions,branch-align-64,cde,cdecp0,cdecp1,cdecp2,cdecp3,cdecp4,cdecp5,cdecp6,cdecp7,cheap-predicable-cpsr,clrbhb,cortex-a510,cortex-a710,cortex-a78,cortex-a78ae,cortex-x1,cortex-x1c,crc,crypto,d32,db,dfb,disable-postra-scheduler,dont-widen-vmovs,dotprod,dsp,execute-only,expand-fp-mlx,exynos,fix-cmse-cve-2021-35465,fix-cortex-a57-aes-1742098,fp-armv8,fp-armv8d16,fp-armv8d16sp,fp-armv8sp,fp16,fp16fml,fp64,fpao,fpregs,fpregs16,fpregs64,fullfp16,fuse-aes,fuse-literals,harden-sls-blr,harden-sls-nocomdat,harden-sls-retbr,hwdiv,hwdiv-arm,i8mm,iwmmxt,iwmmxt2,krait,kryo,lob,long-calls,loop-align,m3,m55,m7,m85,mclass,mp,muxed-units,mve,mve.fp,mve1beat,mve2beat,mve4beat,nacl-trap,neon,neon-fpmovs,neonfp,neoverse-v1,no-branch-predictor,no-bti-at-return-twice,no-movt,no-neg-immediates,noarm,nonpipelined-vfp,pacbti,perfmon,prefer-ishst,prefer-vmovsr,prof-unpr,r4,r5,r52,r52plus,r7,ras,rclass,read-tp-tpidrprw,read-tp-tpidruro,read-tp-tpidrurw,reserve-r9,ret-addr-stack,sb,sha2,slow-fp-brcc,slow-load-D-subreg,slow-odd-reg,slow-vdup32,slow-vgetlni32,slowfpvfmx,slowfpvmlx,soft-float,splat-vfp-neon,strict-align,swift,thumb-mode,thumb2,trustzone,use-mipipeliner,use-misched,v4t,v5t,v5te,v6,v6k,v6m,v6t2,v7,v7clrex,v8,v8.1a,v8.1m.main,v8.2a,v8.3a,v8.4a,v8.5a,v8.6a,v8.7a,v8.8a,v8.9a,v8m,v8m.main,v9.1a,v9.2a,v9.3a,v9.4a,v9.5a,v9.6a,v9a,vfp2,vfp2sp,vfp3,vfp3d16,vfp3d16sp,vfp3sp,vfp4,vfp4d16,vfp4d16sp,vfp4sp,virtualization,vldn-align,vmlx-forwarding,vmlx-hazards,wide-stride-vfp,xscale,zcz",
	.Arm64    = "CONTEXTIDREL2,a320,a35,a510,a520,a520ae,a53,a55,a57,a64fx,a65,a710,a715,a72,a720,a720ae,a73,a75,a76,a77,a78,a78ae,a78c,addr-lsl-slow-14,aes,aggressive-fma,all,alternate-sextload-cvt-f32-pattern,altnzcv,alu-lsl-fast,am,ampere1,ampere1a,ampere1b,amvs,apple-a10,apple-a11,apple-a12,apple-a13,apple-a14,apple-a15,apple-a16,apple-a17,apple-a7,apple-m4,arith-bcc-fusion,arith-cbz-fusion,ascend-store-address,avoid-ldapur,balance-fp-ops,bf16,brbe,bti,call-saved-x10,call-saved-x11,call-saved-x12,call-saved-x13,call-saved-x14,call-saved-x15,call-saved-x18,call-saved-x8,call-saved-x9,carmel,ccdp,ccidx,ccpp,chk,clrbhb,cmp-bcc-fusion,cmpbr,complxnum,cortex-a725,cortex-r82,cortex-r82ae,cortex-x1,cortex-x2,cortex-x3,cortex-x4,cortex-x925,cpa,crc,crypto,cssc,d128,disable-fast-inc-vl,disable-latency-sched-heuristic,disable-ldp,disable-stp,dit,dotprod,ecv,el2vmsa,el3,enable-select-opt,ete,execute-only,exynos-cheap-as-move,exynosm3,exynosm4,f32mm,f64mm,f8f16mm,f8f32mm,falkor,faminmax,fgt,fix-cortex-a53-835769,flagm,fmv,force-32bit-jump-tables,fp-armv8,fp16fml,fp8,fp8dot2,fp8dot4,fp8fma,fpac,fprcvt,fptoint,fujitsu-monaka,fullfp16,fuse-address,fuse-addsub-2reg-const1,fuse-adrp-add,fuse-aes,fuse-arith-logic,fuse-crypto-eor,fuse-csel,fuse-literals,gcs,harden-sls-blr,harden-sls-nocomdat,harden-sls-retbr,hbc,hcx,i8mm,ite,jsconv,kryo,ldp-aligned-only,lor,ls64,lse,lse128,lse2,lsfe,lsui,lut,mec,mops,mpam,mte,neon,neoverse512tvb,neoversee1,neoversen1,neoversen2,neoversen3,neoversev1,neoversev2,neoversev3,neoversev3AE,nmi,no-bti-at-return-twice,no-neg-immediates,no-sve-fp-ld1r,no-zcz-fp,nv,occmo,olympus,oryon-1,outline-atomics,pan,pan-rwv,pauth,pauth-lr,pcdphint,perfmon,pops,predictable-select-expensive,predres,prfm-slc-target,rand,ras,rasv2,rcpc,rcpc-immo,rcpc3,rdm,reserve-lr-for-ra,reserve-x1,reserve-x10,reserve-x11,reserve-x12,reserve-x13,reserve-x14,reserve-x15,reserve-x18,reserve-x2,reserve-x20,reserve-x21,reserve-x22,reserve-x23,reserve-x24,reserve-x25,reserve-x26,reserve-x27,reserve-x28,reserve-x3,reserve-x4,reserve-x5,reserve-x6,reserve-x7,reserve-x9,rme,saphira,sb,sel2,sha2,sha3,slow-misaligned-128store,slow-paired-128,slow-strqro-store,sm4,sme,sme-b16b16,sme-f16f16,sme-f64f64,sme-f8f16,sme-f8f32,sme-fa64,sme-i16i64,sme-lutv2,sme-mop4,sme-tmop,sme2,sme2p1,sme2p2,spe,spe-eef,specres2,specrestrict,ssbs,ssve-aes,ssve-bitperm,ssve-fexpa,ssve-fp8dot2,ssve-fp8dot4,ssve-fp8fma,store-pair-suppress,stp-aligned-only,strict-align,sve,sve-aes,sve-aes2,sve-b16b16,sve-bfscale,sve-bitperm,sve-f16f32mm,sve-sha3,sve-sm4,sve2,sve2-aes,sve2-bitperm,sve2-sha3,sve2-sm4,sve2p1,sve2p2,tagged-globals,the,thunderx,thunderx2t99,thunderx3t110,thunderxt81,thunderxt83,thunderxt88,tlb-rmi,tlbiw,tme,tpidr-el1,tpidr-el2,tpidr-el3,tpidrro-el0,tracev8.4,trbe,tsv110,uaops,use-experimental-zeroing-pseudos,use-fixed-over-scalable-if-equal-cost,use-postra-scheduler,use-reciprocal-square-root,v8.1a,v8.2a,v8.3a,v8.4a,v8.5a,v8.6a,v8.7a,v8.8a,v8.9a,v8a,v8r,v9.1a,v9.2a,v9.3a,v9.4a,v9.5a,v9.6a,v9a,vh,wfxt,xs,zcm-fpr32,zcm-fpr64,zcm-gpr32,zcm-gpr64,zcz,zcz-fp-workaround,zcz-gp",
	.Wasm32   = "atomics,bulk-memory,bulk-memory-opt,call-indirect-overlong,exception-handling,extended-const,fp16,multimemory,multivalue,mutable-globals,nontrapping-fptoint,reference-types,relaxed-simd,sign-ext,simd128,tail-call,wide-arithmetic",
	.Wasm64p32= "atomics,bulk-memory,bulk-memory-opt,call-indirect-overlong,exception-handling,extended-const,fp16,multimemory,multivalue,mutable-globals,nontrapping-fptoint,reference-types,relaxed-simd,sign-ext,simd128,tail-call,wide-arithmetic",
	.Riscv64  = "32bit,64bit,a,andes45,auipc-addi-fusion,b,c,conditional-cmv-fusion,d,disable-latency-sched-heuristic,dlen-factor-2,e,exact-asm,experimental,f,forced-atomics,h,i,ld-add-fusion,log-vrgather,lui-addi-fusion,m,mips-p8700,no-default-unroll,no-sink-splat-operands,no-trailing-seq-cst-fence,optimized-nf2-segment-load-store,optimized-nf3-segment-load-store,optimized-nf4-segment-load-store,optimized-nf5-segment-load-store,optimized-nf6-segment-load-store,optimized-nf7-segment-load-store,optimized-nf8-segment-load-store,optimized-zero-stride-load,predictable-select-expensive,prefer-vsetvli-over-read-vlenb,prefer-w-inst,q,relax,reserve-x1,reserve-x10,reserve-x11,reserve-x12,reserve-x13,reserve-x14,reserve-x15,reserve-x16,reserve-x17,reserve-x18,reserve-x19,reserve-x2,reserve-x20,reserve-x21,reserve-x22,reserve-x23,reserve-x24,reserve-x25,reserve-x26,reserve-x27,reserve-x28,reserve-x29,reserve-x3,reserve-x30,reserve-x31,reserve-x4,reserve-x5,reserve-x6,reserve-x7,reserve-x8,reserve-x9,rva20s64,rva20u64,rva22s64,rva22u64,rva23s64,rva23u64,rvb23s64,rvb23u64,rvi20u32,rvi20u64,save-restore,sdext,sdtrig,sha,shcounterenw,shgatpa,shifted-zextw-fusion,shlcofideleg,short-forward-branch-opt,shtvala,shvstvala,shvstvecd,sifive7,smaia,smcdeleg,smcntrpmf,smcsrind,smdbltrp,smepmp,smmpm,smnpm,smrnmi,smstateen,ssaia,ssccfg,ssccptr,sscofpmf,sscounterenw,sscsrind,ssdbltrp,ssnpm,sspm,ssqosid,ssstateen,ssstrict,sstc,sstvala,sstvecd,ssu64xl,supm,svade,svadu,svbare,svinval,svnapot,svpbmt,svvptc,tagged-globals,unaligned-scalar-mem,unaligned-vector-mem,use-postra-scheduler,v,ventana-veyron,vl-dependent-latency,vxrm-pipeline-flush,xandesbfhcvt,xandesperf,xandesvbfhcvt,xandesvdot,xandesvpackfph,xandesvsintload,xcvalu,xcvbi,xcvbitmanip,xcvelw,xcvmac,xcvmem,xcvsimd,xmipscbop,xmipscmov,xmipslsp,xsfcease,xsfmm128t,xsfmm16t,xsfmm32a16f,xsfmm32a32f,xsfmm32a8f,xsfmm32a8i,xsfmm32t,xsfmm64a64f,xsfmm64t,xsfmmbase,xsfvcp,xsfvfnrclipxfqf,xsfvfwmaccqqq,xsfvqmaccdod,xsfvqmaccqoq,xsifivecdiscarddlone,xsifivecflushdlone,xtheadba,xtheadbb,xtheadbs,xtheadcmo,xtheadcondmov,xtheadfmemidx,xtheadmac,xtheadmemidx,xtheadmempair,xtheadsync,xtheadvdot,xventanacondops,xwchc,za128rs,za64rs,zaamo,zabha,zacas,zalrsc,zama16b,zawrs,zba,zbb,zbc,zbkb,zbkc,zbkx,zbs,zca,zcb,zcd,zce,zcf,zclsd,zcmop,zcmp,zcmt,zdinx,zexth-fusion,zextw-fusion,zfa,zfbfmin,zfh,zfhmin,zfinx,zhinx,zhinxmin,zic64b,zicbom,zicbop,zicboz,ziccamoa,ziccamoc,ziccif,zicclsm,ziccrse,zicntr,zicond,zicsr,zifencei,zihintntl,zihintpause,zihpm,zilsd,zimop,zk,zkn,zknd,zkne,zknh,zkr,zks,zksed,zksh,zkt,zmmul,ztso,zvbb,zvbc,zve32f,zve32x,zve64d,zve64f,zve64x,zvfbfmin,zvfbfwma,zvfh,zvfhmin,zvkb,zvkg,zvkn,zvknc,zvkned,zvkng,zvknha,zvknhb,zvks,zvksc,zvksed,zvksg,zvksh,zvkt,zvl1024b,zvl128b,zvl16384b,zvl2048b,zvl256b,zvl32768b,zvl32b,zvl4096b,zvl512b,zvl64b,zvl65536b,zvl8192b",
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

// Note: check_target_feature_is_enabled is not implemented here because it requires
// target_features_set which is populated by the compiler frontend, not available
// in standalone checker. The backend/LLVM will validate enabled features.
// C++: build_settings.cpp:2094-2118
