package p585a
Color :: enum{R, G, B}
S :: "hello"
A :: [4]int{10, 20, 30, 40}
E :: [Color]int{.R = 1, .G = 2, .B = 3}
R :: [4]int{0..=1 = 7, 2..=3 = 9}
CA :: S[1]
CB :: A[2]
CC :: E[.G]
CD :: R[3]
main :: proc() {
	#assert(CA == 'e')
	#assert(CB == 30)
	#assert(CC == 2)
	#assert(CD == 9)
}
