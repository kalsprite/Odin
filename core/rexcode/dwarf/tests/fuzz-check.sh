#!/usr/bin/env bash
# Randomised `.debug_line` programs, decoded by a reader that is not ours and
# required to match what the generator intended.
#
# decode-check.sh proves one carefully chosen unit is right. This one goes after
# the interactions -- a file switch on the same row as a negative line advance
# that also crosses the special-opcode boundary -- which is where a state machine
# actually breaks. Programs are emitted many units to a section, so it doubles as
# the check that a unit after the first gets correct section-relative fixups.
#
# A failure prints the SEED and keeps the artifacts. The seed reproduces it
# exactly: the generator's PRNG is written out in fuzz.odin rather than taken
# from the standard library.
#
# Run for BOTH DWARF versions: the generated programs are identical, only the
# header and the file numbering differ, so a disagreement in one version and not
# the other points straight at the version-dependent code.
#
#   fuzz-check.sh [--programs N] [--seed S] [--units-per-batch U] [--versions "4 5"]
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/../../../.." && pwd)
odin=${ODIN:-$root/odin}
export ODIN_ROOT=${ODIN_ROOT:-$root}

programs=5000
seed=1
units=20
versions="4 5"
while [ $# -gt 0 ]; do
	case "$1" in
		--programs) programs=$2; shift 2 ;;
		--seed)     seed=$2;     shift 2 ;;
		--units-per-batch) units=$2; shift 2 ;;
		--versions) versions=$2; shift 2 ;;
		*) echo "fuzz-check: unknown argument $1"; exit 2 ;;
	esac
done

for tool in clang llvm-dwarfdump nm python3; do
	if ! command -v "$tool" >/dev/null 2>&1; then
		echo "fuzz-check: SKIP -- $tool is not installed, and it is required"
		exit 0
	fi
done
if command -v llvm-objcopy >/dev/null 2>&1; then objcopy_cmd=llvm-objcopy
elif command -v objcopy    >/dev/null 2>&1; then objcopy_cmd=objcopy
else
	echo "fuzz-check: SKIP -- neither llvm-objcopy nor objcopy is installed"
	exit 0
fi

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT

"$odin" build "$here" -out:"$work/tester" >/dev/null || { echo "fuzz-check: FAIL -- could not build the tester"; exit 1; }
printf 'int f(int x){return x*3;}\nint main(void){return f(2);}\n' > "$work/host.c"

grand_total=0
fail=0

for v in $versions; do
clang -gdwarf-"$v" -O0 "$work/host.c" -o "$work/host" 2>/dev/null || { echo "fuzz-check: FAIL -- could not build the host"; exit 1; }

total=0
batches=0

while [ "$total" -lt "$programs" ]; do
	batches=$((batches + 1))
	batch_seed=$((seed + batches))
	bin="$work/b.bin"; intent="$work/b.intent"

	n=$("$work/tester" -fuzz "$batch_seed" "$units" "$bin" "$intent" "$v") || {
		echo "fuzz-check: FAIL -- generator failed at seed $batch_seed"; exit 1; }

	"$objcopy_cmd" --update-section .debug_line="$bin" "$work/host" "$work/patched" || {
		echo "fuzz-check: FAIL -- injection failed at seed $batch_seed"; exit 1; }

	llvm-dwarfdump --debug-line "$work/patched" > "$work/decoded.txt" 2>&1

	if ! python3 - "$intent" "$work/decoded.txt" "$batch_seed" <<'PY'
import re, sys
intent_path, decoded_path, seed = sys.argv[1], sys.argv[2], sys.argv[3]

FLAGS = (("s","is_stmt"),("p","prologue_end"),("e","epilogue_begin"),("b","basic_block"))

def parse_intent(path):
	rows = []
	for ln in open(path):
		t = ln.split()
		if not t: continue
		rows.append((int(t[0], 16), 'END') if t[1] == 'END'
		            else (int(t[0], 16), int(t[1]), int(t[2]), int(t[3]), int(t[4]), t[5]))
	return rows

def parse_llvm(path):
	rows = []
	for ln in open(path):
		m = re.match(r'^(0x[0-9a-f]{16})\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s*(.*)$', ln)
		if not m: continue
		addr, flags = int(m[1], 16), m[8]
		if 'end_sequence' in flags:
			rows.append((addr, 'END')); continue
		f = "".join(c for c, name in FLAGS if name in flags) or "-"
		rows.append((addr, int(m[2]), int(m[3]), int(m[4]), int(m[6]), f))
	return rows

intent = parse_intent(intent_path)
decoded = parse_llvm(decoded_path)

if decoded == intent:
	sys.exit(0)

print(f'  MISMATCH at seed {seed}: {len(intent)} rows intended, {len(decoded)} decoded')
shown = 0
for i in range(max(len(intent), len(decoded))):
	a = intent[i] if i < len(intent) else None
	b = decoded[i] if i < len(decoded) else None
	if a != b:
		print(f'    row {i}: intended {a}, decoded {b}')
		shown += 1
		if shown == 10:
			print('    ... (further differences suppressed)')
			break
sys.exit(1)
PY
	then
		fail=$((fail + 1))
		keep=$(mktemp -d -t dwarf-fuzz-XXXXXX)
		cp "$bin" "$intent" "$work/decoded.txt" "$keep/" 2>/dev/null
		echo "  artifacts kept in $keep -- reproduce with: tester -fuzz $batch_seed $units out.bin out.intent $v"
	fi

	total=$((total + n))
done

echo "fuzz-check: DWARF $v -- $total randomised programs over $batches batches"
grand_total=$((grand_total + total))
done

echo "fuzz-check: $grand_total randomised programs in total, $fail with disagreements"
if [ "$fail" -ne 0 ]; then echo "fuzz-check: FAIL"; exit 1; fi
echo "fuzz-check: PASS"
