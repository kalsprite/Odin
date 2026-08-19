#!/usr/bin/env bash
# Behavioural check: a real debugger, on a real process, answering questions
# whose only possible source is the debug info this package emitted.
#
# Every other instrument compares a dump against an intent. This one asks
# whether the result is USABLE, which is a different question and the one that
# actually matters to clODIN. Two things make it honest:
#
#   * the host's own .debug_* sections are REMOVED and replaced with ours, and
#     the CU describes the host's real code under an invented file name and
#     invented line numbers that appear nowhere else. A right answer has no
#     other source.
#   * the LOCATIONS are not invented. Stack offsets, the frame-base register and
#     the lexical block's range are read out of the host's own debug info and
#     reproduced. A synthesiser that guessed offsets would be testing the guess;
#     reproducing the reference's answer tests the encoding.
#
# The shadowing case is worth stating: the host declares `inner` in a nested
# block, and our CU calls that same storage `n` inside a DW_TAG_lexical_block
# while an outer `n` lives at a different offset. `print n` therefore has two
# right answers depending on where the process is stopped, and only correct
# block scoping produces both.
#
#   gdb-check.sh [--versions "4 5"]
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/../../../.." && pwd)
odin=${ODIN:-$root/odin}
export ODIN_ROOT=${ODIN_ROOT:-$root}

versions="4 5"
while [ $# -gt 0 ]; do
	case "$1" in
		--versions) versions=$2; shift 2 ;;
		*) echo "gdb-check: unknown argument $1"; exit 2 ;;
	esac
done

for tool in clang gdb nm python3 llvm-dwarfdump; do
	if ! command -v "$tool" >/dev/null 2>&1; then
		echo "gdb-check: SKIP -- $tool is not installed, and it is required"
		exit 0
	fi
done
if command -v llvm-objcopy >/dev/null 2>&1; then objcopy_cmd=llvm-objcopy
elif command -v objcopy    >/dev/null 2>&1; then objcopy_cmd=objcopy
else
	echo "gdb-check: SKIP -- neither llvm-objcopy nor objcopy is installed"
	exit 0
fi

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
ok=0; bad=0

check() { # <name> <expected> <actual>
	if [ "$2" = "$3" ]; then
		ok=$((ok + 1)); printf '  ok    %s\n' "$1"
	else
		bad=$((bad + 1))
		printf '  FAIL  %s\n        expected: %s\n        actual:   %s\n' "$1" "$2" "$3"
	fi
}

"$odin" build "$here" -out:"$work/tester" >/dev/null || { echo "gdb-check: FAIL -- could not build the tester"; exit 1; }

# Source lines matter: the extractor below finds breakpoint addresses by the
# host's OWN line numbers, before that information is thrown away.
cat > "$work/host.c" <<'C'
volatile int sink;
int warr[4] = {10, 20, 30, 40};
int *wptr = &warr[1];
union { int i; long l; } wuni = { .i = 5 };
int wenum = 7;
struct { const char *data; long len; } wstr = { "hi", 2 };
struct { union { int i; long l; } u; int tag; } wtagged = { { .i = 5 }, 3 };
typedef struct { int a; long b; } widget_pair;
int widget_probe(int seed) {
	int n = seed * 3;
	widget_pair p;
	p.a = n + 1;
	p.b = n * 2;
	{
		int inner = 777;
		sink += inner;
	}
	sink += p.a + (int)p.b + n;
	return n;
}
int main(void) { return widget_probe(14) == 42 ? 0 : 1; }
C
HOST_LINE_INNER=16   # `sink += inner;`   -- inside the nested block
HOST_LINE_OUTER=18   # `sink += p.a ...;` -- after it

# The invented line numbers our CU uses. Nothing in the host carries these.
OUR_PROBE=41
OUR_INNER=45
OUR_OUTER=47
OUR_MAIN=91

