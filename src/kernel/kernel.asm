; ============================================================================
; rx286 - src/kernel/kernel.asm
; Placeholder kernel image (M1); M4 replaces it.
; ============================================================================

cpu 286
bits 16
%include "build.inc"
%include "layout.inc"

        incbin USER_BIN
