; ============================================================================
; rx286 - src/kernel/tss.asm
; The two 286 task state segments.
;
; tss is the one task's. The CPU reads SS0:SP0 from it on every interrupt
; from ring 3, and saves the task's state into it if a double fault switches
; tasks. Its back link is 0, so a program's IRET with NT set faults instead
; of switching (Intel 10.1).
;
; df_tss is the double-fault task's (Intel 9.6.2: "a task gate must be used
; for the double fault handler"): it starts df_task on its own stack with
; interrupts off, so a kernel stack overflow is reported, not a triple fault.
; ============================================================================

tss:
        tss286 0, KSTACK_SIZE, SEL_KSTACK, 0, 0, 0, 0, 0, 0
df_tss:
        tss286 0, 0, 0, df_task, 0x0002, DFSTACK_SIZE, SEL_DFSTACK, SEL_KDATA, SEL_KDATA
