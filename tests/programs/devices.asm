; ============================================================================
; rx286 - tests/programs/devices.asm
; The speaker, game port, mouse, serial and wait calls, with good and bad
; arguments (tests/devices).
;
; Each check prints one line. Built with TEST_SOUND, the kernel adds a probe
; line for every tone: whether the speaker's output runs at the frequency
; asked. The program then waits for a key, which ends the test.
; ============================================================================

cpu 286
bits 16
%include "build.inc"
%include "program.inc"

MOUSE_SETTLE_TICKS  equ 20              ; the mouse's reset and "M" take 6 ticks or so
REST_TICKS          equ 5

begin_udata
before              dw 0
byte_buffer         db 0
end_udata

; ----------------------------------------------------------------------------
; entry - the checks, then wait for a key
;   In:       the kernel's start (program.inc)
;   Out:      does not return
;   Destroys: everything
; ----------------------------------------------------------------------------
entry:
        cld
        call check_sound
        call check_joystick
        call check_mouse
        call check_serial
        call check_wait
.wait:
        mov al, KEY_WAIT
        sys SYS_READ_KEY
        jmp .wait

; ----------------------------------------------------------------------------
; check_sound - three tones, a rest, and what the call refuses
;   In:       DS = ES = the program's data
;   Out:      nothing
;   Destroys: everything
; ----------------------------------------------------------------------------
check_sound:
        mov bx, 440
        mov cx, 2
        sys SYS_SOUND
        PRINT "sound: 440 Hz: "
        call report_error
        mov bx, 1000
        mov cx, 2
        sys SYS_SOUND
        PRINT "sound: 1000 Hz: "
        call report_error
        mov bx, 2000
        mov cx, 2
        sys SYS_SOUND
        PRINT "sound: 2000 Hz: "
        call report_error
        sys SYS_TICKS
        mov [before], ax
        xor bx, bx
        mov cx, REST_TICKS
        sys SYS_SOUND
        sys SYS_TICKS
        sub ax, [before]
        PRINT "sound: a rest of 5 ticks: "
        cmp ax, REST_TICKS
        jb .short
        cmp ax, REST_TICKS + 1
        ja .long
        PRINT "5 ticks", CHAR_LF
        jmp .refused
.short:
        PRINT "TOO SHORT", CHAR_LF
        jmp .refused
.long:
        PRINT "TOO LONG", CHAR_LF
.refused:
        PRINT "sound: 18 Hz: "
        mov bx, SOUND_MIN_HZ - 1
        mov cx, 1
        sys SYS_SOUND
        call report_error
        PRINT "sound: 20001 Hz: "
        mov bx, SOUND_MAX_HZ + 1
        mov cx, 1
        sys SYS_SOUND
        call report_error
        PRINT "sound: 501 ticks: "
        mov bx, 440
        mov cx, SOUND_MAX_TICKS + 1
        sys SYS_SOUND
        jmp report_error

; ----------------------------------------------------------------------------
; check_joystick - one reading: the buttons, and each axis present or absent
;   In:       DS = ES = the program's data
;   Out:      nothing
;   Destroys: everything
; ----------------------------------------------------------------------------
check_joystick:
        sys SYS_JOYSTICK
        PRINT "joystick: buttons "
        call print_hex8
        PRINT ", axes"
        mov ax, bx
        call report_axis
        mov ax, cx
        call report_axis
        mov ax, dx
        call report_axis
        mov ax, si
        call report_axis
        jmp print_newline

; ----------------------------------------------------------------------------
; report_axis - " absent" or " present" (its time varies with the emulator)
;   In:       AX = an axis from SYS_JOYSTICK
;   Out:      nothing
;   Destroys: nothing
; ----------------------------------------------------------------------------
report_axis:
        cmp ax, JOY_ABSENT
        je .absent
        PRINT " present"
        ret
.absent:
        PRINT " absent"
        ret

; ----------------------------------------------------------------------------
; check_mouse - once its reset is over, the mouse has said who it is, and is
;   in the middle of the screen with no button down
;   In:       DS = ES = the program's data
;   Out:      nothing
;   Destroys: everything
; ----------------------------------------------------------------------------
check_mouse:
        xor al, al
        mov cx, MOUSE_SETTLE_TICKS
        sys SYS_WAIT
        sys SYS_MOUSE
        PRINT "mouse: "
        test ax, ax
        jnz .present
        PRINT "ABSENT"
        jmp .where
.present:
        PRINT "present"
.where:
        PRINT ", at "
        mov ax, cx
        call print_dec
        PRINT ", "
        mov ax, dx
        call print_dec
        PRINT ", buttons "
        mov ax, bx
        call print_dec
        jmp print_newline

; ----------------------------------------------------------------------------
; check_serial - a byte to the modem, and none from it (no one is there)
;   In:       DS = ES = the program's data
;   Out:      nothing
;   Destroys: everything
; ----------------------------------------------------------------------------
check_serial:
        PRINT "serial: write: "
        mov si, byte_buffer
        mov cx, 1
        sys SYS_SERIAL_WRITE
        call report_error
        PRINT "serial: read: "
        mov di, byte_buffer
        mov cx, 1
        sys SYS_SERIAL_READ
        jmp report_error

; ----------------------------------------------------------------------------
; check_wait - SYS_WAIT: a timed sleep, a key that does not come, what it
; refuses, and the registers it keeps
;   In:       DS = ES = the program's data
;   Out:      nothing
;   Destroys: everything
; ----------------------------------------------------------------------------
check_wait:
        sys SYS_TICKS
        mov [before], ax
        xor al, al
        mov cx, REST_TICKS
        sys SYS_WAIT
        push ax
        sys SYS_TICKS
        sub ax, [before]
        PRINT "wait: 5 ticks: "
        cmp ax, REST_TICKS
        jb .bad
        cmp ax, REST_TICKS + 1
        ja .bad
        PRINT "slept, events "
        pop ax
        call print_hex8
        call print_newline
        jmp .key
.bad:
        pop ax
        PRINT "WRONG", CHAR_LF
.key:
        PRINT "wait: a key, 3 ticks at most: events "
        mov al, WAIT_KEY
        mov cx, 3
        sys SYS_WAIT
        call print_hex8
        call print_newline
        PRINT "wait: nothing for ever: "
        xor al, al
        xor cx, cx
        sys SYS_WAIT
        call report_error
        PRINT "wait: an unknown event: "
        mov al, 0x80
        mov cx, 1
        sys SYS_WAIT
        call report_error
        mov bx, 0x1111
        mov dx, 0x3333
        mov si, 0x4444
        mov di, 0x5555
        mov bp, 0x6666
        xor al, al
        mov cx, 1
        sys SYS_WAIT
        PRINT "wait: registers "
        cmp bx, 0x1111
        jne .changed
        cmp cx, 1
        jne .changed
        cmp dx, 0x3333
        jne .changed
        cmp si, 0x4444
        jne .changed
        cmp di, 0x5555
        jne .changed
        cmp bp, 0x6666
        jne .changed
        PRINT "kept", CHAR_LF
        ret
.changed:
        PRINT "CHANGED", CHAR_LF
        ret

; ----------------------------------------------------------------------------
; report_error - "error N" if CF, else "no error"
;   In:       CF and AX as a system call returned them
;   Out:      nothing
;   Destroys: nothing
; ----------------------------------------------------------------------------
report_error:
        jnc .none
        PRINT "error "
        call print_dec
        call print_newline
        ret
.none:
        PRINT "no error", CHAR_LF
        ret

%include "uprint.asm"
%include "format.asm"
