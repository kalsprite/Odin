# docflag_probe -- positive control for the doc-output FLAG BITS (#479 / #483)

Four declarations, one per (kind, bit) combination that docs_writer sets from an entity VARIANT,
plus a negative control.

    <PORT_BIN> .claude/tools/docflag_probe -dump-doc:/tmp/out.txt

Expected, exactly:

    doc	exported_proc	    Procedure	flags=Export
    doc	exported_var	    Variable	flags=Export
    doc	plain_proc	        Procedure	flags=-           <-- negative control
    doc	some_foreign_proc	Procedure	flags=Foreign

WHY IT EXISTS. #479 fixed docs_writer to read is_foreign/is_export from the Entity VARIANT
(Variable/Procedure) rather than from common entity flags that nothing ever sets. That fix was
asserted from a line-for-line C++ reading and stayed UNMEASURED for a long time, because no gate
looked at doc flag bits at all -- doccmp.sh compares entity PRESENCE.

`plain_proc` matters as much as the other three: without it, a bug that sets every bit
unconditionally would pass. And `core/c/libc` covers the fourth combination this file cannot --
foreign VARIABLES (3 of them) alongside 393 foreign procedures.

THE A/B THAT VERIFIED IT (#483): neutering the four variant reads drops libc's Foreign count from
396 to 0 with the entity count unchanged. So these four sites are the only producers of the bit.
