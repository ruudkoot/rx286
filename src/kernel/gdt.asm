; ============================================================================
; rx286 - src/kernel/gdt.asm
; The global descriptor table, written out at assembly time.
;
; docs/protected-mode.md explains each descriptor. Every base is a constant
; of layout.inc, or a label of kdata at its physical address (the TSSs);
; every
; segment's accessed bit is preset, so the CPU never writes this table but
; for the TSS's busy bit. Every descriptor has DPL 0: the program's segments
; are in its LDT (ldt.asm), and the GDT holds none a program could load.
; ============================================================================

; kdata_descriptor label, limit, access - a descriptor of something in kdata.
; A label cannot be split into bytes, but KDATA_PHYS's low word plus a
; label's place in kdata (the label less KDATA_VSTART) never carries
; (checked below), so the base is written in two parts.
%macro kdata_descriptor 3
    dw (%2)
    dw (KDATA_PHYS & 0xFFFF) + (%1) - KDATA_VSTART
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
        segment_descriptor KDATA_BASE, 0xFFFF, ACC_KDATA            ; SEL_KDATA: and the arena
        segment_descriptor KSTACK_PHYS, KSTACK_SIZE - 1, ACC_KDATA  ; SEL_KSTACK
        kdata_descriptor tss, TSS286_LIMIT, ACC_TSS                 ; SEL_TSS
        kdata_descriptor df_tss, TSS286_LIMIT, ACC_TSS              ; SEL_DFTSS
        segment_descriptor DFSTACK_PHYS, DFSTACK_SIZE - 1, ACC_KDATA    ; SEL_DFSTACK
        segment_descriptor VIDEO_PHYS, VIDEO_SIZE - 1, ACC_KDATA    ; SEL_VIDEO
%rep SPACE_MAX + THREAD_MAX                                 ; the pools (cap.asm)
        segment_descriptor 0, 0, 0
%endrep
        segment_descriptor 0, 0, 0                                  ; SEL_SCRATCH
        segment_descriptor 0, 0, 0                                  ; SEL_SCRATCH2
gdt_end:

%if GDT_ENTRIES * 8 - 1 != GDT_LIMIT
  %error "gdt.asm: GDT_LIMIT does not match GDT_ENTRIES"
%endif

; The pseudo-descriptor LGDT reads: limit, 24-bit base, a zero byte.
gdt_pointer:
        dw GDT_LIMIT
        dw (KDATA_PHYS & 0xFFFF) + gdt - KDATA_VSTART
        db KDATA_PHYS >> 16, 0
