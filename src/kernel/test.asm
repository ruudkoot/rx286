; ============================================================================
; rx286 - src/kernel/test.asm
; What only test builds have (roadmap D16): typed keys, device probes, kernel
; faults on purpose, and the end of a test through Bochs' shutdown port.
;
; Typing: tools/run-test compiles a test's key script into test_keys (see
; tools/rxlib.py for the operations). On every tick, test_tick types the
; next byte through the 8042's command D2h, which puts it where the keyboard
; would and raises IRQ1 (roadmap E7). It types only while something waits in
; kbd_wait_key with nothing buffered, unless the script says "now". When the
; script is done and something waits again, the test ends: "TEST END" on
; COM1, then the shutdown port.
;
; A test image asks for more with -d (tools/run-test):
;   TEST_PANIC_DIVIDE, TEST_PANIC_ASSERT, TEST_PANIC_GP, TEST_PANIC_STACK
;                       a kernel fault of that kind
;   TEST_PROBES         make the diskette and fixed-disk controllers and the
;                       RTC interrupt, though rx286 has no driver for them
;   TEST_FPU_KERNEL     a 287 error raised by the kernel itself
;   TEST_TICKS          compare the timer with the RTC
;   TEST_KEYBOARD       print every key read (before there is a program)
;   TEST_IMAGE_SUM      the sum of KERNEL.BIN's words (entry.asm)
; Release and debug builds assemble none of this.
; ============================================================================

%ifdef WITH_TEST_HOOKS

TEST_OP_END         equ 0
TEST_OP_WHEN_WAITING equ 1
TEST_OP_NOW         equ 2
TEST_OP_WAIT        equ 3
TEST_PROBE_TICKS    equ 5               ; how long a probe waits for its interrupt
TEST_RTC_TICKS      equ 10              ; how long the RTC probe keeps re-arming
TEST_HDC_LIMIT      equ 10000           ; polls of the disk controller's BSY
TEST_CLOCK_SECONDS  equ 3
TEST_FPU_CW_ZM      equ 0x037B          ; every exception masked but zero-divide

begin_kdata
%ifdef TEST_KEYS_INC
%include TEST_KEYS_INC
%else
test_keys           db TEST_OP_END
%endif
test_key_ptr        dw test_keys
test_wait_left      db 0
test_fpu_cw         dw TEST_FPU_CW_ZM
msg_test_end        db "TEST END", CHAR_LF, 0
msg_shutdown        db "Shutdown", 0
msg_key             db "key ", 0
msg_key_abandoned   db "key: waiting abandoned for a restart", CHAR_LF, 0
msg_probe_rtc       db "probe: the RTC kept interrupting; IRQ8 stayed masked", CHAR_LF, 0
msg_ticks_ok        db "timer: 50 ticks a second, by the clock", CHAR_LF, 0
msg_ticks_bad       db "timer: ticks in 3 seconds of the clock: ", 0
msg_fpu_done        db "fpu: the kernel's test raised its error", CHAR_LF, 0
end_kdata

; ----------------------------------------------------------------------------
; test_start - what the test image asked for, once the kernel is ready
;   In:       DS = ES = SEL_KDATA; interrupts off
;   Out:      nothing (or never, for the panic tests)
;   Destroys: AX, BX, CX, DX, SI, DI
; ----------------------------------------------------------------------------
test_start:
%ifdef TEST_PANIC_DIVIDE
        xor ax, ax
        xor dx, dx
.divide:
        div ax
%endif
%ifdef TEST_PANIC_ASSERT
        xor ax, ax
        test ax, ax
        ASSERT nz, "AX is not zero"
%endif
%ifdef TEST_PANIC_GP
        mov ax, SEL_NULL
        mov es, ax
.gp:
        mov ax, [es:0]                  ; a null selector: #GP(0)
%endif
%ifdef TEST_PANIC_STACK
        call test_recurse
%endif
%ifdef TEST_PROBES
        call test_probes
%endif
%ifdef TEST_FPU_KERNEL
        call test_fpu_kernel
%endif
%ifdef TEST_TICKS
        call test_ticks
%endif
        ret

