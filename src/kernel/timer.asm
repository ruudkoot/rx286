; ============================================================================
; rx286 - src/kernel/timer.asm
; The 8254's channel 0, IRQ0: PIT_HZ ticks a second (roadmap D14).
;
; Channel 0 is programmed explicitly, never inherited from the BIOS.
; Channels 1 (the DRAM's refresh: roadmap X7) and 2 (the speaker) are never
; touched. The tick count is 32 bits: at 50 Hz it wraps after 2.7 years.
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
%ifdef WITH_TEST_HOOKS
        call test_tick
%endif
        ret
