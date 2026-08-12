package pgbad

ps :: proc(data: string) -> int { return 0 }
pb :: proc(data: []u8)  -> int { return 1 }
p  :: proc { ps, pb }

main :: proc() {
	DOC :: #load("definitely_missing_file.txt")
	_ = p(DOC)
}
