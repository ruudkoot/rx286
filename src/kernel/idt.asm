; ============================================================================
; rx286 - src/kernel/idt.asm
; The interrupt descriptor table: vectors 00h to 30h, written out at
; assembly time (roadmap D10).
;
; Vector 8 is a task gate to the double-fault task; 30h, the system call, is
; the only gate of DPL 3; every other vector is a DPL 0 interrupt gate to its
; stub in interrupt.asm. Any vector beyond 30h is beyond the IDT's limit, a
; general protection fault (docs/interrupts.md).
; ============================================================================

idt:
%assign vector 0
%rep IDT_ENTRIES
  %if vector == VEC_DF
        task_gate SEL_DFTSS
  %elif vector == VEC_SYSCALL
        interrupt_gate isr_stub_ %+ vector, ACC_INT_GATE_USER
  %else
        interrupt_gate isr_stub_ %+ vector, ACC_INT_GATE
  %endif
  %assign vector vector + 1
%endrep

; The pseudo-descriptor LIDT reads.
idt_pointer:
        dw IDT_LIMIT
        dw (KDATA_PHYS & 0xFFFF) + idt
        db KDATA_PHYS >> 16, 0
