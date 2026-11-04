; ============================================================================
; rx286 - src/lib/format.asm
; Numbers as text: hexadecimal and decimal, into a buffer.
;
; Pure routines, shared by the kernel and the program (each assembles its
; own copy) and tested on the host (tests/unit/test_format.py). They read
; their one table through CS, so they work in any data segment.
; ============================================================================

; ----------------------------------------------------------------------------
; fmt_hex16 - AX as four hexadecimal digits
;   In:       AX = the number; ES:DI = where to write
;   Out:      DI advanced past the four digits
;   Destroys: nothing
; ----------------------------------------------------------------------------
fmt_hex16:
        xchg al, ah
        call fmt_hex8
        xchg al, ah
        jmp fmt_hex8

; ----------------------------------------------------------------------------
; fmt_hex8 - AL as two hexadecimal digits
;   In:       AL = the number; ES:DI = where to write
;   Out:      DI advanced past the two digits
;   Destroys: nothing
; ----------------------------------------------------------------------------
fmt_hex8:
        push ax
        push bx
        mov bx, ax
        shr bl, 4
        and bx, 0x000F
        mov ah, [cs:fmt_digits + bx]
        mov bl, al
        and bx, 0x000F
        mov al, [cs:fmt_digits + bx]
        xchg al, ah
        stosw
        pop bx
        pop ax
        ret

; ----------------------------------------------------------------------------
; fmt_dec16 - AX as an unsigned decimal number, without leading zeros
;   In:       AX = the number; ES:DI = where to write
;   Out:      DI advanced past the digits (one to five)
;   Destroys: nothing
; ----------------------------------------------------------------------------
fmt_dec16:
        push dx
        xor dx, dx
        call fmt_dec32
        pop dx
        ret

; ----------------------------------------------------------------------------
; fmt_dec32 - DX:AX as an unsigned decimal number, without leading zeros
;   In:       DX:AX = the number; ES:DI = where to write
;   Out:      DI advanced past the digits (one to ten)
;   Destroys: nothing
; ----------------------------------------------------------------------------
fmt_dec32:
        push ax
        push bx
        push cx
        push dx
        push si
        mov si, ax                      ; SI = low word
        mov bx, 10
        xor cx, cx                      ; CX = digits pushed
.divide:
        ; DX:SI / 10, one word at a time: high word first, its remainder
        ; carried into the low word's division.
        mov ax, dx
        xor dx, dx
        div bx                          ; AX = high quotient, DX = remainder
        xchg ax, si                     ; SI = high quotient, AX = low word
        div bx                          ; AX = low quotient, DX = the digit
        push dx
        inc cx
        mov dx, si                      ; DX:AX = the quotient
        mov si, ax
        or ax, dx
        jnz .divide
.write:
        pop ax
        add al, '0'
        stosb
        loop .write
        pop si
        pop dx
        pop cx
        pop bx
        pop ax
        ret

fmt_digits      db "0123456789ABCDEF"
