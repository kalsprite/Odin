package enumbacking
E :: enum u8 { A = 300, B }
F :: enum string { A }
main :: proc() { _ = E.A; _ = F.A }
