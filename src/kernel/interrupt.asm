; ============================================================================
; rx286 - src/kernel/interrupt.asm
; Every interrupt's way in and out: a stub per vector, the common entry that
; builds the frame, dispatch by vector, and the common exit.
;
; A stub pushes a zero where the CPU pushes no error code, then the vector,
; and jumps to isr_common. isr_common saves the registers (the frame of
; kernel.inc), loads the kernel's data segment, and calls the vector's
; handler with BP at the frame. A handler may change the frame: that is how
; system calls return values and how a faulting program is restarted. On the
; way back to ring 3, a restart that was asked for during a system call is
; done (D15), and a return IP past the program's limit is its fault.
; ============================================================================

; The stubs, one per vector of the IDT but the double fault's (a task gate).
%assign vector 0
%rep IDT_ENTRIES
  %if vector != VEC_DF
isr_stub_ %+ vector:
    %if vector != VEC_TS && vector != VEC_NP && vector != VEC_SS && vector != VEC_GP
        push byte 0                     ; no error code from the CPU
    %endif
        push byte vector
        jmp isr_common
  %endif
  %assign vector vector + 1
%endrep

; ----------------------------------------------------------------------------
; isr_common - the frame, the handler, the way back
;   In:       the stub's and the CPU's pushes on the current stack (ring 0)
;   Out:      returns to the interrupted code with IRET
;   Destroys: nothing of the interrupted code's but what the handler changed
;             in the frame
; ----------------------------------------------------------------------------
isr_common:
        pusha
        push ds
        push es
        mov bp, sp
        mov ax, SEL_KDATA
        mov ds, ax
        mov es, ax
        cld
        mov bx, [bp + FRAME_VECTOR]
        shl bx, 1
        call [isr_handlers + bx]
        ; Back to ring 3 with a restart pending (Ctrl+Break or a 287 error
        ; during a system call): restart the program instead.
        test byte [bp + FRAME_CS], CPL_MASK
        jz .restore
        cmp byte [restart_pending], 0
        je .check_ip
        call restart_program
.check_ip:
        ; IRET checks the return IP against CS's limit (Intel B-51) and would
        ; fault here, in ring 0: a program whose INT 30h is its segment's last
        ; two bytes, or one interrupted at an IP past its limit (a 286 checks
        ; the limit when it fetches). That is the program's #GP.
        mov ax, [bp + FRAME_CS]
        lsl dx, ax
        cmp [bp + FRAME_IP], dx
        jbe .restore
        mov word [bp + FRAME_VECTOR], VEC_GP
        mov word [bp + FRAME_ERROR], 0
        call fault_program
.restore:
        pop es
        pop ds
        popa
        add sp, 4                       ; the vector and the error code
        iret

begin_kdata
; The handler of each vector, called with BP at the frame and DS = ES =
; SEL_KDATA. The double fault's entry is never used: its gate is a task gate.
isr_handlers:
%assign vector 0
%rep IDT_ENTRIES
  %if vector <= VEC_CPU_LAST
        dw exception
  %elif vector <= VEC_IRQ_LAST
        dw irq
  %else
        dw syscall
  %endif
  %assign vector vector + 1
%endrep
end_kdata
