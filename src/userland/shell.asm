; ============================================================================
; rx286 - src/userland/shell.asm
; Placeholder for the shell (M6): it waits for keys and drops them.
;
; M7 replaces it with the shell.
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
