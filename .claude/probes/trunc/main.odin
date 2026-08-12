package trunc

i := 3

a1 :: proc() { x: int = 1.5;      _ = x }   // direct: expect BOTH reject
a2 :: proc() { x: int = 2.0;      _ = x }   // integral-valued float: ?
a3 :: proc() { x := 1.5 / i;      _ = x }   // the #281 case
a4 :: proc() { x := 2.0 / i;      _ = x }   // integral-valued, division
a5 :: proc() { x := 1.5 * i;      _ = x }   // multiply, not division
a6 :: proc() { x := 1.5 + i;      _ = x }   // add
a7 :: proc() { f := 1.5; x := f / i; _ = x } // typed f64 / int
main :: proc() {}
