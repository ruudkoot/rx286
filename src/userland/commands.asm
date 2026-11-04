; ============================================================================
; rx286 - src/userland/commands.asm
; The shell's commands but `crash` (crash.asm).
;
; Each is called with SI at the rest of the line (past the command's word
; and the spaces after it), DS = ES = the program's data, and may destroy
; any register but DS and ES.
; ============================================================================

SECONDS_PER_HOUR    equ 3600
SECONDS_PER_MINUTE  equ 60
FPU_SCALE           equ 100000000000000000      ; 10^17: 18 digits in the BCD store
HELP_COLUMN         equ 9
BCD_DIGIT_BYTES     equ 9               ; FBSTP's 18 digits, two a byte (the tenth byte: the sign)

begin_udata
fpu_scale           dq FPU_SCALE
fpu_two             dw 2
fpu_bcd             times 10 db 0       ; FBSTP's 18 BCD digits and a sign byte
end_udata

; ----------------------------------------------------------------------------
; cmd_help - one line for every command
;   In:       DS = ES = the program's data
;   Out:      nothing
;   Destroys: AX, BX, CX, SI
; ----------------------------------------------------------------------------
cmd_help:
        mov bx, commands_start
.next:
        mov si, [cs:bx]
        test si, si
        jz .done
        PRINT "  "
        call print_str
        call parse_word_length          ; pad the word to a column
        neg cx
        add cx, HELP_COLUMN
.pad:
        mov al, ' '
        call print_char
        loop .pad
        mov si, [cs:bx + 4]
        call print_str
        call print_newline
        add bx, COMMAND_ENTRY
        jmp .next
.done:
        call cmd_drive_help
        PRINT "Keys: Backspace, Esc (clear the line), Up (the last line);", CHAR_LF
        PRINT "Ctrl+Break restarts the shell, Ctrl+Alt+Del the machine.", CHAR_LF
        ret

; ----------------------------------------------------------------------------
; cmd_echo - write the rest of the line
;   In:       SI = the rest of the line
;   Out:      nothing
;   Destroys: nothing
; ----------------------------------------------------------------------------
cmd_echo:
        call print_str
        jmp print_newline

