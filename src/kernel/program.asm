; ============================================================================
; rx286 - src/kernel/program.asm
; A program in rings 1-3: started, faulted, started again (roadmap D11).
;
; Each thread runs a program (thread.asm): the root, and what the root
; builds and starts (roadmap l4.md L5). A program's code, data and stack are
; slots 0, 1 and 2 of its space; it starts with its registers zero, IF on
; and IOPL 0 (or 1: D11). A fault of a thread that has a fault endpoint is
; a call on that endpoint, which its handler - the root - answers by
; reporting it and restarting it (l4.md D18); a thread without one is
; reported by the kernel (and its registers, in debug and test builds). A
; restart begins at its entry with a fresh stack and a fresh 287; the
; program the keys are for also with an empty keyboard ring. The kernel
; does not reset a program's data: its entry code initialises what it
; needs.
; ============================================================================

begin_kdata
msg_program_fault   db "program fault ", 0
end_kdata

; ----------------------------------------------------------------------------
; restart_program - make the frame return to the running thread's
; program's entry, afresh
;   In:       BP = a frame from ring 3; DS = SEL_KDATA
;   Out:      the frame changed; restart_pending clear
;   Destroys: nothing
; ----------------------------------------------------------------------------
restart_program:
%ifdef WITH_TEST_HOOKS
        call test_restart_check
%endif
        push ax
        push bx
        mov bx, [cur_thread]
        mov ax, [bx + T_ENTRY]
        mov [bp + FRAME_IP], ax
        call thread_flags
        mov [bp + FRAME_FLAGS], ax
        mov ax, [bx + T_USTACK_TOP]
        mov [bp + FRAME_USER_SP], ax
        mov al, [bx + T_RING]           ; slots 0, 1, 2 of its space, at its ring
        xor ah, ah
        or ax, SEL_UDATA & ~CPL_MASK
        mov [bp + FRAME_DS], ax
        mov [bp + FRAME_ES], ax
        add ax, SEL_USTACK - SEL_UDATA
        mov [bp + FRAME_USER_SS], ax
        sub ax, SEL_USTACK - SEL_UCODE
        mov [bp + FRAME_CS], ax
        xor ax, ax
        mov [bp + FRAME_AX], ax
        mov [bp + FRAME_BX], ax
        mov [bp + FRAME_CX], ax
        mov [bp + FRAME_DX], ax
        mov [bp + FRAME_SI], ax
        mov [bp + FRAME_DI], ax
        mov [bp + FRAME_BP], ax
        call program_reset
        pop bx
        pop ax
        ret

; ----------------------------------------------------------------------------
; program_reset - what a fresh start of the running thread's program needs
; from the kernel
;   In:       DS = SEL_KDATA; interrupts off
;   Out:      nothing
;   Destroys: nothing
; ----------------------------------------------------------------------------
program_reset:
        push bx
        mov byte [restart_pending], 0
%ifdef TEST_ATTACK
        call test_probe_undo            ; undo a test probe's change
%endif
        call fpu_reset_thread           ; a clean 287, whatever the last run left
        call ipc_reset                  ; a reply it owed will not come
        mov bx, [cur_thread]
        test byte [bx + T_FLAGS], TF_FOREGROUND
        jz .done
        call kbd_clear
%ifdef WITH_TEST_HOOKS
        call test_program_started
%endif
%ifdef TEST_FUZZ
        call test_fuzz_alias
%endif
.done:
        pop bx
        ret

; ----------------------------------------------------------------------------
; fault_program - a program's fault: to its fault endpoint, whose handler's
; reply restarts it; or, without one, reported (and its registers, in
; debug and test builds) and restarted here
;   In:       BP = the frame (from rings 1-3); DS = SEL_KDATA
;   Out:      the frame changed to restart the program
;   Destroys: AX, BX, CX, DX, SI, DI
; ----------------------------------------------------------------------------
fault_program:
        xor di, di                      ; FAULT_*
%ifdef WITH_TEST_HOOKS
        call test_fault_quiet           ; the fuzzer counts faults instead
        jnc .flagged
        mov di, FAULT_COUNTED
.flagged:
%endif
        mov bx, [cur_thread]
        cmp word [bx + T_FAULT], 0
        je .kernel
        call ipc_fault                  ; waits for the handler (ipc.asm)
        jmp restart_program
.kernel:
        test di, di
        jnz .restart
        mov al, ATTR_KERNEL
        call con_set_attr
        mov si, msg_log_prefix
        call kputs
        mov si, msg_program_fault
        call kputs
        mov ax, [bp + FRAME_VECTOR]
        call kput_vector
        cmp ax, VEC_TS
        jb .no_code
        cmp ax, VEC_GP
        ja .no_code
        mov al, '('
        call kputc
        mov ax, [bp + FRAME_ERROR]
        call kput_hex16
        mov al, ')'
        call kputc
.no_code:
        mov si, msg_at
        call kputs
        mov ax, [bp + FRAME_CS]
        call kput_hex16
        mov al, ':'
        call kputc
        mov ax, [bp + FRAME_IP]
        call kput_hex16
        mov al, CHAR_LF
        call kputc
        mov al, ATTR_NORMAL
        call con_set_attr
%ifdef WITH_REGISTERS
        call kput_regs
%endif
.restart:
        jmp restart_program
