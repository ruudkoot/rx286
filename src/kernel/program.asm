; ============================================================================
; rx286 - src/kernel/program.asm
; The program in ring 3: started, faulted, started again (roadmap D11).
;
; The program's code is UCODE:0000, its data UDATA, its stack USTACK; it
; starts with its registers zero, IF on and IOPL 0. A fault of the program
; is reported (and its registers, in debug and test builds), and the
; program starts again at its entry with a fresh stack, a reset 287 and an
; empty keyboard ring. The kernel does not reset the program's data: its
; entry code initialises what it needs.
; ============================================================================

begin_kdata
msg_program_fault   db "program fault ", 0
end_kdata

; ----------------------------------------------------------------------------
; enter_program - start the program for the first time
;   In:       CPL 0, on the kernel stack, interrupts off; DS = SEL_KDATA
;   Out:      does not return: IRET to ring 3
;   Destroys: everything
; ----------------------------------------------------------------------------
enter_program:
        TRACE "kernel: entering the program"
        call program_reset
        push word SEL_USTACK
        push word USTACK_SIZE
        push word FLAGS_USER_START
        push word SEL_UCODE
        push word 0                     ; the program's entry
        xor ax, ax
        xor bx, bx
        xor cx, cx
        xor dx, dx
        xor si, si
        xor di, di
        xor bp, bp
        mov ax, SEL_UDATA
        mov ds, ax
        mov es, ax
        xor ax, ax
        iret

; ----------------------------------------------------------------------------
; restart_program - make the frame return to the program's entry, afresh
;   In:       BP = a frame from ring 3; DS = SEL_KDATA
;   Out:      the frame changed; restart_pending clear
;   Destroys: nothing
; ----------------------------------------------------------------------------
restart_program:
        push ax
        mov word [bp + FRAME_IP], 0
        mov word [bp + FRAME_CS], SEL_UCODE
        mov word [bp + FRAME_FLAGS], FLAGS_USER_START
        mov word [bp + FRAME_USER_SP], USTACK_SIZE
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
        pop ax
        ret

; ----------------------------------------------------------------------------
; program_reset - what a fresh start of the program needs from the kernel
;   In:       DS = SEL_KDATA; interrupts off
;   Out:      nothing
;   Destroys: nothing
; ----------------------------------------------------------------------------
program_reset:
        mov byte [restart_pending], 0
        fninit                          ; a clean 287, whatever the last run left
        call kbd_clear
%ifdef WITH_TEST_HOOKS
        call test_program_started
%endif
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
