; ============================================================================
; rx286 - src/kernel/syscall.asm
; INT 30h, the system call: the program's only way into the kernel (D9).
;
; The function is in the caller's AH, the arguments in its other registers;
; results go back through the frame, and an error sets the frame's CF with
; its code in AX. A buffer is checked with the 286's own instructions before
; the kernel uses it: ARPL against the caller's CS, VERR (or VERW, for a
; buffer the kernel fills), LAR's present bit, LSL, and bounds
; (docs/syscalls.md); and checked again after every interrupt window, since
; a descriptor may change while interrupts are in (l4.md X2). Interrupts
; stay off but where the kernel waits (D15): while read_key waits, after
; each byte write or print writes, and while a disk or printer works.
; ============================================================================

begin_kdata
syscall_table:
        dw sys_exit                     ; SYS_EXIT
        dw sys_write                    ; SYS_WRITE
        dw sys_gone                     ; SYS_READ_KEY: the keyboard driver's (l4.md L8)
        dw sys_ticks                    ; SYS_TICKS
        dw sys_time                     ; SYS_TIME
        dw sys_disk_read                ; SYS_DISK_READ
        dw sys_disk_write               ; SYS_DISK_WRITE
        dw sys_gone                     ; SYS_PRINT: the printer driver's (l4.md L7)
        dw sys_sound                    ; SYS_SOUND
        dw sys_joystick                 ; SYS_JOYSTICK
        dw sys_gone                     ; SYS_MOUSE: the mouse driver's
        dw sys_serial_write             ; SYS_SERIAL_WRITE
        dw sys_serial_read              ; SYS_SERIAL_READ
        dw sys_wait                     ; SYS_WAIT
syscall_table_end:
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
        call call_enter                 ; one thread at a time (l4.md X15)
        and word [bp + FRAME_FLAGS], ~FLAGS_CF
        mov bl, [bp + FRAME_AX + 1]     ; the caller's AH
        cmp bl, SYSCALL_COUNT
        jae .nosys
        xor bh, bh
        shl bx, 1
        call [syscall_table + bx]
        jmp call_leave
.nosys:
%ifdef TEST_ATTACK
        cmp byte [bp + FRAME_AX + 1], SYS_TEST_PROBE
        jne .none
        call test_probe
        jmp call_leave
.none:
%endif
        mov ax, E_NOSYS
        call sys_fail
        jmp call_leave

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
; sys_gone - a call whose device has left the kernel for a driver (roadmap
; l4.md L7): the OS server makes it there
;   In:       BP = the frame
;   Out:      the frame's CF, AX = E_NOSYS
;   Destroys: AX
; ----------------------------------------------------------------------------
sys_gone:
        mov ax, E_NOSYS
        jmp sys_fail

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
        call recheck_buffer             ; after a window, the descriptor may differ
        jc .gone
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
        call kpreempt                   ; a more urgent thread may run here
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
.gone:
        call con_cursor
        mov ax, E_FAULT
        jmp sys_fail

; ----------------------------------------------------------------------------
; recheck_buffer - may the caller still read CX bytes at its DS:SI? Its
; segment's descriptor may have changed during an interrupt window (l4.md X2)
;   In:       BP = the frame (FRAME_DS the caller's selector); SI = offset;
;             CX = bytes left (> 0)
;   Out:      as check_buffer
;   Destroys: AX, DX
; ----------------------------------------------------------------------------
recheck_buffer:
        mov ax, [bp + FRAME_DS]
        ; falls through

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
        test dh, ACC_PRESENT            ; VERR and VERW pass a segment that is
        jz .absent                      ; not present (l4.md E2, X4)
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
.absent:
        pop dx
        stc
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
; sys_wait - SYS_WAIT: sleep until one of the events asked for is there
; (bytes from COM2: the keys and the mouse are their drivers', whose news
; the OS server looks for), for CX ticks at most (0: no limit), or until the
; program is to restart
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
        mov bx, [ticks]
.check:
        mov al, [bp + FRAME_AX]         ; the events asked for
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
        call kwait_unlocked             ; until an interrupt; other threads run
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
;   In:       AL = the events; DS = SEL_KDATA
;   Out:      AL = those there
;   Destroys: AH
; ----------------------------------------------------------------------------
wait_ready:
        push dx
        mov dl, al
        xor ah, ah
                                        ; (the keys and the mouse are their
                                        ; drivers': the OS server waits for
                                        ; them, l4.md L7, L8)
%ifdef WITH_MODEM
        test dl, WAIT_SERIAL
        jz .done
        call modem_ready
        jz .done
        or ah, WAIT_SERIAL
.done:
%endif
        mov al, ah
        pop dx
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
