; ============================================================================
; rx286 - tests/programs/syscalls.asm
; Every system call, with good and bad arguments (tests/syscalls).
;
; Each check prints one line; tests/syscalls/calls.test holds the lines it
; must print. The run ends with SYS_EXIT: the program starts again, sees
; from its data (which the kernel keeps) that it ran before, says so, and
; waits for a key, which ends the test.
; ============================================================================

cpu 286
bits 16
%include "build.inc"
%include "program.inc"

WINDOW_LINES        equ WRITE_MAX / 2   ; bytes a window write: what the data segment holds
WINDOW_SLACK        equ 2               ; ticks either way the edges allow

begin_udata
runs                dw 0
hello               db "hello"
hello_end:
before              dd 0
window_bytes        times WINDOW_LINES db 0     ; filled by each window_write
expected            dw 0
start_seconds       db 0
edge_from           db 0
end_udata

; ----------------------------------------------------------------------------
; entry - the checks, then SYS_EXIT; after the restart, wait for a key
;   In:       the kernel's start (program.inc)
;   Out:      does not return
;   Destroys: everything
; ----------------------------------------------------------------------------
entry:
        inc word [runs]
        cmp word [runs], 1
        je check_write
        PRINT "exit: the program started again, its data kept", CHAR_LF
.wait:
        mov al, KEY_WAIT
        sys SYS_READ_KEY
        jmp .wait

; ----------------------------------------------------------------------------
; check_write - SYS_WRITE: a string, nothing, a bad pointer, too much
;   In:       DS = ES = the program's data
;   Out:      falls through to the next checks
;   Destroys: everything
; ----------------------------------------------------------------------------
check_write:
        mov si, hello
        mov cx, hello_end - hello
        sys SYS_WRITE
        call print_newline
        PRINT "write: returned "
        call print_dec
        call print_newline
        xor cx, cx
        sys SYS_WRITE
        PRINT "write: 0 bytes returned "
        call print_dec
        call print_newline
        ; Past the data segment's limit (UDATA_ROOM).
        mov si, UDATA_ROOM - 2
        mov cx, 4
        sys SYS_WRITE
        call report_error
        ; Wrapping past FFFFh.
        mov si, 0xFFF0
        mov cx, 0x20
        sys SYS_WRITE
        call report_error
        ; A null DS.
        push ds
        xor ax, ax
        mov ds, ax
        xor si, si
        mov cx, 1
        sys SYS_WRITE
        pop ds
        call report_error
        ; More than WRITE_MAX.
        mov si, hello
        mov cx, WRITE_MAX + 1
        sys SYS_WRITE
        call report_error
        ; The code segment is readable: the program may write from it.
        push ds
        push cs
        pop ds
        mov si, cs_byte
        mov cx, 1
        sys SYS_WRITE
        pop ds
        PRINT CHAR_LF, "write: from CS returned "
        call print_dec
        call print_newline
        ; falls through

; ----------------------------------------------------------------------------
; check_others - SYS_READ_KEY, SYS_TICKS, SYS_TIME, an unknown call, and
; the registers a call keeps
;   In:       DS = ES = the program's data
;   Out:      falls through to the window check
;   Destroys: everything
; ----------------------------------------------------------------------------
check_others:
        mov al, KEY_POLL
        sys SYS_READ_KEY
        PRINT "read_key: polled "
        call print_hex16
        call print_newline
        mov al, KEY_WAIT
        sys SYS_READ_KEY
        PRINT "read_key: waited for "
        call print_hex16
        call print_newline
        mov al, 7                       ; neither KEY_WAIT nor KEY_POLL
        sys SYS_READ_KEY
        call report_error
        sys SYS_TICKS
        mov bx, ax
        mov cx, dx
        sys SYS_TICKS
        sub ax, bx
        sbb dx, cx
        PRINT "ticks: "
        test dx, dx
        js .backwards
        PRINT "counting up", CHAR_LF
        jmp .time
.backwards:
        PRINT "went backwards", CHAR_LF
