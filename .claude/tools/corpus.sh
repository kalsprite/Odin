#!/usr/bin/env bash
# corpus.sh <PORT_BIN> [PROBE_ROOT] -- run cmpfull.py over the CURATED probe corpus.
#
# WHY THIS EXISTS. The corpus was previously "every directory in the scratchpad that contains a
# .odin file", reconstructed by hand each time. That is not a corpus, it is a guess, and on
# 2026-08-03 it silently swept in eleven directories that were never probes: Foundation bisect
# scratch from #277, C-style-type scratch from #261, and four vet-mode probes that need the
# -vet harness. They reported FULL-DIFFER, which looks exactly like a regression. It took a
# run of the PRE-change binary to show all eleven differed identically before the change.
#
# The membership list below is therefore explicit, and every exclusion is NAMED WITH ITS REASON.
# An excluded probe is an UNMEASURED probe, not a clean one -- the exclusions are printed.
#
# Add a probe by adding its directory name to CORPUS. Do not re-derive this list from a glob.

set -o pipefail
# #898: the checker library no longer walks up from CWD to find `base/runtime` -- the root
# must be given to it. The harness conforms to the library, not the other way round, so the
# repo root is exported here (self-locating, and respects an ODIN_ROOT already in the env).
export ODIN_ROOT="${ODIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

