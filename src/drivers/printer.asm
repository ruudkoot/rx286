; ============================================================================
; rx286 - src/drivers/printer.asm
; The printer driver (roadmap l4.md L7; storage roadmap D5): the parallel
; ports LPT1 and LPT2, in ring 1 with IOPL 1.
;
; It drives a printer as IBM's BIOS does (5-122): for each byte, wait until
; the printer is not busy, put the byte on the data lines, and pulse
; STROBE. The wait reads the status port LPT_BURST times, then once a
; tick, on the kernel's timer, for LPT_BUSY_TICKS at most: a printer is
; busy for a moment after each strobe, and a tick a byte would be 50 bytes a
; second (P15). The printer's interrupt (-ACK) stays off. A port with no
; printer reads busy and out of paper, as on the AT: the call fails with
; E_PAPER after LPT_BUSY_TICKS. A port with no adapter at all reads all ones,
; which no printer does (not busy, and out of paper): the call fails at once
; with E_TIMEOUT (P15). A call that fails says how many bytes the printer
; took first. The OS server asks it for a write
; to /dev/lpt1 or /dev/lpt2 (DRV_PRINT, drivers.inc), passing the process's
; data segment, which the driver deletes once it has printed from it.
; ============================================================================

cpu 286
bits 16
%include "build.inc"
%include "program.inc"
%include "ports.inc"
%include "kcalls.inc"
%include "drivers.inc"

RING                equ 1
%define SLOT(n) ((n) * 8 + 4 + RING)    ; a slot of the driver's, as a selector
EP                  equ SLOT(DRV_SLOT_EP)
NOTIFY              equ SLOT(DRV_SLOT_NOTIFY)
RECV                equ SLOT(DRV_SLOT_RECV)
LPT_BUSY_TICKS      equ 100 + 1         ; 2 s for the printer to take a byte
LPT_INIT_READS      equ 64              ; -INIT held low that long: 50 us at the least
LPT_BURST           equ 256             ; status reads before a tick's sleep: a ms or so
LPT_NO_ADAPTER      equ 0xFF            ; the status of a port no adapter answers

begin_udata
printer_ports       dw LPT1_BASE, LPT2_BASE
end_udata

; ----------------------------------------------------------------------------
; entry - reset both printers, then serve
;   In:       its start: DS = ES = its data, IOPL 1
;   Out:      does not return
;   Destroys: everything
; ----------------------------------------------------------------------------
entry:
        cld
        call printer_init
        ; falls through

; ----------------------------------------------------------------------------
; serve - print what the OS server asks, for ever
;   In:       nothing
;   Out:      does not return
;   Destroys: everything
; ----------------------------------------------------------------------------
serve:
        mov dx, EP
        mov bp, RECV
        kcall KCALL_RECV
.message:
        jc serve
        cmp al, NOTIFY_LABEL
        je serve                        ; its timer's bits, late: nothing to answer
        cmp al, DRV_PRINT
        jne .unknown
        call print                      ; BX the status, CX the bytes printed
.answer:
        mov dx, RECV                    ; the segment, used: room for the next
        kcall KCALL_DELETE
        mov dx, EP
        mov bp, RECV
        kcall KCALL_REPLY_RECV
        jmp .message
.unknown:
        mov bx, E_INVAL                 ; a call it does not know
        xor cx, cx
        jmp .answer

; ----------------------------------------------------------------------------
; printer_init - reset both printers: -INIT low, then high
;   In:       DS = its data
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
; print - bytes of the segment passed, to a printer
;   In:       BX = the printer; CX = bytes; SI = their offset; BP = the
;             segment's selector (0: none came)
;   Out:      BX = 0, or E_INVAL, E_FAULT, E_PAPER, E_TIMEOUT; CX = the bytes
;             printed
;   Destroys: AX, DX, SI, DI, ES
; ----------------------------------------------------------------------------
print:
        cmp bx, PRINTERS
        jae .invalid
        test bp, bp
        jz .fault
        verr bp
        jnz .fault
        call dw_fits                    ; its bytes within its limit (P15)
        jc .fault
        shl bx, 1
        mov di, [printer_ports + bx]
        xor bx, bx                      ; BX = bytes printed
.next:
        jcxz .done
        verr bp                         ; still there after the last wait? (a
        jnz .gone                       ; program killed meanwhile: l4.md L12)
        lsl dx, bp
        cmp si, dx
        ja .gone                        ; or shorter now (P15)
        mov es, bp
        mov al, [es:si]
        call lpt_byte
        jc .failed
        inc si
        inc bx
        dec cx
        jmp .next
.done:
        mov cx, bx
        xor bx, bx
        ret
.failed:
        mov cx, bx
        mov bx, ax
        ret
.gone:
        mov cx, bx
        mov bx, E_FAULT
        ret
.invalid:
        mov bx, E_INVAL
        xor cx, cx
        ret
.fault:
        mov bx, E_FAULT
        xor cx, cx
        ret

; ----------------------------------------------------------------------------
; lpt_byte - one byte to a printer, once it is not busy
;   In:       AL = the byte; DI = the port's base
;   Out:      CF clear; or CF set and AX = E_PAPER or E_TIMEOUT
;   Destroys: AX, DX
; ----------------------------------------------------------------------------
lpt_byte:
        push cx
        push si
        mov ah, al                      ; AH = the byte
        mov cx, LPT_BUSY_TICKS
        mov dx, di
        add dx, LPT_STATUS
.poll:
        mov si, LPT_BURST
.read:
        in al, dx
        cmp al, LPT_NO_ADAPTER
        je .absent
        test al, LPT_STATUS_NOT_BUSY
        jnz .ready
        dec si
        jnz .read
        call tick_wait
        loop .poll
        test al, LPT_STATUS_PAPER_END   ; busy for good
        mov ax, E_PAPER
        jnz .failed
        mov ax, E_TIMEOUT
.failed:
        pop si
        pop cx
        stc
        ret
.absent:
        mov ax, E_TIMEOUT               ; no adapter: no wait
        jmp .failed
.ready:
        mov al, ah
        mov dx, di
        add dx, LPT_DATA
        out dx, al
        add dx, LPT_CONTROL - LPT_DATA
        mov al, LPT_CONTROL_STROBE
        out dx, al
        mov al, LPT_CONTROL_READY
        out dx, al
        pop si
        pop cx
        clc
        ret

; ----------------------------------------------------------------------------
; tick_wait - a tick, on the kernel's timer and the driver's notification
;   In:       nothing
;   Out:      nothing
;   Destroys: nothing
; ----------------------------------------------------------------------------
tick_wait:
        push ax
        push bx
        push cx
        push dx
        mov dx, NOTIFY
        mov cx, 1
        kcall KCALL_TIMER
        mov dx, NOTIFY
        kcall KCALL_RECV
        pop dx
        pop cx
        pop bx
        pop ax
        ret

%include "dfits.asm"
