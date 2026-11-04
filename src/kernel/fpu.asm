; ============================================================================
; rx286 - src/kernel/fpu.asm
; The 80287: initialised for the program, which may use it (roadmap D17).
;
; The kernel never uses the 287 itself. FSETPM puts the 287 in protected
; mode once (Intel's 80287 part); on Bochs' FPU it does nothing. MP is set
; and EM clear (entry.asm), so ESC and WAIT run. On the AT an unmasked 287
; error raises IRQ13 and latches BUSY until port F0h is written (IBM 2-4);
; the error is the program's, since the kernel computes nothing with it.
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

begin_kdata
msg_fpu_error       db "the 287 reported an error (IRQ13)", 0
end_kdata

; ----------------------------------------------------------------------------
; fpu_irq - IRQ13: the program's 287 error
;   In:       BP = the frame; DS = SEL_KDATA
;   Out:      nothing (the dispatcher sends EOI); the program restarts on its
;             way back to ring 3
;   Destroys: AX, SI
; ----------------------------------------------------------------------------
fpu_irq:
        xor al, al
        out FPU_CLEAR_BUSY, al          ; release the latched BUSY first
        fnclex
        mov si, msg_fpu_error
        call klog
        mov byte [restart_pending], 1
        ret