PORT="$1"
ROOT="${2:-/home/kalsprite/dev/odin/.claude/probes}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Curated corpus: plain-mode probes, compared with `odin build` on both sides -------------
CORPUS=(
  an1 fieldvet filevet gx_all4 gx_base gx_plus_fixed
  gx_plus_soa gx_plus_string gy_empty_variadic gy_one_value gy_two_values matcnt1
  matcnt2 p_ap1 p_ap2 p_clob p_cte2 p_cte3
  p_grpC polycyc pp1 p_pv p_pv2 probe_size
  probe_size_ctl p_ti px_group px_group2 px_variadic soa_mina
  soa_minb soa_minc swval sx_slice_badfld sx_soa_arr_bad sx_soa_badfld
  sx_soa_dyn_bad sx_soa_goodfld sx_soa_ok ti1 ti2 typearg
  vetstyle mxidx trunc divwarn finidis objcsuper objcimpl objcnamed objcctx2 dupdefault sel288 sel288b u288 objcdup objcdup2 instty3 instty5 p_cte p_cte1 fieldclose sepgap postdir2 pd3 bcval dirw
  # #579 (merge a64cb7bfd / PR #7227) overload-scoring refinements. These two exist because the
  # 323-package parity corpus could NOT distinguish "ported correctly" from "ported nothing":
  # both changes are inert across every package, so a clean sweep proved neither. Each probe goes
  # AMBIGUOUS on the pre-#579 checker and resolves on the post-merge oracle, so they can fail --
  # which is what makes them worth running.
  # Both are compared with `odin build`, so both need a `main` -- a probe without one scores as a
  # difference on the entry-point error alone, which is a comparator artefact and not a finding.
  #   p579def  untyped constant prefers its DEFAULT type: f(1) over f(int)/f(i64) picks int
  #   p579val  candidate ordering: proc($S: string) beats proc(x: $T)
  #   p579def2 dummy_argument_count, default arm: h(1) picks proc(x: int) over proc(x: int, y := 0)
  #   p579vard dummy_argument_count, variadic arm: v(1) picks proc(x: int) over proc(x: int, ..int)
  p579def p579val p579def2 p579vard
  # #571. Constant string slicing: an inverted constant range (the "[%d > %d]" message) and a
  # non-constant index into a constant string (which the port used to accept silently).
  # NOT added: the sibling probe `S :: "hello"; x := S[3:1]`, which the ORACLE cannot check --
  # it dies on src/string.cpp(77) `lo <= hi && hi <= max`. A probe whose reference side aborts
  # cannot be a corpus member; the port's guarded behaviour there is a documented divergence.
  p571sl
  # #664. @(entry_point_only). Three defects at one site; these two are the reachable, build-mode
  # halves. Both need a real `main` (corpus members are compared with `odin build`), and having one
  # is not incidental -- it makes `main` the genuine entry point, so the violating call from
  # `caller` is exactly C++'s rule rather than an artefact of nothing being registered.
  #   p664a  BOTH violations: attribute + a wrong-typed argument. This is the ordering probe --
  #          the port used to early-return on the argument error and DROP the attribute diagnostic
  #          entirely (1 vs the oracle's 2). It must stay 2-in-C++-order.
  #   p664b  attribute only. Guards the message TEXT, which diverged in three places.
  # NOT added: p664c (nested proc named `main`), the build-mode form of the ep4 probe for defect C.
  # It FULL-DIFFERs for a HARNESS reason, not a port one -- the same trap `objchang` is excluded for.
  # cmpfull.py runs the oracle as `odin build` (entry point ENABLED) while triage_st checks with
  # no_entry_point=true, and BOTH compilers gate the whole `main` block on `!no_entry_point`
  # (check_decl.cpp check_proc_decl:1529). Run the oracle as `odin check -no-entry-point` and the two
  # sides agree at 0 diagnostics. I briefly filed this as a port defect (#665) and RETRACTED it the
  # same session; see CHECKER_ISSUES/CHECKER-nested-main-skips-the-whole-entry-point-block.md.
  # Defect C itself is covered by the -no-entry-point probes $S/n664/ep4 and ep5, which this
  # build-mode corpus cannot express: under `odin build` a package-level `main` IS the entry point,
  # so the probe would go vacuous.
  p664a p664b
  # #667. The `#config` arm. Three probes, because the defect was three divergences at one site
  # and each probe pins a different one -- and all three ALSO pin the same underlying rule, that
  # the ANCHOR decides whether a diagnostic merges (#578).
  #   p667a  wrong arity  -> text was "'#config' expects 2 arguments: name and default value" and
  #                         the anchor was `close`, not `call`. Pre-fix the port printed TWO lines
  #                         (the un-merged enclosing "Invalid declaration value" plus its own) to
  #                         the oracle's ONE. Fixing the anchor collapsed it with no other change.
  #   p667b  non-identifier first argument -> C++ NAMES the node kind (ast_strings[arg->kind],
  #                         here "basic literal"); the port's text said "first argument must be an
  #                         identifier (config name)" and named nothing. Same anchor/merge story.
  #   p667c  parenthesised non-constant default -> C++ anchors on `def_arg`, the UNPARENTHESISED
  #                         expression it actually checked. The port anchored on the raw argument,
  #                         one column earlier, so its "must be a constant" no longer merged with
  #                         the diagnostic the inner call raises for itself -- three lines vs two.
  # Not vacuous: lines=1/1/2. Each needs a `main` because this corpus compares with `odin build`.
  p667a p667b p667c
  # #668. check_basic_directive_expr -- the BARE-directive path (no call), which is a different
  # function from check_builtin_procedure_directive and had never been read against C++.
  #   p668loc  bare `#location`  -> C++ has its OWN long message AND returns a VALID operand
  #                                (t_source_code_location/Value) so nothing cascades. The port
  #                                had no arm: "Unknown directive: #location".
  #   p668pan  bare `#panic`     -> NOT in C++'s must-be-a-call list, so C++ says "Unknown
  #                                directive: #panic". The port had an invented arm saying
  #                                "'#panic' must be used as a call". Guards the INVERSE
  #                                direction from p668loc, which is why both are members.
  #   p668col  bare `#column`    -> `#column` is not an Odin directive at all; C++ knows no such
  #                                name. The port implemented it and folded it to an untyped
  #                                integer, so it ACCEPTED source the oracle rejects -- the port
  #                                emitted ZERO diagnostics. This is the under-rejection probe.
  #   p668prc  `#procedure` at file scope -> text reworded AND C++ returns a typed empty string
  #                                where the port invalidated the operand.
  # All four lines=1, none vacuous. Controls that must NOT move: #file/#directory/#line (0 errors
  # both sides) and #caller_location/#branch_location (1 each) -- checked by hand, not members,
  # because a 0-diagnostic probe cannot fail this comparator usefully.
  p668loc p668pan p668col p668prc
  # #670. The rest of check_builtin_procedure_directive's arms, read end to end against C++.
  # caller_expression / assert / panic / load_hash / hash came back CLEAN (text AND anchor);
  # these four are the divergences that survived.
  #   p670def   `#defined()`            -> arity error anchored on `close`, not `call` (col 29 vs
  #                                        20, single caret vs span). Same shape as #667 defect A.
  #   p670ld3   `#load("a","b","c")`    -> C++ SPLITS the arity report: got-0 anchors on the paren
  #                                        (nothing to point at), any other count anchors on
  #                                        args[0]. The port used `close` for both, so only the
  #                                        >0 case diverged -- `#load()` alone would have PASSED.
  #   p670ldnc  `#load(1)`              -> the port fused C++'s two guards into one condition
  #                                        behind an invented message; C++ reports "expected a
  #                                        constant string, got untyped integer", NAMING the type.
  #   p670or    `#load(..) or_else g()` -> C++ MISSPELLS "conjuction" (check_expr.cpp:10079) and
  #                                        the port had silently corrected it to "conjunction".
  #                                        The typo is now reproduced deliberately; this probe
  #                                        exists so nobody "fixes" the spelling again.
  # lines=1/2/2/1, none vacuous.
  p670def p670ld3 p670ldnc p670or
  # #672. `f :: proc($T: typeid = int)` -- C++ check_get_params:1972-1978 reports "A type parameter
  # may not have a default value" INSTEAD of evaluating the default (the two are arms of one
  # if/else). The port had no such arm and checked this SILENTLY -- an under-rejection. Fixing it
  # exposed a SECOND defect: the parser built Typeid_Type with `end := tok.pos` (the START) at
  # parser.odin:2728 where its sibling site uses `end_pos(tok)`, so the caret rendered EMPTY.
  # Nothing read that end until this diagnostic anchored on the type expression. Both fixed here.
  p672tp
  # #673. `f :: proc(x: $T = F)` -- a POLYMORPHIC parameter type may not carry a runtime default
  # (C++ check_type.cpp:2001-2026). Constant/Nil/Invalid are fine; Location/Expression/Value are
  # not -- EXCEPT when the default resolves to a polymorphic PROCEDURE entity, which C++ allows.
  # The port had none of it. lines=2 (the poly error plus the ambiguity error the oracle also
  # emits), so this probe pins BOTH that the new diagnostic fires and that it does not displace
  # the existing one.
  p673poly
  # #613. The call-site target-feature checks, which were a REDUCTION of one of C++'s two branches.
  # These are HOST-TARGET probes -- they fire on amd64 with no -target/-microarch, so they belong here
  # and NOT in crosstarget.sh. (#613 was expected to need cross-target probes like #611's; it does not.)
  #   p613a  require-not-enabled     -> "Calling this procedure requires target feature '%s' to be enabled"
  #   p613b  require-invalid-for-arch-> "Called procedure requires target feature '%s' which is invalid ..."
  #   p613c  enable-invalid-for-arch -> "Called procedure enables target feature '%s' which is invalid ..."
  #   p613d  #force_inline at FILE SCOPE. Must use `proc "contextless"`: an ordinary proc hits
  #          "Procedures requiring a 'context' cannot be called at the global scope" FIRST on BOTH sides,
  #          so the probe matched while proving nothing about the rule under test.
  #   p613e  #force_inline non-superset, including the "\tSuggested Example:" continuation line.
  p613a p613b p613c p613d p613e
  # #620. Type-vs-typeid comparison. The port's check_comparison arms (check_expr.odin:1789/1795) are a
  # REDUCTION of C++ check_comparison:3206-3242: one of two add_type_info_type, no add_type_and_value,
  # and no constant fold. No DIAGNOSTIC divergence is measured on any form I could reach -- these three
  # are adopted to keep it that way, not because they currently differ.
  #   ptid   `#assert(int == typeid_of(int))`. THE ARM'S REAL GUARD: instrumenting check_expr.odin:1789
  #          and counting fires shows ptid FIRES IT TWICE (instrument positive-controlled, #558).
  #          Both sides yield .Value for the SAME reason -- typeid_of is not a constant in Odin, so C++
  #          takes its else-branch too. 2 diagnostics per side.
  #   ptid2  `T :: typeid_of(int)` -- 0 fires (the declaration fails first and cascades). 4 per side.
  #   ptid3  `f :: proc($T: typeid) { #assert(int == T) }` -- the constant-typeid form. CLEAN on both
  #          sides (the fold happens), and it is a real guard despite being clean: if folding broke, the
  #          port would emit "is not a constant boolean" exactly as in ptid. But note it does NOT reach
  #          check_expr.odin:1789 at all (0 fires) -- it folds EARLIER via a path not yet identified,
  #          so do NOT cite ptid3 as that arm's guard. I originally did, and it was wrong.
  ptid ptid2 ptid3
  # #624. check_type_internal has TWO structurally identical mode switches -- one for Ident, one for
  # Selector_Expr -- and C++ gives their DEFAULT arms different text: the Ident arm says
  # "'%s' used as a type when not a type", the Selector arm says "'%s' is not a type". The port used the
  # selector wording in BOTH, and both sites carried the SAME (wrong) citation, which is what hid it:
  # a reader checking either one against the cited C++ range saw a range that matched neither.
  # nontype pins all three messages -- two ident forms (variable, constant) and one selector form.
  nontype
  # #625. check_procedure_type's #optional_ok boolean check anchored on the PROCEDURE TYPE where C++
  # anchors on the SECOND RETURN VALUE (check_type.cpp:2700 `error(second->token, ...)`). Measured A/B
  # on the same probe: pre-fix 4:7 / 7:7 (the `proc` keyword), post-fix 4:23 / 7:26 (the offending
  # return), oracle 4:23 / 7:26. The sibling #optional_allocator_error arm genuinely DOES anchor on
  # the procedure type in C++ (:2717), so the two arms differ deliberately and neither can be inferred
  # from the other -- which is why the probe carries BOTH an unnamed and a NAMED second return.
  optok
  # #626. check_call_arguments_proc_group's named-argument loop (check_expr.cpp:7548-7577). The port did
  # ONE of C++'s four steps and omitted the TYPE HINT, so a named argument needing a hint was rejected.
  #   pgnamed   ACCEPT probe, 0 diagnostics both sides: `pg(1, c = .Green)` where every candidate takes
  #             `c: Color`. Was "Cannot determine type for implicit selector expression '.Green'" -- a
  #             live OVER-REJECTION of valid code. This is the probe that would catch a regression.
  #   pgnamed2  the "Invalid parameter name 's.y'" arm (:7555-7559), REACHABLE and byte-identical at
  #             13:12. Also pins that an UNMATCHED name (`nope = .Green`) still errors in BOTH -- no
  #             hint is found, so the hint logic must not invent one.
  #   pgnamed3  ORDERING guard: a positional arg after a named one is caught by the EARLIER
  #             "Non-named parameter is not allowed to follow named parameter" check, in both
  #             implementations. This is why C++'s :7550-7553 "Expected a 'field = value'" arm is
  #             UNMEASURED -- ported for faithfulness, but no input reaches it (#313).
  pgnamed pgnamed2 pgnamed3
  # #627. is_type_load_safe was a hand-enumerated Basic_Kind list where C++ (types.cpp:3010) tests
  # `flags & (BasicFlag_Boolean|BasicFlag_Numeric|BasicFlag_Rune)`, Numeric including QUATERNION.
  # The list omitted every quaternion, every endian-specific int/float, and plain `.Rune`.
  # loadsafe is an ACCEPT probe -- 0 diagnostics on both sides -- covering `#load` into
  # []quaternion128, []rune and []u32le, plus []u32 as the control that was already accepted.
  # A/B on the same probe: pre-fix binary 3 errors, post-fix 0, oracle 0.
  # NOTE: this probe carries a data.bin that `#load` reads; do not prune it as an unused file.
  loadsafe
  # #628. is_type_nearly_simple_compare's Basic arm hand-enumerated 24 kinds where C++ tests
  # `flags & (BasicFlag_SimpleCompare|BasicFlag_Numeric)` and then special-cases Basic_typeid.
  # ACCEPT probe, 0 diagnostics both sides. A/B: pre-fix 9 errors, post-fix 0, oracle 0.
  # It pins BOTH consumers of the predicate at once -- the `intrinsics.type_is_nearly_simple_compare`
  # constant (via #assert) and the `struct #simple` field diagnostic -- so a regression in either
  # surfaces here.
  # THE bit_field ENTRIES ARE LOAD-BEARING AS A NEGATIVE CONTROL: they are the cases that passed
  # BEFORE the fix, because core_type() unwraps Bit_Field to its backing integer in both
  # implementations. They are what refuted my claimed second gap; keep them.
  nearsimple
  # #632. Imaginary literals folded to their REAL part: `3i` was stored as the f64 3, and the
  # j/k suffixes were typed untyped COMPLEX rather than untyped quaternion. A silently WRONG
  # VALUE, which is why parity, vet parity, modelsweep and this corpus were ALL green while it
  # was live -- the only way to see it is to make the value itself decide an outcome.
  #   imag  #assert(real(X) == 0) and #assert(imag(X) == 3) for `X :: 3i`. Deliberately phrased
  #         as CONSTANT predicates so no renderer sits between the stored value and the verdict
  #         (#558's lesson). A/B: pre-fix 2 errors, post-fix 0, oracle 0.
  #   uq    the REJECT half -- converting an untyped quaternion (`3j`) toward complex128, f64
  #         and int. A/B: pre-fix 0 diagnostics (a live UNDER-rejection), post-fix 3, oracle 3,
  #         text-identical. The first line is a quaternion128 ACCEPT control that must keep
  #         working, so the probe cannot be satisfied by simply rejecting more.
  #   uqm   3-constant contrast (3j / 3i / 3) whose real value is in the model dump; carried
  #         here as a cheap accept control that all three still check cleanly.
  imag uq uqm
  i2umap i2ureject
  # #642. check_builtin_jmag_kmag was a REIMPLEMENTATION with eight divergences from
  # check_builtin.cpp:3834-3888 -- see the note on the proc. The severe one was a MISSING CONSTANT
  # FOLD: it always set mode = .Value, so jmag/kmag on a TYPED constant quaternion became
  # non-constant and every constant-context use failed. That is a live OVER-REJECTION of code the
  # oracle accepts, and no gate here could see it before these probes.
  #   qmag     the ACCEPT half. The two typed-constant folds are what #642 closed; the six real/imag
  #            assertions and the three result-WIDTH bindings (f64/f32/f16) are controls that
  #            already passed, which is what proves the probe is not satisfied by rejecting more.
  #   qmagrej  the REJECT half, including UPSTREAM #642 itself: jmag(3j) and kmag(3k) can NEVER
  #            succeed, because C++ clobbers an untyped constant to t_untyped_complex and then
  #            demands a quaternion. The port reproduces that deliberately.
  # NO QUATERNION `==` ANYWHERE: `#assert(q == 0)` ABORTS the oracle (#635). Every assertion here
  # compares the FLOAT result of jmag/kmag/real/imag, which is measurable on both sides.
  qmag qmagrej
  # #648 (= #643 + #647, one arm). check_builtin_quaternion's tail was a REIMPLEMENTATION with four
  # divergences from check_builtin.cpp:3697-3768, measured 8 of 10 probes DIFFER before the rewrite:
  # (a) it set mode = .Constant and then stored `operand.value = nil` behind a "for now" comment, so
  # NOTHING was folded -- reported from a backend; (b) the result type was hardcoded quaternion128,
  # so f64 and f16 components were REJECTED where the oracle accepts them; (c) three diagnostics were
  # absent (mismatched components, non-float, endian-specific); (d) one invented message.
  #   quat     the ACCEPT half -- the four component folds, the untyped-float promotion from INTEGER
  #            literals, and the three width derivations (f16/f32/f64 -> quaternion64/128/256). The
  #            f32 line is the control: it passed before the fix too.
  #   quatrej  the REJECT half -- exactly the three missing diagnostics.
  # NO QUATERNION `==` (#635 aborts the oracle): every assertion compares the FLOAT result of
  # real/imag/jmag/kmag, which is measurable on both sides.
  quat quatrej
  # #634. The SIXTH hand-enumeration (after #95, #117, #118, #627, #628): the zero value for an
  # empty compound literal of a constant type. C++ check_expr.cpp:11613-11634 is an ordered chain
  # of FLAG tests; the port listed kinds by hand and omitted string16/cstring16, which carry
  # BasicFlag_String in types.cpp:529-530 AND in the port's own basic_flags_table.odin:85-86.
  # A/B: pre-fix 2 errors (the two string16 assertions), post-fix 0, oracle 0.
  # THE TWELVE OTHER ASSERTIONS ARE LOAD-BEARING CONTROLS -- bool/int/f32/complex/rune/string/
  # cstring all passed BEFORE the fix, which is what proves the probe exercises the arm rather
  # than being satisfied by the port simply rejecting more.
  # DELIBERATELY NO QUATERNION COMPARISON: `#assert(quaternion128{} == 0)` ABORTS the oracle
  # (GB_PANIC exact_value.cpp:1092, 5/5 -- no ExactValue_Quaternion arm in compare_exact_values).
  # That is upstream #635 and lives in $S/qcrash; a probe that crashes the oracle is UNMEASURABLE.
  emptycl
  # #640. type_integer_to_signed / type_integer_to_unsigned were REIMPLEMENTATIONS: two
  # hand-written Basic_Kind tables in types.odin (the SEVENTH hand-enumeration, after #95, #117,
  # #118, #627, #628, #634) behind two invented messages. C++ maps by ENUM ADJACENCY,
  # basic_types[kind +/- 1] (check_builtin.cpp:6946/:6990), after gating on kind, SIGNEDNESS
  # DIRECTION, untypedness and polymorphism -- four gates the port had none of.
  #   i2umap    the ACCEPT half. Seven of the eight assertions are controls that already passed;
  #             the eighth is `rune -> f16`, which is an UPSTREAM quirk the adjacency reproduces
  #             for free (rune carries BasicFlag_Integer without BasicFlag_Unsigned, types.cpp:506,
  #             so it passes the signed gate and its enum successor is F16). Verified against the
  #             stock oracle 5/5. The endian pairs are here because the deleted table returned
  #             them UNCHANGED under a stale "endian type globals may not exist" comment.
  #   i2ureject the REJECT half -- all four gates plus the non-type arm. A/B: every one of these
  #             lines DIFFERED from the oracle before the fix and matches after.
  # #584. check_index: three divergences in one probe -- the 'Cannot index a constant' message
  # and its Suggestion, and an INVENTED `if !index_ok { .Invalid; return }` bail that suppressed
  # the assignment diagnostic on the following line (oracle 3 diagnostics, port 2).
  p584a
  # #585. get_constant_field_single ported to C++'s contract (success/finish out-params) and
  # check_index routed through it.
  #   p585a  four constant EXTRACTION shapes that must all succeed and produce the right value:
  #          string byte, positional array element, keyed enumerated-array element, and a
  #          range-keyed (`0..=1 = 7`) element. Forced into constant declarations so the value
  #          itself is load-bearing -- an earlier draft used `a := S[1]`, which makes `a` a
  #          VARIABLE, so the #assert could not be constant and the probe proved nothing.
  #   p585b  the FAILING path: indexing a sparse enumerated-array constant outside its keyed
  #          range. This is the diagnostic the port could not emit at all before -- there was
  #          no `success` flag to test.
  p585a p585b
  # #305 file-tag parsing. One probe per distinct path through parse_file_tag /
  # parse_vet_tag / parse_feature_tag, not one per syntactic variation:
  #   vettag  bare `#+vet` turns every vet check on
  #   vettag2 invalid vet flag name + the 13-line list
  #   vettag3 `!` negation, and the Unknown-tag catch-all
  #   vettag4 "Expected a space after #+vet", and the feature-flag list
  #   vettag6 a bad tag in ONE file suppresses the WHOLE package's semantic pass
  #   vt_b    a delimiter rune is returned as its own token and reported as a bad name
  #   vt_c    a bare `!` with no name after it
  #   vt_e    two integer-division-by-zero flags at once
  #   vt_f    notting a flag that does not support it
  #   vt_m    a comma is a bad flag name, NOT a separator
  #   vt_n    tags are case-sensitive, and the message carries the whole tag text
  vettag vettag2 vettag3 vettag4 vettag6 vt_b vt_c vt_e vt_f vt_m vt_n
  # #307. Only vt_nopkg is a corpus member -- see EXCLUDED for its two siblings.
  #   vt_nopkg  a lone package-less file: used to SEGFAULT the checker 20/20; now reports
  #             "Expected a package declaration at the beginning of the file" and nothing else
  vt_nopkg
  # #306 build-tag diagnostics, one probe per C++ error condition in parse_build_tag /
  # parse_build_project_directory_tag. Each a.odin carries the malformed tag plus a package
  # clause; b.odin keeps the package resolvable and supplies main.
  #   bt_space  "Expected a space after #+build"          (#+buildlinux)
  #   bt_bang   "Expected a build platform after '!'"     (#+build !)
  #   bt_comma  "Invalid build tag: Missing ',' before"   (#+build linux windows)
  #   bt_subt   "Invalid subtarget"                       (#+build darwin:bogussub)
  #   bt_plat   "Invalid build tag platform"              (#+build bogusplatform)
  #   bt_projb  "Expected a build-project-name after '!'" -- ALSO the #24 use-after-free repro:
  #             this segfaulted 15/15 on three pre-change binaries
  #   bt_dbg    two malformed tags in one file, so the pass is proven not to stop at the first
  bt_space bt_bang bt_comma bt_subt bt_plat bt_projb bt_dbg
  # #385. The two named-argument LABEL sites in check_call_arguments_proc_group. Both used to
  # index split_args.named with a counter that did not track the operand -- one never incremented
  # at all, one shared with the comma counter -- reproducing C++ faithfully at the time (#156).
  # Upstream rewrote the lambda; these probes pin the corrected labelling so it cannot drift back.
  #   nameidx   the "Given argument types:" block -- must print `alpha =` then `beta =`
  #   nameidx2  the try_addr "Suggestion:" line -- same, with a leading positional and an `&`
  nameidx nameidx2
  # #385/#225. The integer-literal exponent branch, one line per rejected form in a.odin and
  # the accepted contrast set in b.odin. Upstream replaced two GB_ASSERTs (`base == 10`,
  # `text[i] != '-'`) that ABORTED the compiler with early `success = false` returns, so forms
  # like `0b1e5` and `0d1e-5` went from "no oracle behaviour to match" to a syntax error. The
  # port had accepted them silently, which became a real under-rejection the moment the
  # assertions went away. The predicate lives in TWO places -- the parser's
  # integer_value_is_valid and the checker's big_int_from_string -- so this probe pins both.
  intlit
  # #386. Upstream PR #7208 deleted the "polymorphic procedure as default value"
  # short-circuit from check_is_assignable_to_with_score. It returned true with score 1 for
  # ANY polymorphic procedure assigned to ANY concrete proc type, on the promise that it
  # "will be properly instantiated when actually used" -- so a polymorphic procedure that
  # could never instantiate to the target was accepted without complaint. a.odin holds one
  # rejected shape per declaration (arity 2v1, arity 1v2, result 0v1); b.odin holds the
  # accepted contrast, a polymorphic proc that DOES fit, used both as the default and passed
  # explicitly. Nothing in the plain corpus or either parity sweep reached this site.
  polydef
  # #388/#389, the two parse_package/parse_stmt error-path defects found by triaging the 22
  # oracle-nonzero packages that #331 had deferred.
  #   rsvpkg  `package builtin` then a bare `typeid`. The reserved-name error must NOT suppress
  #           the file body: C++ raises it through the file-UNAWARE syntax_error(Token), which
  #           cannot bump f->error_count, and the decl loop is gated on that count.
  #   unktag  `#bogus` at file scope -- the statement-level unknown-tag catch-all. The port used
  #           to build a Tag_Stmt silently and let the file-scope check reject it with a
  #           different message.
  rsvpkg unktag
  # #390 the `#define` and `#include` arms of parse_stmt's tag dispatch. One probe per distinct
  # path through the arm, not per syntactic variation:
  #   defprobe  `#define FOO 1`      object-like with a body -> the expr_to_string Suggestion
  #   defexpr   `#define FOO 1 + 2*3`  same path, but pins the printer past a single literal
  #   defcall   `#define FOO(x) x*2`   adjacent paren -> call_like -> Note, NOT a Suggestion
  #   defcall3  `#define FOO()`        empty arg list; also the nil-operand parse_call_expr crash
  #   defbare   `#define FOO`          ident, no body -> Note
  #   defspc    `#define FOO (x)`      paren NOT adjacent, so NOT call_like -> Suggestion
  #   defnum    `#define 123`          next token is not an ident; message anchors on it anyway
  #   defnone   `#define`              nothing on the line -> the '#'-anchored fallback branch
  #   definc    `#include "stdio.h"`   the sibling arm: text, anchor and fix_advance all differed
  defprobe defexpr defcall defcall3 defbare defspc defnum defnone definc
  # #390 also unblocked the `Foo[]` Suggestion (parser.cpp:3369-3373), declined twice before
  # for want of a continuation channel (#307 added it) and an expression printer (#390 did).
  #   opidx   `x: Foo[]` in a type position -- allow_type set, so the Suggestion IS emitted.
  #           The POSITIVE control: without it this probe still passes at 1 line.
  #   opidx2  `v[]` on a value -- allow_type clear, so the Suggestion must NOT appear
  #   opidx3  `Bar :: Foo[]` -- also 1 line; pins that the gate is allow_type and not merely
  #           "the operand names a type"
  opidx opidx2 opidx3
  # #391 proc-group candidacy with an INVALID argument. C++ (check_expr.cpp:6954-6958) skips an
  # invalid operand instead of scoring it, so every candidate survives and the group reports
  # "Ambiguous procedure group call". The port had that guard on its named-argument path only,
  # so a positional call rejected every candidate and reported "No procedures or ambiguous
  # call" plus a package-qualified overload list.
  #   pgbad   a failed `#load` passed to a two-member group -- the whole divergence in 3 lines
  pgbad
  # #392 `context` as a default parameter value (check_type.cpp:1807-1809).
  #   ctxdef  `proc(ctx := context)` -- LEGAL, and vendor/libc-shim's set_context is this
  #           exact shape. The port rejected it ("Default parameter must be a constant, got
  #           context") and then cascaded a bogus missing-parameter error at every call.
  #   pandep  a `#panic` in a DEPENDENCY package plus two type errors in the dependent. Both
  #           compilers report all three. Kept as the standing refutation of "a compile-time
  #           panic upstream suppresses downstream diagnostics" -- hypothesis 3 of #335 -- so
  #           that it does not get re-derived.
  ctxdef pandep
  # #401 fix_advance_to_next_stmt's progress test was INVERTED, so recovery skipped the very
  # statement-start token it should have stopped on.
  #   soarec  `soa_zip :: proc(slices: ...) -> #soa[]Struct ---` -- the base/builtin.odin:349
  #           shape. Three agreed diagnostics, then the oracle recovers onto `#soa` and reports
  #           the unknown tag; the port used to skip it. This is also the last residual of
  #           #337/#388 -- base/builtin is byte-identical at 15/15 with it fixed.
  soarec
  # #308 tag ORDER. C++ walks a file's tags in source order and stops at the first EXCLUDING one.
  #   bt_order   `#+build windows` then `#+vet bogusname` -- excluded first, so silent
  #   bt_order2  `#+vet bogusname` then `#+build windows` -- vet reported, THEN excluded
  bt_order bt_order2
  # #309 fixed-capacity dynamic array compound literals (found via the #7 newdiag worklist).
  #   n7_fixok   `[dynamic; 4]int = {1, 2}` -- LEGAL; the port used to reject it outright
  #   n7_fixcap  `[dynamic; 2]int = {1,2,3}` -- capacity overflow + the index out-of-bounds line
  n7_fixok n7_fixcap
  # #310 bit-set operators and the default-parameter message (from the #7 newdiag worklist).
  #   n7_bs_m       `a * b` on bit sets -- REJECTED now; the port used to accept it
  #   n7_bs_q       `a / b` -- bit-set-specific message, not the numeric one
  #   n7_bs_s/p     `a - b` / `a + b` -- still legal (difference / union), guards the fix
  #   n7_bs_nonnum  non-numeric non-bit_set -- plain "numeric expressions", no "or bit_sets"
  #   n7_dashdash   `x: int = ---` as a DEFAULT PARAMETER has its own message
  n7_bs_m n7_bs_q n7_bs_s n7_bs_p n7_bs_nonnum n7_dashdash
  # #311 size_of(&x) warning -- ALSO the regression guard for warning_node's caret range, which
  # #302 fixed for error_node and missed here. The oracle underlines `&x` with `^^`.
  n7_sizeof
  # #312 struct #simple field validation.
  #   n7_simp1/2  a non-nearly-simple field (string, []int) is rejected
  #   n7_simp3    all-valid fields stay clean -- the over-reach guard
  #   n7_simp4    a #simple struct nested in another, which exercises the is_simple early-out
  n7_simp1 n7_simp2 n7_simp3 n7_simp4
  # #314 check_shift rebuilt from C++, plus the three simd Suggestion lines.
  #   n7_sshl    `v << s` on #simd with a SIGNED amount -- the whole point: C++ faults the
  #              AMOUNT and suggests simd.shl; the port used to fault the OPERAND instead
  #   n7_stern   a #simd condition in a ternary -> "Use 'simd.select'"
  #   n7_sidx    indexing a #simd vector -> "Use 'simd.extract' or 'simd.replace'"
  #   n7_shctl / n7_tectl / n7_ixctl  the same three shapes on NON-simd types: the
  #              over-reach guards, proving the Suggestion is gated and not unconditional
  #   n7_sh2000  shift amount above MAX_BIG_INT_SHIFT -> "must be <= 1024"
  #   n7_shneg   negative shift amount -> "cannot be negative" (expression, not value)
  #   n7_shhint  untyped constant shift against a non-integer type_hint
  n7_sshl n7_stern n7_sidx n7_shctl n7_tectl n7_ixctl n7_sh2000 n7_shneg n7_shhint
  # #316 label-as-expression, and the directive-call inlining/tailing diagnostics.
  #   n7_label    `x := loop` on a loop label -- was accepted silently
  #   n7_inldir   `#force_inline #config(...)` -> "Inlining directives ..."
  #   n7_inldir2  recognised name whose HANDLER fails -- the check still fires
  #   n7_inlord   `#force_inline #load(missing)` -- pins that only the inlining error appears
  #   n7_inlbi    `#force_inline len(...)` -- the "Inlining OPERATORS" sibling, already
  #               ported; kept as the guard that the two messages stay distinct
  n7_label n7_inldir n7_inldir2 n7_inlord n7_inlbi
  # #319 inline-asm directive validation.
  #   n7_asmbad  `#bogus` on an asm expression -- was accepted in silence
  #   n7_asmdup  duplicate #side_effects and conflicting #att/#intel: the ANCHOR probe.
  #              All five messages pointed at the `asm` keyword, not the offending directive.
  n7_asmbad n7_asmdup
  # #320 the inline-asm PROC TYPE. n7_asmok was an EXCLUDED #320 repro; it is a corpus member
  # now that the arm builds a Type_Proc with the .Inline_Asm convention.
  #   n7_asmok    valid asm bound to a variable -> "Invalid use of inline asm in variable
  #               declaration". This is the probe that was dead: the check existed and was
  #               faithful, but is_type_asm_proc could never be true.
  #   n7_asmpb    asm at FILE scope -> "only allowed within a procedure body"
  #   n7_asmstr   a non-constant asm string -> "Expected a constant string for the inline asm
  #               main parameter" (the port used to word this differently)
  #   n7_asmpt    an undefined PARAMETER type -- the port never checked param types at all
  n7_asmok n7_asmpb n7_asmstr n7_asmpt
  # #321 `#must_tail`: parser dispatch + the checker's type-identity diagnostic.
  #   n7_mtail3  VALID #must_tail, types match -- oracle is SILENT and the port used to emit a
  #              syntax error. The over-rejection, and the reason this was not "just" a missing
  #              diagnostic.
  #   n7_mtail2  types differ -> the message plus "Call type: ..., parent type: ..."
  #   n7_mtail   the STACKED form `#force_no_inline #must_tail f()`, which also proves the
  #              outer directive no longer erases the inner one's tailing flag
  n7_mtail n7_mtail2 n7_mtail3
  # #322 the parser's span-carrying error channel. These three were EXCLUDED one tick earlier
  # with the correct message at the correct position and a one-column caret; they are members
  # now that error_node/err_range exist, and they are what proves the channel end-to-end.
  #   n7_mtailpl    #must_tail on a procedure literal
  #   n7_mtailbad   #must_tail on a non-callable, naming the node kind
  #   n7_mtailboth  #force_inline #force_no_inline on one literal
  n7_mtailpl n7_mtailbad n7_mtailboth
  # #322 part 2 -- node-anchored parser diagnostics converted to error_node.
  #   c22_blockstmt  "Expected a normal statement rather than a block statement"
  #   c22_do         "'do' has been disallowed" under -strict-style
  #   c22_paren      "Expected a type within the parentheses"
  c22_blockstmt c22_do c22_paren
  # #323 the Ellipsis node's position. c22_vararg2 was EXCLUDED one tick earlier -- the span
  # #322 added made a pre-existing off-by-two anchor visible.
  #   c22_vararg2   "Extra variadic parameter after ellipsis", now anchored at the `..`
  #   c23_varname   "Variadic parameters can only have one field name", the sibling site
  #   c23_varok     a VALID variadic proc -- the over-reach guard, since the position change
  #                 touches EVERY Ellipsis node, not just the two that carry diagnostics
  c22_vararg2 c23_varname c23_varok
  # #324 the last three node-anchored parser sites. Two needed only the span; the third
  # needed the ANCHOR changed as well -- see the ledger.
  #   c24_blank    "Invalid polymorphic type definition with a blank identifier"
  #   c24_complit  "Expected a compound literal after #partial, got ..."
  #   c24_tid      "Specialization of typeid is not allowed without polymorphic names",
  #                written PARENTHESISED so the type-vs-unparen'd-tt anchor is exercised
  c24_blank c24_complit c24_tid
  # #315 the blank-assignment path. n7_biglit / n7_sh200 / n7_sh100 were EXCLUDED as #315
  # repros since #314; they are members now.
  #   c15_blank  `_ = X` with X = 2^200 -- the repro
  #   c15_typed  `x: int = 2^200` -- already matched, kept as the discriminator that proved
  #              the expressibility check itself was fine
  #   c15_arg    `f(X)` -- likewise, the call-site path
  #   c15_ctl    a plain valid `_ = y` -- the over-reach guard, since removing the skip makes
  #              check_assignment_variable run for EVERY blank assignment
  c15_blank c15_typed c15_arg c15_ctl n7_biglit n7_sh200 n7_sh100
  # #325 part 1: the file-scope simple-statement guard, which the port had COMMENTED OUT.
  #   c25_filescope  `x = 2` at file scope -- was accepted in silence
  #   c25_ok         valid file-scope decls AND in-proc =, +=, *= -- the over-reach guard,
  #                  since the restored guard sits on EVERY assignment operator
  #   c25_ops        `y += 1` at file scope, the compound-operator form
  c25_filescope c25_ok c25_ops
  # #326: parse_setup_file_decls, the post-parse file-scope walk the port never had.
  #   c26_exprstmt  `f()` at file scope -- "Only declarations are allowed at file scope, got
  #                 expression statement", the phase's own diagnostic
  #   c26_when      the SAME call inside `when true { }`. This one is why the phase needs
  #                 parse_setup_file_when_stmt: a when body's stmts never enter file.decls, so a
  #                 flat loop over decls cannot see them and the port was silent here.
  #   c26_dirstmt   `#assert(1 == 1)` at file scope -- SILENT on both sides. The over-reach guard:
  #                 the gate must let a directive ExprStmt through (it feeds directive_count),
  #                 so this probe fails the moment the exemption is dropped.
  c26_exprstmt c26_when c26_dirstmt
  # #327: import-path validation in that phase, plus the foreign-import decl's three C++ branches.
  #   c27_absimp   import "/usr/lib/whatever" -- was reported by the CHECKER as "Unable to find
  #                package", i.e. wrong message, wrong stage, wrong severity
  #   c27_winimp   import "C:/some/path" -- the same defect via the drive-letter rule, and the
  #                probe that pins is_import_path_absolute as NOT platform-conditional: the
  #                reference rejects a Windows path while running on Linux
  #   c27_fgnabs   foreign import lib "/abs/libfoo.a" -- port was SILENT, a pure under-rejection
  #   c27_fgnzero  foreign import lib {} -- anchor was at `import`, not the library name; also
  #                the probe that caught the DOUBLE report when the zero-path arm returned a real
  #                decl instead of C++'s Bad_Decl
  #   c27_fgnproc  foreign import inside a procedure body -- the whole branch was missing
  c27_absimp c27_winimp c27_fgnabs c27_fgnzero c27_fgnproc
  # #328: slice-checking arms. n8_forsemi is deliberately ABSENT -- it was my bad probe, both
  # compilers emit the same recovery there, so it tests nothing.
  #   n8_enumslice    slicing a [E]int -- message wording, the missing 'slice.enumerated_array'
  #                   Suggestion, and the o->expr anchor, all three at one site
  #   n8_fixcapslice  `f()[:]` on a [dynamic; N]T return -- the addressability guard the port's
  #                   own comment cited and never wrote
  n8_enumslice n8_fixcapslice
  # #331 simd reduce predicate + the #unroll Suggestion.
  #   n9_simdbool  #simd[4]f32 -- the message, now naming boolean OR integer
  #   n9_simdint   #simd[4]i32 -- THE over-rejection probe: legal to the reference, the port
  #                used to reject it. This is the member that would catch a narrowing regression;
  #                n9_simdbool alone would not.
  #   n9_unroll    #unroll for over a slice -- the conditional Suggestion line
  #   n9_unrollctl #332: `#unroll for x in a` over a fixed [3]int -- LEGAL. Was rejected as "not
  #                known at compile time" because the port's guard dropped C++'s inline_for_depth
  #                conjunct. It was NOT a corpus member while it failed; it is one now.
  n9_simdbool n9_simdint n9_unroll n9_unrollctl
  # #334 the polymorphic type-to-value Suggestion.
  #   na_polytype  `f(int)` where `f :: proc(x: $T)` -- error + Suggestion
  #   na_polyval   `f(1, "s")` -- a genuine VALUE mismatch: error and NO Suggestion. The
  #                over-reach guard, since C++ gates the line on operand.mode == Type.
  # #335 the #c_vararg pair, now fixed and both members.
  #   na_cvararg  naming a `#c_vararg` param directly -> error + c_va_start Suggestion. Also the
  #               regression guard for the REMOVED body/foreign over-rejection: if that check
  #               came back, this probe would report it instead.
  #   na_cvok     `intrinsics.c_va_start(&list, args)` -- names the SAME parameter legally and
  #               must stay SILENT. This is what proves allow_c_vararg_param is wired; without it
  #               the new check rejects here. NOTE: the first version of this probe used
  #               `c.va_start`, which does not exist -- both sides failed identically on an
  #               undeclared name and the control was VACUOUS while appearing to pass.
  na_polytype na_polyval na_cvararg na_cvok
  # #336 address-of an undetermined type -- one C++ site, two worklist messages.
  #   nb_addr   `x := &x` -- error WITHOUT the Suggestion (operand is undeclared, not a Variable)
  #   nb_addr2  `a := &b; b := &a` -- exercises the gate BOTH ways in one file: bare error for
  #             'b', error+Suggestion for 'a'. An unconditional Suggestion fails this, and so
  #             does a Suggestion that never fires.
  nb_addr nb_addr2
  # #337 convert_stmt_to_expr's anchor: statement start vs current token.
  #   nb_forsemi   `for x := 0 x < 3 {` -- the shape that exposed it
  #   nb_ifsimple  `if x := 1 {`        -- the SAME helper via a different caller
  nb_forsemi nb_ifsimple
  # #338 deferred-procedure chaining.
  #   nc_defchain  a -> b -> c : rejected. Was accepted in SILENCE.
  #   nc_defok     a -> b      : still accepted -- guards against an over-eager chaining check
  nc_defchain nc_defok
  # #339 `for init; ; {` -- a missing diagnostic plus a truncated one.
  #   nd_forsemi2 / nd_fordo  the two trigger tokens C++ names ({ and do)
  #   nd_forok    a normal 3-clause for AND one with an empty post but a real condition; both
  #               must stay silent, so an over-eager check fails here
  nd_forsemi2 nd_fordo nd_forok
  # #317 the Basic_Directive node's END, and the Unknown-directive anchor. All three were
  # EXCLUDED #317 repros; they are members now.
  #   n7_inlctl    "Failed to `#load` file" -- caret marks the `#`, not `#load`
  #   n7_inldir3   "Unknown directive: #x" -- anchored at the DIRECTIVE, not the call
  #   n7_inlscope  two #loads, one inlined -- the second load's caret
  n7_inlctl n7_inldir3 n7_inlscope
  # #633 recon: the `0h` hexadecimal-float bit-pattern literal had NO corpus coverage at all, in a
  # tree where core/math/math_erf.odin alone contains 113 of them. It is currently CORRECT -- and
  # correct by a route that surprised me, so it is worth pinning: the live path delegates to
  # core:strconv, which is Odin-literal-aware (strconv.odin:1101) and decodes the bit pattern.
  # The DEAD faithful port (exact_value_float_from_string) would get it WRONG, because it passes the
  # `0h` prefix into parse_u64_of_base where C++'s u64_from_string strips it. So the day #633 wires
  # the faithful path in, these two members are what turns that mistake red instead of shipping it.
  #   hexf   ACCEPT control -- f16/f32/f64 widths, underscores, must stay silent on both sides
  #   hexf2  the value-revealing REJECT -- int(0h3fb999999999999a) forces the checker to PRINT the
  #          decoded value (0.1), so a wrong decode cannot pass as a matching error message
  hexf hexf2
  # #751/#636 (upstream #7268): string16 constants must hold UTF-16, not UTF-8 bytes.
  # All three go RED on the pre-#636 port build and GREEN after, so they discriminate (#25):
  #   s16len   len() of a string16 constant == UTF-16 CODE UNITS, not UTF-8 bytes
  #   s16cast  a `string -> string16` CONSTANT CAST re-expresses the value (the only legal
  #            direction; `string16 -> string` is rejected outright by both compilers)
  #   s16slice slicing a string16 constant -- was #583's spurious "Cannot slice constant value",
  #            which turned out to be the SAME root cause rather than a second defect
  s16len s16cast s16slice
  # #754 (upstream merge b9bbcd33b): #soa of an ARRAY element. Both go RED on the pre-#754 build:
  #   soaarr       `#soa[4][3]f32` + `soa[0][1]` + `&soa[0][1]` -- CRASHED the port (SIGILL,
  #                "SOA element must be struct type"), three sites deep: complete_soa_type had no
  #                array arm, check_set_index_data dropped Soa_Variable, check_unary_expr asserted
  #   soaarrslice  `soa[0][:]` -- the "Cannot slice array '%s'" message interpolated the OPERAND
  #                where C++ interpolates the whole SLICE node ('soa[0]' vs 'soa[0][:]')
  soaarr soaarrslice
  # #758 (upstream merge b9bbcd33b): C++ check_slice_expr grew an `invalid_indices` flag that
  # suppresses the whole constant-string folding block, not just the substring() call the port had
  # already skipped to avoid reproducing the upstream assertion. The difference is the operand's
  # MODE, so it only shows where constness is demanded. Both go RED on the pre-#758 build:
  #   slcinv   `S :: "hello"; T :: S[3:1]` -- the port folded anyway and left mode == .Constant,
  #            so it dropped the oracle's "'S[3:1]' is not a compile-time known constant"
  #   slcinv2  the same plus `U :: len(T)`, which shows the suppression CASCADES: the oracle also
  #            reports "Invalid declaration value 'len(T)'" on the use, and the port reported
  #            neither. An under-rejection two diagnostics deep, from one missing flag.
  slcinv slcinv2
  # #633: the DRIFT gate. C++ has ONE function (exact_value_from_token, parser.cpp:815) that both
  # computes a literal's value AND raises the syntax error when it comes back Invalid. The port
  # cannot have that, because the diagnostic must be raised by the PARSER and the value is computed
  # in the CHECKER, and core/odin/parser does not (and must not) import core/odin/checker. So the
  # rule is written twice -- literal_value_is_valid in the parser, and the converter in the checker
  # -- and nothing structural keeps them in step. This member is what notices if they drift.
  # NOT A MEMBER YET -- see the EXCLUDED entry for `litdrift` below. The battery does its job (it
  # found something), but what it found is an ORDERING divergence, not literal drift, and a
  # FULL-DIFFER member would leave this gate permanently red.
  #
  # #652: a typeid switch skipped C++'s entire non-type case branch (convert_to_typed +
  # check_comparison + seen-map), because the port's guard carried an invented `!is_typeid_switch`
  # conjunct that C++ (check_stmt.cpp:1303) does not have.
  #   dupcase  the REPRO -- `switch tid { case 5: }`. Oracle rejects, port was SILENT. This is the
  #            member that would have caught it, and nothing in the corpus did.
  #   dupctl   the CONTROL -- the same shape in a NON-typeid switch, which both compilers always
  #            caught. It is what proved the defect was the one conjunct and not the conversion
  #            machinery, so it belongs here to keep that isolation honest.
  #   dupty2   #298's shape (duplicate TYPE cases + a polymorphic type as a case) which had NO
  #            corpus coverage at all -- I went looking for a `dupty` member while gating #652 and
  #            there was none, so the type-case branch and add_type_switch_case were ungated. It is
  #            byte-identical across oracle / pre-#652 / post-#652, which is the measurement that
  #            showed #652 left that branch alone; pinning it makes that permanent.
  dupcase dupctl dupty2
  # #650: C++ gives the "Failed to parse file: %s; invalid token found in file" abort a position
  # whose line/column are real but whose OFFSET is never written -- parser.cpp:6977 zero-inits the
  # TokenPos and init_ast_file (parser.cpp:5731) fills in only line and column, while file_id is
  # patched afterwards and offset never is. token_pos_cmp (tokenizer.cpp:210) compares OFFSET
  # FIRST, so that one diagnostic sorts ahead of every diagnostic in every file. The port passed a
  # complete position, sorted it correctly, and therefore diverged. The fix is deliberate
  # bug-compatibility -- the reference's position is internally inconsistent, but parity is the
  # contract and the only observable is diagnostic ORDER. The port's token_pos_cmp is FAITHFUL and
  # must NOT be "fixed"; the defect was in how the position was CONSTRUCTED.
  #   offprobe  p1 holds the abort at a HIGH offset (col 25), p2 an ordinary error at a LOW offset
  #             (col 6) in a file that sorts later by path. Oracle order is p1-abort, p2,
  #             p1(2:27); pre-#650 the port gave p2, p1-abort, p1(2:27). Verified as a FIRING gate:
  #             FULL-MATCH on the fixed binary, FULL-DIFFER on $S/tst_pre650.
  #             p1's second literal error carries a trailing `// tail` comment ON PURPOSE. Without
  #             it that error lands at end-of-line, where C++ renders "( empty line )" instead of
  #             the source line and omits the caret (#639, filed upstream, not fixed) -- which made
  #             the probe FULL-DIFFER for a reason having nothing to do with the ordering under
  #             test. Do not remove the comment.
  offprobe
  # #617/#655. The intrinsics type-query builtins had INVENTED diagnostic texts. Found by
  # reading type_is_specialization_of against check_builtin.cpp:7348 and then PROBING the
  # siblings rather than assuming the family was clean -- which is what turned one defect into
  # five. All six probes were FULL-DIFFER on $S/tst_pre617 and are FULL-MATCH now.
  #   tsp1/tsp2  type_is_specialization_of, args 1 and 0. The whole arm was a reimplementation:
  #              a hand-written polymorphic_parent identity test for Struct/Union only, in place
  #              of check_type_specialization_to, with no in_polymorphic_specialization around
  #              the pattern argument and no "Invalid specialization type" diagnostic. Rewritten
  #              from C++. The VALUE agreed on every probe I could build, so this is verified on
  #              messages and unchanged on values -- not claimed as a value fix.
  #   tvo1       type_is_variant_of, same invented first-argument text.
  #   tss1/tss2  type_is_superset_of, BOTH arguments. Its C++ arm (check_builtin.cpp:7979) uses
  #              a DIFFERENT wording -- "'%s' expects a type, got %s" -- which I initially got
  #              wrong by pattern-replacing the shared invented text across the file. The blanket
  #              edit hit three procs when I had verified one; these two probes are what caught
  #              it. Members so the distinction stays pinned.
  #   tm1        type_merge. Message was right after the sweep but the mode assignment was not:
  #              C++ sets mode=Type/type=t_invalid at the top of the arm and returns bare, so
  #              adding mode=.Invalid on the error path was a divergence I introduced.
  tsp1 tsp2 tvo1 tss1 tss2 tm1
  # #657. The "Did you mean?" TIE-BREAK ORDER. scope_map_slot_order simulates C++'s ScopeMap, and
  # the hash, the 75% max-load rule and the Robin Hood probe were all already faithful -- what was
  # missing ran BEFORE the insert loop: C++ RESERVES package and file scopes (checker.cpp:240/261),
  # so their maps start at next_pow2(2N) and never pass through the 16 -> 32 -> 64 doublings the
  # simulation assumed. Different capacity => different `hash & mask` => different slots.
  # These four are SIZE-GRADED on purpose; that grading is what localised the bug, because the
  # boundary between matching and differing IS the arithmetic:
  #   ordsm2  6 names  -> 2*6=12 does NOT exceed the inline cap, so C++ stays at 16 and the port
  #                       was ALREADY correct. THE CONTROL: it was FULL-MATCH before the fix and
  #                       must stay so. A fix that "works" by changing small scopes is wrong.
  #   ordmid  11 names -> next_pow2(22)=32. Still BELOW the growth threshold of 12, which is what
  #                       ruled out the rehash path and forced reading the reserve call.
  #   ordbig  40 names -> next_pow2(80)=128 vs the simulated 16->32->64. Pins the displayed
  #                       TOP-TEN MEMBERSHIP, not just its order (port showed name40 for oracle's
  #                       name06), so this one guards a user-visible set, not a cosmetic sort.
  #   cvt3    core:simd, ~100 names -- the ORIGINAL #653 repro, previously EXCLUDED. It is the only
  #                       one of the four with real nesting, so it is what proves calc_decl_count
  #                       (which counts NAMES and takes max() across a `when`) rather than
  #                       len(file.decls) is the right count. Promoted from EXCLUDED to member.
  # All four A/B'd against $S/tst_pre657: ordsm2 MATCH->MATCH, the other three DIFFER->MATCH.
  ordsm2 ordmid ordbig cvt3
  # #662. An instantiated polymorphic record printed WITHOUT its argument list: the oracle prints
  # `Foo($T=int)`, the port printed `Foo`. The string is not assembled by the printer -- it IS the
  # instantiated type's NAME, composed at instantiation by check_expr.cpp:8548-8583 and written to
  # BOTH Named.name and the type_name entity's token. The port had no equivalent, so every
  # diagnostic naming such a type lost its arguments and `Foo(int)`/`Foo(string)` printed alike.
  #   sp7  `Buf(4, int)` and `Foo(int)` surfaced through a type-mismatch message. Chosen over the
  #        original repro sp5 for two reasons. (a) COVERAGE: sp5 has only a typeid parameter, so it
  #        exercises neither the Entity_Constant arm (`$N=4`) nor the ", " separator -- a fix that
  #        handled types and nothing else would have passed sp5 outright (#25/#39). sp7 pins all
  #        three. (b) DETERMINISM: sp5 is where-clause-based and so carries the #660 render flake,
  #        which changes lines around the one under test; sp7 has no where clause and is stable.
  # A/B on the pre-#662 binary: `of type 'Buf'` / `of type 'Foo'`; post-fix and oracle both
  # `of type 'Buf($N=4, $T=int)'` / `of type 'Foo($T=int)'`.
  sp7

  # #674. The polymorphic-call argument surface. The defect this pins is INVISIBLE to every
  # message-based method: check_call_arguments_internal skipped `Entity_Constant` parameters
  # outright, on a comment claiming they are "resolved during instantiation". C++ special-cases
  # only `Entity_TypeName` there; a `$N: int` parameter is scored like any other, so
  #   p674f  `f :: proc($N: int) -> int` called as `f("hi")` -- oracle rejects, port ACCEPTED.
  # The other five are controls that must NOT move, chosen to cover each neighbouring branch of
  # the same loop, because the fix also removed an early `return` on instantiation failure
  # (C++ records err and falls through):
  #   p674a  `f :: proc(a: $T, b: T)` / `f(1, "hi")`  -- T bound from an earlier parameter
  #   p674d  `#no_broadcast` on a polymorphic parameter (the allow_array_programming branch)
  #   p674g  `f :: proc($N: f32)` / `f(3)`            -- VALID; over-rejection control (#81)
  #   p674h  `f :: proc(a: $T, b: ^T)` / `f(1, &f32)` -- pointer specialization
  #   p674i  `#any_int n: int` on a polymorphic proc  -- the #any_int escape branch
  #   p674j  the PROC-GROUP form of p674f -- that path routes through
  #          score_type_name_argument and never had the invented skip, so it is the control
  #          proving the defect was the direct path's alone (#534's "check both copies").
  #   p674k  `f :: proc($T: typeid, x: int)` / `f(1)` -- POSITIVE CONTROL for the new
  #          Type_Name arm. The oracle emits TWO diagnostics here; the second, "Expected a
  #          type for the argument 'T'", is emitted by the replacement arm and by nothing
  #          else on the direct path, so this member goes red if that arm is ever re-skipped.
  #   p674gf1 `f :: proc(a: []$T, b: int)` / `f(1, "no")` and
  #   p674gf2 `f :: proc(a: ^$T, b: int)`  / `f(y, "no")` -- instantiation CANNOT succeed here,
  #          and the oracle still reports the SECOND argument. These pin the fall-through: the
  #          port used to return the moment generation failed, so every remaining argument went
  #          unchecked. Both DIFFERED with only the Entity_Constant fix in place.
  #   p674sh `shrink(&arr)` / `shrink(&arr, 2)` / `shrink(&m)` -- REGRESSION GUARD. Porting C++'s
  #          check_get_params assignability block (check_type.cpp:2197-2222) made this over-reject
  #          `No procedures or ambiguous call for procedure group 'shrink'`, because the port's
  #          operand array still holds a ZEROED slot for an unsupplied defaulted parameter where
  #          C++ has already filled it. That block is deliberately NOT ported; this member is what
  #          catches a retry that repeats the mistake.
  p674a p674d p674f p674g p674h p674i p674j p674k p674gf1 p674gf2 p674sh

  # #675. C++'s check_get_params assignability gate (check_type.cpp:2197-2222), which #674 had to
  # back out. It emits NOTHING -- its whole effect is `success = false` -- so the observable is
  # not a message but WHETHER THE PROCEDURE IS INSTANTIATED, and therefore whether its BODY is
  # ever checked. All three probes put an undeclared name in the body to make that visible:
  #   p675a  `f :: proc(a: $T, #any_int n: int)` / `f(1, "hi")` -- generation must FAIL, so the
  #          body error must NOT appear. The port used to print it; the oracle never does.
  #   p675b  same body, parameter WITHOUT `#any_int` -- generation must SUCCEED and the body
  #          error must appear on both sides. Proves the gate is confined to the `#any_int`
  #          branch (`bool ok = true` upstream) and has not become a broad rejection.
  #   p675d  `#any_int` given an ENUM operand -- castable, so generation must SUCCEED. Proves
  #          the check_is_castable_to escape is wired.
  p675a p675b p675d

  # #676. check_matrix_type_expr: an ORDER defect and an ANCHOR defect, both found from one
  # monotonicity group (8 inversions / 11 citations) whose "after" values clustered on two
  # anchors -- #63's signature for a small number of misplaced blocks, not scattered noise.
  #   p676a  `matrix[0, 0]string`      -- the port ran the element-type check FIRST, and since it
  #          and the column-count error share `mt.column_count`, the same-position merge (#578)
  #          kept the element error and DROPPED the genuine column-count one. Oracle: row + column
  #          count. Port before: row count + element type.
  #   p676d  `matrix[x, x]string` with a non-constant x -- same swap on "Array count must be a
  #          constant integer": oracle emits it TWICE (row and column), the port emitted it once.
  #   p676b  `matrix[100000, 100000]string` -- both defects at once. The port's max-elements error
  #          was anchored at the column count, colliding with the element error, so ONLY the
  #          element error survived; the oracle prints both.
  #   p676e  `matrix[9, 9]f32`  and
  #   p676f  `matrix[100000, 100000]f32` -- the ANCHOR alone, no merge involved. C++
  #          check_type.cpp:3135 is `error(node, ...)`: the whole matrix type (2:6), not the column
  #          count. The comment that used to sit at this site asserted the opposite.
  #   p676c  `matrix[0, 3]string` -- CONTROL: only the row count is bad, so no anchor collision and
  #          both sides always agreed. It must stay FULL-MATCH through any re-ordering here.
  p676a p676b p676c p676d p676e p676f

  # #677. check_bit_field_type_expr: TWO under-reporting defects, both `continue`s the port has and
  # C++ does not. Found from a 7/12 citemono group whose seven inversions all shared ONE "after
  # 1128" -- #63's single-anchor signature, and the anchor was the duplicate-name check sitting at
  # the TOP of the loop where C++ has it at :1128, after the type and bit-size validation.
  #   p677a  `a: u8|3, a: string|4` -- duplicate AND a bad type. Oracle: redeclaration AND "must be
  #          <= 8 bytes, got 16". Port before: redeclaration only, because the early check skipped
  #          check_type entirely.
  #   p677f  `a: u8|"x", a: u8|3` -- the non-integer bit-size arm `continue`d, so the FIRST field's
  #          name was never registered and the second `a` was not seen as a duplicate. Oracle emits
  #          both diagnostics; the port emitted one. C++:1122-1126 has no continue.
  #   p677b  `a: u8|3, a: u8|99` -- CONTROL for the direction of the move. The bit-size CLAMPS live
  #          inside C++'s `else` at :1130, so a DUPLICATED field must NOT get "cannot exceed 64
  #          bits". Both sides emit the redeclaration alone; this member fails if the clamps are
  #          ever hoisted above the duplicate check.
  #   p677g  `a: u8|x, a: u8|3` with a non-constant x -- CONTROL: that arm already set the operand
  #          invalid and carried on, matching C++, and must keep doing so.
  #   p677c  two distinct valid fields -- CONTROL, no diagnostics either side.
  #   p677d  plain duplicate, nothing else wrong -- CONTROL, one diagnostic either side.
  #   p677e  `a: u8|"x"` alone -- CONTROL for the non-integer arm with no duplicate following.
  p677a p677b p677c p677d p677e p677f p677g

  # #678. The bit_field ENDIANNESS check was a REIMPLEMENTATION, found by reading #677's residual:
  # the block cited check_type.cpp:1127-1167 (the redeclaration/clamps/entity region) while C++'s
  # endianness pass is at :1190-1230, AFTER the field loop, over the collected entities.
  #   p678a  `bit_field u32le { a: u16be|5 }` -- the port's message was INVENTED ("bit_field field
  #          has big endianness but backing type has little endianness"; that text is nowhere in
  #          src/) and anchored at the field TYPE. C++: "All 'bit_field' field types must match the
  #          same endian kind as the backing type, ..." at the field NAME.
  #   p678b  `bit_field u32 { a: u16le|5, b: u16be|5 }` -- UNDER-REJECTION. The port gated the whole
  #          check on the backing type being explicitly endian-specific, so a NATIVE backing type
  #          disabled it. C++'s determine_endian_kind returns Endian_Native for a plain u32 and
  #          mismatches against it: oracle two errors, port NONE.
  #   p678d  `bit_field u32le { a: u16be|5, b: u16be|99 }` -- the port's `continue` after its error
  #          also suppressed the bit-size clamp diagnostic the oracle emits.
  #   p678c  `bool` + `u8` fields under an `le` backing -- CONTROL. determine_endian_kind returns
  #          Unknown for booleans and for anything smaller than 2 bytes, so neither comparison
  #          fires; a fix that drops those guards turns this red.
  #   p678e  all-`le` fields under an `le` backing -- CONTROL, no diagnostics either side.
  p678a p678b p678c p678d p678e

  # #680. `check_global_variable_decl` -- the group was 6/8 with all six sharing one anchor, and the
  # anchor turned out to be the ONE CORRECT citation among eight stale ones. No reordering, no
  # defect: the port's structure matches C++ exactly and only the line numbers had drifted (+70
  # before the init expression, +76 after). Correcting them took the group to ZERO.
  # These three pin the "Illegal declaration cycle" path, which is what the DELIBERATELY-NOT-PORTED
  # check_decl.cpp:1801-1806 block would otherwise duplicate. That block's predicate
  # (checker.cpp:625-646) accepts exactly `x := x` and `x := i if c else i`; on every such shape the
  # port's earlier dependency-walk detector already produces C++'s exact output. If someone ports
  # the block anyway, these members catch the second diagnostic.
  #   p680a  `x := x`                          -- the bare-ident arm of the predicate
  #   p680e  `x: int = x`                      -- same, with an explicit type so e->type is preset
  #   p680g  `x: string = x if true else x`    -- the ternary arm, both branches
  p680a p680e p680g
  # #693. Duplicate type case, where the two case expressions build DISTINCT but structurally
  # identical Type objects (`case ^int:` twice). C++ tracks seen case types in a TypeSet, which slots
  # by type_hash_canonical_type, so it reports the duplicate; the port's set was keyed by type
  # POINTER and silently ACCEPTED the program -- a live under-rejection invisible to any check that
  # reads only the port's own output (#71), and not present in any of the 323 parity packages.
  # Needs a `main` because corpus members are compared with `odin build`.
  dupptr
  # #698. Indexing a CONSTANT SLICE with a CONSTANT index -- `A :: []int{10,20,30,40}` then `A[3]`.
  # A live OVER-REJECTION: the port answered "Cannot index a constant 'A'" plus a suggestion about
  # variable indices that did not apply, where C++ resolves the element. check_index_value's
  # `max_count >= 0` arm had no else, so a constant index against a type with no STATIC length fell
  # through to the `value^ = -1` sentinel that C++ reserves for non-constant indices, and the
  # caller's faithful `index < 0` guard then fired. The member carries a constant ARRAY and a
  # constant STRING alongside the slice precisely because those two were NEVER affected -- both
  # have a static length and take the `max_count >= 0` arm -- so they are the #25 control that must
  # not change. Reported by mirc; no parity package indexes a constant slice.
  cidxslice
  # #703. FAILING `#assert` -- the caret. C++ anchors both "Compile time assertion" errors on the
  # CALL (`error(call, ...)`, check_builtin.cpp:2644/:2647); the port anchored on `call_expr.expr`,
  # the CALLEE, so the caret spanned only `#assert` and was a CONSTANT `^~~~~~^` no matter what was
  # asserted. This is #574's defect exactly: that tick fixed all three errors in the `#panic` arm
  # and missed the `#assert` arm a few lines above it in the same file. The member carries FOUR
  # argument shapes (literal, constant ident, binary expr, unary expr) because the port's caret was
  # identical across all of them while the oracle's width tracks the argument -- one shape would
  # have shown the bug but would not have shown that the width is argument-DEPENDENT.
  # No prior member exercised a FAILING #assert, which is how 300 green members missed it.
  asrt
  # #712. DUPLICATE PACKAGE NAME. `check_unique_package_names` was a REIMPLEMENTATION, not a port:
  # invented message text, no `error_line` block, no "found at previous location" line, and it
  # anchored on a `tokenizer.Token` where C++ anchors on the `pkg_decl` NODE -- so the caret was a
  # single `^` instead of `^~~~~~~~~~^` under `package dup`. The anchor was ONE root cause for TWO
  # symptoms (1:9 vs 1:1 AND the caret width), fixed by one argument in parser.odin:343 (#163).
  # The member is two subpackages both named `dup` imported by a third, which is the ONLY shape that
  # takes the emitting branch.
  # WHY THIS WAS INVISIBLE FOR 300 MEMBERS AND 323 PARITY PACKAGES: every one of them has unique
  # package names, so the branch was never taken. An invented diagnostic on an unexercised path is
  # invisible to a comparator that only ever sees the path NOT taken -- #71's shape from the other
  # side. It was found by READING C++, not by any sweep, which is exactly why it belongs here now.
  # Determinism measured 8/8 identical before adoption (#115).
  n712
  # #743/#746: intrinsics.type_is_specialization_of had ZERO coverage of any kind. Its only
  # occurrence tree-wide is its DECLARATION (base/intrinsics/intrinsics.odin) -- no call site in
  # core/ or base/, so no package check, no parity sweep and no corpus member has ever exercised
  # it. The port's arm was rewritten from C++ under #617 and the write-up said, honestly, that it
  # was "verified on messages and unchanged on values"; that was as far as inspection could reach.
  # These four are the first actual measurement, and the reason a regression here would now be
  # caught instead of shipping (#186: zero call sites means no gate COULD have covered it).
  #   tsof_val    BOTH value directions as #assert -- Foo(int) IS a specialization of Foo, Bar(int)
  #               and int are NOT. Deliberately NOT where-clause-based: the `where` form carries the
  #               #660 definitions-block render flake (same reason sp5 is excluded), which a
  #               fixed-expectation comparator scores as a difference unrelated to the rule.
  #               PROVEN to have content: flipping one assertion makes BOTH sides reject with a
  #               byte-identical message (#177) -- a silent probe is worthless without that.
  #   tsof_e1     non-type first argument -> "Expected a type for ..." (C++ check_builtin.cpp:7350-7355)
  #   tsof_e2     undeclared specialization type -> the resolve failure (C++ :7364-7369)
  tsof_val tsof_e1 tsof_e2
  # #748: PROMOTED FROM THE EXCLUSION LIST. Its note read "the oracle emits a <nopos> Note
  # continuation block the port does not ... they are genuinely absent" -- true when written, during
  # #196's SCRATCH phase. #196 then landed ("all five signature-Note branches + variadic suggestion
  # ported") and the exclusion was never retired: the log entry outlived the state it described
  # (#208). Re-derived from source -- BOTH sides now emit the full block, verbatim:
  #   Note: The input parameter types differ between the procedure signature types
  #         Expected: $V / Got: $T, $U
  # 6/6 stable FULL-MATCH, and the WHY is established, not just the agreement (#146). It gates the
  # signature-Note branches, which nothing else in the corpus does.
  p_ppp
  # #787 struct alignment-directive coherence. Four probes, each pinning a distinct path that the
  # ORIGINAL filed repro did not reach -- two of them found a SECOND defect the filing never named.
  #   stalign1  #packed + #min_field_align + #align  -- the filed repro. C++ ST_ALIGN is a MACRO
  #             whose `return;` leaves check_struct_type, so the FIRST conflict is reported and the
  #             rest are not. Port had it as a nested proc whose result was discarded: 1 vs 2 errors.
  #   stalign2  #packed + #align only -- same abort, reached from the THIRD ST_ALIGN invocation
  #             rather than the first. Pins that all three call sites propagate, not just one.
  #   stalign3  #min_field_align > #max_field_align with NO #align -- C++ anchors this error on
  #             st->align, which here is nullptr, so it emits a POSITIONLESS "Error:" with no file,
  #             line or source snippet. The port had anchored it on min_field_align and printed a
  #             full position. Do NOT "fix" the bare Error: line; it is what the reference prints.
  #   stalign4  #align + #min_field_align + #max_field_align, all three coherence blocks true.
  #             Same anchor => print_all_errors MERGES them into ONE (#578). The port's divergent
  #             anchor escaped the merge and emitted a spurious second error.
  # All four FULL-MATCH. stalign3/stalign4 gate the SAME single line, from opposite directions.
  stalign1 stalign2 stalign3 stalign4

  # #803/#806 -- SWITCH CLAUSE ANCHORS. Two defects the same battery found.
  #   #803 Case_Clause end was `end_pos(p.prev_tok)` unconditionally. C++
  #        (parser_pos.cpp:238-244) is a THREE-WAY rule: last STATEMENT's end, else last LIST
  #        expression's end, else the `case` token. For an empty `case:` the port's version is
  #        the COLON, so every CLAUSE-anchored caret rendered `^~~~^` for the oracle's `^~~^`.
  #   swend1  type switch, duplicate `case:`   -- branch 3 (empty clause)
  #   swend2  value switch, duplicate `case:`  -- branch 3, the half the filed note never tested
  #   swend3  duplicate default with a MULTI-statement body -- branch 1; catches an implementation
  #           that takes the FIRST statement's end rather than the last.
  #   #806 The duplicate-VALUE-case emitter used error_node + error_line, so its
  #        "previous case at" continuation printed AFTER the source snippet. C++
  #        (check_expr.cpp:9673-9677) embeds it in the format string, so it prints BEFORE.
  #   swend4  duplicate value case -- gates the ORDER of the four output lines, which is
  #           invisible to any check that only counts or sorts them.
  # NOTE: swend4 is also a #803 CONTROL. It is anchored on the case EXPRESSION, not the clause,
  # so it MATCHED both before and after the parser change -- that is what bounded #803's blast
  # radius to clause-anchored diagnostics rather than "every switch diagnostic" as filed.
  swend1 swend2 swend3 swend4

  # #801 -- #min_field_align / #max_field_align were inert for OFFSETS.
  # C++ type_set_offsets_of (types.cpp:4545-4592) takes both as PARAMETERS and clamps EVERY
  # field: `align = gb_max(type_align_of_internal(t), min_field_align)` then, if max != 0,
  # `align = gb_min(align, max_field_align)`. The port clamped NOTHING.
  # WHY IT SURVIVED #112 AND #113: #113 wired these two directives into type_align_of, which is
  # the WHOLE-STRUCT alignment (types.cpp:4506-4511) -- a different computation that happens to
  # read the same two fields. "Wired up" was true of one consumer and false of the other.
  #   offalign1  #min_field_align raises a u8 field's offset 1 -> 8 (and size 2 -> 16)
  #   offalign2  #max_field_align CAPS a u64 field's offset 8 -> 2
  #   offalign3  BOTH directives at once, three fields deep -- catches a clamp applied in the
  #              wrong order, which offalign1/2 alone cannot distinguish
  #   offalign4  NESTED: the inner struct's directive must govern the inner layout only, and
  #              must NOT leak into the outer struct's field offsets
  # All four assert exact offsets, so they emit ZERO lines when correct -- a silent probe here
  # means the arithmetic agrees, not merely that both sides errored the same way.
  # NOT ADDED, DELIBERATELY: a #packed + #min_field_align case. The oracle REJECTS that
  # combination outright (a coherence error, see stalign*), so it would gate the diagnostic, not
  # the layout. C++'s packed arm takes neither parameter.
  offalign1 offalign2 offalign3 offalign4
  # #815. @(deprecated) on a TYPE was silent in the port and warns twice in the oracle.
  # The port assigned e.deprecated_message in exactly ONE place tree-wide -- check_decl.odin,
  # the PROCEDURE path -- while C++ also copies it in check_type_decl (check_decl.cpp:524).
  # The attribute was collected and the warning emitter was a complete faithful port; ONLY the
  # copy was missing, so the symptom was SILENCE rather than a wrong message. Nothing in the
  # existing corpus put @(deprecated) on a type, which is exactly why 324 green probes AND two
  # 323/323 parity sweeps all missed it -- a whole attribute path with zero coverage.
  # It has a `main` because members are compared with `odin build`; `Foo` is used TWICE (return
  # type and composite literal) so the probe pins BOTH warning positions, not just the count.
  # This probe is EMPTY on the pre-fix checker and matches the oracle after, so it can fail.
  p815type

  # LEDGER #828. type_to_string rendered an INSTANTIATED polymorphic procedure without its
  # bindings: `proc(i64, i64, f64) -> i64` where the reference prints `proc($T=i64, i64, f64) -> i64`.
  # The port's Tuple arm ignored the parameter ENTITY KIND and collapsed C++'s four renderings
  # (types.cpp:5573-5624) onto one. Nothing saw it: modeldiff.py does not compare the `type=`
  # column, and no package in the corpus or in either parity sweep put an `#assert`/`#panic`
  # inside an instantiated polymorphic body -- which is the diagnostic that prints such a
  # signature, via the `Called within '<name>' :: <sig>` continuation.
  # It has a `main` because members are compared with `odin build`, and it needs no flags, so
  # unlike the #826 rtti probes it can live here rather than in crosstarget.sh.
  # On the pre-fix checker the continuation line differs; after the fix it is byte-identical.
  p828poly

  # LEDGER #846. `e: os.Error = 0` -- a LIVE OVER-REJECTION until this tick: the reference accepts
  # it, the port emitted "Cannot convert untyped value '0' to 'Error' from 'untyped integer'".
  # C++'s convert_to_typed `case Type_Union:` opens with a transition-period carve-out (upstream's
  # own words: "IMPORTANT NOTE HACK(bill) ... comparisons against `0` with the `os.Error` type")
  # that was never ported.
  # WHY NO GATE SAW IT: `core/os` is in the 323-package parity list, but the carve-out EXEMPTS
  # package `os` itself (`c->pkg->name != "os"`), so it takes a DIFFERENT package assigning 0 to an
  # os.Error -- which nothing in the corpus or the package list happened to do. #815 again.
  # Needs no flags and has a `main`, so it belongs here rather than in crosstarget.sh. Note the
  # carve-out is also gated on `!strict_style`, and corpus members run plain `odin build`, so this
  # member exercises the ENABLED direction only.
  p846oserr

  # LEDGER #858. A pointer-subject type switch: `p: ^U; switch v in p`. C++
  # (check_stmt.cpp:1586-1591) uses a nil SENTINEL in two steps -- clear on
  # `list.count > 1 || saw_nil`, then `if (case_type == nullptr) case_type = type_deref(x.type)`
  # -- so the multi-type clause AND the DEFAULT clause (empty list, so the count test never
  # fires) both bind the DEREFERENCED subject type. #781 found the port had collapsed that to one
  # condition seeded with `x.type`, binding `^U`; the fix landed but NOTHING EVER OBSERVED IT.
  # This member is that missing observation. It has no diagnostics on either side today, and it
  # CAN fail: if the deref regresses, the port rejects `y: U = v` while the oracle accepts it.
  # Positive control (kept out of the corpus, at $S/p781neg): asserting `v: ^U` instead makes BOTH
  # sides emit 2 errors, which is what proves this probe reads the binding rather than passing
  # vacuously.
  p781ptr

  # LEDGER #859. `switch a.b in u { case int: ; case: ; case: }` -- a NON-IDENTIFIER lhs together
  # with DUPLICATE DEFAULT CLAUSES. C++ (check_stmt.cpp:1475-1490) runs the whole case-clause loop,
  # emitting "Multiple default clauses", and only THEN rejects the lhs, so BOTH diagnostics appear.
  # #779 found the port returning before the loop and emitting only the identifier error; the fix
  # (relocating the check below the loop) landed but NOTHING EVER OBSERVED IT. This member is that
  # observation: 2 errors on each side, same order, same positions.
  # It CAN fail: reinstating the early return drops the port to 1 error while the oracle keeps 2.
  # Control (kept out of the corpus, $S/p779ctl): with ONE default clause both sides emit exactly 1,
  # which is what proves the second error is the duplicate-default one and not an artefact.
  # Reproduces an UPSTREAM ODDITY deliberately -- "Expected an identifier, got 'identifier'" -- because
  # C++ reports the KIND OF RHS while positioning at rhs, though it is lhs that failed. Faithful.
  p779dflt

  # LEDGER #862. #796's two shapes, rebuilt after #860 found the originals had been DELETED despite
  # a ledger entry recording them as "re-ran ... 4/4 byte-identical". C++ enters check_or_return_expr
  # (check_expr.cpp:10185) and check_or_branch_expr (10268) through check_multi_expr_with_type_hint,
  # whose validity switch emits error_operand_no_value / error_operand_not_expression and sets
  # Addressing_Invalid; bare check_expr_base emits NEITHER. #796 filed both port sites as still using
  # check_expr_base -- they do not, both call the helper -- but nothing observed it until now.
  # orret: No_Value (`f() or_return`) + Type (`int or_return`) operands.
  # orbr:  the same two under or_break / or_continue, which is the OTHER sibling.
  # Both emit exactly 2 errors per side, byte-identical. They CAN fail: revert either entry call to
  # check_expr_base and the port emits neither message while the oracle still emits both.
  # Control (kept out of the corpus, $S/orctl): the same construct with a VALID operand
  # (`ok() or_return` returning an enum) gives 0 errors on BOTH sides -- which is what makes the two
  # errors attributable to the OPERAND KIND rather than to or_return itself.
  orret
  orbr
)

