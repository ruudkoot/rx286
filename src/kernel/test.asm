; ============================================================================
; rx286 - src/kernel/test.asm
; What only test builds have (roadmap D16): typed keys, device probes, kernel
; faults on purpose, and the end of a test through Bochs' shutdown port.
;
; Typing: tools/run-test compiles a test's key script into test_keys (see
; tools/rxlib.py for the operations). On every tick, test_tick types the
; next byte through the 8042's command D2h, which puts it where the keyboard
; would and raises IRQ1 (roadmap E7). It types only while something waits
; for a key (kbd_wait_key, SYS_WAIT) with nothing buffered, unless the
; script says "now"; a mouse packet in the script goes to the mouse driver
; at the next tick, as IRQ4 would hand it over. When the script is done and
; something waits again for a key, with no time limit, the test ends: "TEST
; END" on the log, then the shutdown port.
;
; A test image asks for more with -d (tools/run-test):
;   TEST_PANIC_DIVIDE, TEST_PANIC_ASSERT, TEST_PANIC_GP, TEST_PANIC_STACK
;                       a kernel fault of that kind
;   TEST_PROBES         make the printer port's -ACK and the RTC interrupt,
;                       though rx286 has no driver for them
;   TEST_FPU_KERNEL     a 287 error raised by the kernel itself
;   TEST_TICKS          compare the timer with the RTC
;   TEST_SOUND          measure every tone SYS_SOUND starts, by its output
;   TEST_KEYBOARD       print every key read (the program never starts)
;   TEST_IMAGE_SUM      the sum of KERNEL.BIN's words (entry.asm)
;   TEST_TYPE_DIRECT    type keys by handing each byte to the driver instead
;                       of through the 8042: MAME runs IBM's own 8042
;                       firmware, which has no command D2h (M9)
;   TEST_ATTACK         the attack program runs: check the kernel's code and
;                       tables before every restart (M8)
;   TEST_FUZZ           the fuzzer runs: the same checks, faults counted
;                       instead of reported, a watchdog, and the end after
;                       FUZZ_ITERATIONS starts (M8)
; Release and debug builds assemble none of this.
; ============================================================================

%ifdef WITH_TEST_HOOKS

TEST_OP_END         equ 0
TEST_OP_WHEN_WAITING equ 1
TEST_OP_NOW         equ 2
TEST_OP_WAIT        equ 3
TEST_OP_MOUSE       equ 4               ; three bytes of a mouse packet follow
TEST_SOUND_SLACK    equ 2               ; changes of channel 2's output either way
TEST_PROBE_TICKS    equ 5               ; how long a probe waits for its interrupt
TEST_RTC_TICKS      equ 10              ; how long the RTC probe keeps re-arming
TEST_LPT_LIMIT      equ 10000           ; polls of the printer's BUSY
TEST_CLOCK_SECONDS  equ 3
TEST_FPU_CW_ZM      equ 0x037B          ; every exception masked but zero-divide
FUZZ_ITERATIONS     equ 10000           ; starts of the fuzz program before the end
FUZZ_WATCHDOG       equ 5               ; ticks a fuzz iteration may run
%ifdef TEST_ATTACK
  %define TEST_KERNEL_CHECKS
%elifdef TEST_FUZZ
  %define TEST_KERNEL_CHECKS
%endif

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
msg_sound_ok        db "probe: the speaker sounds at the frequency asked", CHAR_LF, 0
msg_sound_bad       db "probe: the speaker's output changed this often in a tick: ", 0
msg_ticks_ok        db "timer: 50 ticks a second, by the clock", CHAR_LF, 0
msg_ticks_bad       db "timer: ticks in 3 seconds of the clock: ", 0
msg_fpu_done        db "fpu: the kernel's test raised its error", CHAR_LF, 0
msg_kernel_changed  db "the kernel's code or tables changed", 0
msg_stack_leak      db "a frame from ring 3 is not at the kernel stack's top", 0
%ifdef TEST_KERNEL_CHECKS
test_sum            dw 0
test_sum_known      db 0
%endif
%ifdef TEST_FUZZ
fuzz_starts         dw 0
fuzz_ticks          dw 0
fuzz_faults         times VEC_CPU_LAST + 1 dw 0
fuzz_watchdogs      dw 0
fuzz_fpu_errors     dw 0
fuzz_in_random      dw 0                ; faults inside the random bytes (CS = UFUZZ)
msg_fuzz_done       db "fuzz: ", 0
msg_fuzz_done2      db " iterations; the kernel's code and tables unchanged", CHAR_LF, 0
msg_fuzz_faults     db "fuzz: faults", 0
msg_fuzz_watchdog   db " watchdog ", 0
msg_fuzz_fpu        db " IRQ13 ", 0
msg_fuzz_random     db "fuzz: faults inside the random bytes: ", 0
msg_fuzz_seed       db "fuzz: the program's seed was ", 0
%endif
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

