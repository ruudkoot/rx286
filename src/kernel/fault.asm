; ============================================================================
; rx286 - src/kernel/fault.asm
; The CPU's exceptions: a fault of the program, or a panic (roadmap D11, D13).
;
; Who faulted is in the frame's CS: CPL 3 is the program (program.asm reports
; it and starts the program again), CPL 0 the kernel (a panic). NMI is always
; a panic. The single-step trap counts as the program's fault: only a
; program sets TF; in ring 0 it is the program's trap that the 286 carried
; into a fault's handler, and is dropped; vector 9 in ring 0 is the
; program's 287, which overran a segment after the CPU had moved on.
; ============================================================================

begin_kdata
restart_pending     db 0                ; restart the program on the way back to ring 3
msg_kernel_fault    db "exception in the kernel", 0
msg_fpu_overrun     db "the 287 overran a segment (vector 9)", 0
end_kdata

; ----------------------------------------------------------------------------
; exception - the handler of vectors 00h-1Fh
;   In:       BP = the frame; DS = ES = SEL_KDATA
;   Out:      returns only if the program faulted, with the frame changed so
;             that the program starts again, or for a carried single step
;   Destroys: AX, BX, CX, DX, SI, DI
; ----------------------------------------------------------------------------
exception:
        cmp word [bp + FRAME_VECTOR], VEC_NMI
        je nmi
        test byte [bp + FRAME_CS], CPL_MASK
        jnz fault_program
        cmp word [bp + FRAME_VECTOR], VEC_DB
        je .carried_trap
        cmp word [bp + FRAME_VECTOR], VEC_MP
        je .overrun
        mov si, msg_kernel_fault
        jmp panic
.overrun:
        ; Vector 9 in the kernel: the program's 287 overran a segment while
        ; the CPU had moved on (Intel 9.6.3: "any time after the processor
        ; extension is started"). The program's, as IRQ13 is: restart it on
        ; the way back; the restart's FNINIT resets the 287.
        mov si, msg_fpu_overrun
        call klog
        mov byte [restart_pending], 1
        ret
.carried_trap:
        ; A single-step trap in the kernel. The kernel never sets TF: this is
        ; the program's. When an instruction with TF set faults, the 286
        ; services the fault first and the pending trap after it, before the
        ; first instruction of the fault's handler (Intel 9.7.1, table 9-4),
        ; so the trap's frame points at that handler, in ring 0. Intel: check
        ; the privilege level after any single step. Clear TF and let the
        ; fault's handler run. (A 386 or later, Bochs, never does this.)
        and word [bp + FRAME_FLAGS], ~FLAGS_TF
        TRACE "a program's single-step trap carried into a fault's handler"
        ret

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
