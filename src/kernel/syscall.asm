; ============================================================================
; rx286 - src/kernel/syscall.asm
; INT 30h, the system call (roadmap D9). (M4: no program yet; every call
; answers E_NOSYS. M6 adds the calls.)
; ============================================================================

; ----------------------------------------------------------------------------
; syscall - the handler of vector 30h
;   In:       BP = the frame; DS = ES = SEL_KDATA
;   Out:      the frame's AX = E_NOSYS and its CF set
;   Destroys: nothing
; ----------------------------------------------------------------------------
syscall:
        mov word [bp + FRAME_AX], E_NOSYS
        or word [bp + FRAME_FLAGS], FLAGS_CF
        ret
