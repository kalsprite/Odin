#!/usr/bin/env bash

# #906: the checker library no longer walks up from CWD to find `base/runtime` (#898 removed it,
# because a LIBRARY's answer must not depend on the caller's working directory). Tools that only
# `cd` into the repo were relying on that walk-up BY ACCIDENT and now report "Undeclared name:
# append" -- runtime never loaded. The harness conforms to the library: export the root.
export ODIN_ROOT="${ODIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
# docflag.sh <PORT_BIN> -- gate the doc-output FLAG BITS (#480).
#
# WHY THIS EXISTS. doccmp.sh compares which ENTITIES the doc writer emits; its own header says it
# checks presence. The Doc_Entity_Flag BITS attached to those entities were gated by nothing at
# all, and that gap has now cost four defects:
#
#   #479  Foreign/Export were read from entity flags nothing ever set -- two permanently dead bits.
#   #480  Var_Thread_Local, Builtin_Pkg_Builtin and Builtin_Pkg_Intrinsics were DECLARED and
#         assigned nowhere in the port -- three more.
#
# All six were invisible to every existing gate, because a wrong flag bit produces no diagnostic
# and changes no entity count.
#
# THIS IS A PORT-SIDE GATE. `odin doc` prints rendered documentation, not a bit field, so the bits
# are not directly diffable against the oracle (that needs a reference-side dump, #475). What this
# CAN do is (a) assert the exact expected bits on a probe built for the purpose, (b) assert that
# every bit the port can reach is still reachable, and (c) catch a bit that silently stops firing.
#
# THE REACHABILITY CHECK IS THE LOAD-BEARING ONE. A bit that is never observed anywhere is either
# a genuine gap (#479/#480 shape) or legitimately unreachable from these inputs -- and the two are
# distinguished by the EXPECTED_ABSENT list below, which is a claim that must be justified, not a
# convenience. Anything absent and NOT listed fails the gate.

