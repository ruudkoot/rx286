; ============================================================================
; rx286 - src/kernel/pic.asm
; The two 8259A interrupt controllers, and the rule for every IRQ line
; (roadmap D12).
;
; The BIOS left IRQ0-7 on vectors 08h-0Fh, the CPU's own exceptions in
; protected mode (roadmap X1), so pic_init reprograms both controllers to
; 20h-2Fh before interrupts are enabled. A line with a driver goes to it; the
; first interrupt of a line without one is reported, and the line masked, so
; nothing goes unreported and nothing can flood. IRQ7 and IRQ15 are checked
; for spurious delivery first: no EOI to the PIC that raised them (a spurious
; IRQ15 still gets the master's EOI, for the cascade). IRQ2, the cascade, is
; never masked: that would cut off IRQ8-15 (roadmap X9).
; ============================================================================

PIC_SPURIOUS_BIT    equ 0x80            ; IR7 of either PIC
IRQ_SPURIOUS_MASTER equ 7
IRQ_SPURIOUS_SLAVE  equ 15

begin_kdata
; The driver of each line, or 0 for none.
irq_drivers:
        dw timer_irq                    ; IRQ0
        dw kbd_irq                      ; IRQ1
        dw 0                            ; IRQ2
        dw modem_irq                    ; IRQ3: COM4, the modem (COM2 is the log, polled)
        dw mouse_irq                    ; IRQ4: COM1, the mouse
        dw 0                            ; IRQ5
        dw fd_irq                       ; IRQ6
        dw 0                            ; IRQ7
        dw 0, 0, 0, 0, 0                ; IRQ8-12
        dw fpu_irq                      ; IRQ13
        dw hd_irq                       ; IRQ14
        dw 0                            ; IRQ15
irq_spurious        dw 0                ; spurious IRQ7 and IRQ15 seen
msg_unhandled       db "unhandled IRQ ", 0
msg_masked          db ", now masked", CHAR_LF, 0
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
        mov al, 0xFF                    ; mask every line until the drivers are ready
        out PIC1_DATA, al
        out PIC2_DATA, al
        ret

; ----------------------------------------------------------------------------
; pic_unmask_all - every line on, IRQ2 included
;   In:       nothing
;   Out:      nothing
;   Destroys: AX
; ----------------------------------------------------------------------------
pic_unmask_all:
        xor al, al
        out PIC1_DATA, al
        out PIC2_DATA, al
        ret

; ----------------------------------------------------------------------------
; irq - the handler of vectors 20h-2Fh: spurious check, driver or rule, EOI
;   In:       BP = the frame; DS = ES = SEL_KDATA
;   Out:      nothing
;   Destroys: AX, BX, CX, DX, SI, DI
; ----------------------------------------------------------------------------
irq:
        mov bx, [bp + FRAME_VECTOR]
        sub bx, VEC_IRQ0                ; BX = the line
        cmp bx, IRQ_SPURIOUS_MASTER
        je .check_master
        cmp bx, IRQ_SPURIOUS_SLAVE
        je .check_slave
.real:
        push bx
        shl bx, 1
        mov ax, [irq_drivers + bx]
        test ax, ax
        jz .unhandled
        call ax
        pop bx
        jmp pic_eoi
.unhandled:
        pop bx
        call irq_unhandled
        jmp pic_eoi
.check_master:
        mov al, PIC_READ_ISR
        out PIC1_CMD, al
        in al, PIC1_CMD
        test al, PIC_SPURIOUS_BIT
        jnz .real
        inc word [irq_spurious]
        TRACE "spurious IRQ7"
        ret                             ; no EOI: the master has nothing in service
.check_slave:
        mov al, PIC_READ_ISR
        out PIC2_CMD, al
        in al, PIC2_CMD
        test al, PIC_SPURIOUS_BIT
        jnz .real
        inc word [irq_spurious]
        TRACE "spurious IRQ15"
        mov al, PIC_EOI                 ; the master did see IRQ2
        out PIC1_CMD, al
        ret

; ----------------------------------------------------------------------------
; pic_eoi - end of interrupt for a line: the slave first, then the master
;   In:       BX = the line, 0-15
;   Out:      nothing
;   Destroys: AL
; ----------------------------------------------------------------------------
pic_eoi:
        mov al, PIC_EOI
        cmp bx, 8
        jb .master
        out PIC2_CMD, al
.master:
        out PIC1_CMD, al
        ret

; ----------------------------------------------------------------------------
; irq_unhandled - report a line without a driver, and mask it
;   In:       BX = the line, 0-15; DS = SEL_KDATA
;   Out:      nothing
;   Destroys: AX, CX, DX, SI
; ----------------------------------------------------------------------------
irq_unhandled:
        mov cx, bx
        mov dx, PIC1_DATA
        cmp cl, 8
        jb .mask
        sub cl, 8
        mov dx, PIC2_DATA
.mask:
        mov ah, 1
        shl ah, cl
        in al, dx
        or al, ah
        out dx, al
        mov al, ATTR_KERNEL
        call con_set_attr
        mov si, msg_log_prefix
        call kputs
        mov si, msg_unhandled
        call kputs
        mov ax, bx
        xor dx, dx
        call kput_dec32
        mov si, msg_masked
        call kputs
        mov al, ATTR_NORMAL
        jmp con_set_attr
