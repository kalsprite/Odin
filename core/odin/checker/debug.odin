package checker

/*
Debug logging utilities for the checker.

This module provides debug logging functions that are controlled by
build_context.show_debug_messages flag.

C++ Reference: main.cpp:44-56
*/

import "core:fmt"
import "core:sync"

// Global mutex for thread-safe debug output
// C++: main.cpp:44
@(private = "file")
debugf_mutex: sync.Mutex

// debugf prints a debug message to stderr if show_debug_messages is enabled
// C++: main.cpp:46-56
debugf :: proc(format: string, args: ..any) {
	if build_context.show_debug_messages {
		sync.lock(&debugf_mutex)
		defer sync.unlock(&debugf_mutex)

		// Write to stderr
		fmt.eprint("[DEBUG] ")
		fmt.eprintf(format, ..args)
	}
}

// debugf_no_prefix prints a debug message without the [DEBUG] prefix
debugf_no_prefix :: proc(format: string, args: ..any) {
	if build_context.show_debug_messages {
		sync.lock(&debugf_mutex)
		defer sync.unlock(&debugf_mutex)

		fmt.eprintf(format, ..args)
	}
}

// debug_println prints a debug line to stderr if show_debug_messages is enabled
debug_println :: proc(args: ..any) {
	if build_context.show_debug_messages {
		sync.lock(&debugf_mutex)
		defer sync.unlock(&debugf_mutex)

		fmt.eprint("[DEBUG] ")
		fmt.eprintln(..args)
	}
}

// debug_entity_type prints entity name and type for debugging
debug_entity_type :: proc(prefix: string, e: ^Entity) {
	if build_context.show_debug_messages {
		// Formatted outside the lock on purpose. type_to_string walks arbitrary checker
		// types and asserts on malformed ones; an assertion ends the thread through
		// runtime.trap() without unwinding, so doing this while holding debugf_mutex
		// would leave the mutex locked and hang every other thread that logs afterwards.
		// The lock only needs to cover the write.
		type_str := e.type != nil ? type_to_string(e.type) : "<nil type>"

		sync.lock(&debugf_mutex)
		defer sync.unlock(&debugf_mutex)

		fmt.eprintf("[DEBUG] %s %s :: %s\n", prefix, e.token.text, type_str)
	}
}
