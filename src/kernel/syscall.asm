; ============================================================================
; rx286 - src/kernel/syscall.asm
; INT 30h, the system call: the program's only way into the kernel (D9).
;
; The function is in the caller's AH, the arguments in its other registers;
; results go back through the frame, and an error sets the frame's CF with
; its code in AX. A buffer is checked with the 286's own instructions before
; the kernel uses it: ARPL against the caller's CS, VERR (or VERW, for a
; buffer the kernel fills), LSL, and bounds (docs/syscalls.md). Interrupts
; stay off but where the kernel waits (D15): while read_key waits, after
; each byte write or print writes, and while a disk or printer works.
; ============================================================================

begin_kdata
syscall_table:
        dw sys_exit                     ; SYS_EXIT
        dw sys_write                    ; SYS_WRITE
        dw sys_read_key                 ; SYS_READ_KEY
        dw sys_ticks                    ; SYS_TICKS
        dw sys_time                     ; SYS_TIME
        dw sys_disk_read                ; SYS_DISK_READ
        dw sys_disk_write               ; SYS_DISK_WRITE
        dw sys_print                    ; SYS_PRINT
        dw sys_sound                    ; SYS_SOUND
        dw sys_joystick                 ; SYS_JOYSTICK
        dw sys_mouse                    ; SYS_MOUSE
        dw sys_serial_write             ; SYS_SERIAL_WRITE
        dw sys_serial_read              ; SYS_SERIAL_READ
        dw sys_wait                     ; SYS_WAIT
syscall_table_end:
wait_events         db 0                ; what SYS_WAIT waits for
end_kdata

%if SYSCALL_COUNT != 14
  %error "syscall.asm: syscall_table does not match SYSCALL_COUNT"
%endif

; ----------------------------------------------------------------------------
; syscall - the handler of vector 30h: dispatch on the caller's AH
;   In:       BP = the frame (from ring 3); DS = ES = SEL_KDATA
;   Out:      the frame's registers as the call returns them
;   Destroys: AX, BX, CX, DX, SI, DI
; ----------------------------------------------------------------------------
syscall:
        and word [bp + FRAME_FLAGS], ~FLAGS_CF
        mov bl, [bp + FRAME_AX + 1]     ; the caller's AH
        cmp bl, SYSCALL_COUNT
        jae .nosys
        xor bh, bh
        shl bx, 1
        jmp [syscall_table + bx]
.nosys:
        mov ax, E_NOSYS
        ; falls through

; ----------------------------------------------------------------------------
; sys_fail - return an error: the frame's CF set, its AX the code
;   In:       AX = the error code; BP = the frame
;   Out:      nothing
;   Destroys: nothing
; ----------------------------------------------------------------------------
sys_fail:
        mov [bp + FRAME_AX], ax
        or word [bp + FRAME_FLAGS], FLAGS_CF
        ret

; ----------------------------------------------------------------------------
; sys_exit - SYS_EXIT: the program starts again
;   In:       BP = the frame; DS = SEL_KDATA
;   Out:      the frame changed to the program's entry
;   Destroys: nothing
; ----------------------------------------------------------------------------
sys_exit:
        TRACE "program: exit"
        jmp restart_program

; ----------------------------------------------------------------------------
; sys_write - SYS_WRITE: the caller's DS:SI, CX bytes, to the console
;   In:       BP = the frame; DS = SEL_KDATA
;   Out:      the frame's AX = bytes written, or an error
;   Destroys: AX, BX, CX, DX, SI, ES
; ----------------------------------------------------------------------------
sys_write:
        mov cx, [bp + FRAME_CX]
        cmp cx, WRITE_MAX
        ja .invalid
        mov word [bp + FRAME_AX], 0
        jcxz .done
        mov si, [bp + FRAME_SI]
        mov ax, [bp + FRAME_DS]
        call check_buffer               ; ES = the caller's segment, or CF
        jc .fault
        xor bx, bx                      ; BX = bytes written
.next:
        mov al, [es:si]
        call con_emit
        inc si
        inc bx
        ; Let interrupts in after every byte (STI acts after the next
        ; instruction): a byte's work is at most a scroll or a clear of the
        ; screen. Stop early if the program is to restart.
        sti
        nop
        cli
        cmp byte [restart_pending], 0
        jne .written
        loop .next
.written:
        call con_cursor
        mov [bp + FRAME_AX], bx
.done:
        ret
.invalid:
        mov ax, E_INVAL
        jmp sys_fail
.fault:
        mov ax, E_FAULT
        jmp sys_fail

