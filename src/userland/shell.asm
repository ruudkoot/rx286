; ============================================================================
; rx286 - src/userland/shell.asm
; The demonstration shell: rx286's one program, in ring 3 (roadmap D19).
;
; It reads a line with a small editor (Backspace, Esc to clear, Up to
; recall the last line), finds the command's word in its table and runs it.
; Its prompt and its drive commands are DOS's (drives.asm, on the FAT12
; library fat.asm: storage roadmap D8).
; Every command reaches the kernel only through the system calls; `crash`
; does what no program may, and the kernel's report and the shell's restart
; show the sandbox at work. The kernel keeps the shell's data across a
; restart, so the shell knows whether it has started before and keeps its
; last line.
; ============================================================================

cpu 286
bits 16
%include "build.inc"
%include "program.inc"
%include "kcalls.inc"

LINE_MAX            equ 70              ; characters a line may hold
CHAR_DEL            equ 0x7F

begin_udata
starts              dw 0                ; how often the shell has started
line                times LINE_MAX + 1 db 0
line_length         dw 0
last_line           times LINE_MAX + 1 db 0
end_udata

; ----------------------------------------------------------------------------
; entry - the banner, then read and run lines forever
;   In:       the kernel's start (program.inc)
;   Out:      does not return
;   Destroys: everything
; ----------------------------------------------------------------------------
entry:
        cld
        inc word [starts]
        cmp word [starts], 1
        jne .again
        call drives_init
        PRINT "rx286 shell: type help for the commands", CHAR_LF
        jmp .loop
.again:
        PRINT "rx286 shell, started again", CHAR_LF
.loop:
        call print_prompt
        call read_line
        call run_line
        jmp .loop

; ----------------------------------------------------------------------------
; read_line - read a line with the editor
;   In:       DS = ES = the program's data
;   Out:      line = the line, zero-terminated; line_length its length
;   Destroys: AX, BX, CX, SI, DI
; ----------------------------------------------------------------------------
read_line:
        mov word [line_length], 0
.key:
        mov al, KEY_WAIT
        sys SYS_READ_KEY
        cmp al, CHAR_CR
        je .enter
        cmp al, CHAR_BS
        je .backspace
        cmp al, CHAR_ESC
        je .clear
        test al, al
        jz .special
        cmp al, ' '
        jb .key                         ; other control characters: ignored
        cmp al, CHAR_DEL
        jae .key
        mov bx, [line_length]
        cmp bx, LINE_MAX
        jae .key                        ; the line is full
        mov [line + bx], al
        inc word [line_length]
        call print_char
        jmp .key
.backspace:
        call erase_char
        jmp .key
.clear:
        call erase_line
        jmp .key
.special:
        cmp ah, SC_UP
        jne .key
        call erase_line                 ; Up: the last line instead
        mov si, last_line
        mov di, line
        xor cx, cx
.copy:
        lodsb
        stosb
        test al, al
        jz .copied
        inc cx
        jmp .copy
.copied:
        mov [line_length], cx
        mov si, line
        call print_str
        jmp .key
.enter:
        call print_newline
        mov bx, [line_length]
        mov byte [line + bx], 0
        ret

; ----------------------------------------------------------------------------
; erase_char - take the last character off the line, and off the screen
;   In:       DS = the program's data
;   Out:      nothing
;   Destroys: AX
; ----------------------------------------------------------------------------
erase_char:
        cmp word [line_length], 0
        je .done
        dec word [line_length]
        PRINT CHAR_BS, " ", CHAR_BS
.done:
        ret

; ----------------------------------------------------------------------------
; erase_line - take every character off the line, and off the screen
;   In:       DS = the program's data
;   Out:      nothing
;   Destroys: AX
; ----------------------------------------------------------------------------
erase_line:
        cmp word [line_length], 0
        je .done
        call erase_char
        jmp erase_line
.done:
        ret

; ----------------------------------------------------------------------------
; run_line - find the line's command and run it; keep the line for Up
;   In:       line, zero-terminated; DS = ES = the program's data
;   Out:      nothing
;   Destroys: everything but DS, ES
; ----------------------------------------------------------------------------
run_line:
        mov si, line
        call parse_skip_spaces
        cmp byte [si], 0
        je .done                        ; an empty line
        mov si, line                    ; keep it for Up
        mov di, last_line
        mov cx, LINE_MAX + 1
        rep movsb
        mov si, line
        call parse_skip_spaces
        call drive_line                 ; "b:": done, if so
        jnc .done
        mov bx, commands_start
.next:
        mov di, [cs:bx]                 ; the command's word, or 0 at the end
        test di, di
        jz .unknown
        mov si, line
        call parse_match
        jnc .found
        add bx, COMMAND_ENTRY
        jmp .next
.found:
        call [cs:bx + 2]                ; SI = the rest of the line
.done:
        ret
.unknown:
        PRINT "unknown command: "
        mov si, line
        call parse_skip_spaces
        call parse_word_length
        sys SYS_WRITE
        PRINT "; type help", CHAR_LF
        ret

; The commands: the word, the routine, a line of help; a zero word ends the
; table. The table is in the code segment (read through CS), its strings in
; the data segment.
COMMAND_ENTRY       equ 6
%macro command 3
        dw %%word, %2, %%help
    [section udata]
%%word: db %1, 0
%%help: db %3, 0
    __?SECT?__
%endmacro

commands_start      equ $
        command "help", cmd_help, "these lines"
        command "echo", cmd_echo, "echo TEXT: write TEXT"
        command "clear", cmd_clear, "clear the screen"
        command "dir", cmd_dir, "dir [PATH]: a directory's files, or a file's line"
        command "cd", cmd_cd, "cd [PATH]: show or change a drive's directory"
        command "type", cmd_type, "type FILE: show a file"
        command "print", cmd_print, "print FILE: send a file to the printer on LPT1"
        command "beep", cmd_beep, "a short tone on the speaker"
        command "play", cmd_play, "a tune on the speaker"
        command "joy", cmd_joy, "the game port's buttons and axes"
        command "mouse", cmd_mouse, "follow the mouse on COM1, until Esc"
        command "term", cmd_term, "a terminal on COM2 (a modem), until Esc"
        command "uptime", cmd_uptime, "time since the kernel started"
        command "date", cmd_date, "the date and time of the real-time clock"
        command "keys", cmd_keys, "show each key's scancode and ASCII, until Esc"
        command "fpu", cmd_fpu, "the square root of 2 and pi, by the 80287"
        command "mem", cmd_mem, "the shell's own segments, as the CPU sees them"
        command "crash", cmd_crash, "crash KIND: try what no program may (crash help)"
        command "spin", cmd_spin, "loop forever; Ctrl+Break gets the shell back"
        command "exit", cmd_exit, "end the shell; the kernel starts it again"
        dw 0

%include "commands.asm"
%include "fat12.asm"
%include "fatname.asm"
%include "fat.asm"
%include "drives.asm"
%include "devices.asm"
%include "crash.asm"
%include "parse.asm"
%include "uprint.asm"
%include "format.asm"
