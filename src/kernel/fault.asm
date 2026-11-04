; ============================================================================
; rx286 - src/kernel/fault.asm
; The CPU's exceptions: a fault of the program, or a panic (roadmap D11, D13).
;
; Who faulted is in the frame's CS: CPL 3 is the program (program.asm reports
; it and starts the program again), CPL 0 the kernel (a panic). NMI is always
; a panic. The single-step trap counts as the program's fault: only a
; program sets TF.
; ============================================================================

begin_kdata
restart_pending     db 0                ; restart the program on the way back to ring 3
msg_kernel_fault    db "exception in the kernel", 0
end_kdata

; ----------------------------------------------------------------------------
; exception - the handler of vectors 00h-1Fh
;   In:       BP = the frame; DS = ES = SEL_KDATA
;   Out:      returns only if the program faulted, with the frame changed so
;             that the program starts again
;   Destroys: AX, BX, CX, DX, SI, DI
; ----------------------------------------------------------------------------
exception:
        cmp word [bp + FRAME_VECTOR], VEC_NMI
        je nmi
        test byte [bp + FRAME_CS], CPL_MASK
        jnz fault_program
        mov si, msg_kernel_fault
        jmp panic

; ----------------------------------------------------------------------------
; nmi - a parity error or an I/O channel check: panic, with port 61h
;   In:       BP = the frame; DS = SEL_KDATA
;   Out:      does not return
;   Destroys: everything
; ----------------------------------------------------------------------------
nmi:
        in al, SYS_PORT_B               ; bit 7 parity check, bit 6 I/O channel check
        mov di, msg_nmi_status
        call fmt_hex8
        mov si, msg_nmi
        jmp panic

begin_kdata
msg_nmi             db "NMI: a parity error or an I/O channel check; port 61h = "
msg_nmi_status      db "??h", 0
end_kdata
