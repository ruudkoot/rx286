; ============================================================================
; rx286 - src/lib/posix/thread.asm
; What POSIX's threads need in assembly (roadmap os-server.md P13;
; pthread.c): a thread's first instruction, and a word incremented in
; one instruction, which no other thread can come between on a single CPU
; (LOCK would fault at CPL 3 on a 286: l4.md E6). The C convention of
; cabi.inc.
; ============================================================================

cpu 286
bits 16
%include "build.inc"
%include "cabi.inc"

global rx_thread_entry, rx_inc
extern rx_thread_main

code_section

; ----------------------------------------------------------------------------
; rx_thread_entry - where a thread of PX_THREAD's starts: at the top of its
; stack, whose base holds its own data (rx/tls.h), DS and ES the process's
; data, SS its copy (17h); pthread.c's rx_thread_main does the rest
;   In:       SP = its stack's top
;   Out:      does not return
;   Destroys: everything
; ----------------------------------------------------------------------------
rx_thread_entry:
        cld
        call rx_thread_main             ; does not return
.stop:
        jmp .stop

; ----------------------------------------------------------------------------
; rx_inc - void rx_inc(unsigned *word): the word incremented, at once
;   In:       the stack: the word's address
;   Out:      nothing
;   Destroys: BX
; ----------------------------------------------------------------------------
rx_inc:
        push bp
        mov bp, sp
        mov bx, ARG(0)
        inc word [bx]
        pop bp
        ret
