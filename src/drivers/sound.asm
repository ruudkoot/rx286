; ============================================================================
; rx286 - src/drivers/sound.asm
; The sound driver (roadmap l4.md L10; devices roadmap D3, D4): the speaker
; and the game port, in ring 1 with IOPL 1. It took the kernel's code for
; both as it was.
;
; The speaker: timer channel 2 as a square wave, gated to the speaker
; through system port B. A sound is synchronous, like a disk's sector: the
; driver programs channel 2 to the frequency, opens the gate, sleeps on its
; timer for the ticks asked, and closes the gate. A frequency of 0 is a
; rest: silence for the ticks, which a program may use to wait. Ctrl+Break
; ends a sound at once: the OS server signals the driver's notification
; with DRV_STOP_BIT, and a stop left over from before a sound is dropped
; when it starts. Port B is changed bit by bit, the others written back as
; read, as IBM asks (5-10) and its BIOS does. Channel 2 is never used
; otherwise. In TEST_SOUND builds the kernel's probe measures each tone and
; each silence (KCALL_TEST).
;
; The game port at 201h: two joysticks' four buttons and four axes. The
; buttons are read as they are. Each axis is a one-shot: a write to the port
; starts all four, and an axis's bit stays 1 for a time that grows with the
; resistance of its joystick (about 24 us plus 11 us a kilohm). The driver
; times them with timer channel 0, whose count it latches, and gives each
; axis in microseconds. Interrupts stay off while it times, JOY_AXIS_MAX_US
; at most, well under a tick: an axis whose bit does not rise at once, or
; has not fallen by then, has no joystick behind it, and is JOY_ABSENT. Its
; five results are more than a reply's four words: they go into the block
; of the transfer segment the OS server passes (os.inc).
; ============================================================================

cpu 286
bits 16
%define KERNEL_LOG                      ; its lines: the kernel's log
%include "build.inc"
%include "program.inc"
%include "ports.inc"
%include "kcalls.inc"
%include "drivers.inc"
%include "os.inc"

RING                equ 1
%define SLOT(n) ((n) * 8 + 4 + RING)    ; a slot of the driver's, as a selector
EP                  equ SLOT(DRV_SLOT_EP)
NOTIFY              equ SLOT(DRV_SLOT_NOTIFY)
RECV                equ SLOT(DRV_SLOT_RECV)
JOY_AXES            equ 4
JOY_LIMIT_CLOCKS    equ JOY_AXIS_MAX_US * (PIT_INPUT_HZ / 1000) / 1000
JOY_NS_PER_CLOCK    equ 1000000000 / PIT_INPUT_HZ      ; 838

begin_udata
joy_times           times JOY_AXES dw 0
end_udata

; ----------------------------------------------------------------------------
; entry - serve, for ever
;   In:       its start: DS = ES = its data, IOPL 1
;   Out:      does not return
;   Destroys: everything
; ----------------------------------------------------------------------------
entry:
        cld
        ; falls through

; ----------------------------------------------------------------------------
; serve - sound and read the game port as the OS server asks
;   In:       nothing
;   Out:      does not return
;   Destroys: everything
; ----------------------------------------------------------------------------
serve:
        mov dx, EP
        mov bp, RECV
        kcall KCALL_RECV
.message:
        jc serve
        cmp al, NOTIFY_LABEL
        je serve                        ; its notification's bits: a stop or a
        cmp al, DRV_SOUND               ; timer left over, nothing to answer
        je .sound
        mov bx, E_INVAL                 ; a call it does not know
        cmp al, DRV_JOYSTICK
        jne .unknown
        call joystick
        mov dx, RECV                    ; the segment, used: room for the next
        kcall KCALL_DELETE
        jmp .reply
.sound:
        call sound                      ; BX the status
        jmp .reply
.unknown:
        mov dx, RECV
        kcall KCALL_DELETE
.reply:
        mov dx, EP
        mov bp, RECV
        kcall KCALL_REPLY_RECV
        jmp .message

; ----------------------------------------------------------------------------
; sound - a tone of BX hertz, or a rest, for CX ticks, or until stopped
;   In:       BX = the frequency (0: a rest); CX = the ticks
;   Out:      BX = 0 or E_INVAL
;   Destroys: AX, CX, DX, SI, DI
; ----------------------------------------------------------------------------
sound:
        cmp cx, SOUND_MAX_TICKS
        ja .invalid
        test bx, bx
        jz .wait
        cmp bx, SOUND_MIN_HZ
        jb .invalid
        cmp bx, SOUND_MAX_HZ
        ja .invalid
        mov dx, PIT_INPUT_HZ >> 16
        mov ax, PIT_INPUT_HZ & 0xFFFF
        div bx                          ; AX = channel 2's divisor (BX >= SOUND_MIN_HZ)
        call speaker_on
%ifdef TEST_SOUND
        mov al, TEST_SOUND_PROBE        ; the kernel's probe: BX the frequency
        kcall KCALL_TEST
