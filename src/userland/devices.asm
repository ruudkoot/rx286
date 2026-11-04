; ============================================================================
; rx286 - src/userland/devices.asm
; The shell's devices: beep and play (the speaker), joy (the game port),
; mouse (COM1) and term (COM2), each through its system call (devices
; roadmap D6).
;
; mouse and term wait in SYS_WAIT for a key or their device's news, so the
; shell sleeps while nothing happens; Esc ends them.
; ============================================================================

BEEP_HZ             equ 880
BEEP_TICKS          equ 10
MOUSE_CELL          equ 8               ; the mouse's units in a character cell
JOY_BUTTONS         equ 4
TERM_CHUNK          equ 64              ; bytes taken from COM2 at a time

begin_udata
term_buffer         times TERM_CHUNK db 0
joy_axes            times JOY_BUTTONS dw 0
end_udata

; ----------------------------------------------------------------------------
; cmd_beep - a short tone
;   In:       DS = the program's data
;   Out:      nothing
;   Destroys: AX, BX, CX
; ----------------------------------------------------------------------------
cmd_beep:
        mov bx, BEEP_HZ
        mov cx, BEEP_TICKS
        sys SYS_SOUND
        ret

; ----------------------------------------------------------------------------
; cmd_play - a tune: tune_notes, a frequency and a length in ticks each
;   In:       DS = the program's data
;   Out:      nothing
;   Destroys: AX, BX, CX, SI
; ----------------------------------------------------------------------------
cmd_play:
        mov si, tune_notes
.note:
        mov bx, [cs:si]
        mov cx, [cs:si + 2]
        jcxz .done
        sys SYS_SOUND
        add si, 4
        jmp .note
.done:
        ret

; A frequency in hertz (0: a rest) and a length in ticks; a length of 0 ends it.
tune_notes  dw 392, 10, 392, 10, 440, 20, 392, 20, 523, 20, 494, 30, 0, 10
            dw 392, 10, 392, 10, 440, 20, 392, 20, 587, 20, 523, 30, 0, 0

; ----------------------------------------------------------------------------
; cmd_joy - one reading of the game port: the buttons down, and each axis's
; time, or "absent"
;   In:       DS = ES = the program's data
;   Out:      nothing
;   Destroys: AX, BX, CX, DX, SI, DI
; ----------------------------------------------------------------------------
cmd_joy:
        sys SYS_JOYSTICK
        mov [joy_axes], bx
        mov [joy_axes + 2], cx
        mov [joy_axes + 4], dx
        mov [joy_axes + 6], si
        mov bl, al
        PRINT "buttons:"
        test bl, bl
        jnz .pressed
        PRINT " none"
.pressed:
        mov al, '1'
        mov cx, JOY_BUTTONS
.button:
        shr bl, 1
        jnc .up
        PRINT " "
        call print_char
.up:
        inc al
        loop .button
        PRINT "; axes:"
        mov si, joy_axes
        mov cx, JOY_BUTTONS
.axis:
        lodsw
        cmp ax, JOY_ABSENT
        jne .time
        PRINT " absent"
        jmp .next
.time:
        PRINT " "
        call print_dec
        PRINT " us"
.next:
        loop .axis
        jmp print_newline

; ----------------------------------------------------------------------------
; cmd_mouse - the mouse's position and buttons whenever they change, until
; Esc or both buttons
;   In:       DS = ES = the program's data
;   Out:      nothing
;   Destroys: AX, BX, CX, DX, SI, DI
; ----------------------------------------------------------------------------
cmd_mouse:
        sys SYS_MOUSE
        test ax, ax
        jnz .present
        PRINT "No mouse on COM1", CHAR_LF
        ret
.present:
        PRINT "Move the mouse; Esc or both buttons end.", CHAR_LF
        call show_mouse
.wait:
        mov al, WAIT_KEY | WAIT_MOUSE
        xor cx, cx
        sys SYS_WAIT
        mov dl, al
        test dl, WAIT_MOUSE
        jz .key
        push dx
        sys SYS_MOUSE
        call show_mouse
        pop dx
        cmp bx, MOUSE_LEFT | MOUSE_RIGHT
        je .done
.key:
        test dl, WAIT_KEY
        jz .wait
        mov al, KEY_POLL
        sys SYS_READ_KEY
        cmp al, CHAR_ESC
        jne .wait
.done:
        ret

; ----------------------------------------------------------------------------
; show_mouse - "x 320, y 100 (column 40, row 12), buttons: none"
;   In:       BX = the buttons, CX = x, DX = y (SYS_MOUSE's)
;   Out:      nothing
;   Destroys: AX
; ----------------------------------------------------------------------------
show_mouse:
        PRINT "x "
        mov ax, cx
        call print_dec
        PRINT ", y "
        mov ax, dx
        call print_dec
        PRINT " (column "
        mov ax, cx
        shr ax, 3
        call print_dec
        PRINT ", row "
        mov ax, dx
        shr ax, 3
        call print_dec
        PRINT "), buttons: "
        cmp bx, MOUSE_LEFT | MOUSE_RIGHT
        je .both
        cmp bx, MOUSE_LEFT
        je .left
        cmp bx, MOUSE_RIGHT
        je .right
        PRINT "none", CHAR_LF
        ret
.both:
        PRINT "both", CHAR_LF
        ret
.left:
        PRINT "left", CHAR_LF
        ret
.right:
        PRINT "right", CHAR_LF
        ret

%if MOUSE_CELL != 8
  %error "devices.asm: show_mouse divides by 8"
%endif

; ----------------------------------------------------------------------------
; cmd_term - a terminal on COM2, the modem's line: what comes is shown, what
; is typed is sent (Enter as CR); Esc ends it. Where COM2 carries the
; kernel's log (debug and test builds), it says so.
;   In:       DS = ES = the program's data
;   Out:      nothing
;   Destroys: AX, BX, CX, DX, SI, DI
; ----------------------------------------------------------------------------
cmd_term:
        xor cx, cx
        sys SYS_SERIAL_WRITE            ; nothing, to ask whether COM2 is the modem
        jnc .ours
        PRINT "COM2 carries the kernel's log in this build; a release build", CHAR_LF
        PRINT "makes it the modem's line.", CHAR_LF
        ret
.ours:
        PRINT "Terminal on COM2 at 9600 baud; Esc ends.", CHAR_LF
.wait:
        mov al, WAIT_KEY | WAIT_SERIAL
        xor cx, cx
        sys SYS_WAIT
        mov dl, al
        test dl, WAIT_SERIAL
        jz .key
        mov di, term_buffer
        mov cx, TERM_CHUNK
        sys SYS_SERIAL_READ
        mov cx, ax
        mov si, term_buffer
        sys SYS_WRITE
.key:
        test dl, WAIT_KEY
        jz .wait
        mov al, KEY_POLL
        sys SYS_READ_KEY
        test al, al
        jz .wait                        ; a key without ASCII
        cmp al, CHAR_ESC
        je .done
        mov [term_buffer], al
        mov si, term_buffer
        mov cx, 1
        sys SYS_SERIAL_WRITE
        jmp .wait
.done:
        jmp print_newline
