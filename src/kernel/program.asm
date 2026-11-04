; ============================================================================
; rx286 - src/kernel/program.asm
; A program in ring 3: started, faulted, started again (roadmap D11).
;
; Each thread runs a program (thread.asm): the program, and the counter
; beside it (roadmap l4.md L2). A program's code is UCODE:0000, its data
; UDATA, its stack USTACK, in its own LDT; it starts with its registers
; zero, IF on and IOPL 0. A fault of a program is reported (and its
; registers, in debug and test builds), and the program starts again at its
; entry with a fresh stack and a fresh 287; the program the keys are for
; also with an empty keyboard ring. The kernel does not reset a program's
; data: its entry code initialises what it needs.
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
        mov word [bp + FRAME_IP], 0
        mov word [bp + FRAME_CS], SEL_UCODE
        mov word [bp + FRAME_FLAGS], FLAGS_USER_START
        mov bx, [cur_thread]
        mov ax, [bx + T_USTACK_TOP]
        mov [bp + FRAME_USER_SP], ax
        mov word [bp + FRAME_USER_SS], SEL_USTACK
        mov word [bp + FRAME_DS], SEL_UDATA
        mov word [bp + FRAME_ES], SEL_UDATA
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
        call ldt_restore                ; undo any test probe's change
        call fpu_reset_thread           ; a clean 287, whatever the last run left
        mov bx, [cur_thread]
        test byte [bx + T_FLAGS], TF_FOREGROUND
        jz .done
        call kbd_clear
%ifdef WITH_TEST_HOOKS
        call test_program_started
%endif
.done:
        pop bx
        ret

; ----------------------------------------------------------------------------
; fault_program - report the program's fault, then restart it
;   In:       BP = the frame (from ring 3); DS = SEL_KDATA
;   Out:      the frame changed to restart the program
;   Destroys: AX, SI
; ----------------------------------------------------------------------------
fault_program:
%ifdef WITH_TEST_HOOKS
        call test_fault_quiet           ; the fuzzer counts faults instead
        jc .restart
%endif
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
