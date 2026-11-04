; ============================================================================
; rx286 - src/kernel/modem.asm
; COM2 as the program's serial line, for a modem: SYS_SERIAL_WRITE and
; SYS_SERIAL_READ (devices roadmap D2).
;
; In release builds (and test builds made with MODEM_COM2), COM2 runs at
; 9600 baud, 8N1, DTR and RTS up. A byte that comes raises IRQ3, and the
; kernel puts it in a ring of MODEM_RING bytes; a full ring drops it, and
; counts it. The program takes what is in the ring with SYS_SERIAL_READ,
; which never waits: SYS_WAIT waits for it. SYS_SERIAL_WRITE sends as
; SYS_PRINT prints: each byte once the UART can take it (2 s at most),
; interrupts let in after each, a restart ending it early. In debug and
; test builds COM2 is the kernel's log, and both calls fail with E_BUSY.
;
; Every tick also fetches what COM2 holds (timer_irq), in case an interrupt
; was lost. A 16450 holds one byte: at 9600 baud one comes every 1.04 ms,
; and the kernel's longest stretches with interrupts off (the game port's
; timing, 4 ms; a scroll of the screen, a few ms on a real AT) can lose
; some, which modem_overruns counts. A 16550's FIFO, turned on where there is
; one, holds 16. A port that reads all ones has no UART.
; ============================================================================

%ifdef WITH_MODEM

MODEM_RING          equ 256             ; byte indices wrap by themselves
MODEM_BYTE_TICKS    equ 100 + 1         ; 2 s for the UART to take a byte
MODEM_IRQ_BYTES     equ 16              ; bytes taken at most in one interrupt

begin_kdata
modem_ring          times MODEM_RING db 0
modem_head          db 0                ; the next byte to take
modem_tail          db 0                ; where the next byte goes
modem_dropped       dw 0                ; bytes lost to a full ring
modem_overruns      dw 0                ; bytes the UART lost before they were read
end_kdata

; ----------------------------------------------------------------------------
; modem_init - COM2 at 9600 baud, 8N1, DTR, RTS and OUT2 up, an interrupt
; for each byte that comes
;   In:       interrupts off
;   Out:      nothing
;   Destroys: AL, DX
; ----------------------------------------------------------------------------
modem_init:
        mov dx, COM2_BASE + UART_LCR
        mov al, UART_LCR_DLAB
        out dx, al
        mov dx, COM2_BASE + UART_DLL
        mov al, UART_DIVISOR_9600
        out dx, al
        mov dx, COM2_BASE + UART_DLM
        xor al, al
        out dx, al
        mov dx, COM2_BASE + UART_LCR
        mov al, UART_LCR_8N1
        out dx, al
        mov dx, COM2_BASE + UART_FCR
        mov al, UART_FCR_FIFO
        out dx, al
        mov dx, COM2_BASE + UART_RBR
        in al, dx                       ; nothing stale
        mov dx, COM2_BASE + UART_IER
        mov al, UART_IER_RECEIVED
        out dx, al
        mov dx, COM2_BASE + UART_MCR
        mov al, UART_MCR_RUN
        out dx, al
        ret

; ----------------------------------------------------------------------------
; modem_irq - IRQ3, and every tick: the bytes COM2 has, into the ring
;   In:       DS = SEL_KDATA
;   Out:      nothing (the dispatcher sends EOI)
;   Destroys: AX, BX, CX, DX
; ----------------------------------------------------------------------------
modem_irq:
        mov cx, MODEM_IRQ_BYTES
.next:
        mov dx, COM2_BASE + UART_LSR
        in al, dx
        cmp al, UART_LSR_ABSENT
        je .done                        ; no UART there
        test al, UART_LSR_OVERRUN
        jz .no_overrun
        inc word [modem_overruns]
.no_overrun:
        test al, UART_LSR_DATA
        jz .done
        mov dx, COM2_BASE + UART_RBR
        in al, dx
        mov bl, [modem_tail]
        mov bh, bl
        inc bh
        cmp bh, [modem_head]
        je .full
        xor bh, bh
        mov [modem_ring + bx], al
        inc byte [modem_tail]
        loop .next
        ret
