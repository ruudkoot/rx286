; ============================================================================
; rx286 - src/kernel/pic.asm
; The two 8259A interrupt controllers, and the rule for every IRQ line
; (roadmap D12).
;
; The BIOS left IRQ0-7 on vectors 08h-0Fh, the CPU's own exceptions in
; protected mode (roadmap X1), so pic_init reprograms both controllers to
; 20h-2Fh before interrupts are enabled. A line with a driver of the
; kernel's goes to it. A line a driver outside the kernel has bound to a
; notification (KCALL_IRQ; roadmap l4.md L7, D10) is masked, acknowledged
; and the notification signalled; the driver's IRQ_ACK unmasks it, and an
; interrupt that came meanwhile waits in the 8259A. The first interrupt of
; a line without either is reported, and the line masked, so nothing goes
; unreported and nothing can flood. IRQ7 and IRQ15 are checked
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
        dw 0                            ; IRQ1: the keyboard driver's (l4.md L8)
        dw 0                            ; IRQ2
%ifdef WITH_MODEM
        dw modem_irq                    ; IRQ3: COM2, the modem
%else
        dw 0                            ; IRQ3: COM2 is the log, polled
%endif
        dw 0                            ; IRQ4: COM1, the mouse: its driver's
        dw 0                            ; IRQ5
        dw 0                            ; IRQ6: the diskette driver's (l4.md L9)
        dw 0                            ; IRQ7
        dw 0, 0, 0, 0, 0                ; IRQ8-12
        dw fpu_irq                      ; IRQ13
        dw 0                            ; IRQ14: the fixed disk driver's
        dw 0                            ; IRQ15
irq_notify          times IRQ_LINES dw 0    ; a line's bound notification, or 0
irq_bits            times IRQ_LINES dw 0    ; and the bits it signals
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
        cmp word [irq_notify + bx], 0
        jne .bound
        mov ax, [irq_drivers + bx]
        test ax, ax
        jz .unhandled
        call ax
        pop bx
        call pic_eoi
        jmp wake_waiters                ; threads waiting inside the kernel look again
.bound:
        pop bx
        call pic_mask                   ; until its driver says it is done
        call pic_eoi
        jmp irq_signal
.unhandled:
        pop bx
        call irq_unhandled
        call pic_eoi
        jmp wake_waiters
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
; irq_signal - a bound line's notification, signalled with its bits
;   In:       BX = the line; DS = SEL_KDATA
;   Out:      nothing (a line not bound: nothing)
;   Destroys: AX, SI
; ----------------------------------------------------------------------------
irq_signal:
        push bx
        shl bx, 1
        mov si, [irq_notify + bx]
        mov ax, [irq_bits + bx]
        pop bx
        test si, si
        jz .done
        jmp ntf_signal                  ; (ipc.asm)
.done:
        ret

; ----------------------------------------------------------------------------
; pic_mask - a line off at its 8259A
;   In:       BX = the line, 0-15
;   Out:      nothing
;   Destroys: AX
; ----------------------------------------------------------------------------
pic_mask:
        push cx
        push dx
        call pic_line_bit
        in al, dx
        or al, ah
        out dx, al
        pop dx
        pop cx
        ret

; ----------------------------------------------------------------------------
; pic_unmask - a line on at its 8259A
;   In:       BX = the line, 0-15
;   Out:      nothing
;   Destroys: AX
; ----------------------------------------------------------------------------
pic_unmask:
        push cx
        push dx
        call pic_line_bit
        in al, dx
        not ah
        and al, ah
        out dx, al
        pop dx
        pop cx
        ret

; ----------------------------------------------------------------------------
; pic_line_bit - a line's mask port and bit
;   In:       BX = the line, 0-15
;   Out:      DX = its 8259A's data port; AH = its bit there
;   Destroys: CL
; ----------------------------------------------------------------------------
pic_line_bit:
        mov cx, bx
        mov dx, PIC1_DATA
        cmp cl, 8
        jb .bit
        sub cl, 8
        mov dx, PIC2_DATA
.bit:
        mov ah, 1
        shl ah, cl
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
        call pic_mask
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