# --- Deliberate exclusions, each with the reason it is not a corpus member --------------------
# name                reason
EXCLUDED=(
  'wclean|#890/#905 NONDETERMINISTIC ON BOTH SIDES, so a fixed-expectation comparator cannot score it. This is the where-clause continuation-duplication repro: a failing where clause rendered its caret line, its blank separator and its With-the-following-definitions block TWICE while the header appeared once. MEASURED 2026-08-14, 20 runs per binary: pre-fix port 6/20 duplicated, post-fix port 0/20 -- the fix (a compare-exchange at the site that PRINTS, not the site that reads) holds. BUT THE ORACLE HAS THE SAME RACE, measured 1/30 here and 1/10 at #890, and it is UNFIXED UPSTREAM (filed as UPSTREAM-UNFILED-where-clause-continuation-rendered-twice). So on roughly one run in thirty this probe would report FULL-DIFFER because the ORACLE duplicated, with nothing wrong in the port -- a false regression indistinguishable from a real one. That is exactly the #635 probe-hygiene rule (a probe the oracle cannot answer stably is UNMEASURABLE, not a finding) applied to nondeterminism rather than to a crash. THE RIGHT INSTRUMENT IS A PORT-ONLY REPEAT CHECK, on flake.sh reasoning: the property worth protecting is that the PORT never duplicates, and comparing against the oracle here compares against the side that is wrong. Probe kept at .claude/probes/wclean as the repro and as the input for that check.'
  'loadmiss|#860 UPSTREAM BACKEND CRASH: the ORACLE SEGFAULTS on this 6/6 under `odin build`, so cmpfull scores it ORACLE-CRASHED and it cannot be a member. `data := #load("missing-file") or_else panic(...)` followed by a type-sensitive USE (`x: []u8 = data`). THREE ingredients, each verified necessary: the file must be MISSING (so or_else takes the not-found path where the tail does o^ = y), the default must be DIVERGING (so y_is_diverging skips check_assignment), and the result must be USED at a type. Drop any one and the oracle exits 0 or 1. THE CRASH IS IN THE BACKEND, NOT THE CHECKER: `odin check` on the same input is clean 4/4 while `odin build` segfaults 4/4, and the coredump names lb_append_tuple_values (src/llvm_backend_stmt.cpp:2495) under lb_generate_procedure. THE PORT IS A CHECKER AND IS CORRECT HERE -- 0 diagnostics, agreeing with the oracle CHECKER. Kept on disk as the repro for Jon to file; nothing is owed on the port side. Related: #285 and objc_super, both upstream crashes the port survives.'
  'litdrift|#639 ONLY, as of 2026-08-10. Built during #633: 16 one-literal files probing the parser/checker literal rule. Two divergences were tangled here and both are now resolved. (1) The ORDERING divergence -- the oracle put the hard tokenizer aborts ahead of the per-literal errors -- was #650, FIXED, and is now gated by the `offprobe` member above; litdrift is no longer the repro for it. (2) What remains is entirely #639, an UPSTREAM rendering bug filed and not fixed: f13 (`L13 :: 0h123`) and f14 (`L14 :: 0h1234567`) put their diagnostic at end-of-line, where C++ prints "( empty line )" in place of the source line and omits the caret, while the port prints the real line and caret. Every MESSAGE, KIND and POSITION agrees on both sides -- verified 2026-08-10; the only difference cmpfull can see is that unpaired `<cont>` line, which survives normalisation precisely because C++ emits no caret under it. NOTHING in the port is wrong here, so this stays excluded rather than being made bug-compatible: unlike #650, the observable is decoration and not semantics. Re-check when #639 lands upstream; the probe dirs are kept because they are the repro.'
  # All five re-probed 2026-08-04 (LEDGER #378). probe.sh reports MATCH for four of them; cmpfull.py
  # reports FULL-DIFFER for the same four. cmpfull is right and probe.sh is the looser instrument --
  # see the ledger. Reasons below are what the FULL comparison actually shows, not what probe.sh says.
  "fb|Foundation bisect scratch (#277/#278). probe.sh says MATCH; the FULL diff is 16 lines. Still excluded."
  "fb2|Foundation bisect scratch, deliberately truncated: SEL/BOOL/UInteger are USED but never DECLARED. 19 diagnostics each side at identical positions, differing on which of Undeclared-name vs is-not-a-type 4 of them get. The plain undeclared-name path MATCHES in isolation, in a foreign block, and in a proc type -- so this is recovery CLASSIFICATION after a cascade in a fragment with no declaration source, not an isolable rule."
  "fbisect|as fb; FULL diff is 15 lines."
  # SINGLE-quoted deliberately. This note names two commands, and in a DOUBLE-quoted array
  # element bash command-substitutes the backticks AT CONSTRUCTION time -- the exclusion
  # block then printed ~40 lines of `odin` usage text, twice, burying the list of what was
  # NOT measured. Cosmetic in effect, but it is command execution from a data string, and
  # this block exists precisely to stay legible. Keep single quotes for any note with ` or $.
  'objchang|#277 scratch. Message text and position divergences FIXED in #378. The residual is a HARNESS MISMATCH, not a port defect (#379): cmpfull.py runs the oracle as `odin build`, triage_st sets command_kind={.Check}, and C++ suppresses "only works on darwin" under Command_check/Command_doc (check_builtin.cpp:284). Oracle as `odin check` emits 0 of them, same as the port. Excluded until the comparators agree on which command they emulate.'
  "shadowparam|vet-mode probe -- a member of the VET corpus (corpus_vet.sh), which now exists and runs it; TEXT-MATCH as of #384. Excluded HERE only because this harness is the plain one."
  "shadowvar|vet-mode probe -- a member of the VET corpus (corpus_vet.sh), which now exists and runs it; TEXT-MATCH as of #384. Excluded HERE only because this harness is the plain one."
  "vetctl|vet-mode probe -- a member of the VET corpus (corpus_vet.sh), which now exists and runs it; TEXT-MATCH as of #384. Excluded HERE only because this harness is the plain one."
  "vetmap|vet-mode probe -- a member of the VET corpus (corpus_vet.sh), which now exists and runs it; TEXT-MATCH as of #384. Excluded HERE only because this harness is the plain one."
  'sp5|#662: the ORIGINAL repro, superseded as a corpus member by sp7 -- kept on disk because it is what found the defect. Two reasons it is not the gate. (a) It is where-clause-based, so it carries the #660 render flake: continuation lines in its definitions block duplicate nondeterministically, which a fixed-expectation comparator scores as a difference unrelated to the rule under test. (b) Its only polymorphic parameter is a typeid, so it never reaches the Entity_Constant arm or the ", " separator -- it would have PASSED a fix that handled types alone (#25/#39). sp7 pins all three arms and has no where clause. Both sides agree here (5/5 `S :: Foo($T=int);`) as of 2026-08-10; this is an instrument exclusion, not an unresolved divergence.'
  "objcctx|#285 UPSTREAM: the ORACLE segfaults on this 6/6 (zero-param @(objc_context_provider)). Port is correct; kept on disk as the repro"
  "vt_nopkg2|#307: the ORACLE is nondeterministic on the 'Suggestion: Add package ...' line -- it emitted it in 3/20 runs here (C++ parser.cpp:6863 calls this a race itself). Port is deterministic and matches the 17/20 majority; a fixed-expectation comparator cannot score it"
  "vt_nopkg3|#307: as vt_nopkg2, from the other side -- oracle emits the Suggestion in 19/20 runs, port always does, so it matches the majority but differs on the odd run"
)

