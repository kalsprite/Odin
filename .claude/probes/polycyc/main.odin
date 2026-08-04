package polycyc

Object :: struct { isa: rawptr }

// The polymorphic parameter T is NEVER used in the body -- Copying(X) does not
// embed X for any X. So `Array` below is not actually self-referential.
Copying :: struct($T: typeid) { using _: Object }

Array :: struct { using _: Copying(Array) }

main :: proc() {}
