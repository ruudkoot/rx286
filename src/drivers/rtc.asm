; ============================================================================
; rx286 - src/drivers/rtc.asm
; The RTC driver, "rtc" (roadmap l4.md L10, D20 B): the MC146818 real-time
; clock, read for SYS_TIME, in ring 1 with IOPL 1.
;
; The kernel sets the clock to 24-hour BCD with its interrupts off at its
; start; the driver only reads it (src/lib/cmos.asm), and is its one reader.
; The OS server asks it with DRV_CLOCK_TIME; the seven BCD bytes come back
; in the reply's four words.
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

; ----------------------------------------------------------------------------
; entry - read the clock as the OS server asks, for ever
;   In:       its start: DS = ES = its data, IOPL 1
;   Out:      does not return
;   Destroys: everything
; ----------------------------------------------------------------------------
entry:
        cld
.receive:
        mov dx, EP
        xor bp, bp
        kcall KCALL_RECV
.message:
        jc .receive
        cmp al, DRV_CLOCK_TIME
        jne .receive                    ; its notification's bits: nothing to answer
        call rtc_read                   ; CX, DX, BX, AL: the date and time
        mov si, dx                      ; SI = month and day
        xor ah, ah
        mov di, ax                      ; DI = the seconds
        mov dx, EP
        xor bp, bp
        kcall KCALL_REPLY_RECV
        jmp .message

%include "cmos.asm"
