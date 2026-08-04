package declcycle
A :: struct { b: B }
B :: struct { a: A }
main :: proc() {}
