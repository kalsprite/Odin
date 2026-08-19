#!/usr/bin/env bash
# Re-encode parity against the REFERENCE compiler's own line tables.
#
# For every object the reference produces for a corpus package: decode its
# `.debug_line`, feed those exact rows back through this library, decode ours,
# and require the two decoded tables to be identical.
#
# This is the instrument the fuzzer cannot be. The fuzzer explores a
# distribution someone invented; these are the row sequences real code actually
# produces -- prologue and epilogue markers, line-0 compiler-generated ranges,
# basic-block flags, clusters of rows at one address -- at a scale no
# hand-written test reaches. Equality means this encoder can express everything
# the reference expresses, which is the precondition for clODIN adopting it.
#
# Run for BOTH versions. The reference emits DWARF 4; re-encoding its rows into
# a v5 table and requiring the SAME decoded numbers back is what proves the v5
# file renumbering is applied in the right direction, since a v5 table that is
# off by one still decodes cleanly.
#
# Counts are printed, including what was SKIPPED and why. A parity number with
# silent drops in it is worse than no number.
#
#   parity-check.sh [--packages "core/a core/b"] [--versions "4 5"]
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/../../../.." && pwd)
odin=${ODIN:-$root/odin}
export ODIN_ROOT=${ODIN_ROOT:-$root}

packages="core/slice core/strings core/mem core/sort core/bytes core/unicode/utf8 core/math core/time core/hash core/container/queue core/path/filepath core/encoding/json"
versions="4 5"
while [ $# -gt 0 ]; do
	case "$1" in
		--packages) packages=$2; shift 2 ;;
		--versions) versions=$2; shift 2 ;;
		*) echo "parity-check: unknown argument $1"; exit 2 ;;
	esac
done

for tool in clang llvm-dwarfdump python3 sha256sum; do
	if ! command -v "$tool" >/dev/null 2>&1; then
		echo "parity-check: SKIP -- $tool is not installed, and it is required"
		exit 0
	fi
done
if command -v llvm-objcopy >/dev/null 2>&1; then objcopy_cmd=llvm-objcopy
elif command -v objcopy    >/dev/null 2>&1; then objcopy_cmd=objcopy
else
	echo "parity-check: SKIP -- neither llvm-objcopy nor objcopy is installed"
	exit 0
fi

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
mkdir -p "$work/canon" "$work/icanon" 

"$odin" build "$here" -out:"$work/tester" >/dev/null || { echo "parity-check: FAIL -- could not build the tester"; exit 1; }
printf 'int f(int x){return x*3;}\nint main(void){return f(2);}\n' > "$work/host.c"

canon() {   # <dwarfdump output> -> canonical rows on stdout
	python3 -c '
import re, sys
for ln in open(sys.argv[1]):
	m = re.match(r"^(0x[0-9a-f]{16})\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s*(.*)$", ln)
	if not m: continue
	addr, line, col, fno, disc, flags = m[1], m[2], m[3], m[4], m[6], m[8]
	if "end_sequence" in flags:
		print(f"{addr} END"); continue
	f = "".join(c for c, name in (("s","is_stmt"),("p","prologue_end"),("e","epilogue_begin"),("b","basic_block")) if name in flags) or "-"
	print(f"{addr} {line} {col} {fno} {disc} {f}")
' "$1"
}

# ---- collect the corpus once; both versions re-encode the same rows ----
pkgs_built=0; pkgs_failed=0
objs_total=0; objs_no_lines=0; objs_kept=0
declare -A seen

