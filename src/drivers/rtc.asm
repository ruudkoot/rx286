; ============================================================================
; rx286 - src/drivers/rtc.asm
; The RTC driver, "rtc" (roadmap l4.md L10, D20 B): the MC146818 real-time
; clock, read for a process's time (PX_TIME), in ring 1 with IOPL 1.
;
; The kernel sets the clock to 24-hour BCD with its interrupts off at its
; start; the driver only reads it (src/lib/cmos.asm), and is its one reader.
; The OS server asks it with DRV_CLOCK_TIME; the seven BCD bytes come back
; in the reply's four words.
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
        cmp al, NOTIFY_LABEL
        je .receive                     ; its notification's bits: nothing to answer
        mov bx, E_INVAL                 ; a call it does not know
        cmp al, DRV_CLOCK_TIME
        jne .reply
        call rtc_read                   ; CX, DX, BX, AL: the date and time
        mov si, dx                      ; SI = month and day
        xor ah, ah
        mov di, ax                      ; DI = the seconds
        call rtc_valid
        jnc .reply
        or di, DRV_CLOCK_INVALID << 8   ; no time to give (P15)
.reply:
        mov dx, EP
        xor bp, bp
        kcall KCALL_REPLY_RECV
        jmp .message

; ----------------------------------------------------------------------------
; rtc_valid - is the time read one to give? The clock's battery good
; (register D's VRT), and each field BCD: a clock that is not there reads
; FFh (P15)
;   In:       BX, CX, SI, DI = the time as read (DI's high byte 0)
;   Out:      CF clear if so
;   Destroys: AX
; ----------------------------------------------------------------------------
rtc_valid:
        mov al, CMOS_REG_D              ; (bit 7 clear: NMI stays enabled)
        out CMOS_INDEX, al
        in al, CMOS_DATA
        test al, CMOS_REG_D_VRT
        jz .invalid
        mov ax, bx
        call bcd_word
        jc .invalid
        mov ax, cx
        call bcd_word
        jc .invalid
        mov ax, si
        call bcd_word
        jc .invalid
        mov ax, di
        call bcd_word
        jc .invalid
        clc
        ret
.invalid:
        stc
        ret

; ----------------------------------------------------------------------------
; bcd_word - is each of a word's four nibbles 0 to 9?
;   In:       AX = the word
;   Out:      CF clear if so
;   Destroys: AX
; ----------------------------------------------------------------------------
bcd_word:
        push cx
        mov cx, 4
.nibble:
        push ax
        and al, 0x0F
        cmp al, 9
        pop ax
        ja .not
        shr ax, 4
        loop .nibble
        pop cx
        clc
        ret
.not:
        pop cx
        stc
        ret

%include "cmos.asm"