if [ -z "$PORT" ]; then echo "usage: corpus.sh <PORT_BIN> [PROBE_ROOT]" >&2; exit 2; fi

dirs=()
missing=0
for p in "${CORPUS[@]}"; do
  if [ -d "$ROOT/$p" ]; then dirs+=("$ROOT/$p"); else
    printf "MISSING-PROBE %s\n" "$p"; missing=$((missing+1))
  fi
done

# The comparator's exit status is CHECKED, and the summary below is not printed without it.
# Until 2026-08-04 this call was unguarded: if cmpfull.py died, it printed nothing, the shell
# carried on, and "CORPUS-DONE members=176" appeared exactly as it does on a clean run. I hit that
# for real while A/B-testing a modified comparator -- the copy resolved its repo root from its own
# path, could not find ./odin, and threw on every single probe. The run reported 176 members and
# had compared ZERO. Same species as #275/#367/#369/#370: a summary that looks like a result for
# work that did not happen. LEDGER #380.
# Capture the status into a variable FIRST. `if ! cmd; then ... $? ...` reports the IF's status,
# not the command's, so the first version of this guard printed "exit 0" while aborting -- the same
# read-$?-through-a-construct mistake that gave a wrong answer twice today through pipelines.
python3 "$HERE/cmpfull.py" "$PORT" "${dirs[@]}"
cmp_rc=$?
# LEDGER #747: exit 4 means the comparator RAN and found divergences -- a real measurement that
# FAILED. Anything else non-zero means it did not run properly, which is the #380 case where the
# numbers are not a measurement at all. Collapsing the two would relabel every genuine port defect
# as a broken tool.
if [ $cmp_rc -eq 4 ]; then
  corpus_failed=1
