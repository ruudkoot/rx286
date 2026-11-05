; ============================================================================
; rx286 - src/userland/counter.asm
; The counter: a second program, beside the shell (roadmap l4.md L2).
;
; It counts, for ever, in its own data segment: a program that never waits,
; which a preemptive scheduler must not let starve the shell. The root
; starts it in a thread and a space of its own, below the shell's priority
; (roadmap l4.md L5). Assembled on its own, with rooms of its own
; (CTEXT_ROOM, CDATA_ROOM), and put in the boot image as a module.
;
; Test builds with TEST_COUNTER_FPU make it a check of the 287 instead: it
; keeps 1 on the 287's stack and compares it with a fresh 1 for ever, so
; any loss of its 287 state while other threads use the 287 shows; it then
; says so on the kernel's log (KCALL_LOG) and stops counting. TEST_COUNTER_FAULT makes it
; fault once, at its first start, so that the root reports a fault of a
; module of its name (tests/root).
; ============================================================================

cpu 286
bits 16
%include "build.inc"
%include "layout.inc"
%include "kcalls.inc"

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
%ifdef TEST_COUNTER_FAULT
        cmp byte [faulted], 0
        jne .counting
        mov byte [faulted], 1
.fault:
        db 0x0F, 0x0B                   ; UD2: #UD on a 286 too
.counting:
%endif
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
        kcall KCALL_LOG
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
%ifdef TEST_COUNTER_FAULT
faulted             db 0
%endif
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
