; ============================================================================
; rx286 - src/kernel/gdt.asm
; The global descriptor table, written out at assembly time.
;
; docs/protected-mode.md explains each descriptor. Every base is a constant
; of layout.inc, or kdata's base plus a label of kdata (the TSSs); every
; segment's accessed bit is preset, so the CPU never writes this table but
; for the TSS's busy bit.
; ============================================================================

; kdata_descriptor offset, limit, access - a descriptor of something in kdata.
; A label cannot be split into bytes, but KDATA_PHYS's low word plus a kdata
; offset never carries (checked below), so the base is written in two parts.
%macro kdata_descriptor 3
    dw (%2)
    dw (KDATA_PHYS & 0xFFFF) + (%1)
    db KDATA_PHYS >> 16
    db (%3)
    dw 0                            ; reserved: zero
%endmacro

%if (KDATA_PHYS & 0xFFFF) + KDATA_ROOM > 0x10000
  %error "gdt.asm: kdata crosses a 64 KB boundary; kdata_descriptor would carry"
%endif

gdt:
        segment_descriptor 0, 0, 0                                  ; SEL_NULL
        segment_descriptor KTEXT_PHYS, ktext_end - 1, ACC_KCODE     ; SEL_KCODE
        segment_descriptor KDATA_PHYS, kdata_end - 1, ACC_KDATA     ; SEL_KDATA
        segment_descriptor KSTACK_PHYS, KSTACK_SIZE - 1, ACC_KDATA  ; SEL_KSTACK
        kdata_descriptor tss, TSS286_LIMIT, ACC_TSS                 ; SEL_TSS
        kdata_descriptor df_tss, TSS286_LIMIT, ACC_TSS              ; SEL_DFTSS
        segment_descriptor DFSTACK_PHYS, DFSTACK_SIZE - 1, ACC_KDATA    ; SEL_DFSTACK
        segment_descriptor VIDEO_PHYS, VIDEO_SIZE - 1, ACC_KDATA    ; SEL_VIDEO
        segment_descriptor UTEXT_PHYS, UTEXT_ROOM - 1, ACC_UCODE    ; SEL_UCODE
        segment_descriptor UDATA_PHYS, UDATA_ROOM - 1, ACC_UDATA    ; SEL_UDATA
        segment_descriptor USTACK_PHYS, USTACK_SIZE - 1, ACC_UDATA  ; SEL_USTACK
%ifdef TEST_FUZZ
        segment_descriptor UDATA_PHYS, UDATA_ROOM - 1, ACC_UCODE    ; SEL_UFUZZ
%endif
gdt_end:

%if GDT_ENTRIES * 8 - 1 != GDT_LIMIT
  %error "gdt.asm: GDT_LIMIT does not match GDT_ENTRIES"
%endif

; The pseudo-descriptor LGDT reads: limit, 24-bit base, a zero byte.
gdt_pointer:
        dw GDT_LIMIT
        dw (KDATA_PHYS & 0xFFFF) + gdt
        db KDATA_PHYS >> 16, 0