.full:
        inc word [modem_dropped]
        loop .next
.done:
        ret

; ----------------------------------------------------------------------------
; modem_ready - are there bytes in the ring?
;   In:       DS = SEL_KDATA
;   Out:      ZF clear if so
;   Destroys: AL
; ----------------------------------------------------------------------------
modem_ready:
        mov al, [modem_head]
        cmp al, [modem_tail]
        ret

; ----------------------------------------------------------------------------
; sys_serial_write - SYS_SERIAL_WRITE: the caller's DS:SI, CX bytes, on COM2
;   In:       BP = the frame; DS = SEL_KDATA
;   Out:      the frame's AX = bytes sent; or an error, and the frame's CX =
;             bytes sent before it (E_TIMEOUT)
;   Destroys: AX, BX, CX, DX, SI, ES
; ----------------------------------------------------------------------------
sys_serial_write:
        mov cx, [bp + FRAME_CX]
        cmp cx, SERIAL_MAX
        ja .invalid
        mov word [bp + FRAME_AX], 0
        jcxz .done
        mov si, [bp + FRAME_SI]
        mov ax, [bp + FRAME_DS]
        call check_buffer               ; ES = the caller's segment
        jc .fault
        xor bx, bx                      ; BX = bytes sent
.next:
        push cx
        mov dx, COM2_BASE + UART_LSR
        mov ah, UART_LSR_THRE
        mov al, UART_LSR_THRE
        mov cx, MODEM_BYTE_TICKS
        call kpoll
        pop cx
        jc .late
        mov al, [es:si]
        mov dx, COM2_BASE + UART_THR
        out dx, al
        inc si
        inc bx
        sti                             ; interrupts in after every byte
        nop
        cli
        cmp byte [restart_pending], 0
        jne .sent
        loop .next
.sent:
        mov [bp + FRAME_AX], bx
.done:
        ret
.late:
        mov [bp + FRAME_CX], bx
        mov ax, E_TIMEOUT
        jmp sys_fail
.invalid:
        mov ax, E_INVAL
        jmp sys_fail
.fault:
        mov ax, E_FAULT
        jmp sys_fail

; ----------------------------------------------------------------------------
; sys_serial_read - SYS_SERIAL_READ: what the ring holds, up to CX bytes, to
; the caller's ES:DI; it does not wait
;   In:       BP = the frame; DS = SEL_KDATA
;   Out:      the frame's AX = bytes read (perhaps 0); or an error
;   Destroys: AX, BX, CX, DX, SI, DI, ES
; ----------------------------------------------------------------------------
sys_serial_read:
        mov cx, [bp + FRAME_CX]
        cmp cx, SERIAL_MAX
        ja .invalid
        mov word [bp + FRAME_AX], 0
        jcxz .done
        mov ax, [bp + FRAME_ES]
        mov si, [bp + FRAME_DI]
        call check_buffer_writable      ; ES = the caller's segment
        jc .fault
        mov di, si
        xor dx, dx                      ; DX = bytes read
.next:
        mov bl, [modem_head]
        cmp bl, [modem_tail]
        je .read
        xor bh, bh
        mov al, [modem_ring + bx]
        stosb
        inc byte [modem_head]
        inc dx
        loop .next
.read:
        mov [bp + FRAME_AX], dx
.done:
        ret
.invalid:
        mov ax, E_INVAL
        jmp sys_fail
.fault:
        mov ax, E_FAULT
        jmp sys_fail

%else

; ----------------------------------------------------------------------------
; sys_serial_write - SYS_SERIAL_WRITE where COM2 is the log
;   In:       BP = the frame
;   Out:      the error E_BUSY
;   Destroys: AX
; ----------------------------------------------------------------------------
sys_serial_write:
        mov ax, E_BUSY
        jmp sys_fail

; ----------------------------------------------------------------------------
; sys_serial_read - SYS_SERIAL_READ where COM2 is the log
;   In:       BP = the frame
;   Out:      the error E_BUSY
;   Destroys: AX
; ----------------------------------------------------------------------------
sys_serial_read:
        mov ax, E_BUSY
        jmp sys_fail

%endif