%endif
.wait:
        jcxz .done
        push cx
        mov dx, NOTIFY                  ; a stop left over is no reason to stop
        kcall KCALL_POLL
        pop cx
        mov dx, NOTIFY
        kcall KCALL_TIMER
.sleep:
        mov dx, NOTIFY
        kcall KCALL_RECV                ; BX = the bits
        jc .sleep
        test bx, DRV_TIMER_BIT | DRV_STOP_BIT
        jz .sleep
.done:
        call speaker_off
%ifdef TEST_SOUND
        mov al, TEST_SILENCE_PROBE
        kcall KCALL_TEST
%endif
        xor bx, bx
        ret
.invalid:
        mov bx, E_INVAL
        ret

; ----------------------------------------------------------------------------
; speaker_on - channel 2 as a square wave of a divisor, to the speaker
;   In:       AX = the divisor
;   Out:      nothing
;   Destroys: AX
; ----------------------------------------------------------------------------
speaker_on:
        push ax
        mov al, PIT_CH2_LOHI_MODE3
        out PIT_MODE, al
        pop ax
        out PIT_CH2, al
        mov al, ah
        out PIT_CH2, al
        in al, SYS_PORT_B
        or al, SYS_PORT_B_GATE2 | SYS_PORT_B_SPEAKER
        out SYS_PORT_B, al
        ret

; ----------------------------------------------------------------------------
; speaker_off - channel 2 stopped, the speaker silent
;   In:       nothing
;   Out:      nothing
;   Destroys: AL
; ----------------------------------------------------------------------------
speaker_off:
        in al, SYS_PORT_B
        and al, ~(SYS_PORT_B_GATE2 | SYS_PORT_B_SPEAKER) & 0xFF
        out SYS_PORT_B, al
        ret

; ----------------------------------------------------------------------------
; joystick - the buttons pressed and the four axes, into the block of the
; transfer segment passed: AX the buttons (bit n set: button n pressed), BX,
; CX, DX, SI axes 0-3 in microseconds, or JOY_ABSENT
;   In:       BP = the segment (0: none came)
;   Out:      nothing
;   Destroys: AX, BX, CX, DX, SI, DI, ES
; ----------------------------------------------------------------------------
joystick:
        test bp, bp
        jz .done
        verw bp                         ; (a program killed meanwhile: l4.md L12)
        jnz .done
        mov dx, GAME_PORT
        in al, dx
        not al
        shr al, GAME_PORT_BUTTON_SHIFT
        xor ah, ah
        mov es, bp
        mov [es:XFER_AX], ax
        push ds
        pop es
        call joy_axes
        verw bp
        jnz .done
        mov es, bp
        mov ax, [joy_times]
        mov [es:XFER_BX], ax
        mov ax, [joy_times + 2]
        mov [es:XFER_CX], ax
        mov ax, [joy_times + 4]
        mov [es:XFER_DX], ax
        mov ax, [joy_times + 6]
        mov [es:XFER_SI], ax
.done:
        ret

; ----------------------------------------------------------------------------
; joy_axes - start the one-shots and time each axis into joy_times, with
; interrupts off
;   In:       DS = ES = its data
;   Out:      joy_times
;   Destroys: AX, BX, CX, DX, SI, DI
; ----------------------------------------------------------------------------
joy_axes:
        mov di, joy_times
        mov ax, JOY_ABSENT
        mov cx, JOY_AXES
        rep stosw
        pushf
        cli
        mov dx, GAME_PORT
        out dx, al                      ; any value: the one-shots start
        call pit_count
        mov si, ax                      ; SI = the count at the start
        in al, dx
        and al, GAME_PORT_AXES
        mov bl, al                      ; BL = the axes that rose, still timing
.poll:
        test bl, bl
        jz .done
        mov dx, GAME_PORT
        in al, dx
        mov bh, al
        call pit_elapsed                ; AX = clocks since SI
        cmp ax, JOY_LIMIT_CLOCKS
        ja .done
        not bh
        and bh, bl                      ; BH = the axes that fell since
        jz .poll
        xor bl, bh
        mov cx, JOY_NS_PER_CLOCK
        mul cx
        mov cx, 1000
        div cx                          ; AX = microseconds
        mov di, joy_times
.axis:
        shr bh, 1
        jnc .next
        mov [di], ax
.next:
        add di, 2
        test bh, bh
        jnz .axis
        jmp .poll
.done:
        popf
        ret

; ----------------------------------------------------------------------------
; pit_count - timer channel 0's count, latched (the kernel's channel: a
; latch does not disturb it)
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
; pit_elapsed - the 8254's clocks since a count of channel 0. In mode 3 the
; count falls by two a clock from PIT_DIVISOR, twice a period; so for a span
; under half a period (10 ms), the clocks are half the counts between, with
; PIT_DIVISOR added if the count reloaded meanwhile
;   In:       SI = the count then (pit_count); interrupts off
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