; ----------------------------------------------------------------------------
; test_after_start - TEST_KEYBOARD: the kernel reads and prints keys itself,
; and the program never starts
;   In:       DS = ES = SEL_KDATA; interrupts off
;   Out:      does not return
;   Destroys: everything
; ----------------------------------------------------------------------------
%ifdef TEST_KEYBOARD
test_after_start:
.next:
        call kbd_wait_key
        jz .abandoned
        mov si, msg_key
        call kputs
        xchg al, ah
        call kput_hex8                  ; the scancode
        mov al, ' '
        call kputc
        mov al, ah
        call kput_hex8                  ; the ASCII
        mov al, CHAR_LF
        call kputc
        jmp .next
.abandoned:
        mov si, msg_key_abandoned
        call kputs
        mov byte [restart_pending], 0
        jmp .next
%else
        jmp test_end
%endif

%ifdef TEST_PANIC_STACK
; ----------------------------------------------------------------------------
; test_recurse - call itself until the kernel stack runs out
;   In:       nothing
;   Out:      does not return: the stack fault becomes a double fault
;   Destroys: the stack
; ----------------------------------------------------------------------------
test_recurse:
        push ax
        call test_recurse
%endif

; ----------------------------------------------------------------------------
; test_tick - every tick: type the key script's next byte when it is time
;   In:       DS = SEL_KDATA; interrupts off
;   Out:      nothing (or never: the end of the test)
;   Destroys: AX, BX, SI
; ----------------------------------------------------------------------------
test_tick:
        mov si, [test_key_ptr]
        mov al, [si]
        cmp al, TEST_OP_WAIT
        je .wait
        cmp al, TEST_OP_NOW
        je .now
        ; TEST_OP_WHEN_WAITING and TEST_OP_END: only while a reader waits
        ; with nothing buffered
        cmp byte [kbd_waiting], 0
        je .done
        mov bl, [kbd_head]
        cmp bl, [kbd_tail]
        jne .done
        cmp al, TEST_OP_END
        je test_end
.now:
        in al, KBC_STATUS
        test al, KBC_STATUS_OBF
        jnz .done                       ; the last byte typed is still unread
        mov al, [si + 1]
        call test_type
        add word [test_key_ptr], 2
        ret
.wait:
        cmp byte [test_wait_left], 0
        jne .count
        mov al, [si + 1]
        mov [test_wait_left], al
.count:
        dec byte [test_wait_left]
        jnz .done
        add word [test_key_ptr], 2
.done:
        ret

; ----------------------------------------------------------------------------
; test_type - type one scancode through the 8042 (command D2h, PS/2 only)
;   In:       AL = the scancode
;   Out:      nothing
;   Destroys: AX
; ----------------------------------------------------------------------------
test_type:
        mov ah, al
        call kbc_wait_input
        mov al, KBC_CMD_WRITE_OUT
        out KBC_COMMAND, al
        call kbc_wait_input
        mov al, ah
        out KBC_DATA, al
        ret

; ----------------------------------------------------------------------------
; test_wait_ticks - sleep for CX ticks, with interrupts on meanwhile
;   In:       CX = ticks; DS = SEL_KDATA; interrupts off
;   Out:      nothing
;   Destroys: AX, CX
; ----------------------------------------------------------------------------
test_wait_ticks:
        mov ax, [ticks]
        add cx, ax
.sleep:
        sti
        hlt
        cli
        mov ax, [ticks]
        cmp ax, cx
        jne .sleep
        ret

%ifdef TEST_PROBES
; ----------------------------------------------------------------------------
; test_probes - make three devices without a driver interrupt: each line
; must be reported once and masked, and the RTC must not flood
;   In:       DS = SEL_KDATA; interrupts off
;   Out:      nothing
;   Destroys: AX, BX, CX, DX
; ----------------------------------------------------------------------------
test_probes:
        ; The diskette controller interrupts when it leaves reset (IRQ6).
        mov dx, FDC_DOR
        mov al, FDC_DOR_RESET
        out dx, al
        mov al, FDC_DOR_MOTORS_OFF
        out dx, al
        mov cx, TEST_PROBE_TICKS
        call test_wait_ticks
        ; The fixed-disk controller interrupts when a command ends (IRQ14).
        mov dx, HDC_CONTROL
        xor al, al                      ; nIEN clear: interrupts on
        out dx, al
        mov cx, TEST_HDC_LIMIT
        mov dx, HDC_STATUS