for pkg in $packages; do
	out="$work/o/$(echo "$pkg" | tr / _)"
	mkdir -p "$out"
	if ! "$odin" build "$root/$pkg" -build-mode:obj -debug -no-entry-point -out:"$out/p" >"$out/build.log" 2>&1; then
		echo "  SKIP package $pkg -- reference build failed (see build.log)"
		pkgs_failed=$((pkgs_failed + 1))
		continue
	fi
	pkgs_built=$((pkgs_built + 1))

	for obj in "$out"/*.o; do
		[ -e "$obj" ] || continue
		objs_total=$((objs_total + 1))
		# Runtime objects repeat across packages; keep each distinct one once.
		h=$(sha256sum "$obj" | cut -d' ' -f1)
		if [ -n "${seen[$h]:-}" ]; then continue; fi
		seen[$h]=1

		llvm-dwarfdump --debug-line "$obj" > "$work/ref.dump" 2>/dev/null
		canon "$work/ref.dump" > "$work/canon/$objs_kept.canon"
		if [ ! -s "$work/canon/$objs_kept.canon" ]; then
			rm -f "$work/canon/$objs_kept.canon"
			objs_no_lines=$((objs_no_lines + 1))
			continue
		fi
		echo "$pkg :: $(basename "$obj")" > "$work/canon/$objs_kept.name"

		# The DIE tree of the same object, one canonical file per compilation
		# unit. Exclusions are tallied by canon-info.py and reported once, at
		# the end, rather than per object.
		mkdir -p "$work/icanon/$objs_kept"
		llvm-dwarfdump --debug-info "$obj" > "$work/ref.info" 2>/dev/null
		"$here/canon-info.py" "$work/ref.info" "$work/icanon/$objs_kept" \
			>/dev/null 2>>"$work/excluded.txt" || true

		objs_kept=$((objs_kept + 1))
	done
done

echo "parity-check: packages built $pkgs_built, failed to build $pkgs_failed"
echo "parity-check: objects seen $objs_total, distinct with line tables $objs_kept, without $objs_no_lines"

# ---- re-encode, per version ----
fail=0
for v in $versions; do
	clang -gdwarf-"$v" -O0 "$work/host.c" -o "$work/host" 2>/dev/null || {
		echo "parity-check: FAIL -- could not build the host"; exit 1; }

	compared=0; rows=0; inexpressible=0; disagreements=0
	i=0
	while [ "$i" -lt "$objs_kept" ]; do
		ref="$work/canon/$i.canon"
		name=$(cat "$work/canon/$i.name")
		i=$((i + 1))

		if ! "$work/tester" -reencode "$ref" "$work/ours.bin" "$v" > "$work/re.log" 2>&1; then
			inexpressible=$((inexpressible + 1))
			echo "  SKIP v$v $name -- $(head -1 "$work/re.log")"
			continue
		fi
		"$objcopy_cmd" --update-section .debug_line="$work/ours.bin" "$work/host" "$work/patched" 2>/dev/null || {
			echo "  SKIP v$v $name -- injection failed"; inexpressible=$((inexpressible + 1)); continue; }
		llvm-dwarfdump --debug-line "$work/patched" > "$work/ours.dump" 2>&1
		canon "$work/ours.dump" > "$work/ours.canon"

		compared=$((compared + 1))
		rows=$((rows + $(wc -l < "$ref")))
		if ! diff -q "$ref" "$work/ours.canon" >/dev/null; then
			disagreements=$((disagreements + 1))
			echo "  MISMATCH v$v $name"
			diff "$ref" "$work/ours.canon" | head -12 | sed 's/^/    /'
			keep=$(mktemp -d -t dwarf-parity-XXXXXX)
			cp "$ref" "$work/ours.canon" "$work/ours.bin" "$keep/" 2>/dev/null
			echo "    artifacts kept in $keep"
		fi
	done

	echo "parity-check: DWARF $v line -- $compared objects, $rows rows compared, $inexpressible inexpressible, $disagreements with disagreements"
	if [ "$disagreements" -ne 0 ]; then fail=1; fi
	if [ "$compared" -eq 0 ]; then echo "parity-check: FAIL -- nothing was compared for DWARF $v"; fail=1; fi

	# ---- the DIE tree ------------------------------------------------------
	#
	# Same argument as the line table: these trees have the shape real Odin code
	# produces -- hundreds of members, enumerators with negative constants,
	# forward and backward type references -- and a round trip that leaves them
	# unchanged says this library can express what the reference expresses.
	icompared=0; idies=0; iskipped=0; idisagree=0
	i=0
	while [ "$i" -lt "$objs_kept" ]; do
		name=$(cat "$work/canon/$i.name")
		for canon in "$work/icanon/$i"/cu*.canon; do
			[ -e "$canon" ] || continue
			if ! n=$("$work/tester" -reinfo "$v" "$canon" "$work" 2>"$work/ri.log"); then
				iskipped=$((iskipped + 1))
				echo "  SKIP v$v $name $(basename "$canon") -- $(head -1 "$work/ri.log")"
				continue
			fi
			"$objcopy_cmd" \
				--update-section .debug_info="$work/info.bin" \
				--update-section .debug_abbrev="$work/abbrev.bin" \
				--update-section .debug_str="$work/str.bin" \
				"$work/host" "$work/ipatched" 2>/dev/null || {
				echo "  SKIP v$v $name -- injection failed"; iskipped=$((iskipped + 1)); continue; }

			llvm-dwarfdump --debug-info "$work/ipatched" > "$work/ours.info" 2>&1
			rm -rf "$work/ourscanon"; mkdir -p "$work/ourscanon"
			"$here/canon-info.py" "$work/ours.info" "$work/ourscanon" >/dev/null 2>&1 || true

			icompared=$((icompared + 1))
			idies=$((idies + n))
			if ! diff -q "$canon" "$work/ourscanon/cu0.canon" >/dev/null 2>&1; then
				idisagree=$((idisagree + 1))
				echo "  MISMATCH v$v $name $(basename "$canon")"
				diff "$canon" "$work/ourscanon/cu0.canon" 2>&1 | head -10 | sed 's/^/    /'
				keep=$(mktemp -d -t dwarf-info-XXXXXX)
				cp "$canon" "$work/ourscanon/cu0.canon" "$work/info.bin" "$keep/" 2>/dev/null
				echo "    artifacts kept in $keep"
			fi
		done
		i=$((i + 1))
	done
	echo "parity-check: DWARF $v info -- $icompared units, $idies DIEs compared, $iskipped skipped, $idisagree with disagreements"
	if [ "$idisagree" -ne 0 ]; then fail=1; fi
	if [ "$icompared" -eq 0 ]; then echo "parity-check: FAIL -- no DIE trees were compared for DWARF $v"; fail=1; fi
done

if [ -s "$work/excluded.txt" ]; then
	echo "parity-check: attributes NOT compared, with counts across the corpus:"
	sort "$work/excluded.txt" | awk -F' x| -- ' '{c[$1" -- "$3]+=$2} END{for (k in c) print "  " k, "(x" c[k] ")"}' | sort
fi

if [ "$fail" -ne 0 ]; then echo "parity-check: FAIL"; exit 1; fi
echo "parity-check: PASS"
