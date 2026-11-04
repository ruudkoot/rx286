; ============================================================================
; rx286 - src/kernel/pic.asm
; The two 8259A interrupt controllers: IRQ0-15 on vectors 20h-2Fh.
;
; The BIOS left IRQ0-7 on vectors 08h-0Fh, the CPU's own exceptions in
; protected mode (roadmap X1), so pic_init reprograms both before the kernel
; enables interrupts, and masks every line. (M4: every IRQ is a panic; M5
; adds the drivers and the rule for lines without one.)
; ============================================================================

begin_kdata
msg_unexpected_irq  db "an IRQ before any driver", 0
end_kdata

; ----------------------------------------------------------------------------
; pic_init - both 8259As on vectors 20h-2Fh, cascaded on IRQ2, all masked
;   In:       interrupts off
;   Out:      nothing
;   Destroys: AX
; ----------------------------------------------------------------------------
pic_init:
        mov al, PIC_ICW1_ICW4
        out PIC1_CMD, al
        out PIC2_CMD, al
        mov al, PIC1_VECTOR_BASE
        out PIC1_DATA, al
        mov al, PIC2_VECTOR_BASE
        out PIC2_DATA, al
        mov al, PIC1_ICW3_SLAVE_AT
        out PIC1_DATA, al
        mov al, PIC2_ICW3_ID
        out PIC2_DATA, al
        mov al, PIC_ICW4_8086
        out PIC1_DATA, al
        out PIC2_DATA, al
        mov al, 0xFF                    ; mask every line
        out PIC1_DATA, al
        out PIC2_DATA, al
        ret

; ----------------------------------------------------------------------------
; irq - the handler of vectors 20h-2Fh
;   In:       BP = the frame; DS = ES = SEL_KDATA
;   Out:      does not return before M5
;   Destroys: everything
; ----------------------------------------------------------------------------
irq:
        mov si, msg_unexpected_irq
        jmp panic
