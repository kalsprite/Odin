package cidxslice

// #698. Indexing a CONSTANT SLICE with a CONSTANT index. The port rejected this outright with
// "Cannot index a constant 'A'" plus a suggestion about variable indices that did not apply.
// A constant ARRAY (B) and a constant STRING (C) were never affected, because both have a static
// length and so take check_index_value's `max_count >= 0` arm; a slice's length is not static, so
// max_count is -1 and only the else arm -- which the port did not have -- writes the index.
//
// The assignment to `string` is a forcing device: it makes the checker PRINT the resolved type of
// each index expression, so this member locks in that all three resolve rather than merely that
// they are accepted. Pre-fix the first row read "Cannot index a constant"; post-fix all three read
// "Cannot assign value ... of type 'int'/'u8'".
A :: []int{10, 20, 30, 40}
B :: [4]int{10, 20, 30, 40}
C :: "abcd"

f :: proc() {
	x: string = A[3]
	y: string = B[3]
	z: string = C[3]
	_, _, _ = x, y, z
}

main :: proc() {
	f()
}
