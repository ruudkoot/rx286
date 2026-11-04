; ============================================================================
; rx286 - src/boot-loader/boot-loader.asm
; Placeholder loader (M1); M3 replaces it.
; ============================================================================

cpu 286
bits 16
%include "build.inc"
%include "layout.inc"

        org LOADER_PHYS
        times LOADER_SECTORS * 512 db 0