; ----------------------------------------------------------------------------
; cmd_clear - clear the screen (the console's form feed)
;   In:       DS = the program's data
;   Out:      nothing
;   Destroys: nothing
; ----------------------------------------------------------------------------
cmd_clear:
        PRINT CHAR_FF
        ret

; ----------------------------------------------------------------------------
; cmd_uptime - h:mm:ss.cc since the kernel started (SYS_TICKS)
;   In:       DS = ES = the program's data
;   Out:      nothing
;   Destroys: AX, BX, CX, DX, SI
; ----------------------------------------------------------------------------
cmd_uptime:
        sys SYS_TICKS                   ; DX:AX = ticks
        mov cx, SYS_TICKS_HZ
        mov bx, ax
        mov ax, dx
        xor dx, dx
        div cx                          ; the high word first
        mov si, ax
        mov ax, bx
        div cx                          ; SI:AX = seconds, DX = ticks left over
        push dx
        mov dx, si
        mov cx, SECONDS_PER_HOUR
        div cx                          ; AX = hours, DX = seconds within the hour
        PRINT "up "
        call print_dec
        mov ax, dx
        xor dx, dx
        mov cx, SECONDS_PER_MINUTE
        div cx                          ; AX = minutes, DX = seconds
        PRINT ":"
        call print_dec2
        PRINT ":"
        mov ax, dx
        call print_dec2
        PRINT "."
        pop ax
        mov cl, 100 / SYS_TICKS_HZ      ; hundredths a tick
        mul cl
        call print_dec2
        jmp print_newline

; ----------------------------------------------------------------------------
; print_dec2 - AX (0-99) as two decimal digits
;   In:       AX = the number
;   Out:      nothing
;   Destroys: nothing
; ----------------------------------------------------------------------------
print_dec2:
        push ax
        cmp ax, 10
        jae .two
        mov al, '0'
        call print_char
        pop ax
        push ax
.two:
        call print_dec
        pop ax
        ret

; ----------------------------------------------------------------------------
; cmd_date - the real-time clock's date and time (SYS_TIME, BCD)
;   In:       DS = ES = the program's data
;   Out:      nothing
;   Destroys: AX, BX, CX, DX
; ----------------------------------------------------------------------------
cmd_date:
        sys SYS_TIME
        push ax
        mov al, ch
        call print_hex8                 ; BCD prints as its digits
        mov al, cl
        call print_hex8
        PRINT "-"
        mov al, dh
        call print_hex8
        PRINT "-"
        mov al, dl
        call print_hex8
        PRINT " "
        mov al, bh
        call print_hex8
        PRINT ":"
        mov al, bl
        call print_hex8
        PRINT ":"
        pop ax
        call print_hex8
        jmp print_newline

; ----------------------------------------------------------------------------
; cmd_keys - each key's scancode and ASCII, until Esc
;   In:       DS = ES = the program's data
;   Out:      nothing
;   Destroys: AX
; ----------------------------------------------------------------------------
cmd_keys:
        PRINT "Press keys; Esc ends.", CHAR_LF
.next:
        mov al, KEY_WAIT
        sys SYS_READ_KEY
        test ax, ax
        jz .next
        cmp al, CHAR_ESC
        je .done
        PRINT "scancode "
        xchg al, ah
        call print_hex8
        PRINT "h, ASCII "
        xchg al, ah
        call print_hex8
        PRINT "h"
        cmp al, ' '
        jb .line
        cmp al, CHAR_DEL
        jae .line
        PRINT " '"
        call print_char
        PRINT "'"
.line:
        call print_newline
        jmp .next
.done:
        ret

; ----------------------------------------------------------------------------
; cmd_fpu - the square root of 2 and pi to 18 digits, by the 287: each
; times 10^17, stored as 18 BCD digits (FBSTP), printed with the point
;   In:       DS = ES = the program's data
;   Out:      nothing
;   Destroys: AX, CX, SI
; ----------------------------------------------------------------------------
cmd_fpu:
        fninit
        fild qword [fpu_scale]          ; ST0 = 10^17
        fild word [fpu_two]
        fsqrt
        fmul st0, st1
        fbstp [fpu_bcd]                 ; rounded to the nearest integer
        PRINT "sqrt(2) = "
        call print_bcd18
        fldpi
        fmul st0, st1
        fbstp [fpu_bcd]
        PRINT "pi      = "
        call print_bcd18
        fstp st0
        fwait
        ret

; ----------------------------------------------------------------------------
; print_bcd18 - fpu_bcd's 18 digits as d.ddddddddddddddddd
;   In:       fpu_bcd stored by FBSTP; DS = the program's data
;   Out:      nothing
;   Destroys: AX, CX, SI
; ----------------------------------------------------------------------------
print_bcd18:
        fwait                           ; the 287 has stored it
        mov si, fpu_bcd + BCD_DIGIT_BYTES - 1   ; the most significant pair
        mov cx, BCD_DIGIT_BYTES
.pair:
        mov al, [si]
        shr al, 4
        add al, '0'
        call print_char
        cmp si, fpu_bcd + BCD_DIGIT_BYTES - 1
        jne .low
        PRINT "."                       ; after the first digit
.low:
        mov al, [si]
        and al, 0x0F
        add al, '0'
        call print_char
        dec si
        loop .pair
        jmp print_newline

; ----------------------------------------------------------------------------
; cmd_mem - the shell's segments: where the root put them, as the kernel
; says (KCALL_SEGMENT on each capability), and their limits as the CPU sees
; them (LSL)
;   In:       DS = ES = the program's data
;   Out:      nothing
;   Destroys: AX, BX, CX, DX
; ----------------------------------------------------------------------------
cmd_mem:
        PRINT "code:  selector "
        mov bx, cs
        call print_segment
        PRINT "data:  selector "
        mov bx, ds
        call print_segment
        PRINT "stack: selector "
        mov bx, ss
        call print_segment
        PRINT "Nothing else is reachable: the kernel's selectors fault here.", CHAR_LF
        ret

; ----------------------------------------------------------------------------
; print_segment - "SSSSh, base BBBBBh, limit LLLLh"
;   In:       BX = the selector, a segment capability of the shell's
;   Out:      nothing
;   Destroys: AX, CX, DX
; ----------------------------------------------------------------------------
print_segment:
        mov dx, bx
        kcall KCALL_SEGMENT             ; DL:AX = its base
        push ax
        mov ax, bx
        call print_hex16
        PRINT "h, base "
        mov al, dl
        add al, '0'                     ; the base's top digit: 0-9 here
        call print_char
        pop ax
        call print_hex16
        PRINT "h, limit "
        lsl ax, bx
        call print_hex16
        PRINT "h", CHAR_LF
        ret

; ----------------------------------------------------------------------------
; cmd_spin - loop forever; only Ctrl+Break (or Ctrl+Alt+Del) ends it
;   In:       DS = the program's data
;   Out:      does not return
;   Destroys: nothing
; ----------------------------------------------------------------------------
cmd_spin:
        PRINT "Spinning; Ctrl+Break gets the shell back.", CHAR_LF
.forever:
        jmp .forever

; ----------------------------------------------------------------------------
; cmd_exit - SYS_EXIT: the kernel starts the shell again
;   In:       nothing
;   Out:      does not return
;   Destroys: everything
; ----------------------------------------------------------------------------
cmd_exit:
        sys SYS_EXIT
