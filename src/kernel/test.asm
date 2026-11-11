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
;   TEST_PANIC_DIVIDE, TEST_PANIC_ASSERT, TEST_PANIC_GP, TEST_PANIC_STACK,
;   TEST_PANIC_PAGE
;                       a kernel fault of that kind
;   TEST_PROBES         make the printer port's -ACK and the RTC interrupt,
;                       though rx286 has no driver for them
;   TEST_FPU_KERNEL     a 287 error raised by the kernel itself
;   TEST_TICKS          compare the timer with the RTC
;   TEST_SOUND          measure every tone the sound driver starts, by its output and
;                       port B's bits, and check the silence after each sound
;   TEST_IMAGE_SUM      the sum of KERNEL.BIN's words (entry.asm)
;   TEST_TYPE_DIRECT    type keys by handing each byte to the driver instead
;                       of through the 8042 (KCALL_TEST's TEST_KEY_BYTE, with
;                       IRQ1's bits): MAME runs IBM's own 8042 firmware,
;                       which has no command D2h (M9)
;   TEST_ATTACK         the attack program runs: check the kernel's code and
;                       tables before every restart (M8): a Fletcher sum of
;                       the code, the GDT's fixed part, the IDT, the dispatch
;                       tables and the TSSs, and the GDT's invariants (no
;                       descriptor above DPL 0, every space's LDT exactly its
;                       slots: test_gdt_check; os-server.md P15); its queues
;                       well formed (test_queue_check); on a 386 (Bochs), FS
;                       and GS null on every way back, which a 286 has not
;                       (test_way_back); KCALL_TEST's TEST_PROBE and
;                       TEST_OVERRUN
;   TEST_FUZZ           the fuzzer runs: the same checks at its first start,
;                       every FUZZ_CHECK_EVERY starts and its last (with
;                       interrupts off, each a few ms on an AT); the fuzz
;                       program's own faults counted instead of reported (no
;                       other thread's); a watchdog; the end after
;                       FUZZ_ITERATIONS starts. What it does that a release
;                       kernel does not: the code alias of the program's data
;                       in slot 3, a copy of slot 1 made code (test_fuzz_alias:
;                       no program can make code, l4.md X14); its faults' report
;                       not written (FAULT_COUNTED). KCALL_TEST is KE_NOSYS to
;                       the fuzz program, as in a release build
;   TEST_FUZZ_SEED=n    the fuzz program's first seed n, to replay a failing
;                       one (tests/programs/fuzz.asm)
;   TEST_COUNTER_SAME   the counter at the program's priority (thread.asm;
;   TEST_COUNTER_ABOVE  roadmap l4.md L2), or above it; either also starts
;                       the counter beside a test program (Makefile)
;   TEST_COUNTER_FPU    the counter checks its 287 state (counter-fpu.asm)
;   TEST_THREAD_REPORT  at the end: which threads ran
;   TEST_CAPS           the root gives the program capabilities to try
;                       (src/root; roadmap l4.md L3)
;   TEST_END_TICKS=n    end the test after n ticks, keys or not
;   TEST_STRETCH        measure every stretch with interrupts off, and say
;                       at the end how long the longest was, and where
;                       (roadmaps/realtime.md R0)
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
TEST_SOUND_HANDLER_MS equ 1             ; and fewer for the tick's own handler, up to so long
TEST_PROBE_TICKS    equ 5               ; how long a probe waits for its interrupt
TEST_RTC_TICKS      equ 10              ; how long the RTC probe keeps re-arming
TEST_LPT_LIMIT      equ 10000           ; polls of the printer's BUSY
TEST_CLOCK_SECONDS  equ 3
TEST_FPU_CW_ZM      equ 0x037B          ; every exception masked but zero-divide
FUZZ_ITERATIONS     equ 10000           ; starts of the fuzz program before the end
FUZZ_WATCHDOG       equ 5               ; ticks a fuzz iteration may run
FUZZ_CHECK_EVERY    equ 16              ; starts between the kernel's checks (a power of 2)
FUZZ_WATCHDOG_MOST  equ FUZZ_ITERATIONS / 20    ; the summary: under 5% of the iterations
%ifdef TEST_ATTACK
  %define TEST_KERNEL_CHECKS
%elifdef TEST_FUZZ
  %define TEST_KERNEL_CHECKS
