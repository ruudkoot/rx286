; ============================================================================
; rx286 - src/kernel/ldt.asm
; The program's local descriptor table, and its pristine copy.
;
; The program's segments live here, not in the GDT (roadmap l4.md L1): its
; code, data and stack, the fuzzer's alias of its data as code in fuzz
; builds, and empty slots. An empty slot is all zeros: not present, DPL 0,
; no valid type, so ring 3 can neither load it nor learn anything of it
; with LAR, LSL, VERR or VERW (l4.md E2). Every start of the program copies
; the pristine table over the live one (ldt_restore), so a test probe that
; changed a descriptor (syscall.asm) is undone.
; ============================================================================

; program_ldt_entries - the LDT's slots, in the order of selectors.inc
%macro program_ldt_entries 0
        segment_descriptor UTEXT_PHYS, UTEXT_ROOM - 1, ACC_UCODE    ; SEL_UCODE
        segment_descriptor UDATA_PHYS, UDATA_ROOM - 1, ACC_UDATA    ; SEL_UDATA
        segment_descriptor USTACK_PHYS, USTACK_SIZE - 1, ACC_UDATA  ; SEL_USTACK
  %ifdef TEST_FUZZ
        segment_descriptor UDATA_PHYS, UDATA_ROOM - 1, ACC_UCODE    ; SEL_UFUZZ
  %else
        segment_descriptor 0, 0, 0                                  ; empty
  %endif
  %rep LDT_ENTRIES - 4
        segment_descriptor 0, 0, 0                                  ; empty
  %endrep
%endmacro

program_ldt:
        program_ldt_entries
program_ldt_end:
program_ldt_pristine:
        program_ldt_entries

%if program_ldt_end - program_ldt != LDT_LIMIT + 1
  %error "ldt.asm: the program's LDT does not match LDT_ENTRIES"
%endif

[section ktext]
; ----------------------------------------------------------------------------
; ldt_restore - the program's LDT as it was built
;   In:       DS = SEL_KDATA
;   Out:      nothing
;   Destroys: nothing
; ----------------------------------------------------------------------------
ldt_restore:
        push cx
        push si
        push di
        push es
        push ds
        pop es
        mov si, program_ldt_pristine
        mov di, program_ldt
        mov cx, (LDT_LIMIT + 1) / 2
        cld
        rep movsw
        pop es
        pop di
        pop si
        pop cx
        ret
[section kdata]
