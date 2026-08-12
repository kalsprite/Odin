#+vet unused
package filevet

// This file opts INTO vet via the #+vet tag. Checked WITHOUT a global -vet,
// the unused local below should still be reported if per-file vet flags work.
f :: proc() {
	tagged_unused := 42
}

main :: proc() {}
