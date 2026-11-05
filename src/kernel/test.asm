; ============================================================================
; rx286 - src/kernel/test.asm
; What only test builds have (roadmap D16): typed keys, device probes, kernel
; faults on purpose, and the end of a test through Bochs' shutdown port.
;
; Typing: tools/run-test compiles a test's key script into test_keys (see
; tools/rxlib.py for the operations). On every tick, test_tick types the
; next byte through the 8042's command D2h, which puts it where the keyboard
; would and raises IRQ1 (roadmap E7), for the keyboard driver (roadmap
; l4.md L8). It types only while a reader waits for a key with nothing
; buffered - the OS server says so (KCALL_TEST's TEST_READER) when it found
; no key and waits - unless the script says "now"; a mouse packet in the
; script goes to the mouse driver at the next tick, as IRQ4 would hand it
; over. When the script is done and a reader waits again, with no time
; limit, the test ends: "TEST END" on the log, then the shutdown port.
;
; A test image asks for more with -d (tools/run-test):
;   TEST_PANIC_DIVIDE, TEST_PANIC_ASSERT, TEST_PANIC_GP, TEST_PANIC_STACK
;                       a kernel fault of that kind
;   TEST_PROBES         make the printer port's -ACK and the RTC interrupt,
;                       though rx286 has no driver for them
;   TEST_FPU_KERNEL     a 287 error raised by the kernel itself
;   TEST_TICKS          compare the timer with the RTC
;   TEST_SOUND          measure every tone SYS_SOUND starts, by its output and
;                       port B's bits, and check the silence after each sound
;   TEST_IMAGE_SUM      the sum of KERNEL.BIN's words (entry.asm)
;   TEST_TYPE_DIRECT    type keys by handing each byte to the driver instead
;                       of through the 8042 (KCALL_TEST's TEST_KEY_BYTE, with
;                       IRQ1's bits): MAME runs IBM's own 8042 firmware,
;                       which has no command D2h (M9)
;   TEST_ATTACK         the attack program runs: check the kernel's code and
;                       tables before every restart (M8)
;   TEST_FUZZ           the fuzzer runs: the same checks, faults counted
;                       instead of reported, a watchdog, and the end after
;                       FUZZ_ITERATIONS starts (M8)
;   TEST_COUNTER_SAME   the counter at the program's priority (thread.asm;
;   TEST_COUNTER_ABOVE  roadmap l4.md L2), or above it; either also starts
;                       the counter beside a test program (Makefile)
;   TEST_COUNTER_FPU    the counter checks its 287 state (counter.asm)
;   TEST_THREAD_REPORT  at the end: which threads ran
;   TEST_CAPS           the root gives the program capabilities to try
;                       (src/root; roadmap l4.md L3)
;   TEST_END_TICKS=n    end the test after n ticks, keys or not
; Release and debug builds assemble none of this.
; ============================================================================

%ifdef WITH_TEST_HOOKS

TEST_OP_END         equ 0
TEST_OP_WHEN_WAITING equ 1
TEST_OP_NOW         equ 2
TEST_OP_WAIT        equ 3
TEST_OP_MOUSE       equ 4               ; three bytes of a mouse packet follow
TEST_MOUSE_PACKET   equ 3
TEST_RING_SIZE      equ 16              ; bytes a driver has not yet taken
TR_HEAD             equ 0               ; a test ring: the next byte to take
TR_TAIL             equ 1               ;    where the next byte goes
TR_BYTES            equ 2
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
test_mouse_ring     times TR_BYTES + TEST_RING_SIZE db 0   ; the mouse driver's
test_key_ring       times TR_BYTES + TEST_RING_SIZE db 0   ; the keyboard driver's (MAME)
test_reader         db TEST_READER_NONE                 ; KCALL_TEST's TEST_READER
test_keys_ready     db 0                ; the keyboard driver has started (TEST_KEYS_READY)
test_fpu_cw         dw TEST_FPU_CW_ZM
msg_test_end        db "TEST END", CHAR_LF, 0
msg_shutdown        db "Shutdown", 0
msg_probe_rtc       db "probe: the RTC kept interrupting; IRQ8 stayed masked", CHAR_LF, 0
msg_sound_ok        db "probe: the speaker sounds at the frequency asked", CHAR_LF, 0
msg_sound_bad       db "probe: the speaker's output changed this often in a tick: ", 0
msg_sound_unwired   db "probe: the speaker is NOT CONNECTED", CHAR_LF, 0
msg_silent          db "probe: silent", CHAR_LF, 0
msg_not_silent      db "probe: STILL SOUNDING", CHAR_LF, 0
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
%ifdef TEST_END_TICKS
        cmp word [ticks], TEST_END_TICKS ; a test with nothing to type: it ends
        jae test_end                    ; after so many ticks
%endif
%ifdef TEST_FUZZ
        inc word [fuzz_ticks]
        cmp word [fuzz_ticks], FUZZ_WATCHDOG
        jb .keys
        mov word [fuzz_ticks], 0
        inc word [fuzz_watchdogs]
        mov bx, [fg_thread]             ; the fuzz program's thread, whichever runs:
        call thread_restart             ; in the kernel, on the way back
        cmp bx, [cur_thread]
        jne .keys
        test byte [bp + FRAME_CS], CPL_MASK
        jz .keys
        call restart_program            ; in ring 3: now
.keys:
%endif
        cmp byte [test_keys_ready], 0
        je .done                        ; no keyboard driver yet: the script waits
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
        cmp byte [test_reader], TEST_READER_NONE
        je .done
        cmp al, TEST_OP_END
%ifdef TEST_FUZZ
        je .done                        ; the fuzzer ends by its count, not by keys
%else
        jne .now
        cmp byte [test_reader], TEST_READER_FOREVER
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
        add word [test_key_ptr], 1 + TEST_MOUSE_PACKET
        mov bx, test_mouse_ring
        mov al, [si + 1]
        call test_ring_push
        mov al, [si + 2]
        call test_ring_push
        mov al, [si + 3]
        call test_ring_push
        mov bx, IRQ_MOUSE               ; to the mouse's driver, as IRQ4 would
        jmp irq_signal                  ; (it takes them with KCALL_TEST)
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
        mov byte [test_reader], TEST_READER_NONE    ; until the reader finds none again
%ifdef TEST_TYPE_DIRECT
        mov bx, test_key_ring
        call test_ring_push
        mov bx, IRQ_KEYBOARD            ; to the keyboard driver, as IRQ1 would
        jmp irq_signal
%else
        mov ah, al
        call test_kbc_wait
        mov al, KBC_CMD_WRITE_OUT
        out KBC_COMMAND, al
        call test_kbc_wait
        mov al, ah
        out KBC_DATA, al
        ret
%endif

; ----------------------------------------------------------------------------
; test_kbc_wait - wait until the 8042 can take a byte
;   In:       nothing
;   Out:      nothing
;   Destroys: AL
; ----------------------------------------------------------------------------
test_kbc_wait:
        in al, KBC_STATUS
        test al, KBC_STATUS_IBF
        jnz test_kbc_wait
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
        in al, SYS_PORT_B
        and al, SYS_PORT_B_GATE2 | SYS_PORT_B_SPEAKER
        cmp al, SYS_PORT_B_GATE2 | SYS_PORT_B_SPEAKER
        je .wired
        mov si, msg_sound_unwired
        call kputs
.wired:
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

; ----------------------------------------------------------------------------
; test_silence - after a sound or a rest: port B's gate and speaker bits
; clear, and channel 2's output still over a whole tick
;   In:       DS = SEL_KDATA
;   Out:      a probe line
;   Destroys: AX, SI
; ----------------------------------------------------------------------------
test_silence:
        in al, SYS_PORT_B
        test al, SYS_PORT_B_GATE2 | SYS_PORT_B_SPEAKER
        jnz .sounding
        and al, SYS_PORT_B_OUT2
        mov ah, al
        mov si, [ticks]
.edge:
        sti
        nop
        cli
        cmp si, [ticks]
        je .edge
        mov si, [ticks]
.watch:
        in al, SYS_PORT_B
        and al, SYS_PORT_B_OUT2
        cmp al, ah
        jne .sounding
        sti
        nop
        cli
        cmp si, [ticks]
        je .watch
        mov si, msg_silent
        jmp kputs
.sounding:
        mov si, msg_not_silent
        jmp kputs
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
; test_ring_push - a byte for a driver outside the kernel (l4.md L7, L8),
; which takes it with KCALL_TEST; a full ring drops it
;   In:       AL = the byte; BX = the ring; DS = SEL_KDATA
;   Out:      nothing
;   Destroys: CX, DI
; ----------------------------------------------------------------------------
test_ring_push:
        mov cl, [bx + TR_TAIL]
        mov ch, cl
        inc ch
        and ch, TEST_RING_SIZE - 1
        cmp ch, [bx + TR_HEAD]
        je .full
        mov [bx + TR_TAIL], ch
        xor ch, ch
        mov di, cx
        mov [bx + TR_BYTES + di], al
.full:
        ret

; ----------------------------------------------------------------------------
; test_ring_pop - the next byte of a test ring
;   In:       BX = the ring; DS = SEL_KDATA
;   Out:      CF clear and AL = the byte; CF set if none
;   Destroys: CX, DI
; ----------------------------------------------------------------------------
test_ring_pop:
        mov cl, [bx + TR_HEAD]
        cmp cl, [bx + TR_TAIL]
        je .none
        xor ch, ch
        mov di, cx
        mov al, [bx + TR_BYTES + di]
        inc cl
        and cl, TEST_RING_SIZE - 1
        mov [bx + TR_HEAD], cl
        clc
        ret
.none:
        stc
        ret

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
        cmp bp, TCB_STACK_SIZE - FRAME_SIZE_USER    ; the running thread's kernel stack
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

%ifdef TEST_ATTACK
PROBE_ACC_EXEC_ONLY equ 0xF9            ; present, DPL 3, code, not readable, accessed
PROBE_ACC_READ_ONLY equ 0xF1            ; present, DPL 3, data, not writable, accessed

begin_kdata
; Each probe: the LDT slot it changes (an offset in the LDT), and the
; access byte it leaves there (0: only the present bit cleared).
test_probes:
        dw 0, 0                                         ; (no probe 0)
        dw SEL_UDATA & ~7, 0                            ; PROBE_DS_ABSENT
        dw SEL_UDATA & ~7, PROBE_ACC_EXEC_ONLY          ; PROBE_DS_EXEC
        dw SEL_USTACK & ~7, 0                           ; PROBE_SS_ABSENT
        dw SEL_USTACK & ~7, PROBE_ACC_READ_ONLY         ; PROBE_SS_READONLY
        dw SEL_UCODE & ~7, 0                            ; PROBE_CS_ABSENT
        dw SEL_UCODE & ~7, ACC_UDATA                    ; PROBE_CS_DATA
probe_changed       dw 0                ; the descriptor the last probe changed, or 0
probe_access        db 0                ; its access byte before
end_kdata

; ----------------------------------------------------------------------------
; test_probe - SYS_TEST_PROBE: change one of the program's descriptors, as a
; revocation would; the way back to ring 3 must then null a DS or ES it may
; no longer load, and report a CS or SS it may not as the program's fault,
; never fault itself (roadmap l4.md L1). test_probe_undo undoes it at the
; next start of the program.
;   In:       BP = the frame (AL the probe); DS = SEL_KDATA
;   Out:      the program's LDT changed; or E_INVAL
;   Destroys: AX, BX, SI
; ----------------------------------------------------------------------------
test_probe:
        mov bl, [bp + FRAME_AX]
        test bl, bl
        jz .invalid
        cmp bl, PROBE_COUNT
        jae .invalid
        xor bh, bh
        shl bx, 2
        mov ax, [test_probes + bx + 2]
        mov bx, [test_probes + bx]
        mov si, [cur_thread]
        add bx, [si + T_LDT_LIVE]       ; the program's live LDT, in its space
        call test_probe_undo            ; one probe at a time
        mov [probe_changed], bx
        mov ah, [bx + 5]
        mov [probe_access], ah
        test al, al
        jz .absent
        mov [bx + 5], al                ; the access byte
        ret
.absent:
        and byte [bx + 5], ~ACC_PRESENT
        ret
.invalid:
        mov ax, E_INVAL
        jmp sys_fail

; ----------------------------------------------------------------------------
; test_probe_undo - the descriptor the last probe changed, as it was
;   In:       DS = SEL_KDATA
;   Out:      nothing
;   Destroys: nothing
; ----------------------------------------------------------------------------
test_probe_undo:
        push ax
        push si
        mov si, [probe_changed]
        test si, si
        jz .done
        mov al, [probe_access]
        mov [si + 5], al
        mov word [probe_changed], 0
.done:
        pop si
        pop ax
        ret
%endif

%ifdef TEST_FUZZ
; ----------------------------------------------------------------------------
; test_fuzz_alias - the fuzzer's code alias of its data, SEL_UFUZZ: slot 1's
; descriptor as code in slot 3 of the program's space, at its every start
; (the random code may have deleted it). No program can make code (l4.md
; X14), so the test build's kernel does.
;   In:       BX = the thread; DS = SEL_KDATA
;   Out:      nothing (for a thread not the program's, nothing done)
;   Destroys: nothing
; ----------------------------------------------------------------------------
test_fuzz_alias:
        test byte [bx + T_FLAGS], TF_FOREGROUND
        jz .out
        push ax
        push bx
        push si
        push di
        mov bx, [bx + T_SPACE]
        test byte [bx + SP_LDT + (SEL_UDATA & ~7) + 5], ACC_PRESENT
        jz .done                        ; no data: nothing to alias
        mov ax, SEL_UFUZZ >> 3
        call slot_at                    ; SI, DI = slot 3
        add bx, SP_LDT + (SEL_UDATA & ~7)
        call slot_put_descriptor
        mov byte [di + 5], ACC_UCODE
.done:
        pop di
        pop si
        pop bx
        pop ax
.out:
        ret
%endif

%ifdef TEST_THREAD_REPORT
begin_kdata
msg_report_thread   db "thread ", 0
msg_report_ran      db " ran", CHAR_LF, 0
msg_report_idle     db " did not run", CHAR_LF, 0
end_kdata

; ----------------------------------------------------------------------------
; test_thread_report - at the end of a test of threads: which of them ran
; (roadmap l4.md L2)
;   In:       DS = SEL_KDATA
;   Out:      nothing
;   Destroys: AX, BX, SI
; ----------------------------------------------------------------------------
test_thread_report:
        xor di, di
.thread:
        cmp di, [thread_count]
        jae .done
        push di
        shl di, 1
        mov bx, [thread_list + di]
        pop di
        cmp byte [bx + T_STATE], TS_FREE
        je .next                        ; never started
        mov si, msg_log_prefix
        call kputs
        mov si, msg_report_thread
        call kputs
        mov si, [bx + T_NAME]
        call kputs
        mov si, msg_report_ran
        cmp word [bx + T_RUNS], 0
        jne .say
        mov si, msg_report_idle
.say:
        call kputs
.next:
        inc di
        jmp .thread
.done:
        ret
%endif

; ----------------------------------------------------------------------------
; test_end - "TEST END" on the log on a line of its own, then end Bochs
;   In:       DS = SEL_KDATA
;   Out:      does not return
;   Destroys: everything
; ----------------------------------------------------------------------------
test_end:
        cli
        cmp byte [log_at_start], 0      ; the log's line: begun?
        jne .line_start
        mov al, CHAR_LF
        call com_putc
.line_start:
%ifdef TEST_THREAD_REPORT
        call test_thread_report         ; (on the console too: it starts a line on
%endif                                  ; the log, where the tests read it)
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
