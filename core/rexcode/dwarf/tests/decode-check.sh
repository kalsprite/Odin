#!/usr/bin/env bash
# The oracle for `.debug_line`: emit a known program, decode it with readers that
# are NOT ours, and require their answer to equal what the emitter intended.
#
# Run for BOTH DWARF versions this package emits. The two headers are different
# enough -- v5 moved address_size ahead of header_length, replaced two
# NUL-terminated string lists with format-described tables, and renumbered the
# file table from 0 -- that a v4 pass says nothing about v5.
#
# `llvm-dwarfdump --verify` is run too, as a ratchet and not as the check.
# Measured 2026-08-18: a clang object with one byte flipped in its line program
# decodes to line 4294967293 and --verify still exits 0 saying "No errors."
#
# Method: our unit is injected into a real linked executable with objcopy and the
# sequence's base address is fixed up to a real function's address, so the
# readers are doing exactly what they do to a linker's output.
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/../../../.." && pwd)
odin=${ODIN:-$root/odin}
export ODIN_ROOT=${ODIN_ROOT:-$root}

versions=${VERSIONS:-"4 5"}
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
fail=0
skipped=()

need() { command -v "$1" >/dev/null 2>&1; }

for tool in clang llvm-dwarfdump nm python3; do
	if ! need "$tool"; then
		echo "decode-check: SKIP -- $tool is not installed, and it is required"
		exit 0
	fi
done
if need llvm-objcopy; then objcopy_cmd=llvm-objcopy
elif need objcopy;    then objcopy_cmd=objcopy
else
	echo "decode-check: SKIP -- neither llvm-objcopy nor objcopy is installed"
	exit 0
fi

"$odin" build "$here" -out:"$work/tester" >/dev/null || { echo "decode-check: FAIL -- could not build the tester"; exit 1; }
printf 'int f(int x){return x*3;}\nint main(void){return f(2);}\n' > "$work/host.c"

for v in $versions; do
	echo "--- DWARF $v ---"
	# The host carries the matching version so a reader is never asked to hold
	# a v4 CU and a v5 line table at once.
	clang -gdwarf-"$v" -O0 "$work/host.c" -o "$work/host" 2>/dev/null || {
		echo "decode-check: FAIL -- could not build the host"; exit 1; }

	base=$(nm "$work/host" | awk '$3=="main"{print $1; exit}')
	if [ -z "$base" ]; then echo "decode-check: FAIL -- no 'main' in the host"; exit 1; fi

	"$work/tester" -emit "$base" "$work/line.bin" "$v" > "$work/intent.txt" || {
		echo "decode-check: FAIL -- -emit failed"; exit 1; }
	"$objcopy_cmd" --update-section .debug_line="$work/line.bin" "$work/host" "$work/patched" || {
		echo "decode-check: FAIL -- could not inject .debug_line"; exit 1; }

	llvm-dwarfdump --debug-line "$work/patched" > "$work/llvm.txt" 2>&1
	rm -f "$work/binutils.txt" "$work/elfutils.txt"
	if need readelf;    then readelf    --debug-dump=decodedline "$work/patched" > "$work/binutils.txt" 2>/dev/null; else skipped+=("readelf (binutils)"); fi
	if need eu-readelf; then eu-readelf --debug-dump=decodedline "$work/patched" > "$work/elfutils.txt" 2>/dev/null; else skipped+=("eu-readelf (elfutils)"); fi

	python3 - "$work" <<'PY' || fail=1
import os, re, sys
w = sys.argv[1]

FLAGS = (("s","is_stmt"),("p","prologue_end"),("e","epilogue_begin"),("b","basic_block"))

def read(p):
	try:
		return open(os.path.join(w, p)).read().splitlines()
	except FileNotFoundError:
		return None

def parse_intent(path):
	rows = []
	for ln in read(path) or []:
		t = ln.split()
		if not t: continue
		rows.append((int(t[0], 16), 'END') if t[1] == 'END'
		            else (int(t[0], 16), int(t[1]), int(t[2]), int(t[3]), int(t[4]), t[5]))
	return rows

def parse_llvm(path):
	rows = []
	for ln in read(path) or []:
		m = re.match(r'^(0x[0-9a-f]{16})\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s*(.*)$', ln)
		if not m: continue
		addr, flags = int(m[1], 16), m[8]
		if 'end_sequence' in flags:
			rows.append((addr, 'END')); continue
		f = "".join(c for c, name in FLAGS if name in flags) or "-"
		rows.append((addr, int(m[2]), int(m[3]), int(m[4]), int(m[6]), f))
	return rows

