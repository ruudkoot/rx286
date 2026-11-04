; ============================================================================
; rx286 - tests/unit/selftest.asm
; The host-test harness's own test: a routine that adds and stores.
; ============================================================================

cpu 286
bits 16
%include "build.inc"

; ----------------------------------------------------------------------------
; add_store - AX + BX, also stored at ES:DI
;   In:       AX, BX; ES:DI = where to store the sum
;   Out:      AX = AX + BX
;   Destroys: nothing
; ----------------------------------------------------------------------------
add_store:
        add ax, bx
        mov [es:di], ax
        ret