.time:
        ; The date depends on the emulator (Bochs: 1989; DOSBox-X and MAME:
        ; the host's), so the check is that it is a valid BCD date and time.
        sys SYS_TIME
        PRINT "time: "
        call valid_time
        jc .bad_time
        PRINT "a valid BCD date and time", CHAR_LF
        jmp .unknown
.bad_time:
        PRINT "INVALID", CHAR_LF
.unknown:
        mov ah, 0x7F                    ; no such call
        int SYSCALL_VECTOR
        call report_error
        ; The registers a call does not return are kept.
        mov bx, 0x1111
        mov cx, 0x2222
        mov dx, 0x3333
        mov si, 0x4444
        mov di, 0x5555
        mov bp, 0x6666
        sys SYS_TICKS                   ; returns DX:AX only
        PRINT "registers: "
        cmp bx, 0x1111
        jne .changed
        cmp cx, 0x2222
        jne .changed
        cmp si, 0x4444
        jne .changed
        cmp di, 0x5555
        jne .changed
        cmp bp, 0x6666
        jne .changed
        PRINT "kept", CHAR_LF
        jmp check_window
.changed:
        PRINT "CHANGED", CHAR_LF
        ; falls through

; ----------------------------------------------------------------------------
; check_window - writes of WINDOW_LINES newlines, spaces and form feeds scroll
; or clear the screen that many times. The kernel lets interrupts in after
; every byte (roadmap D15), so the ticks counted across each write match the
; RTC's seconds; with interrupts off for a write, they would fall short.
;   In:       DS = ES = the program's data
;   Out:      does not return: SYS_EXIT
;   Destroys: everything
; ----------------------------------------------------------------------------
check_window:
        mov al, CHAR_LF
        call window_write
        mov al, ' '
        call window_write
        mov al, CHAR_FF
        call window_write
        sys SYS_EXIT

; ----------------------------------------------------------------------------
; window_write - one write of WINDOW_LINES copies of a byte, measured
;   In:       AL = the byte; DS = ES = the program's data
;   Out:      a line: whether the ticks kept pace with the clock
;   Destroys: everything but DS, ES
; ----------------------------------------------------------------------------
window_write:
        mov di, window_bytes
        mov cx, WINDOW_LINES
        rep stosb
        call clock_edge                 ; start at an edge of the RTC's seconds
        mov [start_seconds], al
        sys SYS_TICKS
        mov [before], ax
        mov [before + 2], dx
        mov si, window_bytes
        mov cx, WINDOW_LINES
        sys SYS_WRITE
        call clock_edge                 ; end at the next edge
        mov bl, [start_seconds]
        call bcd_seconds_between        ; AX = the clock's seconds
        mov cx, SYS_TICKS_HZ
        mul cx
        mov [expected], ax              ; the ticks those seconds hold
        sys SYS_TICKS
        sub ax, [before]
        sbb dx, [before + 2]            ; DX:AX = the ticks counted
        PRINT CHAR_LF, "window: "
        test dx, dx
        jnz .lost
        sub ax, [expected]
        add ax, WINDOW_SLACK
        cmp ax, 2 * WINDOW_SLACK
        ja .lost                        ; more than WINDOW_SLACK either way
        PRINT "ticks kept pace with the clock", CHAR_LF
        ret
.lost:
        PRINT "ticks were lost", CHAR_LF
        ret

; ----------------------------------------------------------------------------
; clock_edge - wait until the RTC's seconds change
;   In:       DS = the program's data
;   Out:      AL = the new seconds (BCD)
;   Destroys: AH, BX, CX, DX
; ----------------------------------------------------------------------------
clock_edge:
        sys SYS_TIME
        mov [edge_from], al
.wait:
        sys SYS_TIME
        cmp al, [edge_from]
        je .wait
        ret

; ----------------------------------------------------------------------------
; bcd_seconds_between - seconds from one BCD seconds value to another
;   In:       BL = from, AL = to (BCD, 00-59)
;   Out:      AX = the seconds between (0-59)
;   Destroys: BX
; ----------------------------------------------------------------------------
bcd_seconds_between:
        call bcd_to_binary
        mov ah, al
        mov al, bl
        call bcd_to_binary
        sub ah, al
        jnc .done
        add ah, 60
.done:
        mov al, ah
        xor ah, ah
        ret

; ----------------------------------------------------------------------------
; bcd_to_binary - a BCD byte as a number
;   In:       AL = BCD
;   Out:      AL = the number
;   Destroys: nothing
; ----------------------------------------------------------------------------
bcd_to_binary:
        push bx
        mov bh, ah                      ; MUL below writes AH: keep the caller's
        mov bl, al
        and bl, 0x0F                    ; BL = the units
        shr al, 4
        mov ah, 10
        mul ah                          ; AX = the tens * 10
        add al, bl
        mov ah, bh
        pop bx
        ret

; ----------------------------------------------------------------------------
; valid_time - is SYS_TIME's answer a valid BCD date and time?
;   In:       CX, DX, BX, AL as SYS_TIME returns them
;   Out:      CF clear if every field is BCD and in range
;   Destroys: AX, SI
; ----------------------------------------------------------------------------
valid_time:
        mov si, time_limits
        mov ah, al                      ; seconds
        call .check
        mov ah, bl                      ; minutes
        call .check
        mov ah, bh                      ; hours
        call .check
        mov ah, dl                      ; day
        call .check
        mov ah, dh                      ; month
        call .check
        mov ah, cl                      ; year
        call .check
        mov ah, ch                      ; century
        jmp .check
; AH = a BCD field; [cs:si] = its smallest and largest value; SI moves on
.check:
        mov al, ah
        and al, 0x0F
        cmp al, 9
        ja .bad
        mov al, ah
        cmp al, 0x9F
        ja .bad
        cmp al, [cs:si]
        jb .bad
        cmp al, [cs:si + 1]
        ja .bad
        add si, 2
        clc
        ret
.bad:
        add sp, 2                       ; out of valid_time, not just .check
        stc
        ret

time_limits     db 0x00, 0x59, 0x00, 0x59, 0x00, 0x23, 0x01, 0x31, 0x01, 0x12
                db 0x00, 0x99, 0x19, 0x20

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

cs_byte             db "C"
