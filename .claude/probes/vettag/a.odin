#+vet
package vettag

// `main` and not `foo`: cmpfull.py drives the oracle with `odin build`, so a probe without an
// entry point picks up an "undefined entry point" error the port harness cannot produce.
main :: proc() {
	x := 1
}
