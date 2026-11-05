; ============================================================================
; rx286 - src/kernel/timer.asm
; The 8254's channel 0, IRQ0: PIT_HZ ticks a second (roadmap D14), which
; drive the scheduler's time slices and the kernel's timers (KCALL_TIMER).
;
; Channel 0 is programmed explicitly, never inherited from the BIOS.
; Channel 1 (the DRAM's refresh: roadmap X7) is never touched; channel 2 is
; the sound driver's. The tick count is 32 bits: at 50 Hz it wraps after 2.7
; years. The waits for devices left with the devices (l4.md L10): a driver
; waits on its own notification and the kernel's timer (src/drivers/dwait.asm).
; ============================================================================

begin_kdata
ticks               dd 0
end_kdata

; ----------------------------------------------------------------------------
; timer_init - channel 0 as a square wave of PIT_HZ
;   In:       interrupts off
;   Out:      nothing
;   Destroys: AX
; ----------------------------------------------------------------------------
timer_init:
        mov al, PIT_CH0_LOHI_MODE3
        out PIT_MODE, al
        mov ax, PIT_DIVISOR
        out PIT_CH0, al
        mov al, ah
        out PIT_CH0, al
        ret

; ----------------------------------------------------------------------------
; timer_irq - IRQ0: count the tick
;   In:       BP = the frame; DS = SEL_KDATA
;   Out:      nothing (the dispatcher sends EOI)
;   Destroys: AX, BX, CX, DX, SI, DI (the test hook)
; ----------------------------------------------------------------------------
timer_irq:
        add word [ticks], 1
        adc word [ticks + 2], 0
        call thread_tick                ; the running thread's time slice
        call timers_tick                ; the kernel's timers (ipc.asm)
%ifdef WITH_TEST_HOOKS
        call test_tick
%endif
        ret

%ifdef WITH_TEST_HOOKS
; ----------------------------------------------------------------------------
; ksleep - test builds: sleep with interrupts on for CX ticks (the probes at
; the start, before any thread runs, and the kernel's own 287 test)
;   In:       CX = ticks (1 or more); DS = SEL_KDATA; interrupts off
;   Out:      nothing
;   Destroys: AX
; ----------------------------------------------------------------------------
ksleep:
        mov ax, [ticks]
.wait:
        call kwait                      ; until an interrupt
        push ax
        neg ax
        add ax, [ticks]                 ; the ticks since
        cmp ax, cx
        pop ax
        jb .wait
        ret
%endif
