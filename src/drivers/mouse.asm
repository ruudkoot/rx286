; ============================================================================
; rx286 - src/drivers/mouse.asm
; The mouse driver (roadmap l4.md L7; devices roadmap D1): a Microsoft
; serial mouse on COM1, IRQ4, in ring 1 with IOPL 1.
;
; COM1 runs at 1200 baud, 7N1, and interrupts when a byte comes. At its
; start the driver drops DTR and RTS, which resets the mouse, and raises
; them again MOUSE_RESET_TICKS later, on the kernel's timer; the mouse then
; says "M". From then on each movement or button change is a packet of
; three bytes, the first with bit 6 set:
;   1 L R Y7 Y6 X7 X6     0 X5 X4 X3 X2 X1 X0     0 Y5 Y4 Y3 Y2 Y1 Y0
; X and Y are signed: right and down are positive. A Logitech mouse's fourth
; byte (its middle button) is passed over, and so is a Plug and Play mouse's
; identity, which follows its "M" between parentheses (its letters would
; begin packets): only before the first packet, and MOUSE_PNP_MAX bytes at
; most, since a packet's second or third byte may be '(' too, if its first
; was lost (P15). The driver adds each packet's movement to a position it
; keeps as DOS's mouse driver does in text mode, 0-MOUSE_X_MAX and
; 0-MOUSE_Y_MAX, eight to a character cell, starting in the middle; and
; keeps the buttons. A mouse that never says "M" is reported absent, but
; its packets still count: nothing is detected.
;
; The bytes come at IRQ4, which the root bound to the driver's notification
; (DRV_IRQ_BIT): the driver takes what COM1 has, then acknowledges the line.
; It also looks every MOUSE_POLL_TICKS, on its timer (DRV_TIMER_BIT), for
; bytes whose interrupt was lost (an edge can go, as on a shared line). In
; test builds a key script's mouse bytes come from the kernel (KCALL_TEST),
; with IRQ4's bits. The OS server asks it for the state (DRV_MOUSE_GET) and
; whether the mouse has news (DRV_MOUSE_NEWS), for /dev/mouse's reads,
; ioctl and poll.
; ============================================================================

cpu 286
bits 16
%include "build.inc"
%include "program.inc"
%include "ports.inc"
%include "kcalls.inc"
%include "drivers.inc"

RING                equ 1
%define SLOT(n) ((n) * 8 + 4 + RING)    ; a slot of the driver's, as a selector
EP                  equ SLOT(DRV_SLOT_EP)
NOTIFY              equ SLOT(DRV_SLOT_NOTIFY)
IRQ                 equ SLOT(DRV_SLOT_IRQ)
MOUSE_RESET_TICKS   equ 12              ; DTR and RTS low 200 ms at least
MOUSE_POLL_TICKS    equ 5               ; a look for bytes whose interrupt was lost
MOUSE_ID            equ 'M'
MOUSE_SYNC          equ 0x40            ; a packet's first byte
MOUSE_BYTE          equ 0x7F            ; seven bits a byte
MOUSE_PACKET        equ 3               ; bytes; mouse_index at it: a packet is whole
MOUSE_PACKET_LEFT   equ 0x20
MOUSE_PACKET_RIGHT  equ 0x10
MOUSE_PACKET_Y_HIGH equ 0x0C
MOUSE_PACKET_X_HIGH equ 0x03
MOUSE_IRQ_BYTES     equ 16              ; bytes taken at most in one look
MOUSE_PNP_BEGIN     equ '('             ; a Plug and Play identity's first byte
MOUSE_PNP_END       equ ')'             ; and its last
MOUSE_PNP_MAX       equ 255             ; its bytes at most (P15)

begin_udata
mouse_present       db 0                ; MOUSE_PRESENT once it said "M"
mouse_index         db MOUSE_PACKET     ; the next byte's place in mouse_packet
mouse_packet        times MOUSE_PACKET db 0
mouse_x             dw (MOUSE_X_MAX + 1) / 2
mouse_y             dw (MOUSE_Y_MAX + 1) / 2
mouse_buttons       db 0
mouse_changed       db 0                ; set by a packet that changed the position or
                                        ;    the buttons, cleared by DRV_MOUSE_GET
mouse_pnp           db 0                ; inside a Plug and Play identity: the bytes
                                        ;    it may still have
mouse_packets       db 0                ; 1 once a packet has begun: no identity then
end_udata

; ----------------------------------------------------------------------------
; entry - reset the mouse, let it talk, then serve
;   In:       its start: DS = ES = its data, IOPL 1
;   Out:      does not return
;   Destroys: everything
; ----------------------------------------------------------------------------
entry:
        cld
        call mouse_init
        mov cx, MOUSE_RESET_TICKS       ; the reset
        call timer
.reset:
        mov dx, NOTIFY                  ; until the timer's bit (P15): a stray
        kcall KCALL_RECV                ;    interrupt meanwhile is no reason to end
        jc .reset                       ;    it, and its line goes on again
        test bx, DRV_IRQ_BIT
        jz .no_irq
        push bx
        mov dx, COM1_BASE + UART_RBR
        in al, dx
        mov dx, IRQ
        mov al, IRQ_ACK
        kcall KCALL_IRQ
        pop bx
.no_irq:
        test bx, DRV_TIMER_BIT
        jz .reset
        mov dx, COM1_BASE + UART_RBR
        in al, dx                       ; nothing stale
        mov dx, COM1_BASE + UART_IER
        mov al, UART_IER_RECEIVED
        out dx, al
        mov dx, COM1_BASE + UART_MCR
        mov al, UART_MCR_RUN
        out dx, al
        mov cx, MOUSE_POLL_TICKS
        call timer
        ; falls through

; ----------------------------------------------------------------------------
; serve - the mouse's bytes as they come, and the OS server's questions
;   In:       nothing
;   Out:      does not return
;   Destroys: everything
; ----------------------------------------------------------------------------
serve:
        mov dx, EP
        xor bp, bp
        kcall KCALL_RECV
.message:
        jc serve
        cmp al, NOTIFY_LABEL
        je .news
        cmp al, DRV_MOUSE_GET
        je .get
        mov bx, E_INVAL                 ; a call it does not know (P15)
        cmp al, DRV_MOUSE_NEWS
        jne .reply
        xor bx, bx
        mov bl, [mouse_changed]
        jmp .reply
.get:
        mov al, [mouse_present]
        xor ah, ah
        mov di, ax
        mov bl, [mouse_buttons]
        xor bh, bh
        mov cx, [mouse_x]
        mov si, [mouse_y]
        mov byte [mouse_changed], 0
.reply:
        mov dx, EP
        xor bp, bp
        kcall KCALL_REPLY_RECV
        jmp .message
.news:
        push bx                         ; the bits
        call mouse_take
        pop bx
        test bx, DRV_IRQ_BIT
        jz .timer
        push bx
        mov dx, IRQ
        mov al, IRQ_ACK
        kcall KCALL_IRQ                 ; the line on again
        pop bx
.timer:
        test bx, DRV_TIMER_BIT
        jz serve
        mov cx, MOUSE_POLL_TICKS
        call timer
        jmp serve

; ----------------------------------------------------------------------------
; timer - the driver's timer, CX ticks from now
;   In:       CX = ticks
;   Out:      nothing
;   Destroys: AX, DX
; ----------------------------------------------------------------------------
timer:
        mov dx, NOTIFY
        kcall KCALL_TIMER
        ret

; ----------------------------------------------------------------------------
; mouse_init - COM1 at 1200 baud, 7N1, DTR and RTS low: the mouse resets
;   In:       nothing
;   Out:      nothing
;   Destroys: AL, DX
; ----------------------------------------------------------------------------
mouse_init:
        mov dx, COM1_BASE + UART_LCR
        mov al, UART_LCR_DLAB
        out dx, al
        mov dx, COM1_BASE + UART_DLL
        mov al, UART_DIVISOR_1200
        out dx, al
        mov dx, COM1_BASE + UART_DLM
        xor al, al
        out dx, al
        mov dx, COM1_BASE + UART_LCR
        mov al, UART_LCR_7N1
        out dx, al
        mov dx, COM1_BASE + UART_IER
        xor al, al
        out dx, al
        mov dx, COM1_BASE + UART_MCR
        mov al, UART_MCR_OFF
        out dx, al
        ret

; ----------------------------------------------------------------------------
; mouse_take - the bytes COM1 has (and, in test builds, a key script's)
;   In:       DS = its data
;   Out:      nothing
;   Destroys: AX, BX, CX, DX
; ----------------------------------------------------------------------------
mouse_take:
        mov cx, MOUSE_IRQ_BYTES
.next:
        mov dx, COM1_BASE + UART_LSR
        in al, dx
        cmp al, UART_LSR_ABSENT
        je .script                      ; no UART there
        test al, UART_LSR_DATA
        jz .script
        mov dx, COM1_BASE + UART_RBR
        in al, dx
        call mouse_byte
        loop .next
.script:
%ifdef WITH_TEST_HOOKS
        mov al, TEST_MOUSE_BYTE
        kcall KCALL_TEST
        jc .done
        mov al, bl
        call mouse_byte
        jmp .script
.done:
%endif
        ret

; ----------------------------------------------------------------------------
; mouse_byte - one byte from the mouse
;   In:       AL = the byte; DS = its data
;   Out:      nothing
;   Destroys: AX, BX
; ----------------------------------------------------------------------------
mouse_byte:
        and al, MOUSE_BYTE
        cmp byte [mouse_pnp], 0
        jne .pnp
        test al, MOUSE_SYNC
        jz .data
        cmp byte [mouse_present], 0
        jne .start
        cmp al, MOUSE_ID                ; its first "M": who it is
        jne .start
        mov byte [mouse_present], MOUSE_PRESENT
        ret
.start:
        mov [mouse_packet], al
        mov byte [mouse_index], 1
        mov byte [mouse_packets], 1
        ret
.pnp:
        dec byte [mouse_pnp]            ; (at MOUSE_PNP_MAX bytes: over)
        cmp al, MOUSE_PNP_END
        jne .done
        mov byte [mouse_pnp], 0
        ret
.data:
        mov bl, [mouse_index]
        cmp bl, MOUSE_PACKET
        jb .packet
        cmp al, MOUSE_PNP_BEGIN         ; outside a packet, before the first: an
        jne .done                       ;    identity begins? Else no packet begun,
        cmp byte [mouse_packets], 0     ;    or a fourth byte
        jne .done
        mov byte [mouse_pnp], MOUSE_PNP_MAX
        ret
.packet:
        xor bh, bh
        mov [mouse_packet + bx], al
        inc bl
        mov [mouse_index], bl
        cmp bl, MOUSE_PACKET
        je mouse_move
.done:
        ret

; ----------------------------------------------------------------------------
; mouse_move - a whole packet: the position moved, the buttons as they are
;   In:       mouse_packet; DS = its data
;   Out:      mouse_x, mouse_y, mouse_buttons, mouse_changed
;   Destroys: AX, BX
; ----------------------------------------------------------------------------
mouse_move:
        mov al, [mouse_packet]
        and al, MOUSE_PACKET_X_HIGH
        shl al, 6
        or al, [mouse_packet + 1]
        cbw                             ; AX = the movement right
        add ax, [mouse_x]
        mov bx, MOUSE_X_MAX
        call mouse_clamp
        cmp ax, [mouse_x]
        je .x_same
        mov byte [mouse_changed], 1     ; (news only for a change: P15)
.x_same:
        mov [mouse_x], ax
        mov al, [mouse_packet]
        and al, MOUSE_PACKET_Y_HIGH
        shl al, 4
        or al, [mouse_packet + 2]
        cbw                             ; AX = the movement down
        add ax, [mouse_y]
        mov bx, MOUSE_Y_MAX
        call mouse_clamp
        cmp ax, [mouse_y]
        je .y_same
        mov byte [mouse_changed], 1
.y_same:
        mov [mouse_y], ax
        xor bl, bl
        test byte [mouse_packet], MOUSE_PACKET_LEFT
        jz .right
        or bl, MOUSE_LEFT
.right:
        test byte [mouse_packet], MOUSE_PACKET_RIGHT
        jz .buttons
        or bl, MOUSE_RIGHT
.buttons:
        cmp bl, [mouse_buttons]
        je .buttons_same
        mov byte [mouse_changed], 1
.buttons_same:
        mov [mouse_buttons], bl
        ret

; ----------------------------------------------------------------------------
; mouse_clamp - a coordinate kept between 0 and its last
;   In:       AX = the coordinate (signed); BX = its last value
;   Out:      AX within 0..BX
;   Destroys: nothing
; ----------------------------------------------------------------------------
mouse_clamp:
        test ax, ax
        jns .high
        xor ax, ax
        ret
.high:
        cmp ax, bx
        jle .done
        mov ax, bx
.done:
        ret
