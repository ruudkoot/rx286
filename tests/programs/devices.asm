; ============================================================================
; rx286 - tests/programs/devices.asm
; The speaker, game port, mouse, serial and wait calls, with good and bad
; arguments (tests/devices).
;
; Each check prints one line. Built with TEST_SOUND, the kernel adds probe
; lines for every sound: whether the speaker's output runs at the frequency
; asked, and whether it is silent after. Built with DEVICES_MODEM (and the
; kernel with MODEM_COM2, so COM2 is the modem's line), it runs only the
; modem's checks (tests/devices/modem.test): the buffers the calls refuse,
; and a modem's answer, which must arrive whole while the kernel is busy
; writing to the console and its log. The program then waits for a key, which ends the test.
; ============================================================================

cpu 286
bits 16
%include "build.inc"
%include "program.inc"

MOUSE_SETTLE_TICKS  equ 20              ; the mouse's reset and "M" take 6 ticks or so
REST_TICKS          equ 5
%ifdef TEST_SOUND
REST_SLACK          equ 3               ; the kernel's silence probe watches up to two ticks more
%else
REST_SLACK          equ 1
%endif
ATI_ANSWER          equ 30              ; "ATI", CR, echoed, and the peer's answer
LOG_ROUNDS          equ 30              ; writes of LOG_CHUNK bytes while it answers
LOG_CHUNK           equ 64
COLLECT_ROOM        equ 256

begin_udata
before              dw 0
byte_buffer         db 0
ati                 db "ATI", CHAR_CR
ati_end:
log_chunk           times LOG_CHUNK db 'x'
collected           times COLLECT_ROOM db 0
total               dw 0
end_udata

; ----------------------------------------------------------------------------
; entry - the checks, then wait for a key
;   In:       the kernel's start (program.inc)
;   Out:      does not return
;   Destroys: everything
; ----------------------------------------------------------------------------
entry:
        cld
%ifdef DEVICES_MODEM
        call check_modem
        jmp .wait
%endif
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
        cmp ax, REST_TICKS + REST_SLACK
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
; check_serial - COM2 is the log in test builds: both calls refuse
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
; check_modem - the buffers the modem's calls refuse; then ATI to the
; modem, its answer counted: once with the program idle, once while the
; kernel writes LOG_ROUNDS * LOG_CHUNK bytes to the console and its log (COM3
; in this build), and once more after
;   In:       DS = ES = the program's data
;   Out:      nothing
;   Destroys: everything
; ----------------------------------------------------------------------------
check_modem:
        PRINT "serial: read into the code: "
        push es
        push cs
        pop es
        xor di, di
        mov cx, 4
        sys SYS_SERIAL_READ
        pop es
        call report_error
        PRINT "serial: read across the data's limit: "
        mov di, UDATA_ROOM - 2
        mov cx, 4
        sys SYS_SERIAL_READ
        call report_error
        PRINT "serial: read through a null ES: "
        push es
        xor ax, ax
        mov es, ax
        xor di, di
        mov cx, 4
        sys SYS_SERIAL_READ
        pop es
        call report_error
        PRINT "serial: write from a null DS: "
        push ds
        xor ax, ax
        mov ds, ax
        xor si, si
        mov cx, 1
        sys SYS_SERIAL_WRITE
        pop ds
        call report_error
        PRINT "serial: write too much: "
        mov si, ati
        mov cx, SERIAL_MAX + 1
        sys SYS_SERIAL_WRITE
        call report_error
        call ask_ati
        call collect
        PRINT "modem: idle: answer of "
        call report_total
        call ask_ati_now
        mov bx, LOG_ROUNDS
.round:
        mov si, log_chunk
        mov cx, LOG_CHUNK
        sys SYS_WRITE
        dec bx
        jnz .round
        call print_newline
        call settle
        call collect
        PRINT "modem: while the log is written: answer of "
        call report_total
        call ask_ati
        call collect
        PRINT "modem: after: answer of "
        jmp report_total

; ----------------------------------------------------------------------------
; ask_ati - ATI to the modem, then time for its answer
;   In:       DS = ES = the program's data
;   Out:      nothing
;   Destroys: AX, CX, SI
; ----------------------------------------------------------------------------
ask_ati:
        call ask_ati_now
        ; falls through

; ----------------------------------------------------------------------------
; settle - a second for the modem's answer to come
;   In:       nothing
;   Out:      nothing
;   Destroys: AX, CX
; ----------------------------------------------------------------------------
settle:
        xor al, al
        mov cx, 50
        sys SYS_WAIT
        ret

; ----------------------------------------------------------------------------
; ask_ati_now - ATI to the modem, without waiting
;   In:       DS = ES = the program's data
;   Out:      nothing
;   Destroys: AX, CX, SI
; ----------------------------------------------------------------------------
ask_ati_now:
        mov si, ati
        mov cx, ati_end - ati
        sys SYS_SERIAL_WRITE
        ret

; ----------------------------------------------------------------------------
; collect - every byte the modem's line holds, counted into total
;   In:       DS = ES = the program's data
;   Out:      total
;   Destroys: AX, CX, DI
; ----------------------------------------------------------------------------
collect:
        mov word [total], 0
.more:
        mov di, collected
        mov cx, COLLECT_ROOM
        sys SYS_SERIAL_READ
        add [total], ax
        test ax, ax
        jnz .more
        ret

; ----------------------------------------------------------------------------
; report_total - "N bytes, whole" if total is ATI_ANSWER, else the count
;   In:       total
;   Out:      nothing
;   Destroys: AX
; ----------------------------------------------------------------------------
report_total:
        mov ax, [total]
        call print_dec
        PRINT " bytes", CHAR_LF
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