; ----------------------------------------------------------------------------
; check_buffer - may the caller read CX bytes at AX:SI?
;   In:       AX = the caller's selector; SI = offset; CX = length (> 0);
;             BP = the frame (its CS is the caller's privilege)
;   Out:      CF clear and ES = the selector if so; CF set if not (also for a
;             buffer ending at FFFFh exactly: no program segment is that big)
;   Destroys: AX, DX
; ----------------------------------------------------------------------------
check_buffer:
        mov dx, [bp + FRAME_CS]
        arpl ax, dx                     ; no more privilege than the caller's
        verr ax                         ; readable at that privilege?
        jnz check_refuse
        jmp check_bounds

; ----------------------------------------------------------------------------
; check_buffer_writable - may the caller write CX bytes at AX:SI?
;   In:       as check_buffer
;   Out:      as check_buffer
;   Destroys: AX, DX
; ----------------------------------------------------------------------------
check_buffer_writable:
        mov dx, [bp + FRAME_CS]
        arpl ax, dx
        verw ax                         ; writable at that privilege? (never code)
        jnz check_refuse
        ; falls through

; ----------------------------------------------------------------------------
; check_bounds - the rest of check_buffer: AX:SI, CX bytes, within the
; segment's limit (not expand-down)
;   In:       AX = the selector, already verified; SI, CX as check_buffer
;   Out:      as check_buffer
;   Destroys: AX, DX
; ----------------------------------------------------------------------------
check_bounds:
        lsl dx, ax                      ; DX = the segment's limit
        jnz check_refuse
        push dx
        lar dx, ax                      ; DH = the access byte
        test dh, ACC_EXPAND_DOWN        ; expand-down data (or conforming code):
        pop dx                          ; 0..limit is not its range; refuse it
        jnz check_refuse
        push si
        add si, cx                      ; CF: the buffer runs past FFFFh
        dec si                          ; SI = the last byte (DEC keeps CF)
        jc .wraps
        cmp si, dx
        ja .wraps                       ; past the limit
        pop si
        mov es, ax
        clc
        ret
.wraps:
        pop si
        ; falls through

; ----------------------------------------------------------------------------
; check_refuse - the end of a refused check
;   In:       nothing
;   Out:      CF set
;   Destroys: nothing
; ----------------------------------------------------------------------------
check_refuse:
        stc
        ret

; ----------------------------------------------------------------------------
; sys_read_key - SYS_READ_KEY: a key, waiting for one or not
;   In:       BP = the frame (its AL: KEY_WAIT or KEY_POLL); DS = SEL_KDATA
;   Out:      the frame's AX = the key (AL ASCII, AH scancode), 0 if none
;   Destroys: AX
; ----------------------------------------------------------------------------
sys_read_key:
        mov al, [bp + FRAME_AX]
        cmp al, KEY_POLL
        je .poll
        cmp al, KEY_WAIT
        jne .invalid
        call kbd_wait_key               ; AX = 0 if a restart came first
        mov [bp + FRAME_AX], ax
        ret
.poll:
        call kbd_get
        mov [bp + FRAME_AX], ax
        ret
.invalid:
        mov ax, E_INVAL
        jmp sys_fail

; ----------------------------------------------------------------------------
; sys_wait - SYS_WAIT: sleep until one of the events asked for is there (a
; key, the mouse's news, bytes from COM2), for CX ticks at most (0: no
; limit), or until the program is to restart
;   In:       BP = the frame (AL the WAIT_* events, CX the ticks); DS =
;             SEL_KDATA
;   Out:      the frame's AX = the events there (0: the time ran out, or a
;             restart); or an error (E_INVAL: no event and no limit, or an
;             unknown one)
;   Destroys: AX, BX, CX
; ----------------------------------------------------------------------------
sys_wait:
        mov al, [bp + FRAME_AX]
        mov cx, [bp + FRAME_CX]
        test al, ~(WAIT_KEY | WAIT_MOUSE | WAIT_SERIAL) & 0xFF
        jnz .invalid
        test al, al
        jnz .events
        jcxz .invalid                   ; nothing, for ever
.events:
        mov [wait_events], al
        mov bx, [ticks]
.check:
        call wait_ready
        test al, al
        jnz .done
        cmp byte [restart_pending], 0
        jne .done
        jcxz .sleep
        mov ax, [ticks]
        sub ax, bx
        cmp ax, cx
        mov al, 0
        jae .done
.sleep:
        test byte [wait_events], WAIT_KEY
        jz .halt
        mov byte [kbd_waiting], KBD_WAIT_FOREVER    ; what a test build types into
        jcxz .halt
        mov byte [kbd_waiting], KBD_WAIT_TIMED
.halt:
        sti
        hlt
        cli
        mov byte [kbd_waiting], 0
        jmp .check
.done:
        xor ah, ah
        mov [bp + FRAME_AX], ax
        ret
.invalid:
        mov ax, E_INVAL
        jmp sys_fail

; ----------------------------------------------------------------------------
; wait_ready - which of the events SYS_WAIT waits for are there
;   In:       wait_events; DS = SEL_KDATA
;   Out:      AL = those there
;   Destroys: AH
; ----------------------------------------------------------------------------
wait_ready:
        xor ah, ah
        test byte [wait_events], WAIT_KEY
        jz .mouse
        mov al, [kbd_head]
        cmp al, [kbd_tail]
        je .mouse
        or ah, WAIT_KEY
.mouse:
        test byte [wait_events], WAIT_MOUSE
        jz .serial
        cmp byte [mouse_changed], 0
        je .serial
        or ah, WAIT_MOUSE
.serial:
%ifdef WITH_MODEM
        test byte [wait_events], WAIT_SERIAL
        jz .done
        call modem_ready
        jz .done
        or ah, WAIT_SERIAL
.done:
%endif
        mov al, ah
        ret

; ----------------------------------------------------------------------------
; sys_ticks - SYS_TICKS: ticks since the kernel started
;   In:       BP = the frame; DS = SEL_KDATA
;   Out:      the frame's DX:AX
;   Destroys: AX
; ----------------------------------------------------------------------------
sys_ticks:
        mov ax, [ticks]
        mov [bp + FRAME_AX], ax
        mov ax, [ticks + 2]
        mov [bp + FRAME_DX], ax
        ret

; ----------------------------------------------------------------------------
; sys_time - SYS_TIME: the RTC's date and time, in BCD (D20 B)
;   In:       BP = the frame; DS = SEL_KDATA
;   Out:      the frame's CX, DX, BX and AL as rtc_read gives them, AH 0
;   Destroys: AX, BX, CX, DX
; ----------------------------------------------------------------------------
sys_time:
        call rtc_read
        xor ah, ah
        mov [bp + FRAME_AX], ax
        mov [bp + FRAME_BX], bx
        mov [bp + FRAME_CX], cx
        mov [bp + FRAME_DX], dx
        ret