%ifdef TEST_KEYBOARD
; ----------------------------------------------------------------------------
; test_after_start - TEST_KEYBOARD: the kernel reads and prints keys itself,
; and the program never starts
;   In:       DS = ES = SEL_KDATA; interrupts off
;   Out:      does not return
;   Destroys: everything
; ----------------------------------------------------------------------------
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
;   In:       BP = the timer's frame; DS = SEL_KDATA; interrupts off
;   Out:      nothing (or never: the end of the test)
;   Destroys: AX, BX, CX, DX, SI, DI
; ----------------------------------------------------------------------------
test_tick:
%ifdef TEST_FUZZ
        inc word [fuzz_ticks]
        cmp word [fuzz_ticks], FUZZ_WATCHDOG
        jb .keys
        mov word [fuzz_ticks], 0
        inc word [fuzz_watchdogs]
        mov byte [restart_pending], 1   ; in the kernel: on the way back
        test byte [bp + FRAME_CS], CPL_MASK
        jz .keys
        call restart_program            ; in ring 3: now
.keys:
%endif
        mov si, [test_key_ptr]
        mov al, [si]
        cmp al, TEST_OP_WAIT
        je .wait
        cmp al, TEST_OP_MOUSE
        je .mouse
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
%ifdef TEST_FUZZ
        je .done                        ; the fuzzer ends by its count, not by keys
%else
        jne .now
        cmp byte [kbd_waiting], KBD_WAIT_FOREVER
        je test_end
        ret                             ; a wait with a limit: not the end
%endif
.now:
%ifndef TEST_TYPE_DIRECT
        in al, KBC_STATUS
        test al, KBC_STATUS_OBF
        jnz .done                       ; the last byte typed is still unread
%endif
        add word [test_key_ptr], 2
        mov al, [si + 1]
        jmp test_type
.mouse:
        add word [test_key_ptr], 1 + MOUSE_PACKET
        mov al, [si + 1]
        call mouse_byte
        mov al, [si + 2]
        call mouse_byte
        mov al, [si + 3]
        jmp mouse_byte
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
; test_type - type one scancode through the 8042 (command D2h, PS/2 only),
; or hand it to the driver directly (TEST_TYPE_DIRECT)
;   In:       AL = the scancode; BP = the timer's frame; DS = SEL_KDATA
;   Out:      nothing
;   Destroys: AX, BX, CX, DX, SI, DI
; ----------------------------------------------------------------------------
test_type:
%ifdef TEST_TYPE_DIRECT
        jmp kbd_byte
%endif
        mov ah, al
        call kbc_wait_input
        mov al, KBC_CMD_WRITE_OUT
        out KBC_COMMAND, al
        call kbc_wait_input
        mov al, ah
        out KBC_DATA, al
        ret

%ifdef TEST_PROBES
; ----------------------------------------------------------------------------
; test_probes - make two devices without a driver interrupt: each line
; must be reported once and masked, and the RTC must not flood
;   In:       DS = SEL_KDATA; interrupts off
;   Out:      nothing
;   Destroys: AX, BX, CX, DX, SI
; ----------------------------------------------------------------------------
test_probes:
        ; The printer port interrupts when -ACK ends, if told to (IRQ7): one
        ; byte, a NUL, printed with the port's interrupt on.
        mov dx, LPT1_BASE + LPT_CONTROL
        mov al, LPT_CONTROL_READY | LPT_CONTROL_IRQ
        out dx, al
        mov cx, TEST_LPT_LIMIT
        mov dx, LPT1_BASE + LPT_STATUS
