; ============================================================================
; rx286 - tests/programs/fputhreads.asm
; Two threads, one 287 (roadmap l4.md L2): this program keeps pi on the
; 287's stack while the counter, at the same priority, keeps 1 on its own.
;
; The program spins for a while, asking the time, so that the time slices
; switch the 287 between the two threads many times; then it checks that pi
; is still there. The counter (TEST_COUNTER_FPU) checks its 1 for ever, and
; says so if it ever finds it gone.
; ============================================================================

cpu 286
bits 16
%include "build.inc"
%include "program.inc"

SPIN_TICKS          equ 30              ; six time slices of each thread

; ----------------------------------------------------------------------------
; entry - pi on the 287, a while, and pi again
;   In:       the kernel's start
;   Out:      does not return
;   Destroys: everything
; ----------------------------------------------------------------------------
entry:
        fldpi
        kcall KCALL_TICKS
        mov bx, ax
        add bx, SPIN_TICKS
.spin:
        kcall KCALL_TICKS
        cmp ax, bx
        jb .spin
        fldpi
        fcomp st1                       ; still pi?
        fnstsw ax
        sahf
        jne .lost
        PRINT "program: its 287 state kept", CHAR_LF
        jmp .wait
.lost:
        PRINT "program: its 287 state LOST", CHAR_LF
.wait:
        call read_key
        jmp .wait

%include "uprint.asm"
%include "format.asm"
