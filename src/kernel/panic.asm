; ============================================================================
; rx286 - src/kernel/panic.asm
; The end of the line: a kernel fault, an NMI, a double fault, a failed
; assertion. A red screen with what is known, then halt (roadmap D13).
;
; panic never returns. It masks NMI and halts with interrupts off; a test
; build first ends Bochs through the shutdown port, so the runner sees the
; panic at once. df_task is the double-fault task (tss.asm): it runs on its
; own stack, builds a frame from the state the CPU saved in the TSS, and
; panics, so even a kernel stack overflow is reported.
; ============================================================================

begin_kdata
msg_panic           db "rx286 PANIC: ", 0
msg_at              db " at ", 0
msg_error           db " error ", 0
msg_double_fault    db "double fault", 0
msg_vector          db "vector ", 0
; The CPU's exceptions by vector: four characters each, the name in up to
; VECTOR_NAME_CHARS of them.
vector_names        db "#DE #DB NMI #BP #OF #BR #UD #NM #DF #MP #TS #NP #SS #GP #14 #15 "
                    db "#MF #17 #18 #19 #20 #21 #22 #23 #24 #25 #26 #27 #28 #29 #30 #31 "
end_kdata

; ----------------------------------------------------------------------------
; panic - report and halt
;   In:       SI = what went wrong (a string in kdata), or 0; BP = the
;             frame of the interrupt that caused it, or 0
;   Out:      does not return
;   Destroys: everything
; ----------------------------------------------------------------------------
panic:
        cli
        mov ax, SEL_KDATA
        mov ds, ax
        mov es, ax
        mov al, ATTR_PANIC
        call con_set_attr
        call con_clear
        push si
        mov si, msg_panic
        call kputs
        pop si
        test si, si
        jz .no_text
        call kputs
.no_text:
        mov si, msg_newline
        call kputs
        test bp, bp
        jz .halt
        mov ax, [bp + FRAME_VECTOR]
        call kput_vector
        mov si, msg_error
        call kputs
        mov ax, [bp + FRAME_ERROR]
        call kput_hex16
        mov si, msg_at
        call kputs
        mov ax, [bp + FRAME_CS]
        call kput_hex16
        mov al, ':'
        call kputc
        mov ax, [bp + FRAME_IP]
        call kput_hex16
        mov si, msg_newline
        call kputs
        call kput_regs
.halt:
%ifdef TEST_FUZZ
        call test_fuzz_seed
%endif
%ifdef WITH_TEST_HOOKS
        call test_end
%endif
        mov al, CMOS_NMI_DISABLE | CMOS_REG_D
        out CMOS_INDEX, al
.forever:
        cli
        hlt
        jmp .forever

; ----------------------------------------------------------------------------
; kput_vector - a vector's name: "#GP" for the CPU's, "vector 2Ah" for others
;   In:       AX = the vector; DS = SEL_KDATA
;   Out:      nothing
;   Destroys: nothing
; ----------------------------------------------------------------------------
kput_vector:
        push ax
        push cx
        push si
        cmp ax, VEC_CPU_LAST
        ja .other
        mov si, ax
        shl si, 2
        add si, vector_names
        mov cx, VECTOR_NAME_CHARS
.name:
        lodsb
        cmp al, ' '
        je .done
        call kputc
        loop .name
        jmp .done
.other:
        mov si, msg_vector
        call kputs
        call kput_hex8
        mov al, 'h'
        call kputc
.done:
        pop si
        pop cx
        pop ax
        ret

; ----------------------------------------------------------------------------
; df_task - the double-fault task: a frame from the saved state, then panic
;   In:       entered by a task switch through vector 8; DS = ES = SEL_KDATA,
;             SS:SP = the double-fault stack (df_tss)
;   Out:      does not return
;   Destroys: everything
; ----------------------------------------------------------------------------
df_task:
        ; The faulting state, as the CPU saved it in the one task's TSS
        ; (Intel figure 8-1), pushed in the order of kernel.inc's frame.
        push word [tss + TSS286_SS]
        push word [tss + TSS286_SP]
        push word [tss + TSS286_FLAGS]
        push word [tss + TSS286_CS]
        push word [tss + TSS286_IP]
        push word 0                     ; a double fault's error code is 0
        push word VEC_DF
        push word [tss + TSS286_AX]
        push word [tss + TSS286_CX]
        push word [tss + TSS286_DX]
        push word [tss + TSS286_BX]
        push word [tss + TSS286_SP]
        push word [tss + TSS286_BP]
        push word [tss + TSS286_SI]
        push word [tss + TSS286_DI]
        push word [tss + TSS286_DS]
        push word [tss + TSS286_ES]
        mov bp, sp
        mov si, msg_double_fault
        jmp panic
