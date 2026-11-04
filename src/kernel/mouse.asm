; ============================================================================
; rx286 - src/kernel/mouse.asm
; A Microsoft serial mouse on COM1, IRQ4: SYS_MOUSE (devices roadmap D1).
;
; COM1 runs at 1200 baud, 7N1, and interrupts when a byte comes. At start the
; kernel drops DTR and RTS, which resets the mouse, and raises them again
; MOUSE_RESET_TICKS later (mouse_tick); the mouse then says "M". From then on
; each movement or button change is a packet of three bytes, the first with
; bit 6 set:
;   1 L R Y7 Y6 X7 X6     0 X5 X4 X3 X2 X1 X0     0 Y5 Y4 Y3 Y2 Y1 Y0
; X and Y are signed: right and down are positive. A Logitech mouse's fourth
; byte (its middle button) is passed over, and so is a Plug and Play mouse's
; identity, which follows its "M" between parentheses (its letters would
; begin packets). The kernel adds each packet's
; movement to a position it keeps as DOS's mouse driver does in text mode,
; 0-MOUSE_X_MAX and 0-MOUSE_Y_MAX, eight to a character cell, starting in the
; middle; and keeps the buttons. A mouse that never says "M" is reported
; absent, but its packets still count: nothing is detected.
; ============================================================================

MOUSE_RESET_TICKS   equ 12              ; DTR and RTS low 200 ms at least: the first
                                        ; two ticks may come at once after start
MOUSE_ID            equ 'M'
MOUSE_SYNC          equ 0x40            ; a packet's first byte
MOUSE_BYTE          equ 0x7F            ; seven bits a byte
MOUSE_PACKET        equ 3               ; bytes; mouse_index at it: a packet is whole
MOUSE_PACKET_LEFT   equ 0x20
MOUSE_PACKET_RIGHT  equ 0x10
MOUSE_PACKET_Y_HIGH equ 0x0C
MOUSE_PACKET_X_HIGH equ 0x03
MOUSE_IRQ_BYTES     equ 16              ; bytes taken at most in one interrupt
MOUSE_PNP_BEGIN     equ '('             ; a Plug and Play identity's first byte
MOUSE_PNP_END       equ ')'             ; and its last

begin_kdata
mouse_reset_left    db 0                ; ticks until DTR and RTS rise again
mouse_present       db 0                ; MOUSE_PRESENT once it said "M"
mouse_index         db MOUSE_PACKET     ; the next byte's place in mouse_packet
mouse_packet        times MOUSE_PACKET db 0
mouse_x             dw (MOUSE_X_MAX + 1) / 2
mouse_y             dw (MOUSE_Y_MAX + 1) / 2
mouse_buttons       db 0
mouse_changed       db 0                ; set by a packet, cleared by SYS_MOUSE
mouse_pnp           db 0                ; 1 inside a Plug and Play identity
end_kdata

; ----------------------------------------------------------------------------
; mouse_init - COM1 at 1200 baud, 7N1, DTR and RTS low: the mouse resets
;   In:       interrupts off; DS = SEL_KDATA
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
        mov byte [mouse_reset_left], MOUSE_RESET_TICKS
        ret

; ----------------------------------------------------------------------------
; mouse_tick - on every tick: once the reset has lasted, DTR, RTS and OUT2
; up and the interrupt on, so the mouse's "M" comes in
;   In:       DS = SEL_KDATA
;   Out:      nothing
;   Destroys: AL, DX
; ----------------------------------------------------------------------------
mouse_tick:
        cmp byte [mouse_reset_left], 0
        je .done
        dec byte [mouse_reset_left]
        jnz .done
        mov dx, COM1_BASE + UART_RBR
        in al, dx                       ; nothing stale
        mov dx, COM1_BASE + UART_IER
        mov al, UART_IER_RECEIVED
        out dx, al
        mov dx, COM1_BASE + UART_MCR
        mov al, UART_MCR_RUN
        out dx, al
.done:
        ret

; ----------------------------------------------------------------------------
; mouse_irq - IRQ4, and every tick: the bytes COM1 has
;   In:       DS = SEL_KDATA
;   Out:      nothing (the dispatcher sends EOI)
;   Destroys: AX, BX, CX, DX
; ----------------------------------------------------------------------------
mouse_irq:
        mov cx, MOUSE_IRQ_BYTES
.next:
        mov dx, COM1_BASE + UART_LSR
        in al, dx
        cmp al, UART_LSR_ABSENT
        je .done                        ; no UART there
        test al, UART_LSR_DATA
        jz .done
        mov dx, COM1_BASE + UART_RBR
        in al, dx
        call mouse_byte
        loop .next
.done:
        ret

; ----------------------------------------------------------------------------
; mouse_byte - one byte from the mouse
;   In:       AL = the byte; DS = SEL_KDATA
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
        ret
.pnp:
        cmp al, MOUSE_PNP_END
        jne .done
        mov byte [mouse_pnp], 0
        ret
.data:
        mov bl, [mouse_index]
        cmp bl, MOUSE_PACKET
        jb .packet
        cmp al, MOUSE_PNP_BEGIN         ; outside a packet: an identity begins?
        jne .done                       ; else no packet begun, or a fourth byte
        mov byte [mouse_pnp], 1
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
;   In:       mouse_packet; DS = SEL_KDATA
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
        mov [mouse_x], ax
        mov al, [mouse_packet]
        and al, MOUSE_PACKET_Y_HIGH
        shl al, 4
        or al, [mouse_packet + 2]
        cbw                             ; AX = the movement down
        add ax, [mouse_y]
        mov bx, MOUSE_Y_MAX
        call mouse_clamp
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
        mov [mouse_buttons], bl
        mov byte [mouse_changed], 1
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

; ----------------------------------------------------------------------------
; sys_mouse - SYS_MOUSE: whether there is a mouse, its buttons and position
;   In:       BP = the frame; DS = SEL_KDATA
;   Out:      the frame's AX = MOUSE_PRESENT or 0, BX = the buttons
;             (MOUSE_LEFT, MOUSE_RIGHT), CX = x, DX = y
;   Destroys: AX
; ----------------------------------------------------------------------------
sys_mouse:
        mov al, [mouse_present]
        xor ah, ah
        mov [bp + FRAME_AX], ax
        mov al, [mouse_buttons]
        mov [bp + FRAME_BX], ax
        mov ax, [mouse_x]
        mov [bp + FRAME_CX], ax
        mov ax, [mouse_y]
        mov [bp + FRAME_DX], ax
        mov byte [mouse_changed], 0
        ret