.busy:
        in al, dx
        test al, LPT_STATUS_NOT_BUSY
        loopz .busy
        mov dx, LPT1_BASE + LPT_DATA
        xor al, al
        out dx, al
        mov dx, LPT1_BASE + LPT_CONTROL
        mov al, LPT_CONTROL_STROBE | LPT_CONTROL_IRQ
        out dx, al
        mov al, LPT_CONTROL_READY | LPT_CONTROL_IRQ
        out dx, al
        mov cx, TEST_PROBE_TICKS
        call ksleep
        mov dx, LPT1_BASE + LPT_CONTROL
        mov al, LPT_CONTROL_READY
        out dx, al
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
        call ksleep
        mov bx, TEST_RTC_TICKS
.rearm:
        mov al, CMOS_REG_C
        out CMOS_INDEX, al
        in al, CMOS_DATA
        mov cx, 1
        call ksleep
        dec bx
        jnz .rearm
        call rtc_init                   ; the periodic interrupt off again
        mov si, msg_probe_rtc
        jmp kputs
%endif

%ifdef TEST_SOUND
; ----------------------------------------------------------------------------
; test_sound - count the changes of channel 2's output (port B's OUT2) over a
; whole tick, letting interrupts in: twice the frequency a second, so BX / 25
; a tick, within TEST_SOUND_SLACK
;   In:       BX = the frequency asked, the speaker on; DS = SEL_KDATA
;   Out:      a probe line
;   Destroys: AX, DX, SI, DI
; ----------------------------------------------------------------------------
test_sound:
        push cx
        mov si, [ticks]
.edge:
        sti
        nop
        cli
        cmp si, [ticks]
        je .edge
        mov si, [ticks]
        xor cx, cx                      ; CX = changes
        in al, SYS_PORT_B
        and al, SYS_PORT_B_OUT2
        mov ah, al
.count:
        in al, SYS_PORT_B
        and al, SYS_PORT_B_OUT2
        cmp al, ah
        je .same
        inc cx
        mov ah, al
.same:
        sti
        nop
        cli
        cmp si, [ticks]
        je .count
        mov ax, bx
        shl ax, 1
        xor dx, dx
        mov di, PIT_HZ
        div di                          ; AX = the changes a tick should have
        sub ax, cx
        jns .slack
        neg ax
.slack:
        cmp ax, TEST_SOUND_SLACK
        ja .bad
        mov si, msg_sound_ok
        call kputs
        pop cx
        ret
.bad:
        mov si, msg_sound_bad
        call kputs
        mov ax, cx
        xor dx, dx
        call kput_dec32
        mov al, CHAR_LF
        call kputc
        pop cx
        ret
%endif

%ifdef TEST_FPU_KERNEL
; ----------------------------------------------------------------------------
; test_fpu_kernel - divide by zero on the 287 with zero-divide unmasked
;   In:       DS = SEL_KDATA; interrupts off
;   Out:      nothing
;   Destroys: AX, CX, SI
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
        call ksleep
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
        call ksleep
        call rtc_read
        pop dx
        cmp al, dl
        je .same
        ret
%endif

