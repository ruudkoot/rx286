; ============================================================================
; rx286 - src/kernel/fpu.asm
; The 80287: initialised for the program, which may use it (roadmap D17).
;
; The kernel never uses the 287 itself. FSETPM puts the 287 in protected
; mode once (Intel's 80287 part); on Bochs' FPU it does nothing. MP is set
; and EM clear (entry.asm), so ESC and WAIT run. (M5 adds IRQ13.)
; ============================================================================

; ----------------------------------------------------------------------------
; fpu_init - reset the 287's state and put it in protected mode
;   In:       CPL 0, in protected mode
;   Out:      nothing
;   Destroys: nothing
; ----------------------------------------------------------------------------
fpu_init:
        fninit
        fsetpm
        ret
