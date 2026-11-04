; ============================================================================
; rx286 - src/kernel/ldt.asm
; The programs' local descriptor tables, and their pristine copies.
;
; The descriptors of the programs the kernel's image carries (roadmap l4.md
; L1, L3): the program's code, data and stack, the fuzzer's alias of its
; data as code in fuzz builds, and empty slots; the counter's likewise. At
; start the kernel copies them into each program's space in the arena
; (cap.asm), whose LDT the program then runs with. An empty slot is all zeros: not present, DPL 0,
; no valid type, so ring 3 can neither load it nor learn anything of it
; with LAR, LSL, VERR or VERW (l4.md E2). The counter (l4.md L2) has an
; LDT of the same shape over its own memory, so the same selectors name its
; segments. Every start of a program copies its pristine table over the
; live one (ldt_restore), so a test probe that changed a descriptor
; (test.asm) is undone.
; ============================================================================

; program_ldt_entries - the program's slots, in the order of selectors.inc
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

; counter_ldt_entries - the counter's slots: the same selectors, its memory
%macro counter_ldt_entries 0
        segment_descriptor CTEXT_PHYS, CTEXT_ROOM - 1, ACC_UCODE    ; SEL_UCODE
        segment_descriptor CDATA_PHYS, CDATA_ROOM - 1, ACC_UDATA    ; SEL_UDATA
        segment_descriptor CSTACK_PHYS, CSTACK_SIZE - 1, ACC_UDATA  ; SEL_USTACK
  %rep LDT_ENTRIES - 3
        segment_descriptor 0, 0, 0                                  ; empty
  %endrep
%endmacro

program_ldt_pristine:
        program_ldt_entries
program_ldt_end:
counter_ldt_pristine:
        counter_ldt_entries

%if program_ldt_end - program_ldt_pristine != LDT_LIMIT + 1
  %error "ldt.asm: the program's LDT does not match LDT_ENTRIES"
%endif

[section ktext]
; ----------------------------------------------------------------------------
; ldt_restore - the running thread's segments as its image describes them:
; each present descriptor of the pristine table into its slot again, with
; its shadow entry (a probe, or the program's own KCALL_DELETE, may have
; changed them); a slot the image leaves empty may hold a capability now,
; and is left alone
;   In:       DS = SEL_KDATA
;   Out:      nothing
;   Destroys: nothing
; ----------------------------------------------------------------------------
ldt_restore:
        push ax
        push bx
        push cx
        push dx
        push si
        push di
        mov bx, [cur_thread]
        mov dx, [bx + T_LDT_PRISTINE]
        test dx, dx
        jz .done                        ; a thread made by the kernel's calls: none
        mov bx, [bx + T_SPACE]
        xor cx, cx                      ; the slot
.slot:
        mov si, dx
        test byte [si + 5], ACC_PRESENT
        jz .next
        mov ax, cx
        call slot_at                    ; SI, DI = the slot
        push bx
        mov bx, dx
        call slot_put_descriptor
        pop bx
.next:
        add dx, 8
        inc cx
        cmp cx, LDT_ENTRIES
        jb .slot
.done:
        pop di
        pop si
        pop dx
        pop cx
        pop bx
        pop ax
        ret
[section kdata]
