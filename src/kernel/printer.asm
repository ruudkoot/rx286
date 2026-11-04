; ============================================================================
; rx286 - src/kernel/printer.asm
; The parallel printer ports LPT1 and LPT2: SYS_PRINT (storage roadmap D5).
;
; The printer is driven as IBM's BIOS drives it (5-122): for each byte, wait
; until the printer is not busy, put the byte on the data lines, and pulse
; STROBE. The wait polls the status port with interrupts let in, for
; LPT_BUSY_TICKS at most. The printer's interrupt (-ACK) stays off, so IRQ7
; and IRQ5 keep the rule of a line without a driver. After each byte, as
; SYS_WRITE does, interrupts are let in, and a restart asked for meanwhile
; ends the call early. A port with no printer reads busy and out of paper,
; as on the AT: the call fails with E_PAPER after LPT_BUSY_TICKS. A call that
; fails says in CX how many bytes the printer took first, so the caller
; knows where to go on.
; ============================================================================

LPT_BUSY_TICKS      equ 100 + 1         ; 2 s for the printer to take a byte
LPT_INIT_READS      equ 64              ; -INIT held low that long: 50 us at the least

begin_kdata
printer_ports       dw LPT1_BASE, LPT2_BASE
end_kdata

; ----------------------------------------------------------------------------
; printer_init - reset both printers: -INIT low, then high
;   In:       DS = SEL_KDATA; interrupts off
;   Out:      nothing
;   Destroys: AL, CX, DX, SI
; ----------------------------------------------------------------------------
printer_init:
        mov si, printer_ports
.port:
        mov dx, [si]
        add dx, LPT_CONTROL
        mov al, LPT_CONTROL_INIT
        out dx, al
        mov cx, LPT_INIT_READS
.hold:
        in al, dx
        loop .hold
        mov al, LPT_CONTROL_READY
        out dx, al
        add si, 2
        cmp si, printer_ports + 2 * PRINTERS
        jb .port
        ret

; ----------------------------------------------------------------------------
; sys_print - SYS_PRINT: the caller's DS:SI, CX bytes, to a printer
;   In:       BP = the frame (AL the printer); DS = SEL_KDATA
;   Out:      the frame's AX = bytes printed; or an error, and the frame's CX
;             = bytes printed before it (E_PAPER, E_TIMEOUT)
;   Destroys: AX, BX, CX, DX, SI, DI, ES
; ----------------------------------------------------------------------------
sys_print:
        mov al, [bp + FRAME_AX]
        cmp al, PRINTERS
        jae .invalid
        xor ah, ah
        mov di, ax
        shl di, 1
        mov di, [printer_ports + di]
        mov cx, [bp + FRAME_CX]
        cmp cx, PRINT_MAX
        ja .invalid
        mov word [bp + FRAME_AX], 0
        jcxz .done
        mov si, [bp + FRAME_SI]
        mov ax, [bp + FRAME_DS]
        call check_buffer               ; ES = the caller's segment
        jc .fault
        xor bx, bx                      ; BX = bytes printed
.next:
        call recheck_buffer             ; after a window, the descriptor may differ
        jc .gone
        mov al, [es:si]
        call lpt_byte
        jc .fail
        inc si
        inc bx
        sti                             ; interrupts in after every byte
        nop
        cli
        cmp byte [restart_pending], 0
        jne .printed
        loop .next
.printed:
        mov [bp + FRAME_AX], bx
.done:
        ret
.invalid:
        mov ax, E_INVAL
        jmp sys_fail
.fault:
        mov ax, E_FAULT
        jmp sys_fail
.gone:
        mov ax, E_FAULT
.fail:
        mov [bp + FRAME_CX], bx
        jmp sys_fail

; ----------------------------------------------------------------------------
; lpt_byte - one byte to a printer, once it is not busy
;   In:       AL = the byte; DI = the port's base; DS = SEL_KDATA;
;             interrupts off
;   Out:      CF clear; or CF set and AX = E_PAPER or E_TIMEOUT
;   Destroys: AX, DX
; ----------------------------------------------------------------------------
lpt_byte:
        push cx
        push ax
        mov dx, di
        add dx, LPT_STATUS
        mov ah, LPT_STATUS_NOT_BUSY
        mov al, LPT_STATUS_NOT_BUSY
        mov cx, LPT_BUSY_TICKS
        call kpoll
        pop cx                          ; CL = the byte
        jc .busy
        mov al, cl
        mov dx, di
        add dx, LPT_DATA
        out dx, al
        add dx, LPT_CONTROL - LPT_DATA
        mov al, LPT_CONTROL_STROBE
        out dx, al
        mov al, LPT_CONTROL_READY
        out dx, al
        pop cx
        clc
        ret
.busy:
        test al, LPT_STATUS_PAPER_END
        mov ax, E_PAPER
        jnz .failed
        mov ax, E_TIMEOUT
.failed:
        pop cx
        stc
        ret
