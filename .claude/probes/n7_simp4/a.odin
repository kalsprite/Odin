package n7_simp4
Inner :: struct #simple { a: int }
Outer :: struct #simple { i: Inner }
main :: proc() { o: Outer; _ = o }
