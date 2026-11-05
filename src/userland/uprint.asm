; ============================================================================
; rx286 - src/userland/uprint.asm
; A program's output: strings, characters and numbers, through SYS_WRITE.
;
; Numbers are formatted by src/lib/format.asm (the same code the kernel
; uses) into a buffer in the program's data segment.
; ============================================================================

PRINT_BUF_SIZE      equ 12              ; ten digits of a 32-bit number, with room to spare

begin_udata
print_buf           times PRINT_BUF_SIZE db 0
end_udata

; ----------------------------------------------------------------------------
; print_str - write a zero-terminated string
;   In:       DS:SI = the string
;   Out:      nothing
;   Destroys: nothing
; ----------------------------------------------------------------------------
print_str:
        push ax
        push cx
        push di
        push es
        push ds
        pop es
        mov di, si
        xor al, al
        mov cx, WRITE_MAX
        repne scasb
        mov cx, di
        sub cx, si
        dec cx                          ; CX = its length
        sys SYS_WRITE
        pop es
        pop di
        pop cx
        pop ax
        ret

; ----------------------------------------------------------------------------
; print_char - write one character
;   In:       AL = the character; DS = the program's data
;   Out:      nothing
;   Destroys: nothing
; ----------------------------------------------------------------------------
print_char:
        push ax
        push cx
        push si
        mov [print_buf], al
        mov si, print_buf
        mov cx, 1
        sys SYS_WRITE
        pop si
        pop cx
        pop ax
        ret

; ----------------------------------------------------------------------------
; print_hex16 - AX as four hexadecimal digits
;   In:       AX = the number; DS = ES = the program's data
;   Out:      nothing
;   Destroys: nothing
; ----------------------------------------------------------------------------
print_hex16:
        push di
        mov di, print_buf
        call fmt_hex16
        jmp print_buffer

; ----------------------------------------------------------------------------
; print_hex8 - AL as two hexadecimal digits
;   In:       AL = the number; DS = ES = the program's data
;   Out:      nothing
;   Destroys: nothing
; ----------------------------------------------------------------------------
print_hex8:
        push di
        mov di, print_buf
        call fmt_hex8
        jmp print_buffer

; ----------------------------------------------------------------------------
; print_dec32 - DX:AX in decimal
;   In:       DX:AX = the number; DS = ES = the program's data
;   Out:      nothing
;   Destroys: nothing
; ----------------------------------------------------------------------------
print_dec32:
        push di
        mov di, print_buf
        call fmt_dec32
        ; falls through

; ----------------------------------------------------------------------------
; print_buffer - write print_buf up to DI, then pop DI (the print_* entry)
;   In:       DI = the end of what to write; DI pushed by the caller
;   Out:      nothing
;   Destroys: nothing
; ----------------------------------------------------------------------------
print_buffer:
        push ax
        push cx
        push si
        mov cx, di
        mov si, print_buf
        sub cx, si
        sys SYS_WRITE
        pop si
        pop cx
        pop ax
        pop di
        ret

; ----------------------------------------------------------------------------
; print_dec32_right - DX:AX in decimal, right-aligned in CX columns
;   In:       DX:AX = the number; CX = the columns; DS = ES = the program's data
;   Out:      nothing
;   Destroys: CX
; ----------------------------------------------------------------------------
print_dec32_right:
        push di
        push cx
        mov di, print_buf
        call fmt_dec32
        sub di, print_buf               ; DI = its digits
        pop cx
        sub cx, di                      ; CX = the spaces before them
        jle .digits
        push ax
        mov al, ' '
.pad:
        call print_char
        loop .pad
        pop ax
.digits:
        mov di, print_buf               ; again: print_char used the buffer
        call fmt_dec32
        jmp print_buffer

; ----------------------------------------------------------------------------
; print_dec - AX in decimal
;   In:       AX = the number; DS = ES = the program's data
;   Out:      nothing
;   Destroys: nothing
; ----------------------------------------------------------------------------
print_dec:
        push dx
        xor dx, dx
        call print_dec32
        pop dx
        ret

; ----------------------------------------------------------------------------
; print_newline - write a line feed
;   In:       DS = the program's data
;   Out:      nothing
;   Destroys: nothing
; ----------------------------------------------------------------------------
print_newline:
        push ax
        mov al, CHAR_LF
        call print_char
        pop ax
        ret

%ifndef RAW_SYSCALLS
%include "stub.asm"                     ; what the sys macro calls
%endif