; ----------------------------------------------------------------------------
; test_program_started - every start of the program: in attack and fuzz
; builds, the kernel's code and tables must be as they were at the first
; start; the fuzzer counts its starts and ends the test after enough
;   In:       DS = SEL_KDATA; interrupts off
;   Out:      nothing (or never: a panic, or the fuzzer's end)
;   Destroys: nothing
; ----------------------------------------------------------------------------
test_program_started:
%ifdef TEST_KERNEL_CHECKS
        pusha
        call test_kernel_sum
        cmp byte [test_sum_known], 0
        jne .compare
        mov [test_sum], ax
        mov byte [test_sum_known], 1
        jmp .checked
.compare:
        cmp ax, [test_sum]
        je .checked
        mov si, msg_kernel_changed
        xor bp, bp
        jmp panic
.checked:
  %ifdef TEST_FUZZ
        mov word [fuzz_ticks], 0
        inc word [fuzz_starts]
        cmp word [fuzz_starts], FUZZ_ITERATIONS
        ja test_fuzz_end
  %endif
        popa
%endif
        ret

; ----------------------------------------------------------------------------
; test_restart_check - a frame from ring 3 must sit at the kernel stack's
; top (SP0): anything else is a leak of the kernel's stack
;   In:       BP = the frame being restarted; DS = SEL_KDATA
;   Out:      nothing (or never: a panic)
;   Destroys: nothing
; ----------------------------------------------------------------------------
test_restart_check:
        cmp bp, KSTACK_SIZE - FRAME_SIZE_USER
        je .ok
        mov si, msg_stack_leak
        xor bp, bp
        jmp panic
.ok:
        ret

; ----------------------------------------------------------------------------
; test_fault_quiet - should this fault of the program go unreported?
;   In:       BP = the frame; DS = SEL_KDATA
;   Out:      CF set to keep quiet: the fuzzer counts its faults instead
;   Destroys: nothing
; ----------------------------------------------------------------------------
test_fault_quiet:
%ifdef TEST_FUZZ
        push bx
        mov bx, [bp + FRAME_VECTOR]
        shl bx, 1
        inc word [fuzz_faults + bx]
        cmp word [bp + FRAME_CS], SEL_UFUZZ
        jne .counted
        inc word [fuzz_in_random]
.counted:
        pop bx
        stc
%else
        clc
%endif
        ret

%ifdef TEST_KERNEL_CHECKS
; ----------------------------------------------------------------------------
; test_kernel_sum - the sum of the words of the kernel's code, its GDT,
; IDT, dispatch tables and both TSSs (accessed bits are preset; the TSS's
; busy bit was set before the first start, and nothing else may change)
;   In:       DS = SEL_KDATA
;   Out:      AX = the sum
;   Destroys: BX, CX, SI
; ----------------------------------------------------------------------------
test_kernel_sum:
        xor ax, ax
        xor si, si
        mov cx, ktext_end
        shr cx, 1                       ; words of code
.code:
        add ax, [cs:si]
        add si, 2
        loop .code
        mov si, gdt
        mov cx, (gdt_end - gdt) / 2
        call .data
        mov si, idt
        mov cx, IDT_ENTRIES * 8 / 2        ; words of 8-byte gates
        call .data
        mov si, isr_handlers
        mov cx, IDT_ENTRIES
        call .data
        mov si, irq_drivers
        mov cx, IRQ_LINES
        call .data
        mov si, syscall_table
        mov cx, SYSCALL_COUNT
        call .data
        mov si, tss
        mov cx, TSS286_SIZE                ; words: both TSSs, one after the other
.data:
        add ax, [si]
        add si, 2
        loop .data
        ret
%endif

%ifdef TEST_FUZZ
; ----------------------------------------------------------------------------
; test_fuzz_end - the fuzzer's summary, then the end of the test
;   In:       DS = SEL_KDATA
;   Out:      does not return
;   Destroys: everything
; ----------------------------------------------------------------------------
test_fuzz_end:
        mov si, msg_fuzz_faults
        call kputs
        xor bx, bx
.vector:
        mov ax, [fuzz_faults + bx]
        test ax, ax
        jz .next
        mov al, ' '
        call kputc
        mov ax, bx
        shr ax, 1
        call kput_vector
        mov al, ' '
        call kputc
        mov ax, [fuzz_faults + bx]
        xor dx, dx
        call kput_dec32
.next:
        add bx, 2
        cmp bx, (VEC_CPU_LAST + 1) * 2
        jb .vector
        mov si, msg_fuzz_watchdog
        call kputs
        mov ax, [fuzz_watchdogs]
        xor dx, dx
        call kput_dec32
        mov si, msg_fuzz_fpu
        call kputs
        mov ax, [fuzz_fpu_errors]
        call kput_dec32
        mov al, CHAR_LF
        call kputc
        mov si, msg_fuzz_random
        call kputs
        mov ax, [fuzz_in_random]
        call kput_dec32
        mov al, CHAR_LF
        call kputc
        mov si, msg_fuzz_done
        call kputs
        mov ax, FUZZ_ITERATIONS
        xor dx, dx
        call kput_dec32
        mov si, msg_fuzz_done2
        call kputs
        jmp test_end

; ----------------------------------------------------------------------------
; test_fuzz_seed - on a panic: the seed the fuzz program had (the first word
; of its data), to replay the failing iteration
;   In:       DS = SEL_KDATA
;   Out:      nothing
;   Destroys: AX, SI, ES
; ----------------------------------------------------------------------------
test_fuzz_seed:
        mov si, msg_fuzz_seed
        call kputs
        mov ax, SEL_UDATA
        mov es, ax
        mov ax, [es:0]
        call kput_hex16
        mov al, CHAR_LF
        jmp kputc
%endif

; ----------------------------------------------------------------------------
; test_end - "TEST END" on the log on a line of its own, then end Bochs
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