for v in $versions; do
	echo "--- DWARF $v ---"
	clang -gdwarf-"$v" -O0 "$work/host.c" -o "$work/host" 2>/dev/null || {
		echo "gdb-check: FAIL -- could not build the host"; exit 1; }

	llvm-dwarfdump --debug-info "$work/host" > "$work/ref.info" 2>/dev/null
	llvm-dwarfdump --debug-line "$work/host" > "$work/ref.line" 2>/dev/null
	nm -S --defined-only "$work/host" > "$work/ref.nm" 2>/dev/null

	python3 - "$work" "$HOST_LINE_INNER" "$HOST_LINE_OUTER" \
		"$OUR_PROBE" "$OUR_INNER" "$OUR_OUTER" "$OUR_MAIN" > "$work/spec.txt" <<'PY'
import os, re, sys
w, host_inner, host_outer, our_probe, our_inner, our_outer, our_main = \
	sys.argv[1], *[int(x) for x in sys.argv[2:]]

info = open(os.path.join(w, 'ref.info')).read().splitlines()
line = open(os.path.join(w, 'ref.line')).read().splitlines()
nm   = open(os.path.join(w, 'ref.nm')).read().splitlines()

syms = {}
for ln in nm:
	f = ln.split()
	if len(f) == 4:
		syms[f[3]] = (int(f[0], 16), int(f[1], 16))

# Walk the reference DIEs: the frame-base register, the lexical block's range,
# and each variable's frame offset. Indentation is not consulted -- the block's
# range is taken from its own attributes and variables are matched by name.
frame_reg, block_lo, block_hi = None, None, None
var_off, pending, in_block = {}, {}, False
for ln in info:
	if 'DW_TAG_' in ln:
		if 'DW_AT_name' in pending and 'loc' in pending:
			var_off[pending['DW_AT_name']] = pending['loc']
		pending = {}
		if 'DW_TAG_lexical_block' in ln:
			in_block = True
	m = re.search(r'DW_AT_frame_base\s+\(DW_OP_reg(\d+)', ln)
	if m and frame_reg is None: frame_reg = int(m[1])
	m = re.search(r'DW_AT_location\s+\(DW_OP_fbreg\s+(-?\d+)\)', ln)
	if m: pending['loc'] = int(m[1])
	m = re.search(r'DW_AT_name\s+\("([^"]+)"\)', ln)
	if m: pending['DW_AT_name'] = m[1]
	if in_block:
		m = re.search(r'DW_AT_low_pc\s+\(0x([0-9a-f]+)\)', ln)
		if m and block_lo is None: block_lo = int(m[1], 16)
		m = re.search(r'DW_AT_high_pc\s+\(0x([0-9a-f]+)\)', ln)
		if m and block_hi is None: block_hi = int(m[1], 16)
if 'DW_AT_name' in pending and 'loc' in pending:
	var_off[pending['DW_AT_name']] = pending['loc']

def addr_of_line(n):
	for ln in line:
		m = re.match(r'^(0x[0-9a-f]{16})\s+(\d+)\s+\d+\s+\d+\s+\d+\s+\d+\s+\d+\s+(.*)$', ln)
		if m and int(m[2]) == n and 'is_stmt' in m[3]:
			return int(m[1], 16)
	return None

need = {'frame_reg': frame_reg, 'block_lo': block_lo, 'block_hi': block_hi,
        'seed': var_off.get('seed'), 'n': var_off.get('n'),
        'p': var_off.get('p'), 'inner': var_off.get('inner'),
        'inner_addr': addr_of_line(host_inner), 'outer_addr': addr_of_line(host_outer)}
missing = [k for k, val in need.items() if val is None]
if missing:
	print('could not extract: ' + ', '.join(missing), file=sys.stderr)
	sys.exit(1)

pa, ps = syms['widget_probe']
ma, ms = syms['main']
sa, _  = syms['sink']

