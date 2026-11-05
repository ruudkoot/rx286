; ============================================================================
; rx286 - src/drivers/serial.asm
; The serial driver (roadmap l4.md L10; devices roadmap D2): COM2 as the
; program's line, for a modem, in ring 1 with IOPL 1. It took the kernel's
; modem code as it was.
;
; In release builds (and test builds made with MODEM_COM2), COM2 runs at
; 9600 baud, 8N1, DTR and RTS up. A byte that comes raises IRQ3, and the
; driver puts it in a ring of SERIAL_RING bytes; a full ring drops it, and
; counts it. Its timer looks once a tick too, for bytes whose interrupt was
; lost (on Bochs a UART's interrupt is lost when another UART on its line is
; touched). A 16450 holds one byte: at 9600 baud one comes every 1.04 ms,
; and the longest stretches with interrupts off can lose some, which
; `overruns` counts. A 16550's FIFO, turned on where there is one, holds 16.
; A port that reads all ones has no UART.
;
; The OS server takes what is in the ring for SYS_SERIAL_READ, which never
; waits, and asks whether bytes wait for SYS_WAIT (DRV_SERIAL_NEWS).
; SYS_SERIAL_WRITE sends each byte once the UART can take it, for 2 s at
; most. In debug and test builds COM2 is the kernel's log: the driver never
; touches it, and answers E_BUSY.
; ============================================================================

cpu 286
bits 16
%define KERNEL_LOG                      ; its lines: the kernel's log
%include "build.inc"
%include "program.inc"
%include "ports.inc"
%include "kcalls.inc"
%include "drivers.inc"

RING                equ 1
%define SLOT(n) ((n) * 8 + 4 + RING)    ; a slot of the driver's, as a selector
EP                  equ SLOT(DRV_SLOT_EP)
NOTIFY              equ SLOT(DRV_SLOT_NOTIFY)
IRQ                 equ SLOT(DRV_SLOT_IRQ)
RECV                equ SLOT(DRV_SLOT_RECV)
SERIAL_RING         equ 256             ; byte indices wrap by themselves
SERIAL_BYTE_TICKS   equ 100 + 1         ; 2 s for the UART to take a byte
SERIAL_IRQ_BYTES    equ 16              ; bytes taken at most at once

begin_udata
ring                times SERIAL_RING db 0
ring_head           db 0                ; the next byte to take
ring_tail           db 0                ; where the next byte goes
dropped             dw 0                ; bytes lost to a full ring
overruns            dw 0                ; bytes the UART lost before they were read
irq_seen            db 0                ; set when IRQ3 came (dwait.asm)
end_udata

