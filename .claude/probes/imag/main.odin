package imag
// If `3i` is stored as the REAL number 3, real(3i)==3 and imag(3i)==0.
// If it is stored correctly, real(3i)==0 and imag(3i)==3.
// This cannot be explained by how a dump RENDERS a value -- it is the value itself.
X :: 3i
#assert(real(X) == 0)
#assert(imag(X) == 3)
main :: proc() {}
