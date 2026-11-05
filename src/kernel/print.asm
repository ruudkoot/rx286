; ============================================================================
; rx286 - src/kernel/print.asm
; The kernel's own output: strings, numbers, its messages, trace lines and
; register dumps.
;
; Everything goes through the console (and so to the log in debug and test
; builds), except trace lines in test builds, which go to the log only. Numbers
; are formatted by src/lib/format.asm into a buffer in kdata.
; ============================================================================

NUM_BUF_SIZE        equ 12              ; ten digits of a 32-bit number, and the zero

begin_kdata
num_buf             times NUM_BUF_SIZE db 0
%ifdef TEST_IMAGE_SUM
test_image_sum      dw 0                ; written by entry.asm in real mode
%endif
msg_log_prefix      db "rx286: ", 0
msg_trace_prefix    db "[trace] ", 0
msg_newline         db CHAR_LF, 0
end_kdata

; ----------------------------------------------------------------------------
; kputs - write a zero-terminated string
;   In:       SI = the string in kdata; DS = SEL_KDATA
;   Out:      nothing
;   Destroys: nothing
; ----------------------------------------------------------------------------
kputs:
        push ax
        push si
.next:
        lodsb
        test al, al
        jz .done
        call con_emit
        jmp .next
.done:
        call con_cursor
        pop si
        pop ax
        ret

; ----------------------------------------------------------------------------
; kputc - write one character
;   In:       AL = the character; DS = SEL_KDATA
;   Out:      nothing
;   Destroys: nothing
; ----------------------------------------------------------------------------
kputc:
        jmp con_putc

; ----------------------------------------------------------------------------
; kput_hex16 - AX as four hexadecimal digits
;   In:       AX = the number; DS = SEL_KDATA
;   Out:      nothing
;   Destroys: nothing
; ----------------------------------------------------------------------------
kput_hex16:
        push di
        push es
        push ds
        pop es
        mov di, num_buf
        call fmt_hex16
        jmp kput_number

; ----------------------------------------------------------------------------
; kput_hex8 - AL as two hexadecimal digits
;   In:       AL = the number; DS = SEL_KDATA
;   Out:      nothing
;   Destroys: nothing
; ----------------------------------------------------------------------------
kput_hex8:
        push di
        push es
        push ds
        pop es
        mov di, num_buf
        call fmt_hex8
        jmp kput_number

; ----------------------------------------------------------------------------
; kput_dec32 - DX:AX in decimal
;   In:       DX:AX = the number; DS = SEL_KDATA
;   Out:      nothing
;   Destroys: nothing
; ----------------------------------------------------------------------------
kput_dec32:
        push di
        push es
        push ds
        pop es
        mov di, num_buf
        call fmt_dec32
        ; falls through

; ----------------------------------------------------------------------------
; kput_number - write num_buf up to DI, then restore what the kput_* pushed
;   In:       DI = the end of the digits; ES and DI pushed by the caller
;   Out:      nothing
;   Destroys: nothing
; ----------------------------------------------------------------------------
kput_number:
        mov byte [di], 0
        push si
        mov si, num_buf
        call kputs
        pop si
        pop es
        pop di
        ret

; ----------------------------------------------------------------------------
; klog - one of the kernel's own lines, in its colour: "rx286: <text>"
;   In:       SI = the text in kdata; DS = SEL_KDATA
;   Out:      nothing
;   Destroys: nothing
; ----------------------------------------------------------------------------
klog:
        push ax
        push si
        mov al, ATTR_KERNEL
        call con_set_attr
        mov si, msg_log_prefix
        call kputs
        pop si
        call kputs
        push si
        mov si, msg_newline
        call kputs
        mov al, ATTR_NORMAL
        call con_set_attr
        pop si
        pop ax
        ret

; ----------------------------------------------------------------------------
; klog_number - "rx286: <text>XXXX" in the kernel's colour, XXXX in hex
;   In:       SI = the text in kdata; AX = the number; DS = SEL_KDATA
;   Out:      nothing
;   Destroys: nothing
; ----------------------------------------------------------------------------
klog_number:
        push ax
        push si
        push ax
        mov al, ATTR_KERNEL
        call con_set_attr
        mov si, msg_log_prefix
        call kputs
        pop ax
        pop si
        push si
        call kputs
        call kput_hex16
        mov si, msg_newline
        call kputs
        mov al, ATTR_NORMAL
        call con_set_attr
        pop si
        pop ax
        ret

; ----------------------------------------------------------------------------
; ktrace - a trace line "[trace] <text>": screen and log in debug builds,
; the log only in test builds
;   In:       SI = the text in kdata; DS = SEL_KDATA
;   Out:      nothing
;   Destroys: nothing
; ----------------------------------------------------------------------------
ktrace:
%ifdef WITH_SCREEN_TRACE
        push si
        mov si, msg_trace_prefix
        call kputs
        pop si
        call kputs
        push si
        mov si, msg_newline
        call kputs
        pop si
%elifdef WITH_SERIAL
        push ax
        mov al, [log_at_start]          ; a trace is cut out of the transcript:
        push si                         ; the log's line is as it was
        mov si, msg_trace_prefix
        call com_puts
        pop si
        call com_puts
        push si
        mov si, msg_newline
        call com_puts
        pop si
        mov [log_at_start], al
        pop ax
%endif
        ret

; ----------------------------------------------------------------------------
; kput_regs - the frame's registers, two lines starting "regs:"
;   In:       BP = a frame (kernel.inc); DS = SEL_KDATA. SS:SP is shown for
;             a frame from ring 3, and for the double-fault task's
;   Out:      nothing
;   Destroys: nothing
; ----------------------------------------------------------------------------
kput_regs:
        push ax
        push bx
        push si
        mov bx, regs_table
.next:
        mov si, [bx]                    ; the label, or 0 at the end
        test si, si
        jz .done
        call kputs
        mov si, [bx + 2]                ; the frame offset
        mov ax, [bp + si]
        call kput_hex16
        add bx, 4
        jmp .next
.done:
        cmp word [bp + FRAME_VECTOR], VEC_DF
        je .stack                       ; the double-fault task's frame has SS:SP
        test byte [bp + FRAME_CS], CPL_MASK
        jz .end
.stack:
        mov si, msg_reg_ss
        call kputs
        mov ax, [bp + FRAME_USER_SS]
        call kput_hex16
        mov al, ':'
        call kputc
        mov ax, [bp + FRAME_USER_SP]
        call kput_hex16
.end:
        mov si, msg_newline
        call kputs
        pop si
        pop bx
        pop ax
        ret

begin_kdata
regs_table:
        dw msg_reg_ax, FRAME_AX, msg_reg_bx, FRAME_BX, msg_reg_cx, FRAME_CX
        dw msg_reg_dx, FRAME_DX, msg_reg_si, FRAME_SI, msg_reg_di, FRAME_DI
        dw msg_reg_bp, FRAME_BP, msg_reg_ds, FRAME_DS, msg_reg_es, FRAME_ES
        dw msg_reg_flags, FRAME_FLAGS, 0
msg_reg_ax      db "regs: AX=", 0
msg_reg_bx      db " BX=", 0
msg_reg_cx      db " CX=", 0
msg_reg_dx      db " DX=", 0
msg_reg_si      db " SI=", 0
msg_reg_di      db " DI=", 0
msg_reg_bp      db " BP=", 0
msg_reg_ds      db CHAR_LF, "regs: DS=", 0
msg_reg_es      db " ES=", 0
msg_reg_flags   db " FLAGS=", 0
msg_reg_ss      db " SS:SP=", 0
end_kdata
