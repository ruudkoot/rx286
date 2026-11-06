; ============================================================================
; rx286 - src/userland/counter-fpu.asm
; The counter's check of the 287 (TEST_COUNTER_FPU; roadmap l4.md L2, D17).
;
; It keeps 1 on the 287's stack and compares it with a fresh 1 for ever, so
; any loss of its 287 state while other threads use the 287 shows; it then
; says so on the kernel's log (KCALL_LOG) and stops counting. In assembly,
; since C cannot promise to keep a value on the 287's stack.
; ============================================================================

cpu 286
bits 16
%include "build.inc"
%include "cabi.inc"
%include "kcalls.inc"

global counter_fpu

data_section
msg_lost            db "counter: its 287 state was lost", 10
msg_lost_end:

code_section

; ----------------------------------------------------------------------------
; counter_fpu - void counter_fpu(void): compare a kept 1 with a fresh one,
; for ever
;   In:       DS = the data segment
;   Out:      does not return
;   Destroys: everything
; ----------------------------------------------------------------------------
counter_fpu:
        fld1                            ; ST0 = 1, kept for ever
.check:
        fld1
        fcomp st1                       ; still 1?
        fnstsw ax
        sahf
        je .check
        mov si, DGROUP_OFFSET(msg_lost)
        mov cx, msg_lost_end - msg_lost
        kcall KCALL_LOG
.stop:
        jmp .stop
