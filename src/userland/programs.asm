; ============================================================================
; rx286 - src/userland/programs.asm
; The shell's programs: ps, kill and start (roadmap l4.md L11, D19), on the
; OS server's calls that ask the root (SYS_PS, SYS_KILL, SYS_START).
;
; ps lists every module the root built, by its number: its name, what it
; is, its main thread's priority and state, and how often it has run. kill
; stops a background program, start starts one that was stopped, at its
; entry; neither touches the shell, the OS server, a driver or the root.
; ============================================================================

PS_NAME_COLUMNS     equ 9
PS_KIND_COLUMNS     equ 11

begin_udata
ps_record           times PS_SIZE db 0
ps_kinds            db "root", 0, "OS server", 0, "driver", 0, "foreground", 0
                    db "background", 0
ps_states           db "free", 0, "ready", 0, "running", 0, "waiting", 0, "sending", 0
                    db "receiving", 0, "awaiting its reply", 0
                    db "awaiting a notification", 0, "stopped", 0
end_udata

; ----------------------------------------------------------------------------
; cmd_ps - every module the root built: number, name, kind, priority, state,
; runs
;   In:       SI = the rest of the line; DS = ES = the program's data
;   Out:      nothing
;   Destroys: everything but DS, ES
; ----------------------------------------------------------------------------
cmd_ps:
        PRINT "  # name     kind       priority state, runs", CHAR_LF
        xor bx, bx                      ; BX = the module
.module:
        mov al, bl
        mov di, ps_record
        sys SYS_PS
        jc .done                        ; past the last
        mov ax, bx
        xor dx, dx
        mov cx, 3
        call print_dec32_right
        mov al, ' '
        call print_char
        mov si, ps_record + PS_NAME
        mov cx, PS_NAME_COLUMNS
        call print_padded
        mov si, ps_kinds
        mov al, [ps_record + PS_KIND]
        call nth_text
        mov cx, PS_KIND_COLUMNS
        call print_padded
        mov al, [ps_record + PS_PRIORITY]
        xor ah, ah
        call print_dec
        PRINT "        "
        mov si, ps_states
        mov al, [ps_record + PS_STATE]
        call nth_text
        call print_str
        PRINT ", "
        mov ax, [ps_record + PS_RUNS]
        call print_dec
        call print_newline
        inc bx
        jmp .module
.done:
        ret

; ----------------------------------------------------------------------------
; cmd_kill - stop a background program, named
;   In:       SI = the rest of the line; DS = ES = the program's data
;   Out:      nothing
;   Destroys: everything but DS, ES
; ----------------------------------------------------------------------------
cmd_kill:
        call program_named              ; AL = its number
        jc .out
        sys SYS_KILL
        jnc .out
        cmp ax, E_BUSY
        jne not_background
        PRINT "It is stopped already", CHAR_LF
.out:
        ret

; ----------------------------------------------------------------------------
; cmd_start - start a stopped background program again, named
;   In:       SI = the rest of the line; DS = ES = the program's data
;   Out:      nothing
;   Destroys: everything but DS, ES
; ----------------------------------------------------------------------------
cmd_start:
        call program_named
        jc .out
        sys SYS_START
        jnc .out
        cmp ax, E_BUSY
        jne not_background
        PRINT "It is running already", CHAR_LF
.out:
        ret

; ----------------------------------------------------------------------------
; not_background - kill's or start's refusal of a program the shell may not
; stop or start
;   In:       nothing
;   Out:      nothing
;   Destroys: nothing
; ----------------------------------------------------------------------------
not_background:
        PRINT "Not a background program", CHAR_LF
        ret

; ----------------------------------------------------------------------------
; program_named - the module the line's word names
;   In:       SI = the rest of the line; DS = ES = the program's data
;   Out:      CF clear and AL = its number; or CF set (the trouble printed)
;   Destroys: AH, BX, CX, DI
; ----------------------------------------------------------------------------
program_named:
        cmp byte [si], 0
        je .missing
        xor bx, bx
.module:
        mov al, bl
        mov di, ps_record
        sys SYS_PS
        jc .unknown                     ; past the last
        mov di, ps_record + PS_NAME
        call parse_match
        jnc .found
        inc bx
        jmp .module
.found:
        mov al, bl
        clc
        ret
.missing:
        PRINT "Required parameter missing", CHAR_LF
        stc
        ret
.unknown:
        PRINT "No such program", CHAR_LF
        stc
        ret

; ----------------------------------------------------------------------------
; nth_text - the n-th of zero-terminated texts that follow one another
;   In:       SI = the first; AL = n
;   Out:      SI = the n-th
;   Destroys: AX
; ----------------------------------------------------------------------------
nth_text:
        mov ah, al
.skip:
        test ah, ah
        jz .done
.char:
        lodsb
        test al, al
        jnz .char
        dec ah
        jmp .skip
.done:
        ret

; ----------------------------------------------------------------------------
; print_padded - a zero-terminated text, then spaces to a width
;   In:       SI = the text; CX = the width
;   Out:      nothing
;   Destroys: AX, CX, SI
; ----------------------------------------------------------------------------
print_padded:
.char:
        lodsb
        test al, al
        jz .pad
        call print_char
        loop .char
        ret
.pad:
        jcxz .done
        mov al, ' '
        call print_char
        loop .pad
.done:
        ret
