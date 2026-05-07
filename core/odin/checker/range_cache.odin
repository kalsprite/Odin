package checker

/*
RangeCache tracks which indices and ranges have been initialized in indexed array literals.
Used to detect duplicate indices and overlapping ranges.

Reference: /mnt/c/odin/src/range_cache.cpp
*/

// Range_Value represents a contiguous range of indices [lo, hi] inclusive
// C++ Reference: range_cache.cpp:3-6
Range_Value :: struct {
	lo: i64,
	hi: i64,
}

// Range_Cache tracks initialized indices/ranges in array literals
// C++ Reference: range_cache.cpp:8-10
Range_Cache :: struct {
	ranges: [dynamic]Range_Value,
}

// range_cache_make creates a new RangeCache
// C++ Reference: range_cache.cpp:13-17
range_cache_make :: proc() -> Range_Cache {
	cache := Range_Cache{}
	cache.ranges = make([dynamic]Range_Value)
	return cache
}

// range_cache_destroy frees the RangeCache resources
// C++ Reference: range_cache.cpp:19-21
range_cache_destroy :: proc(c: ^Range_Cache) {
	delete(c.ranges)
}

// range_cache_add_index adds a single index to the cache
// Returns true if the index is new, false if it overlaps with existing range
// C++ Reference: range_cache.cpp:23-33
range_cache_add_index :: proc(c: ^Range_Cache, index: i64) -> bool {
	// Check if index already covered by an existing range
	for v in c.ranges {
		if v.lo <= index && index <= v.hi {
			return false // Index already exists
		}
	}

	// Add new single-element range
	v := Range_Value{index, index}
	append(&c.ranges, v)
	return true
}

// range_cache_add_range adds a range [lo, hi] to the cache
// Returns true if the range is completely new, false if it overlaps with existing range
// C++ Reference: range_cache.cpp:36-59
range_cache_add_range :: proc(c: ^Range_Cache, lo: i64, hi: i64) -> bool {
	assert(lo <= hi, "Range lo must be <= hi")

	// Check for overlap with existing ranges
	for &v in c.ranges {
		// Check if ranges don't overlap
		if hi < v.lo {
			continue // New range is entirely before this range
		}
		if lo > v.hi {
			continue // New range is entirely after this range
		}

		// Ranges overlap! Merge them and return false
		// C++ Reference: range_cache.cpp:47-54
		if v.hi < hi {
			v.hi = hi
		}
		if lo < v.lo {
			v.lo = lo
		}
		return false
	}

	// No overlap found, add new range
	v := Range_Value{lo, hi}
	append(&c.ranges, v)
	return true
}
