; ============================================================================
; rx286 - src/userland/counter.asm
; The counter: a second program, beside the shell (roadmap l4.md L2).
;
; It counts, for ever, in its own data segment: a program that never waits,
; which a preemptive scheduler must not let starve the shell. The kernel
; starts it in a thread of its own, with an LDT of its own (CTEXT, CDATA,
; CSTACK), below the shell's priority. Assembled on its own and included in
; the kernel's image at CTEXT_OFF, as the shell is at UTEXT_OFF.
;
; Test builds with TEST_COUNTER_FPU make it a check of the 287 instead: it
; keeps 1 on the 287's stack and compares it with a fresh 1 for ever, so
; any loss of its 287 state while other threads use the 287 shows; it then
; says so through SYS_WRITE and stops counting.
; ============================================================================

cpu 286
bits 16
%include "build.inc"
%include "layout.inc"
%include "syscalls.inc"

section ctext start=0 vstart=0
section cdata start=COUNTER_DATA_START vstart=0
section ctext

; ----------------------------------------------------------------------------
; entry - count for ever
;   In:       the kernel's start: DS = ES = its data, SS:SP its stack
;   Out:      does not return
;   Destroys: everything
; ----------------------------------------------------------------------------
entry:
%ifdef TEST_COUNTER_FPU
        fld1                            ; ST0 = 1, kept for ever
.check:
        fld1
        fcomp st1                       ; still 1?
        fnstsw ax
        sahf
        jne .lost
        add word [count], 1
        adc word [count + 2], 0
        jmp .check
.lost:
        mov si, msg_lost
        mov cx, msg_lost_end - msg_lost
        sys SYS_WRITE
.stop:
        jmp .stop
%else
.next:
        add word [count], 1
        adc word [count + 2], 0
        jmp .next
%endif

section cdata
count               dd 0
%ifdef TEST_COUNTER_FPU
msg_lost            db "counter: its 287 state was lost", 10
msg_lost_end:
%endif

section ctext
%if ($ - $$) > CTEXT_ROOM
  %error "counter.asm: the code outgrew CTEXT_ROOM"
%endif
section cdata
%if ($ - $$) > CDATA_ROOM
  %error "counter.asm: the data outgrew CDATA_ROOM"
%endif
        times CDATA_ROOM - ($ - $$) db 0