.busy:
        in al, dx
        test al, HDC_STATUS_BSY
        loopnz .busy
        mov dx, HDC_DRIVE_HEAD
        mov al, 0xA0                    ; drive 0, head 0
        out dx, al
        mov dx, HDC_COMMAND
        mov al, HDC_CMD_RECALIBRATE
        out dx, al
        mov cx, TEST_PROBE_TICKS
        call test_wait_ticks
        ; The RTC's periodic interrupt, 1,024 a second (IRQ8). Reading C
        ; re-arms it: a flood if the line were not masked after the first.
        mov al, CMOS_REG_A
        out CMOS_INDEX, al
        mov al, CMOS_REG_A_RATE_1K
        out CMOS_DATA, al
        mov al, CMOS_REG_B
        out CMOS_INDEX, al
        mov al, CMOS_REG_B_24H_BCD | CMOS_REG_B_PIE
        out CMOS_DATA, al
        mov cx, TEST_PROBE_TICKS
        call test_wait_ticks
        mov bx, TEST_RTC_TICKS
.rearm:
        mov al, CMOS_REG_C
        out CMOS_INDEX, al
        in al, CMOS_DATA
        mov cx, 1
        call test_wait_ticks
        dec bx
        jnz .rearm
        call rtc_init                   ; the periodic interrupt off again
        mov si, msg_probe_rtc
        jmp kputs
%endif

%ifdef TEST_FPU_KERNEL
; ----------------------------------------------------------------------------
; test_fpu_kernel - divide by zero on the 287 with zero-divide unmasked
;   In:       DS = SEL_KDATA; interrupts off
;   Out:      nothing
;   Destroys: AX, CX
; ----------------------------------------------------------------------------
test_fpu_kernel:
        sti
        fninit
        fldcw [test_fpu_cw]
        fld1
        fldz
        fdivp st1, st0
        fwait                           ; Bochs raises IRQ13 here (roadmap E8)
        mov cx, 2
        call test_wait_ticks
        cli
        fninit
        mov byte [restart_pending], 0
        mov si, msg_fpu_done
        jmp kputs
%endif

%ifdef TEST_TICKS
; ----------------------------------------------------------------------------
; test_ticks - count the ticks of TEST_CLOCK_SECONDS seconds of the RTC
;   In:       DS = SEL_KDATA; interrupts off
;   Out:      nothing
;   Destroys: AX, BX, CX, DX, SI
; ----------------------------------------------------------------------------
test_ticks:
        call .second_edge
        mov si, [ticks]
        mov cx, TEST_CLOCK_SECONDS
.seconds:
        push cx
        call .second_edge
        pop cx
        loop .seconds
        mov ax, [ticks]
        sub ax, si
        cmp ax, PIT_HZ * TEST_CLOCK_SECONDS - 2
        jb .bad
        cmp ax, PIT_HZ * TEST_CLOCK_SECONDS + 2
        ja .bad
        mov si, msg_ticks_ok
        jmp kputs
.bad:
        mov si, msg_ticks_bad
        call kputs
        xor dx, dx
        call kput_dec32
        mov al, CHAR_LF
        jmp kputc
; wait until the RTC's seconds change
.second_edge:
        call rtc_read
        mov dl, al
.same:
        mov cx, 1
        push dx
        call test_wait_ticks
        call rtc_read
        pop dx
        cmp al, dl
        je .same
        ret
%endif

; ----------------------------------------------------------------------------
; test_program_started - every start of the program (M8 adds its checks)
;   In:       DS = SEL_KDATA; interrupts off
;   Out:      nothing
;   Destroys: nothing
; ----------------------------------------------------------------------------
test_program_started:
        ret

; ----------------------------------------------------------------------------
; test_fault_quiet - should this fault of the program go unreported?
;   In:       BP = the frame; DS = SEL_KDATA
;   Out:      CF set to keep quiet (the fuzzer counts its faults, M8)
;   Destroys: nothing
; ----------------------------------------------------------------------------
test_fault_quiet:
        clc
        ret

; ----------------------------------------------------------------------------
; test_end - "TEST END" on COM1 on a line of its own, then end Bochs
;   In:       DS = SEL_KDATA
;   Out:      does not return
;   Destroys: everything
; ----------------------------------------------------------------------------
test_end:
        cli
        mov ax, [con_pos]
        mov dl, VIDEO_COLUMNS
        div dl
        test ah, ah                     ; the console's column
        jz .line_start
        mov al, CHAR_LF
        call com_putc
.line_start:
        mov si, msg_test_end
        call com_puts
        call com_drain
        mov dx, BOCHS_SHUTDOWN_PORT
        mov si, msg_shutdown
.next:
        lodsb
        test al, al
        jz .halt
        out dx, al
        jmp .next
.halt:
        hlt
        jmp .halt

%endif
