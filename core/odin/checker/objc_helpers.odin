package checker

/*
Objective-C helper functions and global state for checker

This file contains utilities for Objective-C method validation and metadata management.
*/

import "core:sync"

// global_type_name_objc_metadata_mutex protects Type_Name_ObjC_Metadata creation
// C++ Reference: entity.cpp:141 - BlockingMutex global_type_name_objc_metadata_mutex
global_type_name_objc_metadata_mutex: sync.Mutex

// create_type_name_objc_metadata creates and initializes Objective-C class metadata
// C++ Reference: entity.cpp:153-159
create_type_name_objc_metadata :: proc(allocator := context.allocator) -> ^Type_Name_ObjC_Metadata {
	md := new(Type_Name_ObjC_Metadata, allocator)
	md.type_entries = make([dynamic]Type_Name_ObjC_Metadata_Entry, allocator)
	md.value_entries = make([dynamic]Type_Name_ObjC_Metadata_Entry, allocator)
	return md
}
