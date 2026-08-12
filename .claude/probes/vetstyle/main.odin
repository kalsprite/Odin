#+vet style
package vetstyle

// Under -vet-style (or a #+vet style file tag) the strict parser rejects a
// brace on the following line for a procedure body.
f :: proc()
{
}

main :: proc() {}
