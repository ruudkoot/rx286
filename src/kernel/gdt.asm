; ============================================================================
; rx286 - src/kernel/gdt.asm
; The global descriptor table: its fixed part, written out at assembly
; time, which the entry loads; and the whole, which gdt_init builds at
; GDT_PHYS with the pool of the kernel's objects' descriptors (os-server.md
; P3).
;
; docs/protected-mode.md explains each descriptor. Every base is a constant
; of layout.inc, or a label of kdata at its physical address (the TSSs, the
; idle loop's thread); every segment's accessed bit is preset, so the CPU
; never writes this table but for the TSS's busy bit. Every descriptor has
; DPL 0: a program's segments are in its space's LDT (cap.asm), and the GDT
; holds none a program could load.
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
        segment_descriptor KDATA_BASE, KSTACK_BOTTOM - 1, ACC_KDATA | ACC_EXPAND_DOWN ; SEL_KSTACK
        kdata_descriptor tss, TSS286_LIMIT, ACC_TSS                 ; SEL_TSS
        kdata_descriptor df_tss, TSS286_LIMIT, ACC_TSS              ; SEL_DFTSS
        segment_descriptor DFSTACK_PHYS, DFSTACK_SIZE - 1, ACC_KDATA    ; SEL_DFSTACK
        segment_descriptor VIDEO_PHYS, VIDEO_SIZE - 1, ACC_KDATA    ; SEL_VIDEO
        segment_descriptor 0, 0, 0                                  ; SEL_SCRATCH
        segment_descriptor 0, 0, 0                                  ; SEL_SCRATCH2
        kdata_descriptor idle_tcb, TCB_SIZE - 1, ACC_KDATA          ; SEL_IDLE
gdt_end:

%if gdt_end - gdt != SEL_OBJ_POOL
  %error "gdt.asm: the fixed part of the GDT does not end at SEL_OBJ_POOL"
%endif

; The pseudo-descriptors LGDT reads: limit, 24-bit base, a zero byte. The
; entry's, for the fixed part in the image; then gdt_init's.
gdt_pointer:
        dw GDT_BOOT_LIMIT
        dw (KDATA_PHYS & 0xFFFF) + gdt - KDATA_VSTART
        db KDATA_PHYS >> 16, 0
gdt_full_pointer:
        dw GDT_LIMIT
        dw GDT_PHYS & 0xFFFF
        db GDT_PHYS >> 16, 0
