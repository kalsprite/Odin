package loadsafe

// each of these asks: is element type T "load safe"?
// C++ is_type_load_safe uses BasicFlag_Boolean|Numeric|Rune, where
// Numeric = Integer|Float|Complex|QUATERNION.
q  := #load("data.bin", []quaternion128)   // Quaternion -> C++ says load-safe
r  := #load("data.bin", []rune)            // Rune       -> C++ says load-safe
le := #load("data.bin", []u32le)           // endian int -> BasicFlag_Integer
ok := #load("data.bin", []u32)             // control: plainly accepted by both

main :: proc() {}
