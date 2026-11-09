; ============================================================================
; rx286 - src/drivers/dwait.asm
; The waits of a driver outside the kernel (roadmap l4.md L9): for its
; interrupt, for some ticks, for a port's bits, each with a limit in ticks.
;
; They take the place of the kernel's ksleep_until, ksleep and kpoll. A
; driver waits on its notification (drivers.inc): its interrupt signals
; DRV_IRQ_BIT, and a one-tick timer of the kernel's DRV_TIMER_BIT, so the
; driver looks at the time once a tick; a timer that comes after it is no
; longer wanted only makes another look. The ticks are the kernel's
; (KCALL_TICKS). The driver that includes this defines NOTIFY and IRQ (its
; slots' selectors), irq_seen (a byte, set here when the interrupt came),
; and driver_irq (what the interrupt needs at once: the fixed disk reads its
; status); each wait acknowledges the interrupt, so the line is on again.
; ============================================================================

; ----------------------------------------------------------------------------
; dw_ticks - the kernel's ticks (their low word: limits are far below it)
;   In:       nothing
;   Out:      AX = the ticks
;   Destroys: nothing
; ----------------------------------------------------------------------------
dw_ticks:
        push dx
        kcall KCALL_TICKS
        pop dx
        ret

; ----------------------------------------------------------------------------
; dw_wait_irq - wait for the interrupt, for CX ticks at most
;   In:       CX = the limit (1 or more); irq_seen cleared before the command
;   Out:      CF clear if it came; CF set if the time ran out
;   Destroys: AX
; ----------------------------------------------------------------------------
dw_wait_irq:
        push bx
        push dx
        call dw_ticks
        mov bx, ax                      ; BX = the start
.check:
        cmp byte [irq_seen], 0
        jne .came
        call dw_ticks
        sub ax, bx
        cmp ax, cx
        jae .late
        call dw_tick
        jmp .check
.came:
        clc
        jmp .out
.late:
        stc
.out:
        pop dx
        pop bx
        ret

; ----------------------------------------------------------------------------
; dw_run_start - a command's time begins (disk-scheduler.md M2): dw_run_wait
; then looks at the time only when a tick passes, not before each wait, so
; that a sector of a run costs a timer, a receive and the interrupt's
; acknowledgement
;   In:       CX = the command's limit in ticks (1 or more)
;   Out:      nothing
;   Destroys: AX
; ----------------------------------------------------------------------------
dw_run_start:
        call dw_ticks
        mov [dw_start], ax
        mov [dw_limit], cx
        ret

; ----------------------------------------------------------------------------
; dw_run_wait - wait for the interrupt within the command's time. The wait
; arms the notification's timer for the next tick first, as dw_tick does:
; without a timer that near, MAME's AT woke the driver some 13 ms after a
; write's interrupt (disk-scheduler.md M2, *At the close*), its reads and
; Bochs not
;   In:       dw_run_start called for the command; irq_seen cleared before the
;             interrupt waited for
;   Out:      CF clear if it came; CF set if the command's time ran out
;   Destroys: AX
; ----------------------------------------------------------------------------
dw_run_wait:
        push bx
        push cx
        push dx
.check:
        cmp byte [irq_seen], 0
        jne .came
        mov dx, NOTIFY
        mov cx, 1
        kcall KCALL_TIMER
        mov dx, NOTIFY
        kcall KCALL_RECV                ; BX = the bits
        jc .check
        call dw_bits
        test bx, DRV_TIMER_BIT
        jz .check
        call dw_ticks                   ; a tick passed: is the command's time up?
        sub ax, [dw_start]
        cmp ax, [dw_limit]
        jb .check
        cmp byte [irq_seen], 0          ; (the interrupt with the last tick)
        jne .came
        stc
        jmp .out
.came:
        clc
.out:
        pop dx
        pop cx
        pop bx
        ret

begin_udata
dw_start            dw 0                ; dw_run_start's: the tick it began at
dw_limit            dw 0                ;    and its limit
end_udata

; ----------------------------------------------------------------------------
; dw_sleep - sleep for CX ticks (an interrupt meanwhile is taken)
;   In:       CX = ticks (1 or more)
;   Out:      nothing
;   Destroys: AX
; ----------------------------------------------------------------------------
dw_sleep:
        push bx
        call dw_ticks
        mov bx, ax
.again:
        call dw_tick
        call dw_ticks
        sub ax, bx
        cmp ax, cx
        jb .again
        pop bx
        ret

; ----------------------------------------------------------------------------
; dw_poll - read a port until the bits of a mask have a value, for CX
; ticks at most: a burst of reads, then a tick's sleep if they did not find
; it, so that a device slow to answer keeps no thread below the driver from
; running (l4.md L13)
;   In:       DX = the port; AH = the mask; AL = the value wanted under it;
;             CX = the limit in ticks (1 or more)
;   Out:      CF clear or set (the time ran out); AL = what the port read
;             last
;   Destroys: nothing
; ----------------------------------------------------------------------------
dw_poll:
        push bx
        push si
        push di
        mov bl, al
        push ax
        call dw_ticks
        mov si, ax                      ; SI = the start
        pop ax
.burst:
        mov di, DW_POLL_BURST
.read:
        in al, dx
        push ax
        and al, ah
        cmp al, bl
        pop ax
        je .done
        dec di
        jnz .read
        push ax
        call dw_ticks
        sub ax, si
        cmp ax, cx
        jae .late
        call dw_tick                    ; until the next tick (or the interrupt)
        pop ax
        jmp .burst
.late:
        pop ax
        stc
        jmp .out
.done:
        clc
.out:
        pop di
        pop si
        pop bx
        ret

DW_POLL_BURST       equ 512             ; reads between sleeps: two milliseconds or so,
                                        ;    longer than a byte at 9600 baud (1.04 ms),
                                        ;    so that a serial write sleeps a tick only
                                        ;    when the line is slow indeed (P15)

; ----------------------------------------------------------------------------
; dw_tick - wait until the next tick or the interrupt, whichever is first;
; the interrupt taken (driver_irq, irq_seen) and acknowledged
;   In:       nothing
;   Out:      nothing
;   Destroys: AX
; ----------------------------------------------------------------------------
dw_tick:
        push bx
        push cx
        push dx
        mov dx, NOTIFY
        mov cx, 1
        kcall KCALL_TIMER
        mov dx, NOTIFY
        kcall KCALL_RECV                ; BX = the bits
        jc .out
        call dw_bits
.out:
        pop dx
        pop cx
        pop bx
        ret

; ----------------------------------------------------------------------------
; dw_bits - the notification's bits, as a receive returned them: the
; interrupt taken and acknowledged
;   In:       BX = the bits
;   Out:      nothing
;   Destroys: AX, DX
; ----------------------------------------------------------------------------
dw_bits:
        test bx, DRV_IRQ_BIT
        jz .done
        call driver_irq
        mov byte [irq_seen], 1
        push bx
        mov dx, IRQ
        mov al, IRQ_ACK
        kcall KCALL_IRQ                 ; the line on again
        pop bx
.done:
        ret

; ----------------------------------------------------------------------------
; dw_readable - may the driver still read the segment passed? After a wait
; it may be gone: a program killed meanwhile has its segments revoked
; (l4.md L12), and loading it would fault in ring 1
;   In:       BP = the segment
;   Out:      ZF set if so
;   Destroys: nothing
; ----------------------------------------------------------------------------
dw_readable:
        verr bp
        ret

; ----------------------------------------------------------------------------
; dw_writable - may the driver still write the segment passed? (dw_readable)
;   In:       BP = the segment
;   Out:      ZF set if so
;   Destroys: nothing
; ----------------------------------------------------------------------------
dw_writable:
        verw bp
        ret