elif [ $cmp_rc -ne 0 ]; then
  echo "CORPUS-ABORTED comparator failed (exit $cmp_rc) -- NOTHING below is a measurement" >&2
  exit 1
fi

echo "--- exclusions (UNMEASURED, not clean) ---"
for e in "${EXCLUDED[@]}"; do printf "  %-14s %s\n" "${e%%|*}" "${e#*|}"; done
echo "CORPUS-DONE members=${#CORPUS[@]} missing=$missing excluded=${#EXCLUDED[@]}"
if [ "${corpus_failed:-0}" -eq 1 ]; then
  echo "CORPUS-FAILED port and oracle DIVERGE on at least one probe -- see the FULL-DIFFER rows above" >&2
  exit 1
fi

# LEDGER #745 (Jon: "if its got an error in the checker port it needs announced from tool").
# A probe that is not on disk is NOT a pass. Until now `missing` was counted, printed inside the
# summary above, and then ignored -- so a run that located 4 of 302 members printed `members=302`
# and exited 0. That is the #380 failure one level up: the guard was added for the COMPARATOR
# dying, and left open for the INPUTS going missing. #155/#26: a green from an instrument that had
# nothing to measure is not evidence.
if [ "$missing" -gt 0 ]; then
  echo "CORPUS-ABORTED $missing of ${#CORPUS[@]} probe directories are MISSING from $ROOT -- the numbers above are NOT a measurement" >&2
  exit 1
fi

