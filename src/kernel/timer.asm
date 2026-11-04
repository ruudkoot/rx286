; ============================================================================
; rx286 - src/kernel/timer.asm
; The 8254's channel 0, IRQ0: PIT_HZ ticks a second (roadmap D14); and the
; kernel's waits for devices, which count those ticks.
;
; Channel 0 is programmed explicitly, never inherited from the BIOS.
; Channels 1 (the DRAM's refresh: roadmap X7) and 2 (the speaker) are never
; touched. The tick count is 32 bits: at 50 Hz it wraps after 2.7 years.
;
; A driver that waits for its device either sleeps until its interrupt
; handler sets a byte (ksleep_until) or polls a port (kpoll), both with
; interrupts let in (roadmap D15) and both with a limit in ticks: a device
; that never answers is an error, never a hang. A wait of n ticks ends
; when the count has moved on n times, so it lasts more than n - 1 ticks.
; ============================================================================

KPOLL_BURST         equ 64              ; reads of a port between interrupt windows

begin_kdata
ticks               dd 0
ksleep_never        db 0                ; a byte nothing sets: ksleep's
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
        call fd_tick
        call mouse_tick
        call mouse_irq                  ; bytes whose interrupt was lost (an edge
%ifdef WITH_MODEM                       ; can go, as on a shared line)
        call modem_irq
%endif
%ifdef WITH_TEST_HOOKS
        call test_tick
%endif
        ret

; ----------------------------------------------------------------------------
; ksleep_until - sleep with interrupts on until a byte is not zero, or for
; CX ticks at most
;   In:       SI = the byte (kdata); CX = the limit in ticks (1 or more);
;             DS = SEL_KDATA; interrupts off
;   Out:      CF clear if the byte was set; CF set if the time ran out
;   Destroys: AX
; ----------------------------------------------------------------------------
ksleep_until:
        push bx
        mov bx, [ticks]                 ; the low word: limits are far below 65,536
.check:
        cmp byte [si], 0
        jne .set
        mov ax, [ticks]
        sub ax, bx
        cmp ax, cx
        jae .late
        sti                             ; STI acts after HLT has begun: an interrupt
        hlt                             ; already pending still wakes it
        cli
        jmp .check
.set:
        pop bx
        clc
        ret
.late:
        pop bx
        stc
        ret

; ----------------------------------------------------------------------------
; ksleep - sleep with interrupts on for CX ticks
;   In:       CX = ticks (1 or more); DS = SEL_KDATA; interrupts off
;   Out:      nothing
;   Destroys: AX
; ----------------------------------------------------------------------------
ksleep:
        push si
        mov si, ksleep_never
        call ksleep_until
        pop si
        ret

; ----------------------------------------------------------------------------
; kpoll - read a port until the bits of a mask have a value, letting
; interrupts in between bursts of reads, for CX ticks at most
;   In:       DX = the port; AH = the mask; AL = the value wanted under it;
;             CX = the limit in ticks (1 or more); DS = SEL_KDATA;
;             interrupts off
;   Out:      CF clear or set (the time ran out); AL = what the port read last
;   Destroys: nothing
; ----------------------------------------------------------------------------
kpoll:
        push bx
        push si
        push di
        mov bl, al
        mov si, [ticks]
.burst:
        mov di, KPOLL_BURST
.read:
        in al, dx
        push ax
        and al, ah
        cmp al, bl
        pop ax
        je .done
        dec di
        jnz .read
        sti
        nop
        cli
        push ax
        mov ax, [ticks]
        sub ax, si
        cmp ax, cx
        pop ax
        jb .burst
        stc
        jmp .out
.done:
        clc
.out:
        pop di
        pop si
        pop bx
        ret

; ----------------------------------------------------------------------------
; pit_count - timer channel 0's count, latched
;   In:       nothing
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
; pit_elapsed - the 8254's clocks since a count of channel 0. In mode 3 the
; count falls by two a clock from PIT_DIVISOR, twice a period; so for a span
; under half a period (10 ms), the clocks are half the counts between, with
; PIT_DIVISOR added if the count reloaded meanwhile
;   In:       SI = the count then (pit_count)
;   Out:      AX = the clocks since
;   Destroys: nothing else
; ----------------------------------------------------------------------------
pit_elapsed:
        push dx
        call pit_count
        mov dx, si
        sub dx, ax
        jae .halve
        add dx, PIT_DIVISOR             ; it reloaded between
.halve:
        shr dx, 1
        mov ax, dx
        pop dx
        ret
