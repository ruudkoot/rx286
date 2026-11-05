; ============================================================================
; rx286 - tests/programs/idle.asm
; The test program that does nothing: it waits for keys and drops them.
;
; The kernel's tests run it, so their transcripts hold only the kernel's
; lines; a test ends once it waits with no key left to type.
; ============================================================================

cpu 286
bits 16
%include "build.inc"
%include "program.inc"

; ----------------------------------------------------------------------------
; entry - wait for keys, forever
;   In:       the kernel's start (program.inc)
;   Out:      does not return
;   Destroys: AX
; ----------------------------------------------------------------------------
entry:
        mov al, KEY_WAIT
        sys SYS_READ_KEY
        jmp entry

%include "stub.asm"
