package declcycle3
X :: struct { y: Y }
Y :: struct { z: Z }
Z :: struct { x: X }
main :: proc() {}
