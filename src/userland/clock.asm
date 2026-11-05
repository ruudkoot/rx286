; ============================================================================
; rx286 - src/userland/clock.asm
; The clock: a background program beside the shell (roadmap l4.md L11, D19).
;
; It looks at the RTC (SYS_TIME) every CLOCK_LOOK_TICKS ticks, and whenever
; the second has changed it writes the time, HH:MM:SS, which the OS server
; puts in its field of the status line, since it is not the program the
; keys are for. Between looks it sleeps (SYS_WAIT, no event). The shell's
; kill stops it and start starts it again, at its entry.
;
; TEST_DEMO builds (tests/demo) make it fault once, after it has shown
; three seconds, so that a background program's fault is seen reported and
; the program started again while the shell works on.
; ============================================================================

cpu 286
bits 16
%include "build.inc"
%include "program.inc"

CLOCK_LOOK_TICKS    equ 10              ; five looks a second
CLOCK_TEXT          equ 8               ; HH:MM:SS

begin_udata
last_second         db 0xFF             ; the second last shown (none yet)
time_text           times CLOCK_TEXT db 0
%ifdef TEST_DEMO
shown               db 0                ; seconds shown
faulted             db 0
%endif
end_udata

; ----------------------------------------------------------------------------
; entry - show the time, for ever
;   In:       its start (program.inc)
;   Out:      does not return
;   Destroys: everything
; ----------------------------------------------------------------------------
entry:
        cld
.look:
        sys SYS_TIME                    ; BH hours, BL minutes, AL seconds: BCD
        jc .sleep
        cmp al, [last_second]
        je .sleep
        mov [last_second], al
        call show
%ifdef TEST_DEMO
        inc byte [shown]
        cmp byte [shown], 3
        jb .sleep
        cmp byte [faulted], 0
        jne .sleep
        mov byte [faulted], 1
.fault:
        db 0x0F, 0x0B                   ; UD2: #UD on a 286 too
%endif
.sleep:
        xor al, al                      ; no event: a sleep
        mov cx, CLOCK_LOOK_TICKS
        sys SYS_WAIT
        jmp .look

; ----------------------------------------------------------------------------
; show - the time, as HH:MM:SS, written in one call
;   In:       BH = hours, BL = minutes, AL = seconds (BCD); DS = ES = its data
;   Out:      nothing
;   Destroys: AX, CX, SI, DI
; ----------------------------------------------------------------------------
show:
        mov di, time_text
        push ax
        mov al, bh
        call fmt_hex8                   ; BCD's digits are its hexadecimal ones
        mov al, ':'
        stosb
        mov al, bl
        call fmt_hex8
        mov al, ':'
        stosb
        pop ax
        call fmt_hex8
        mov si, time_text
        mov cx, CLOCK_TEXT
        sys SYS_WRITE
        ret

%include "uprint.asm"
%include "format.asm"
