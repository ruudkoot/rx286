; ============================================================================
; rx286 - src/kernel/fpu.asm
; The 80287: shared by the threads, lazily (roadmap D17, l4.md D17).
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

FPU_STATUS_ES       equ 0x80            ; the status word's error summary

begin_kdata
fpu_owner           dw 0                ; the thread whose state the 287 holds, or 0
msg_fpu_error       db "the 287 reported an error (IRQ13)", 0
end_kdata

; ----------------------------------------------------------------------------
; fpu_switch - TS for the thread about to run: clear if the 287 holds its
; state, set otherwise, so that its first 287 instruction raises #NM
;   In:       BX = the thread; DS = SEL_KDATA
;   Out:      nothing
;   Destroys: nothing
; ----------------------------------------------------------------------------
fpu_switch:
        push ax
        smsw ax
        and al, ~MSW_TS
        cmp bx, [fpu_owner]
        je .set
        or al, MSW_TS
.set:
        lmsw ax                         ; (LMSW cannot clear PE: it stays set)
        pop ax
        ret

; ----------------------------------------------------------------------------
; fpu_nm - #NM from a program: the 287 becomes the running thread's. The
; owner's state is saved in its control block, the running thread's restored
; (or the 287 reset for its first use); Intel 11.4, roadmap l4.md D17
;   In:       DS = SEL_KDATA; interrupts off
;   Out:      the running thread owns the 287; TS clear
;   Destroys: AX, BX
; ----------------------------------------------------------------------------
fpu_nm:
        clts
        mov bx, [fpu_owner]
        cmp bx, [cur_thread]
        je .done
        test bx, bx
        jz .load
        ; The AT latches BUSY on a 287 error until port F0h is written, and
        ; FRSTOR waits on BUSY: release it first, or the restore below hangs
        ; with interrupts off (IBM 2-4; l4.md X5). The error itself stays in
        ; the saved state, and comes back with it.
        xor al, al
        out FPU_CLEAR_BUSY, al
        fnsave [bx + T_FPU]
        mov byte [bx + T_FPU_VALID], 1
.load:
        mov bx, [cur_thread]
        cmp byte [bx + T_FPU_VALID], 0
        je .fresh
        frstor [bx + T_FPU]
        jmp .own
.fresh:
        fninit
.own:
        mov [fpu_owner], bx
.done:
        ret

; ----------------------------------------------------------------------------
; fpu_reset_thread - the running thread's program starts again: its 287
; starts clean
;   In:       DS = SEL_KDATA; interrupts off
;   Out:      nothing
;   Destroys: nothing
; ----------------------------------------------------------------------------
fpu_reset_thread:
        push bx
        mov bx, [cur_thread]
        mov byte [bx + T_FPU_VALID], 0
        cmp bx, [fpu_owner]
        jne .done
        clts                            ; it owns the 287: TS is clear anyway
        fninit
.done:
        pop bx
        ret

; ----------------------------------------------------------------------------
; fpu_irq - IRQ13: an error of the 287's owner, whichever thread runs now
; (Intel 11.4: "the numerics error from one task may not be recorded until
; the 286 is running a different task"; roadmap l4.md X5)
;   In:       DS = SEL_KDATA; interrupts off
;   Out:      the owner's program to restart
;   Destroys: AX, BX, SI
; ----------------------------------------------------------------------------
fpu_irq:
        xor al, al
        out FPU_CLEAR_BUSY, al          ; release the latched BUSY first
        smsw ax
        push ax                         ; TS as it was
        clts                            ; the 287 holds the owner's state
        fnstsw ax
        test al, FPU_STATUS_ES
        jz .stale                       ; no error left: a restart's FNINIT cleared
        fnclex                          ; it after the PIC had latched the request
%ifdef TEST_FUZZ
        inc word [fuzz_fpu_errors]      ; the fuzzer counts, quietly
%else
        mov si, msg_fpu_error
        call klog
%endif
        mov bx, [fpu_owner]
        test bx, bx
        jnz .owner
        mov bx, [cur_thread]            ; no owner: the kernel's own test
.owner:
        call thread_restart
.stale:
        pop ax
        lmsw ax                         ; TS as it was
        ret