out = []
out.append(f'func widget_probe {pa:x} {ps} {our_probe}')
out.append(f'fb reg {frame_reg}')
out.append(f'param seed {need["seed"]} int')
out.append(f'var n {need["n"]} int')
out.append(f'var p {need["p"]} pair')
out.append(f'block {block_lo:x} {block_hi:x}')
# The host calls this storage `inner`; our CU calls it `n`, inside the block, so
# the name resolves to two different variables depending on where we stop.
out.append(f'blockvar n {need["inner"]} int')
out.append(f'row {need["inner_addr"]:x} {our_inner}')
out.append(f'row {need["outer_addr"]:x} {our_outer}')
out.append(f'func main {ma:x} {ms} {our_main}')
out.append(f'fb reg {frame_reg}')
out.append(f'global sink {sa:x} int')
# One global per aggregate shape. Globals rather than locals on purpose: their
# addresses come straight from the symbol table, so nothing about these depends
# on having extracted a stack offset correctly.
for name, tid in (('warr', 'arr4'), ('wptr', 'intp'), ('wuni', 'uni'),
                  ('wenum', 'enum'), ('wstr', 'str'), ('wtagged', 'tagged')):
	out.append(f'global {name} {syms[name][0]:x} {tid}')
print('\n'.join(out))
PY

	if [ $? -ne 0 ] || [ ! -s "$work/spec.txt" ]; then
		echo "gdb-check: FAIL -- could not extract the host's own locations"
		exit 1
	fi

	"$objcopy_cmd" \
		--remove-section .debug_str_offsets --remove-section .debug_addr \
		--remove-section .debug_rnglists --remove-section .debug_line_str \
		--remove-section .debug_loclists --remove-section .debug_names \
		--remove-section .debug_ranges --remove-section .debug_aranges \
		--remove-section .debug_loc --remove-section .debug_pubnames \
		--remove-section .debug_pubtypes \
		"$work/host" "$work/stripped" 2>/dev/null || cp "$work/host" "$work/stripped"

	"$work/tester" -emit-cu "$v" "$work/spec.txt" "$work" > "$work/emit.log" || {
		echo "gdb-check: FAIL -- -emit-cu failed"; cat "$work/emit.log"; exit 1; }

	"$objcopy_cmd" \
		--update-section .debug_line="$work/line.bin" \
		--update-section .debug_info="$work/info.bin" \
		--update-section .debug_abbrev="$work/abbrev.bin" \
		--update-section .debug_str="$work/str.bin" \
		"$work/stripped" "$work/patched" || {
		echo "gdb-check: FAIL -- could not inject the sections"; exit 1; }

	if llvm-dwarfdump --verify "$work/patched" > "$work/verify.txt" 2>&1; then
		check "llvm-dwarfdump --verify accepts the unit" "clean" "clean"
	else
		check "llvm-dwarfdump --verify accepts the unit" "clean" \
			"$(grep -m1 -iE 'error' "$work/verify.txt")"
	fi

	probe_addr=$(nm --defined-only "$work/patched" | awk '$3=="widget_probe"{print $1}')
	norm() { python3 -c "import sys; print(hex(int(sys.argv[1], 16)))" "$1"; }
	g() { gdb -batch "$@" "$work/patched" 2>&1; }

	# --- leg one: navigation -------------------------------------------------
	out=$(g -ex "break widget.odin:$OUR_PROBE" -ex "info breakpoints")
	check "break widget.odin:$OUR_PROBE resolves to widget_probe" \
		"in widget_probe at widget.odin:$OUR_PROBE" \
		"$(grep -oE "in widget_probe at widget\.odin:$OUR_PROBE" <<<"$out" | head -1)"
	check "and at its real address" "$(norm "$probe_addr")" \
		"$(norm "$(grep -oE 'Breakpoint 1 at 0x[0-9a-f]+' <<<"$out" | grep -oE '0x[0-9a-f]+' | head -1)")"

	out=$(g -ex "break widget.odin:$OUR_OUTER" -ex run -ex bt)
	check "a backtrace names widget_probe at our line" \
		"#0 widget_probe (seed=14) at widget.odin:$OUR_OUTER" \
		"$(grep -oE "#0 +widget_probe \(seed=14\) at widget\.odin:$OUR_OUTER" <<<"$out" | tr -s ' ' | head -1)"
	check "and its caller frame resolves through our CU to main" "1" \
		"$(grep -cE "^#1 +0x[0-9a-f]+ in main \(\) at widget\.odin:$OUR_MAIN" <<<"$out")"

	# --- leg two: values, types and scope ------------------------------------
	out=$(g -ex "break widget.odin:$OUR_OUTER" -ex run -ex "print n" -ex "print seed" \
	         -ex "print p" -ex "print sink" -ex "ptype p")
	check "print a local int"        '$1 = 42' "$(grep -m1 -oE '\$1 = .*' <<<"$out")"
	check "print a formal parameter" '$2 = 14' "$(grep -m1 -oE '\$2 = .*' <<<"$out")"
	check "print an aggregate local" '$3 = {a = 43, b = 84}' "$(grep -m1 -oE '\$3 = .*' <<<"$out")"
	check "print a global through DW_OP_addr" '$4 = 777' "$(grep -m1 -oE '\$4 = .*' <<<"$out")"
	check "ptype an aggregate through its variable" \
		'type = struct widget_pair { int a; long b; }' \
		"$(sed -n '/^type = struct widget_pair/,/^}/p' <<<"$out" | tr -s ' \n' ' ' | sed 's/ $//')"

	# Under DW_LANG_C99 a struct's name is a C TAG, so the bare name only
	# resolves because the CU also emits a DW_TAG_typedef for it. Asserted
	# separately from the line above: they fail for different reasons.
	out2=$(g -ex "break widget.odin:$OUR_OUTER" -ex run -ex "ptype widget_pair")
	check "ptype the aggregate BY NAME, via its typedef" \
		'type = struct widget_pair { int a; long b; }' \
		"$(sed -n '/^type = struct widget_pair/,/^}/p' <<<"$out2" | tr -s ' \n' ' ' | sed 's/ $//')"

	# --- the rest of the aggregate vocabulary --------------------------------
	out3=$(g -ex "break widget.odin:$OUR_OUTER" -ex run -ex "print warr" -ex "print *wptr" \
	          -ex "print wuni" -ex "print wenum" -ex "print wstr")
	check "print an array, which needs a subrange to have a length" \
		'$1 = {10, 20, 30, 40}' "$(grep -m1 -oE '\$1 = .*' <<<"$out3")"
	check "dereference a pointer, which needs a target type" \
		'$2 = 20' "$(grep -m1 -oE '\$2 = .*' <<<"$out3")"
	check "print a union, whose members share offset 0" \
		'$3 = {i = 5, l = 5}' "$(grep -m1 -oE '\$3 = .*' <<<"$out3")"
	check "print an enum as a NAME, which needs its enumerators" \
		'$4 = W_GREEN' "$(grep -m1 -oE '\$4 = .*' <<<"$out3")"
	# Odin's `string` and `[]T` are this shape: a pointer and a length. The
	# pointer's value is an address, so only the parts we control are asserted.
	check "print a two-word string/slice shape" "1" \
		"$(grep -cE '^\$5 = \{data = 0x[0-9a-f]+ "hi", len = 2\}' <<<"$out3")"

	out4=$(g -ex "break widget.odin:$OUR_OUTER" -ex run -ex "print wtagged" \
	          -ex "print wtagged.u.i" -ex "ptype widget_tagged")
	check "print a tagged-union shape, a struct whose member is an aggregate" \
		'$1 = {u = {i = 5, l = 5}, tag = 3}' "$(grep -m1 -oE '\$1 = .*' <<<"$out4")"
	check "and reach through both levels by name" \
		'$2 = 5' "$(grep -m1 -oE '\$2 = .*' <<<"$out4")"

	# The shadowing case: the same name, two scopes, two different answers.
	out=$(g -ex "break widget.odin:$OUR_INNER" -ex run -ex "print n")
	check "a name in a lexical block resolves to the inner variable" '$1 = 777' \
		"$(grep -m1 -oE '\$1 = .*' <<<"$out")"

	# --- stepping ------------------------------------------------------------
	out=$(g -ex "break widget.odin:$OUR_INNER" -ex run -ex step -ex "info line")
	check "step lands on the next row in our line table" \
		"Line $OUR_OUTER of \"widget.odin\"" \
		"$(grep -oE "Line $OUR_OUTER of \"widget\.odin\"" <<<"$out" | head -1)"
done

echo "gdb-check: $ok assertions passed, $bad failed"
if [ "$bad" -ne 0 ]; then echo "gdb-check: FAIL"; exit 1; fi
echo "gdb-check: PASS"