def report(name, got, want):
	if got == want:
		print(f'{name:<16}{len(got)} rows, all agree with the emitter')
		return 0
	print(f'MISMATCH -- {name.strip(":")} vs intent')
	for i in range(max(len(got), len(want))):
		a = want[i] if i < len(want) else None
		b = got[i] if i < len(got) else None
		if a != b:
			print(f'  row {i}: intended {a}, decoded {b}')
	return 1

intent = parse_intent('intent.txt')
bad = report('llvm-dwarfdump:', parse_llvm('llvm.txt'), intent)

# elfutils prints S/B/P/E flags and a discriminator, but a file NAME rather than
# a number, so this leg compares everything except the file column. Its
# end_sequence row is printed at the LAST BYTE COVERED rather than the exclusive
# end, one below every other tool -- a display convention, normalised here.
elf = read('elfutils.txt')
if elf is None:
	print('eu-readelf:     not run')
else:
	rows = []
	for ln in elf:
		m = re.match(r'^\s*(\d+):(\d+)\s+([SBPE* ]*?)\s*(\d+)\s+\d+\s+\d+\s+\+?(0x[0-9a-f]+)', ln)
		if not m: continue
		line, col, fl, disc, addr = int(m[1]), int(m[2]), m[3], int(m[4]), int(m[5], 16)
		if '*' in fl:
			rows.append((addr + 1, 'END'))
		else:
			f = "".join(c for c, letter in (("s","S"),("p","P"),("e","E"),("b","B")) if letter in fl) or "-"
			rows.append((addr, line, col, disc, f))
	want = [r if r[1] == 'END' else (r[0], r[1], r[2], r[4], r[5]) for r in intent]
	bad |= report('eu-readelf:', rows, want)

# binutils prints a filename column and no column number, so it is checked on
# (address, line) only -- still an independent decode of the opcode stream.
bin_ = read('binutils.txt')
if bin_ is None:
	print('readelf:        not run')
else:
	rows = []
	for ln in bin_:
		m = re.match(r'^\S+\s+(\d+|-)\s+(0x[0-9a-f]+)', ln)
		if not m: continue
		addr = int(m[2], 16)
		rows.append((addr, 'END') if m[1] == '-' else (addr, int(m[1])))
	want = [(r[0], 'END') if r[1] == 'END' else (r[0], r[1]) for r in intent]
	bad |= report('readelf:', rows, want)

sys.exit(bad)
PY

	# The file TABLE, not just the numbers rows name. Compares the resolved path
	# each number yields, which is the only leg that can see a wrong filename or
	# a right filename under the wrong directory index.
	"$work/tester" -emit-files "$v" > "$work/files.intent" || {
		echo "decode-check: FAIL -- -emit-files failed"; exit 1; }
	python3 - "$work" <<'PY2' || fail=1
import os, re, sys
w = sys.argv[1]

dirs, files, cur = {}, [], None
for ln in open(os.path.join(w, 'llvm.txt')):
	m = re.match(r'^include_directories\[\s*(\d+)\] = "(.*)"', ln)
	if m:
		dirs[int(m[1])] = m[2]; continue
	m = re.match(r'^file_names\[\s*(\d+)\]:', ln)
	if m:
		cur = {'no': int(m[1])}; files.append(cur); continue
	if cur is not None:
		m = re.match(r'^\s*name: "(.*)"', ln)
		if m: cur['name'] = m[1]; continue
		m = re.match(r'^\s*dir_index: (\d+)', ln)
		if m: cur['dir'] = int(m[1]); continue

# A directory index with no entry in the table is v4's "the compilation
# directory", which v4 does not write down; the name stands alone.
got = []
for f in files:
	d = dirs.get(f.get('dir', 0))
	got.append((f['no'], f"{d}/{f['name']}" if d is not None else f['name']))

want = []
for ln in open(os.path.join(w, 'files.intent')):
	no, path = ln.rstrip('\n').split('\t')
	want.append((int(no), path))

if got == want:
	print(f'file table:     {len(got)} entries, paths resolve as intended')
	sys.exit(0)
print('MISMATCH -- file table')
for i in range(max(len(got), len(want))):
	a = want[i] if i < len(want) else None
	b = got[i] if i < len(got) else None
	if a != b: print(f'  entry {i}: intended {a}, decoded {b}')
sys.exit(1)
PY2

	if ! llvm-dwarfdump --verify --debug-line "$work/patched" > "$work/verify.txt" 2>&1; then
		echo "llvm-dwarfdump --verify: FAILED"
		tail -20 "$work/verify.txt"
		fail=1
	else
		echo "llvm-dwarfdump --verify: clean (a ratchet, not the check -- see the header)"
	fi
done

for s in "${skipped[@]:-}"; do
	[ -n "$s" ] && echo "decode-check: NOT RUN -- $s is not installed"
done

if [ "$fail" -ne 0 ]; then echo "decode-check: FAIL"; exit 1; fi
echo "decode-check: PASS"