; ----------------------------------------------------------------------------
; entry - COM2 ready (where it is the modem's), then serve
;   In:       its start: DS = ES = its data, IOPL 1
;   Out:      does not return
;   Destroys: everything
; ----------------------------------------------------------------------------
entry:
        cld
%ifdef WITH_MODEM
        call serial_init
%endif
        ; falls through

; ----------------------------------------------------------------------------
; serve - answer the OS server, and take COM2's bytes as they come, for ever
;   In:       nothing
;   Out:      does not return
;   Destroys: everything
; ----------------------------------------------------------------------------
serve:
        call look_soon
        mov dx, EP
        mov bp, RECV
        kcall KCALL_RECV
.message:
        jc serve
        cmp al, NOTIFY_LABEL
        jne .call
        call dw_bits                    ; IRQ3: its bytes taken, the line on again
        test bx, DRV_TIMER_BIT
        jz serve
        call driver_irq                 ; the tick's look
        jmp serve
.call:
        call request                    ; BX the status, CX the bytes
        mov dx, RECV                    ; a segment passed, used: room for the next
        kcall KCALL_DELETE
        push cx
        call look_soon
        pop cx
        mov dx, EP
        mov bp, RECV
        kcall KCALL_REPLY_RECV
        jmp .message

; ----------------------------------------------------------------------------
; look_soon - the timer, a tick from now, for the bytes of a lost interrupt
; (none where COM2 is the log)
;   In:       nothing
;   Out:      nothing
;   Destroys: AX, CX, DX
; ----------------------------------------------------------------------------
look_soon:
%ifdef WITH_MODEM
        mov dx, NOTIFY
        mov cx, 1
        kcall KCALL_TIMER
%endif
        ret

; ----------------------------------------------------------------------------
; request - a call of the OS server's
;   In:       AL = the label; BX CX SI DI its words; BP = a segment passed
;             (0: none came)
;   Out:      BX = 0 or the error; CX = the bytes sent, read, or waiting
;   Destroys: AX, DX, SI, DI, ES
; ----------------------------------------------------------------------------
request:
%ifdef WITH_MODEM
        cmp al, DRV_SERIAL_WRITE
        je serial_write
        cmp al, DRV_SERIAL_READ
        je serial_read
        cmp al, DRV_SERIAL_NEWS
        je .news
        mov bx, E_INVAL
        xor cx, cx
        ret
.news:
        xor bx, bx
        mov al, [ring_head]
        cmp al, [ring_tail]
        je .none
        inc bx
.none:
        xor cx, cx
        ret
%else
        xor bx, bx                      ; COM2 is the log: no news, and every
        xor cx, cx                      ; transfer refused
        cmp al, DRV_SERIAL_NEWS
        je .busy_done
        mov bx, E_BUSY
.busy_done:
        ret
%endif

%ifdef WITH_MODEM
; ----------------------------------------------------------------------------
; serial_init - COM2 at 9600 baud, 8N1, DTR, RTS and OUT2 up, an interrupt
; for each byte that comes
;   In:       nothing
;   Out:      nothing
;   Destroys: AL, DX
; ----------------------------------------------------------------------------
serial_init:
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
; serial_write - bytes of the segment passed, on COM2, each once the UART
; can take it
;   In:       CX = bytes; SI = their offset; BP = the segment (0: none came)
;   Out:      BX = 0 or E_FAULT, E_TIMEOUT; CX = the bytes sent
;   Destroys: AX, DX, SI, ES
; ----------------------------------------------------------------------------
serial_write:
        xor bx, bx                      ; BX = bytes sent
        jcxz .done
        test bp, bp
        jz .fault
        mov es, bp
.next:
        push cx
        mov dx, COM2_BASE + UART_LSR
        mov ah, UART_LSR_THRE
        mov al, UART_LSR_THRE
        mov cx, SERIAL_BYTE_TICKS
        call dw_poll
        pop cx
        jc .late
        mov al, [es:si]
        mov dx, COM2_BASE + UART_THR
        out dx, al
        inc si
        inc bx
        loop .next
.done:
        mov cx, bx
        xor bx, bx
        ret
.late:
        mov cx, bx
        mov bx, E_TIMEOUT
        ret
.fault:
        mov bx, E_FAULT
        ret

; ----------------------------------------------------------------------------
; serial_read - what the ring holds, up to CX bytes, into the segment passed;
; it does not wait
;   In:       CX = the room; SI = where; BP = the segment (0: none came)
;   Out:      BX = 0 or E_FAULT; CX = the bytes read
;   Destroys: AX, DX, SI, DI, ES
; ----------------------------------------------------------------------------
serial_read:
        xor dx, dx                      ; DX = bytes read
        jcxz .read
        test bp, bp
        jz .fault
        mov es, bp
        mov di, si
.next:
        mov bl, [ring_head]
        cmp bl, [ring_tail]
        je .read
        xor bh, bh
        mov al, [ring + bx]
        stosb
        inc byte [ring_head]
        inc dx
        loop .next
.read:
        mov cx, dx
        xor bx, bx
        ret
.fault:
        mov bx, E_FAULT
        xor cx, cx
        ret
%endif

; ----------------------------------------------------------------------------
; driver_irq - IRQ3, and every tick: the bytes COM2 has, into the ring
; (dwait.asm calls it at the interrupt)
;   In:       nothing
;   Out:      nothing
;   Destroys: AX
; ----------------------------------------------------------------------------
driver_irq:
%ifdef WITH_MODEM
        push bx
        push cx
        push dx
        mov cx, SERIAL_IRQ_BYTES
.next:
        mov dx, COM2_BASE + UART_LSR
        in al, dx
        cmp al, UART_LSR_ABSENT
        je .done                        ; no UART there
        test al, UART_LSR_OVERRUN
        jz .no_overrun
        inc word [overruns]
.no_overrun:
        test al, UART_LSR_DATA
        jz .done
        mov dx, COM2_BASE + UART_RBR
        in al, dx
        mov bl, [ring_tail]
        mov bh, bl
        inc bh
        cmp bh, [ring_head]
        je .full
        xor bh, bh
        mov [ring + bx], al
        inc byte [ring_tail]
        loop .next
        jmp .done
.full:
        inc word [dropped]
        loop .next
.done:
        pop dx
        pop cx
        pop bx
%endif
        ret

%include "dwait.asm"