%endif
%ifdef TEST_KERNEL_CHECKS
  %ifndef TEST_TYPE_DIRECT
    %define TEST_386_SEGMENTS           ; Bochs' builds: a 386's FS and GS (MAME's a 286)
  %endif
%endif

begin_kdata
test_give_way       dw 0                ; TEST_GIVE_WAY: windows still to give way
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
test_end_notify     dw 0                ; the notification a key script's end signals
test_end_wait       dw 0                ;    (TEST_END_SYNC), and the ticks left after
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
msg_gdt_dpl         db "a descriptor of the GDT above DPL 0", 0
msg_ldt_changed     db "a space's LDT descriptor is not its LDT", 0
msg_queue_bad       db "a ready queue, or a thread's wait, is not well formed", 0
msg_stack_leak      db "a frame from ring 3 is not at the kernel stack's top", 0
%ifdef TEST_PANIC_PAGE
msg_page_start      db "test: the screen starts at ", 0
msg_page_text       db "h; page 0 shows the panic: ", 0
msg_yes             db "yes", CHAR_LF, 0
msg_no              db "no", CHAR_LF, 0
%endif
%ifdef TEST_KERNEL_CHECKS
test_sum            dw 0, 0             ; Fletcher's two sums (test_kernel_sum)
test_sum_known      db 0
%endif
%ifdef TEST_386_SEGMENTS
test_386            db 0                ; a 386 or later: FS and GS (test_cpu)
%endif
%ifdef TEST_FUZZ
fuzz_starts         dw 0
fuzz_ticks          dw 0
fuzz_faults         times VEC_CPU_LAST + 1 dw 0
fuzz_watchdogs      dw 0
fuzz_watchdog_server dw 0               ; of them, the program waiting on the server
fuzz_fpu_errors     dw 0                ; the fuzz program's 287 errors (IRQ13)
fuzz_in_random      dw 0                ; faults inside the random bytes (CS = UFUZZ)
msg_fuzz_done       db "fuzz: ", 0
msg_fuzz_done2      db " iterations; the kernel's code and tables unchanged", CHAR_LF, 0
msg_fuzz_faults     db "fuzz: faults", 0
msg_fuzz_watchdog   db " watchdog ", 0
msg_fuzz_fpu        db " IRQ13 ", 0
msg_fuzz_random     db "fuzz: faults inside the random bytes: ", 0
msg_fuzz_most       db ", most of the iterations: ", 0
msg_fuzz_restarts   db "fuzz: watchdog restarts ", 0
msg_fuzz_restarts2  db ", ", 0
msg_fuzz_restarts3  db " of them in a wait on the server; under 5%: ", 0
msg_fuzz_yes        db "yes", CHAR_LF, 0
msg_fuzz_no         db "no", CHAR_LF, 0
msg_fuzz_seed       db "fuzz: the program's seed was ", 0
msg_fuzz_unknown    db "unknown (the panic came in another thread's time)", 0
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
%ifdef TEST_PANIC_PAGE
        mov dx, CRTC_INDEX              ; page 3 shown, as a terminal's may be
        mov al, CRTC_START_HIGH
        out dx, al
        mov dx, CRTC_DATA
        mov al, (3 * VIDEO_PAGE / 2) >> 8
        out dx, al
        mov dx, CRTC_INDEX
        mov al, CRTC_START_LOW
        out dx, al
        mov dx, CRTC_DATA
        mov al, (3 * VIDEO_PAGE / 2) & 0xFF
        out dx, al
        xor ax, ax
        test ax, ax
        ASSERT nz, "page 3 is shown"
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
%ifdef TEST_386_SEGMENTS
        call test_cpu
%endif
        ret


%ifdef TEST_PANIC_PAGE
; ----------------------------------------------------------------------------
; test_panic_page - TEST_PANIC_PAGE builds: once the panic is written, the
; CRTC's start address read back, and whether page 0 shows the panic's
; first words, on the screen and the log
;   In:       DS = SEL_KDATA
;   Out:      nothing
;   Destroys: AX, CX, DX, SI, DI, ES
; ----------------------------------------------------------------------------
test_panic_page:
        mov si, msg_page_start
        call kputs
        mov dx, CRTC_INDEX
        mov al, CRTC_START_HIGH
        out dx, al
        mov dx, CRTC_DATA
        in al, dx
        mov ah, al
        mov dx, CRTC_INDEX
        mov al, CRTC_START_LOW
        out dx, al
        mov dx, CRTC_DATA
        in al, dx
        call kput_hex16
        mov si, msg_page_text
        call kputs
        mov ax, SEL_VIDEO
        mov es, ax
        mov si, msg_panic
        xor di, di
.char:
        lodsb
        test al, al
        jz .shown
        cmp [es:di], al
        jne .not
        add di, 2
        jmp .char
.shown:
        mov si, msg_yes
        jmp .say
.not:
        mov si, msg_no
.say:
        jmp kputs
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
        push es
        mov es, bx
        cmp byte [es:T_STATE], TS_REPLY ; (waiting on the server's reply: counted)
        pop es
        jne .restart
        inc word [fuzz_watchdog_server]
.restart:
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
        cmp al, TEST_OP_NOW
        je .now
        ; TEST_OP_WHEN_WAITING, TEST_OP_MOUSE and TEST_OP_END: only while a
        ; reader waits with nothing buffered (a mouse's packet too, since
        ; os-server.md P12: its program polls the terminal as it waits)
        cmp byte [test_reader], TEST_READER_NONE
        je .done
        cmp al, TEST_OP_MOUSE
        je .mouse
        cmp al, TEST_OP_END
%ifdef TEST_FUZZ
        je .done                        ; the fuzzer ends by its count, not by keys
%else
        jne .now
        cmp byte [test_reader], TEST_READER_FOREVER
        je test_end_soon
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
; a tick, within TEST_SOUND_SLACK. The count begins once the tick's timer
; interrupt has returned, so the window is short by that handler's time:
; fewer are allowed for TEST_SOUND_HANDLER_MS of it too (three changes at
; 2000 Hz once disk-scheduler.md M2's OS server had a timer more due then)
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
        sub ax, cx                      ;    less those counted
        mov di, TEST_SOUND_SLACK
        jns .fewer
        neg ax                          ; more: the slack alone
        jmp .slack
.fewer:
        push ax                         ; fewer: and the handler's share, f / 500 for 1 ms
        mov ax, bx
        xor dx, dx
        mov si, 1000 / (2 * TEST_SOUND_HANDLER_MS)
        div si
        add di, ax
        pop ax
.slack:
        cmp ax, di
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
  %ifdef TEST_FUZZ
        mov word [fuzz_ticks], 0
        inc word [fuzz_starts]
        cmp word [fuzz_starts], FUZZ_ITERATIONS
        ja .last
        cmp word [fuzz_starts], 1
        je .check                       ; the first start: the sums to keep
        test word [fuzz_starts], FUZZ_CHECK_EVERY - 1
        jnz .checked
  %endif
.check:
        call test_kernel_check
.checked:
        popa
%endif
        ret
%ifdef TEST_FUZZ
.last:
        call test_kernel_check          ; as the last iteration left them
        jmp test_fuzz_end
%endif

%ifdef TEST_KERNEL_CHECKS
; ----------------------------------------------------------------------------
; test_kernel_check - the kernel's code and tables as at the first check,
; and the GDT's invariants
;   In:       DS = SEL_KDATA; interrupts off
;   Out:      nothing (or never: a panic)
;   Destroys: AX, BX, CX, DX, SI, DI
; ----------------------------------------------------------------------------
test_kernel_check:
        call test_kernel_sum
        cmp byte [test_sum_known], 0
        jne .compare
        mov [test_sum], ax
        mov [test_sum + 2], dx
        mov byte [test_sum_known], 1
        jmp .invariants
.compare:
        cmp ax, [test_sum]
        jne .changed
        cmp dx, [test_sum + 2]
        jne .changed
.invariants:
        call test_gdt_check
        jmp test_queue_check
.changed:
        mov si, msg_kernel_changed
        xor bp, bp
        jmp panic

; ----------------------------------------------------------------------------
; test_queue_check - the queues well formed (l4.md's arena invariant; P15):
; each ready queue holds threads ready at its priority alone, ends at its
; tail, and agrees with ready_mask; every ready thread is in one; a thread
; that sends or receives is in its endpoint's queue, of that kind; one that
; waits on a notification is its waiter. A walk longer than the threads
; are many is a loop.
;   In:       DS = SEL_KDATA
;   Out:      nothing (or never: a panic)
;   Destroys: AX, BX, CX, DX, SI, DI
; ----------------------------------------------------------------------------
test_queue_check:
        push es
        xor dx, dx                      ; the threads the queues hold
        xor si, si                      ; the priority, times two
.queue:
        mov bx, [rq_head + si]
        xor di, di                      ; the last one walked
        mov cx, [thread_count]
        inc cx                          ; steps at most: one more is a loop
.walk:
        test bx, bx
        jz .walked
        mov es, bx
        cmp byte [es:T_STATE], TS_READY
        jne .bad
        mov ax, si
        shr ax, 1
        cmp [es:T_PRIO], al
        jne .bad
        inc dx
        mov di, bx
        mov bx, [es:T_NEXT]
        loop .walk
        jmp .bad
.walked:
        cmp [rq_tail + si], di
        jne .bad
        mov cx, si
        shr cx, 1
        mov al, 1
        shl al, cl
        test [ready_mask], al           ; its bit: set if and only if not empty
        jz .no_bit
        test di, di
        jz .bad
        jmp .next_queue
.no_bit:
        test di, di
        jnz .bad
.next_queue:
        add si, 2
        cmp si, PRIORITIES * 2
        jb .queue
        xor di, di                      ; every thread: its wait where it says
.thread:
        cmp di, [thread_count]
        jae .threads_done
        push di
        shl di, 1
        mov bx, [thread_list + di]
        pop di
        inc di
        mov es, bx
        mov al, [es:T_STATE]
        cmp al, TS_READY
        jne .not_ready
        dec dx                          ; each ready thread once in the queues
        jmp .thread
.not_ready:
        mov si, [es:T_WAIT_OBJ]
        cmp al, TS_NOTIFY
        je .notify
        mov ah, EK_SEND
        cmp al, TS_SEND
        je .endpoint
        mov ah, EK_RECV
        cmp al, TS_RECV
        jne .thread
.endpoint:
        mov es, si
        cmp [es:E_KIND], ah
        jne .bad
        mov ax, [es:E_HEAD]
        mov cx, [thread_count]
.find:
        test ax, ax
        jz .bad                         ; not in its endpoint's queue
        cmp ax, bx
        je .thread
        mov es, ax
        mov ax, [es:T_NEXT]
        loop .find
        jmp .bad
.notify:
        mov es, si
        cmp [es:N_WAITER], bx
        jne .bad
        jmp .thread
.threads_done:
        test dx, dx
        jnz .bad
        pop es
        ret
.bad:
        pop es
        mov si, msg_queue_bad
        xor bp, bp
        jmp panic

; ----------------------------------------------------------------------------
; test_gdt_check - what the sum cannot cover of the GDT, since its pool and
; windows change: no present descriptor above DPL 0 (security.md), and every
; listed space's LDT descriptor an LDT exactly its slots long, at its own
; SP_LDT (l4.md's arena invariant; os-server.md P15)
;   In:       DS = SEL_KDATA
;   Out:      nothing (or never: a panic)
;   Destroys: AX, BX, CX, DX, SI, DI
; ----------------------------------------------------------------------------
test_gdt_check:
        push es
        mov si, GDT_OFF + 8
        mov cx, GDT_ENTRIES - 1
.descriptor:
        mov al, [si + 5]
        test al, ACC_PRESENT
        jz .next
        test al, ACC_DPL_MASK
        jnz .dpl
.next:
        add si, 8
        loop .descriptor
        xor di, di
.space:
        cmp di, [space_bytes]
        jae .done
        mov bx, [space_list + di]       ; the space's own selector (RPL 0, the GDT)
        mov es, bx
        mov si, [es:SP_GDT_SELECTOR]
        test si, si
        jz .ldt                         ; listed, its LDT released
        add si, GDT_OFF
        cmp byte [si + 5], ACC_LDT
        jne .ldt
        mov ax, [es:SP_SLOTS]
        shl ax, 3
        dec ax
        cmp [si], ax                    ; the limit: its slots, not one more
        jne .ldt
        mov ax, [GDT_OFF + bx + 2]      ; the base: the space's, plus SP_LDT
        mov dl, [GDT_OFF + bx + 4]
        add ax, SP_LDT
        adc dl, 0
        cmp [si + 2], ax
        jne .ldt
        cmp [si + 4], dl
        jne .ldt
        add di, 2
        jmp .space
.done:
        pop es
        ret
.dpl:
        mov si, msg_gdt_dpl
        jmp .panic
.ldt:
        mov si, msg_ldt_changed
.panic:
        pop es
        xor bp, bp
        jmp panic
%endif

; ----------------------------------------------------------------------------
; test_restart_check - a frame from ring 3 must be the running thread's, at
; the kernel stack's top (SP0, KFRAME): anything else is a frame deeper on
; the kernel's stack
;   In:       BP = the frame being restarted; DS = SEL_KDATA
;   Out:      nothing (or never: a panic)
;   Destroys: nothing
; ----------------------------------------------------------------------------
test_restart_check:
        cmp bp, KFRAME
        je .ok
        mov si, msg_stack_leak
        xor bp, bp
        jmp panic
.ok:
        ret

; ----------------------------------------------------------------------------
; test_fault_quiet - should this fault go unreported?
;   In:       BP = the frame; DS = SEL_KDATA
;   Out:      CF set to keep quiet: the fuzzer counts the fuzz program's
;             faults instead (any other thread's is reported)
;   Destroys: nothing
; ----------------------------------------------------------------------------
test_fault_quiet:
%ifdef TEST_FUZZ
        push bx
        mov bx, [cur_thread]
        cmp bx, [fg_thread]
        jne .reported                   ; another thread's fault: reported (P15)
        mov bx, [bp + FRAME_VECTOR]
        shl bx, 1
        inc word [fuzz_faults + bx]
        cmp word [bp + FRAME_CS], SEL_UFUZZ
        jne .counted
        inc word [fuzz_in_random]
.counted:
        pop bx
        stc
        ret
.reported:
        pop bx
%endif
        clc
        ret

%ifdef TEST_KERNEL_CHECKS
; ----------------------------------------------------------------------------
; test_kernel_sum - Fletcher's sums of the words of the kernel's code, its
; GDT's fixed part, IDT, dispatch tables and both TSSs (accessed bits are
; preset; the TSS's busy bit was set before the first start, and nothing
; else may change): the running total sees two words exchanged, which a
; plain sum would not (os-server.md P15)
;   In:       DS = SEL_KDATA
;   Out:      AX = the sum of the words, DX = the sum of the running sums
;   Destroys: BX, CX, SI
; ----------------------------------------------------------------------------
test_kernel_sum:
        xor ax, ax
        xor dx, dx
        xor si, si
        mov cx, ktext_end
        shr cx, 1                       ; words of code
.code:
        add ax, [cs:si]
        add dx, ax
        add si, 2
        loop .code
        mov si, GDT_OFF                 ; the GDT's fixed part, before the windows
        mov cx, SEL_SCRATCH / 2
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
        mov si, kcall_table
        mov cx, KCALL_COUNT
        call .data
        mov si, tss
        mov cx, TSS286_SIZE                ; words: both TSSs, one after the other
.data:
        add ax, [si]
        add dx, ax
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
        mov al, CHAR_LF                 ; a line of its own: the random code's bytes
        call kputc                      ; on the log (KCALL_LOG, PX_WRITE) end no line
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
        mov si, msg_fuzz_most           ; random code ran: a floor the test expects
        call kputs
        mov ax, [fuzz_in_random]
        shl ax, 1
        cmp ax, FUZZ_ITERATIONS
        call .yes_no                    ; (CF: fewer than half)
        mov si, msg_fuzz_restarts
        call kputs
        mov ax, [fuzz_watchdogs]
        call kput_dec32
        mov si, msg_fuzz_restarts2
        call kputs
        mov ax, [fuzz_watchdog_server]
        call kput_dec32
        mov si, msg_fuzz_restarts3
        call kputs
        mov ax, FUZZ_WATCHDOG_MOST
        cmp ax, [fuzz_watchdogs]        ; (CF: more than FUZZ_WATCHDOG_MOST)
        call .yes_no
        mov si, msg_fuzz_done
        call kputs
        mov ax, FUZZ_ITERATIONS
        xor dx, dx
        call kput_dec32
        mov si, msg_fuzz_done2
        call kputs
        jmp test_end
.yes_no:
        mov si, msg_fuzz_no
        jc .say
        mov si, msg_fuzz_yes
.say:
        jmp kputs

; ----------------------------------------------------------------------------
; test_fuzz_seed - on a panic: the seed the fuzz program had (the first word
; of its data), to replay the failing iteration (TEST_FUZZ_SEED); read
; only if the LDT loaded is the fuzz program's, and its data still there:
; a panic in another thread's time would fault again here
;   In:       DS = SEL_KDATA
;   Out:      nothing
;   Destroys: AX, SI, ES
; ----------------------------------------------------------------------------
test_fuzz_seed:
        mov si, msg_fuzz_seed
        call kputs
        mov ax, [fg_thread]
        test ax, ax
        jz .unknown
        mov es, ax
        mov ax, [es:T_SPACE]
        test ax, ax
        jz .unknown
        mov es, ax
        sldt ax
        cmp ax, [es:SP_GDT_SELECTOR]
        jne .unknown
        mov ax, SEL_UDATA
        verr ax
        jnz .unknown
        mov es, ax
        mov ax, [es:0]
        call kput_hex16
        jmp .line
.unknown:
        mov si, msg_fuzz_unknown
        call kputs
.line:
        mov al, CHAR_LF
        jmp kputc

%endif

%ifdef TEST_386_SEGMENTS
; ----------------------------------------------------------------------------
; test_cpu - a 386 or later? A 286's SGDT stores FFh as the base's fourth
; byte, which a 386 has (Intel, 80386 Programmer's Reference, 14.7: the
; 286's SGDT): Bochs' attack and fuzz builds then null FS and GS
; (test_way_back)
;   In:       DS = SEL_KDATA
;   Out:      test_386
;   Destroys: AX
; ----------------------------------------------------------------------------
test_cpu:
        push bp
        sub sp, 6
        mov bp, sp
        sgdt [bp]
        mov al, [bp + 5]
        add sp, 6
        pop bp
        cmp al, 0xFF
        je .done                        ; a 286
        mov byte [test_386], 1
.done:
        ret
%endif

%ifdef TEST_KERNEL_CHECKS
; ----------------------------------------------------------------------------
; test_way_back - on a 386, FS and GS null on every way back to a ring above
; 0: the kernel, a 286's, never saves, checks or nulls them, so a segment
; the program loaded there would outlive its descriptor and its restart, a
; state no 286 can be in (docs/emulators.md; P15)
;   In:       DS = SEL_KDATA
;   Out:      nothing
;   Destroys: AX
; ----------------------------------------------------------------------------
test_way_back:
  %ifdef TEST_386_SEGMENTS
        cmp byte [test_386], 0
        je .done
        xor ax, ax
        db 0x8E, 0xE0                   ; mov fs, ax (a 386's: no 286 has FS)
        db 0x8E, 0xE8                   ; mov gs, ax
.done:
  %endif
        ret
%endif
%ifdef TEST_FUZZ
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
probe_space         dw 0                ; the space of the descriptor the last probe
probe_changed       dw 0                ;    changed, and the descriptor, or 0
probe_access        db 0                ; its access byte before
end_kdata

; ----------------------------------------------------------------------------
; test_probe - KCALL_TEST's TEST_PROBE: change one of the program's
; descriptors, as a revocation would; the way back to ring 3 must then null
; a DS or ES it may no longer load, and report a CS or SS it may not as the
; program's fault, never fault itself (roadmap l4.md L1). test_probe_undo
; undoes it at the next start of the program.
;   In:       BP = the frame (BL the probe); DS = SEL_KDATA
;   Out:      the program's LDT changed, KE_OK; or KE_ARG
;   Destroys: AX, BX, SI, ES
; ----------------------------------------------------------------------------
test_probe:
        mov bl, [bp + FRAME_BX]
        test bl, bl
        jz .invalid
        cmp bl, PROBE_COUNT
        jae .invalid
        xor bh, bh
        shl bx, 2
        mov ax, [test_probes + bx + 2]
        mov bx, [test_probes + bx]
        add bx, SP_LDT                  ; the program's LDT, in its space
        call test_probe_undo            ; one probe at a time
        mov es, [cur_thread]
        mov si, [es:T_SPACE]
        mov [probe_space], si
        mov [probe_changed], bx
        mov es, si
        mov ah, [es:bx + 5]
        mov [probe_access], ah
        test al, al
        jz .absent
        mov [es:bx + 5], al             ; the access byte
        jmp kc_done.ok
.absent:
        and byte [es:bx + 5], ~ACC_PRESENT
        jmp kc_done.ok
.invalid:
        jmp kc_done.arg

; ----------------------------------------------------------------------------
; test_probe_undo - the descriptor the last probe changed, as it was
;   In:       DS = SEL_KDATA
;   Out:      nothing
;   Destroys: nothing
; ----------------------------------------------------------------------------
test_probe_undo:
        push ax
        push si
        push es
        mov si, [probe_changed]
        test si, si
        jz .done
        mov es, [probe_space]
        mov al, [probe_access]
        mov [es:si + 5], al
        mov word [probe_changed], 0
.done:
        pop es
        pop si
        pop ax
        ret
%endif

%ifdef TEST_FUZZ
; ----------------------------------------------------------------------------
; test_fuzz_alias - the fuzzer's code alias of its data, SEL_UFUZZ: a copy
; of slot 1, made code, in slot 3 of the program's space, at its every
; start (the random code may have deleted it, or put another capability
; there, which is deleted first). No program can make code (l4.md X14), so
; the test build's kernel does; the alias is slot 1's child, as a copy is,
; so that a revoke of the data takes it too (os-server.md P15).
;   In:       BX = the thread; DS = SEL_KDATA
;   Out:      nothing (for a thread not the program's, nothing done)
;   Destroys: nothing
; ----------------------------------------------------------------------------
test_fuzz_alias:
        push es
        mov es, bx
        test byte [es:T_FLAGS], TF_FOREGROUND
        jz .out
        push ax
        push bx
        push si
        push di
        mov bx, [es:T_SPACE]
        mov es, bx
        test byte [es:SP_LDT + (SEL_UDATA & ~7) + 5], ACC_PRESENT
        jz .done                        ; no data: nothing to alias
        mov ax, SEL_UFUZZ >> 3
        call slot_at                    ; ES:SI, ES:DI = slot 3 (AX destroyed)
        cmp byte [es:si + SH_TYPE], CAP_EMPTY
        je .empty
        mov ax, SEL_UFUZZ >> 3
        call cap_delete_at              ; (BX, AX: the space and slot 3)
        mov ax, SEL_UFUZZ >> 3
        call slot_at
.empty:
        push ds
        push es
        pop ds
        push bx
        mov bx, SP_LDT + (SEL_UDATA & ~7)
        call slot_put_descriptor        ; (DS:BX: slot 1's, in the same space)
        pop bx
        pop ds
        mov byte [es:di + 5], ACC_UCODE
        push cx
        push dx
        mov dx, bx                      ; the child: slot 3 of the space
        mov cx, SEL_UFUZZ >> 3
        mov ax, SEL_UDATA >> 3          ; the parent: slot 1
        call child_link
        pop dx
        pop cx
.done:
        pop di
        pop si
        pop bx
        pop ax
.out:
        pop es
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
;   Destroys: AX, BX, SI, DI, ES
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
        mov es, bx
        cmp byte [es:T_STATE], TS_FREE
        je .next                        ; never started
        mov si, msg_log_prefix
        call kputs
        mov si, msg_report_thread
        call kputs
        mov es, bx
        mov si, [es:T_NAME]
        call kputs
        mov si, msg_report_ran
        mov es, bx
        cmp word [es:T_RUNS], 0
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
; test_end_soon - a key script's end (disk-scheduler.md M6): the server that
; asked (TEST_END_SYNC) told to write what it holds, with TEST_END_BIT; it
; ends the test (TEST_END_NOW), or the kernel does after TEST_SYNC_TICKS.
; Without such a server, or in TEST_END_NOSYNC builds, the end at once
;   In:       DS = SEL_KDATA; interrupts off (the timer's)
;   Out:      nothing, or never (the end)
;   Destroys: AX, SI
; ----------------------------------------------------------------------------
test_end_soon:
%ifndef TEST_END_NOSYNC
        cmp word [test_end_notify], 0
        je test_end
        cmp word [test_end_wait], 0
        jne .waiting
        mov word [test_end_wait], TEST_SYNC_TICKS
        mov si, [test_end_notify]
        mov ax, TEST_END_BIT
        jmp ntf_signal
.waiting:
        dec word [test_end_wait]
        jz test_end
        ret
%else
        jmp test_end
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
%ifdef TEST_STRETCH
        call stretch_report
%endif
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

%ifdef TEST_STRETCH
STRETCH_LIMIT_US    equ 10000           ; the measure's reach: half the timer's period

begin_kdata
stretch_start       dw 0                ; channel 0's count when interrupts went off
stretch_place       dw 0                ; and where (STRETCH_BEGIN's place)
stretch_open        db 0                ; 1 while a stretch is measured
stretch_tick        db 0                ; a tick pending as it began (P15)
stretch_max         dw 0                ; the longest, in the 8254's clocks
stretch_max_place   dw 0
stretch_logged      dw 0                ; clocks of the stretch the log took
stretch_log_count   dw 0                ; channel 0's count when a byte of it began
stretch_work_max    dw 0                ; the longest but the log's time: a release
stretch_work_place  dw 0                ; build's, which has no log
msg_stretch         db "rx286: interrupts off at most ", 0
msg_stretch_us      db " us, at vector ", 0
msg_stretch_call    db ", call ", 0
msg_stretch_idle    db " us, in the idle loop", 0
msg_stretch_work    db "rx286: but the log's bytes, at most ", 0
msg_stretch_under   db "rx286: interrupts never off for 10 ms", CHAR_LF, 0
msg_stretch_over    db "rx286: interrupts off for 10 ms or more", CHAR_LF, 0
end_kdata

; ----------------------------------------------------------------------------
; stretch_begin - interrupts have just gone off: note channel 0's count
;   In:       AX = the place; DS = SEL_KDATA; interrupts off
;   Out:      nothing
;   Destroys: nothing
; ----------------------------------------------------------------------------
stretch_begin:
        mov [stretch_place], ax
        push ax
        call pit_count                  ; the count first, then a tick pending: one
        mov [stretch_start], ax         ;    that comes between is seen as pending
        call tick_pending               ;    at the start, its wrap by the counts
        mov [stretch_tick], al
        mov byte [stretch_open], 1
        mov word [stretch_logged], 0
        pop ax
        ret

; ----------------------------------------------------------------------------
; stretch_log_start - a byte of the log begins: its time is counted apart
;   In:       DS = SEL_KDATA; interrupts off
;   Out:      nothing
;   Destroys: nothing
; ----------------------------------------------------------------------------
stretch_log_start:
        push ax
        call pit_count
        mov [stretch_log_count], ax
        pop ax
        ret

; ----------------------------------------------------------------------------
; stretch_log_stop - the byte is out: its time added to the log's
;   In:       DS = SEL_KDATA; interrupts off
;   Out:      nothing
;   Destroys: nothing
; ----------------------------------------------------------------------------
stretch_log_stop:
        push ax
        push si
        mov si, [stretch_log_count]
        call pit_elapsed
        add [stretch_logged], ax
        pop si
        pop ax
        ret

; ----------------------------------------------------------------------------
; stretch_end - interrupts are about to come on: the stretch measured, and
; kept if it is the longest
;   In:       DS = SEL_KDATA; interrupts off
;   Out:      nothing
;   Destroys: nothing
; ----------------------------------------------------------------------------
stretch_end:
        cmp byte [stretch_open], 0
        je .done
        mov byte [stretch_open], 0
        push ax
        push si
        push dx
        call tick_pending               ; a tick first, then the count: one that
        mov dl, al                      ;    comes between shows as a wrap (P15)
        call pit_count
        mov dh, 0                       ; DH = the count wrapped
        mov si, [stretch_start]
        sub si, ax
        jae .counted
        add si, PIT_DIVISOR
        inc dh
.counted:
        mov ax, si                      ; AX = the 8254's clocks
        cmp byte [stretch_tick], 0      ; a tick came, none was pending at the
        jne .measured                   ;    start, and the counts did not wrap: a
        test dl, dl                     ;    whole period more
        jz .measured
        test dh, dh
        jnz .measured
        add ax, PIT_DIVISOR
.measured:
        pop dx
        cmp ax, [stretch_max]
        jbe .kept
        mov [stretch_max], ax
        push ax
        mov ax, [stretch_place]
        mov [stretch_max_place], ax
        pop ax
.kept:
        sub ax, [stretch_logged]        ; the work alone
        jb .worked                      ; (a byte begun before the stretch)
        cmp ax, [stretch_work_max]
        jbe .worked
        mov [stretch_work_max], ax
        mov ax, [stretch_place]
        mov [stretch_work_place], ax
.worked:
        pop si
        pop ax
.done:
        ret

; ----------------------------------------------------------------------------
; stretch_report - the longest stretch: how long, in microseconds, and where
;   In:       DS = SEL_KDATA; interrupts off
;   Out:      two lines on the log
;   Destroys: AX, BX, CX, DX, SI, DI
; ----------------------------------------------------------------------------
stretch_report:
        mov byte [stretch_open], 0      ; (its own bytes are not measured)
        mov si, msg_stretch_work
        mov ax, [stretch_work_max]
        mov bx, [stretch_work_place]
        call stretch_line
        mov si, msg_stretch
        mov ax, [stretch_max]
        mov bx, [stretch_max_place]
        call stretch_line
        mov si, msg_stretch_under
        cmp ax, STRETCH_LIMIT_US
        jb .verdict
        mov si, msg_stretch_over
.verdict:
        jmp com_puts

; ----------------------------------------------------------------------------
; stretch_line - a stretch's line: how long, and where
;   In:       SI = its text; AX = its clocks; BX = its place
;   Out:      AX = its microseconds
;   Destroys: BX, CX, DX, SI, DI
; ----------------------------------------------------------------------------
stretch_line:
        call com_puts
        mov cx, STRETCH_NS_PER_CLOCK
        mul cx
        mov cx, 1000
        div cx                          ; AX = microseconds
        push ax
        call stretch_dec
        mov ax, bx
        cmp ax, 0xFFFF
        jne .vector
        mov si, msg_stretch_idle
        call com_puts
        jmp .line
.vector:
        mov si, msg_stretch_us
        call com_puts
        push ax
        mov al, ah
        call stretch_hex
        pop ax
        mov si, msg_stretch_call
        call com_puts
        call stretch_hex
.line:
        mov al, CHAR_LF
        call com_putc
        pop ax
        ret

; ----------------------------------------------------------------------------
; stretch_dec - a number in decimal on the log
;   In:       AX = the number; DS = ES = SEL_KDATA
;   Out:      nothing
;   Destroys: SI, DI
; ----------------------------------------------------------------------------
stretch_dec:
        mov di, stretch_text
        call fmt_dec16
        mov byte [di], 0
        mov si, stretch_text
        jmp com_puts

; ----------------------------------------------------------------------------
; stretch_hex - a byte in hexadecimal on the log
;   In:       AL = the byte; DS = ES = SEL_KDATA
;   Out:      nothing
;   Destroys: SI, DI
; ----------------------------------------------------------------------------
stretch_hex:
        mov di, stretch_text
        call fmt_hex8
        mov byte [di], 0
        mov si, stretch_text
        jmp com_puts

begin_kdata
stretch_text        times 12 db 0
end_kdata

STRETCH_NS_PER_CLOCK  equ 1000000000 / PIT_INPUT_HZ      ; 838 ns a clock of the 8254

; ----------------------------------------------------------------------------
; pit_count - timer channel 0's count, latched
;   In:       interrupts off
;   Out:      AX = the count
;   Destroys: nothing else
; ----------------------------------------------------------------------------
pit_count:
        mov al, PIT_LATCH_CH0
        out PIT_MODE, al
        in al, PIT_CH0
        mov ah, al
        in al, PIT_CH0
        xchg al, ah
        ret

; ----------------------------------------------------------------------------
; pit_elapsed - the 8254's clocks since a count of channel 0, a rate
; generator in these builds (timer_init): the count falls by one a clock
; from PIT_DIVISOR, once a period, so the clocks are the counts between,
; with PIT_DIVISOR added if it reloaded meanwhile (P15: in mode 3 it fell
; by two, twice a period, and a stretch past 10 ms could not be told)
;   In:       SI = the count then (pit_count)
;   Out:      AX = the clocks since
;   Destroys: nothing else
; ----------------------------------------------------------------------------
pit_elapsed:
        push dx
        call pit_count
        mov dx, si
        sub dx, ax
        jae .counted
        add dx, PIT_DIVISOR             ; it reloaded between
.counted:
        mov ax, dx
        pop dx
        ret

; ----------------------------------------------------------------------------
; tick_pending - is the timer's interrupt waiting in the master PIC's IRR?
; With interrupts off a tick stays there: a whole period passed (P15)
;   In:       interrupts off
;   Out:      AL = 1 if so, else 0
;   Destroys: nothing else
; ----------------------------------------------------------------------------
tick_pending:
        mov al, PIC_READ_IRR
        out PIC1_CMD, al
        in al, PIC1_CMD
        and al, 1                       ; IRQ 0
        ret
%endif

%endif