cd /home/kalsprite/dev/odin || exit 2
PORT="$1"
[ -x "$PORT" ] || { echo "usage: docflag.sh <PORT_BIN>" >&2; exit 2; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
fail=0

# ---- (0) BINARY CONTRACT (#759). This gate requires a triage_st-family binary, because that is
# the one that implements `-dump-doc:<path>` (triage_st/main.odin:102). Handed `triage_doc` -- a
# different tool with a different contract -- every dump below silently fails to appear, the probe
# checks all report `<missing>`, and the reachability check reports EVERY flag as unreachable. That
# is exactly what happened, and it read as sixteen dead bits in the checker rather than as one
# wrong argument. #621 is the same lesson on parity_vet (the plain harness passed where the vet
# harness was required), and it is the second time a gate has been fed the wrong binary. REFUSE.
"$PORT" .claude/tools/docflag_probe -dump-doc:"$TMP/contract.txt" >/dev/null 2>&1
if [ ! -s "$TMP/contract.txt" ]; then
	echo "DOCFLAG-ABORTED '$PORT' produced no doc dump for -dump-doc: -- this gate needs a" >&2
	echo "  triage_st-family binary (odin build .claude/tools/triage_st). NOTHING WAS MEASURED." >&2
	exit 2
fi

# ---- (1) POSITIVE + NEGATIVE CONTROL on the dedicated probe --------------------------------
# plain_proc matters as much as the other three: without a declaration that must come back with
# NO bits, a bug that sets every bit unconditionally would pass all of them.
"$PORT" .claude/tools/docflag_probe -dump-doc:"$TMP/probe.txt" >/dev/null 2>&1
expect_probe() {
	local name="$1" want="$2"
	local got
	got=$(grep -P "^doc\t$name\t" "$TMP/probe.txt" | head -1 | grep -o 'flags=.*')
	if [ "$got" = "flags=$want" ]; then
		echo "  OK   $name -> $want"
	else
		echo "  FAIL $name -> expected 'flags=$want', got '${got:-<missing>}'"; fail=1
	fi
}
echo "PROBE (docflag_probe):"
expect_probe exported_proc     Export
expect_probe exported_var      Export
expect_probe plain_proc        -            # negative control
expect_probe some_foreign_proc Foreign

# ---- (2) REACHABILITY across a spread of real packages -------------------------------------
# core/simd and base:intrinsics-heavy packages cover the Builtin_Pkg pair in BOTH directions;
# core/c/libc covers foreign variables alongside foreign procedures (#483's A/B target).
PKGS="core/simd core/fmt core/c/libc core/strings core/os"
# The probe counts as an input: it is where Export and several param bits are reachable at all.
cp "$TMP/probe.txt" "$TMP/all.txt"
for p in $PKGS; do
	"$PORT" "$p" -dump-doc:"$TMP/one.txt" >/dev/null 2>&1 && cat "$TMP/one.txt" >> "$TMP/all.txt"
done
grep -o 'flags=[^ ]*' "$TMP/all.txt" | tr '|' '\n' | sed 's/flags=//' | sort -u | grep -v '^-$' > "$TMP/seen.txt"

# Every Doc_Entity_Flag member, read from the source so the gate cannot go stale against it.
sed -n '/^Doc_Entity_Flag :: enum u64 {/,/^}/p' core/odin/checker/docs_writer.odin |
	grep -oP '^\t\K[A-Za-z_]+' | sort -u > "$TMP/declared.txt"

# Bits legitimately not reachable from these inputs. EACH ONE NEEDS A REASON.
#   Param_Auto_Cast  -- declared in BOTH implementations and assigned in NEITHER. C++
#                       docs_format.cpp:225 declares OdinDocEntityFlag_Param_AutoCast and nothing
#                       in src/ sets it -- there is no EntityFlag_AutoCast and no `if` for it at
#                       all. Flagging it would report a shared non-feature.
#                       (#477 refined this: the PORT used to carry an invented EntityFlag
#                       Auto_Cast plus an invented read of it here. Both are gone; the bit was
#                       unsettable either way, so removing them changed no output.)
#   Var_Static       -- VERIFIED unreachable through the doc writer, in BOTH implementations, and
#                       for a structural reason rather than a gap. Entity_Flag.Static is set ONLY
#                       in STATEMENT context -- check_stmt.odin:3111/3138, mirroring
#                       check_stmt.cpp:2262/2280 -- i.e. on local variables inside procedure
#                       bodies. DECLARATION context explicitly CLEARS it (check_decl.odin:250,
#                       check_decl.cpp:1709). The doc writer emits declaration-context entities,
#                       so the two never meet. Same category as Param_Auto_Cast: a shared
#                       non-feature, not a port defect. Probe declares a proc-local @(static)
#                       anyway, so if that ever changes the bit will appear and this entry will
#                       start looking wrong -- which is the intent.
cat > "$TMP/expected_absent.txt" <<'EOF'
Param_Auto_Cast
Var_Static
EOF
sort -u "$TMP/expected_absent.txt" -o "$TMP/expected_absent.txt"

echo
echo "REACHABILITY over: $PKGS"
comm -23 "$TMP/declared.txt" "$TMP/seen.txt" > "$TMP/absent.txt"
unexplained=$(comm -23 "$TMP/absent.txt" "$TMP/expected_absent.txt")
echo "  bits observed:   $(tr '\n' ' ' < "$TMP/seen.txt")"
echo "  bits absent:     $(tr '\n' ' ' < "$TMP/absent.txt")"
if [ -n "$unexplained" ]; then
	echo "  FAIL unreachable and unexplained: $(echo "$unexplained" | tr '\n' ' ')"
	echo "       Either the bit stopped firing, or it is newly unexercised and needs a reason."
	fail=1
else
	echo "  OK   every absent bit is on the justified list"
fi

# ---- (3) DETERMINISM -- the dump must not vary run to run ----------------------------------
# #484: the doc writer had an item-tracker overflow that was ~80% and is now ~1-3%, so a varying
# dump is a live hazard rather than a hypothetical one.
# #757 CHANGED THIS TO CAPTURE STDOUT, AND #759 REVERTS THAT: #757's root cause was WRONG.
# `-dump-doc:` IS a real flag -- on `triage_st` (triage_st/main.odin:102), which is the binary this
# gate takes. I diagnosed it against `triage_doc`, which is a DIFFERENT tool with a different
# contract (`<package-path>...`, prints `ENTITY <Kind> <Name>` to stdout and carries no flags at
# all), because that is the binary I happened to be invoking the gate with. Running the gate with
# the wrong binary produced "no dump", and reading the wrong tool's source explained it perfectly.
# Two wrongs that agreed. The stdout capture #757 installed would have compared triage_st's
# DIAGNOSTIC output, not its doc dump -- a determinism check on the wrong stream.
"$PORT" core/strings -dump-doc:"$TMP/d1.txt" >/dev/null 2>&1
"$PORT" core/strings -dump-doc:"$TMP/d2.txt" >/dev/null 2>&1
echo
# EXISTENCE BEFORE COMPARISON (#228). A missing or empty dump is an ABORT -- the tool produced
# nothing and the comparison is not a measurement -- and must never be reported as a difference.
if [ ! -s "$TMP/d1.txt" ] || [ ! -s "$TMP/d2.txt" ]; then
	echo "DETERMINISM: ABORTED (core/strings produced no dump -- NOT a determinism result)"; fail=1
elif cmp -s "$TMP/d1.txt" "$TMP/d2.txt"; then
	echo "DETERMINISM: OK (core/strings byte-identical across 2 runs)"
else
	echo "DETERMINISM: FAIL (core/strings differs between runs -- see #484)"; fail=1
fi

echo
[ $fail -eq 0 ] && echo "DOCFLAG-DONE: all checks passed" || echo "DOCFLAG-FAILED"
exit $fail
