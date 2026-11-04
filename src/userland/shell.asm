; ============================================================================
; rx286 - src/userland/shell.asm
; Placeholder program (M4): two empty sections at their offsets. M6 gives it
; code, M7 replaces it with the shell.
; ============================================================================

cpu 286
bits 16
%include "build.inc"
%include "layout.inc"

section utext start=USER_TEXT_START vstart=0
        jmp $
section udata start=USER_DATA_START vstart=0
        db 0
