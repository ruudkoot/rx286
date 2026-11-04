; ============================================================================
; rx286 - src/kernel/keyboard.asm
; The keyboard: the 8042's IRQ1, the modifiers, a ring of keys, and the two
; keys the kernel keeps for itself (Ctrl+Break, Ctrl+Alt+Del).
;
; The 8042 translates the AT keyboard's codes to set 1 (its command byte,
; written here: roadmap D14). Each key pressed is put in a ring of
; KBD_RING_SIZE as its ASCII (keymap.asm) and scancode; a full ring drops
; the key. The E0h prefix of an enhanced keyboard is followed for the right
; Ctrl and Alt, the arrows, Delete and Ctrl+Pause; the E1h sequence (Pause)
; is skipped. Ctrl+Break (Ctrl+Scroll Lock on the AT keyboard, Ctrl+Pause on
; an enhanced one) restarts the program (D11); Ctrl+Alt+Del resets the
; machine (D21). The keyboard's LEDs are left alone.
; ============================================================================

KBD_RING_SIZE       equ 16              ; a power of two
KBD_E1_SEQUENCE     equ 5               ; the bytes after E1h in Pause's sequence
SC_RELEASE          equ 0x80            ; set in a key's release code
SC_PREFIX_E0        equ 0xE0
SC_PREFIX_E1        equ 0xE1
SC_CTRL             equ 0x1D
SC_LSHIFT           equ 0x2A
SC_RSHIFT           equ 0x36
SC_ALT              equ 0x38
SC_CAPS_LOCK        equ 0x3A
SC_SCROLL_LOCK      equ 0x46            ; Break, with Ctrl, on the AT keyboard
SC_DELETE           equ 0x53            ; keypad . and Del
SC_SYSRQ            equ 0x54            ; the AT keyboard's Sys Req
KBC_FLUSH_LIMIT     equ 32              ; bytes read at most when emptying the 8042
KBD_WAIT_FOREVER    equ 1               ; kbd_waiting: a key, however long it takes
KBD_WAIT_TIMED      equ 2               ; a key, or the time runs out (SYS_WAIT)

begin_kdata
kbd_ring            times KBD_RING_SIZE dw 0
kbd_head            db 0                ; the next key to take
kbd_tail            db 0                ; where the next key goes
kbd_mods            db 0                ; KBD_* of keymap.asm
kbd_e0              db 0                ; 1 after an E0h prefix
kbd_e1_skip         db 0                ; bytes of Pause's sequence still to skip
kbd_waiting         db 0                ; KBD_WAIT_*: what a test build may type into
kbd_dropped         dw 0                ; keys lost to a full ring
msg_ctrl_break      db "Ctrl+Break: the program starts again", 0
msg_reset           db "Ctrl+Alt+Del: resetting", 0
end_kdata

; ----------------------------------------------------------------------------
; kbd_init - the 8042's command byte, and nothing left in its buffer
;   In:       interrupts off; DS = SEL_KDATA
;   Out:      nothing
;   Destroys: AX, CX
; ----------------------------------------------------------------------------
kbd_init:
        call kbd_flush
        call kbc_wait_input
        mov al, KBC_CMD_WRITE_CB
        out KBC_COMMAND, al
        call kbc_wait_input
        mov al, KBC_COMMAND_BYTE
        out KBC_DATA, al
        call kbd_flush
        mov byte [kbd_mods], 0
        ret

; ----------------------------------------------------------------------------
; kbd_flush - read and drop whatever waits in the 8042's output buffer
;   In:       nothing
;   Out:      nothing
;   Destroys: AX, CX
; ----------------------------------------------------------------------------
kbd_flush:
        mov cx, KBC_FLUSH_LIMIT
.next:
        in al, KBC_STATUS
        test al, KBC_STATUS_OBF
        jz .done
        in al, KBC_DATA
        loop .next
.done:
        ret

; ----------------------------------------------------------------------------
; kbc_wait_input - wait until the 8042 can take a byte
;   In:       nothing
;   Out:      nothing
;   Destroys: AL
; ----------------------------------------------------------------------------
kbc_wait_input:
        in al, KBC_STATUS
        test al, KBC_STATUS_IBF
        jnz kbc_wait_input
        ret

; ----------------------------------------------------------------------------
; kbd_irq - IRQ1: one byte from the keyboard
;   In:       BP = the frame; DS = ES = SEL_KDATA
;   Out:      nothing (the dispatcher sends EOI)
;   Destroys: AX, BX, CX, DX, SI, DI
; ----------------------------------------------------------------------------
kbd_irq:
        in al, KBC_DATA
        ; falls through

; ----------------------------------------------------------------------------
; kbd_byte - one byte from the keyboard, as IRQ1 reads it from port 60h
;   In:       AL = the byte; BP = an interrupt's frame; DS = ES = SEL_KDATA
;   Out:      nothing
;   Destroys: AX, BX, CX, DX, SI, DI
; ----------------------------------------------------------------------------
kbd_byte:
        cmp byte [kbd_e1_skip], 0
        jne .skip
        cmp al, SC_PREFIX_E1
        je .pause
        cmp al, SC_PREFIX_E0
        je .prefix
        cmp byte [kbd_e0], 0
        jne .extended
        jmp kbd_scancode
.skip:
        dec byte [kbd_e1_skip]
        ret
.pause:
        mov byte [kbd_e1_skip], KBD_E1_SEQUENCE
        ret
.prefix:
        mov byte [kbd_e0], 1
        ret
.extended:
        mov byte [kbd_e0], 0
        mov ah, al
        and ah, ~SC_RELEASE             ; AH = the key, AL = the byte
        cmp ah, SC_CTRL                 ; the right Ctrl
        je kbd_scancode
        cmp ah, SC_ALT                  ; the right Alt
        je kbd_scancode
        cmp ah, SC_SCROLL_LOCK          ; Ctrl+Pause sends E0h 46h
        je kbd_scancode
        cmp ah, SC_DELETE
        je kbd_scancode
        cmp ah, SC_UP
        je .navigation
        cmp ah, SC_DOWN
        je .navigation
        cmp ah, SC_LEFT
        je .navigation
        cmp ah, SC_RIGHT
        je .navigation
        ret                             ; the other extended keys: ignored
.navigation:
        test al, SC_RELEASE
        jnz .done
        xor al, al                      ; no ASCII; the scancode in AH
        jmp kbd_put
.done:
        ret

; ----------------------------------------------------------------------------
; kbd_scancode - a set-1 byte: the modifiers, the kernel's keys, or a key
;   In:       AL = the byte; BP = the frame; DS = SEL_KDATA
;   Out:      nothing
;   Destroys: AX, BX
; ----------------------------------------------------------------------------
kbd_scancode:
        mov ah, al
        and ah, ~SC_RELEASE             ; AH = the key
        mov bl, KBD_LSHIFT
        cmp ah, SC_LSHIFT
        je .modifier
        mov bl, KBD_RSHIFT
        cmp ah, SC_RSHIFT
        je .modifier
        mov bl, KBD_CTRL
        cmp ah, SC_CTRL
        je .modifier
        mov bl, KBD_ALT
        cmp ah, SC_ALT
        je .modifier
        test al, SC_RELEASE
        jnz .done                       ; a key released: nothing more
        cmp ah, SC_CAPS_LOCK
        je .caps
        cmp ah, SC_SCROLL_LOCK
        je .scroll_lock
        cmp ah, SC_DELETE
        je .delete
%ifdef WITH_CHECKS
        cmp ah, SC_SYSRQ                ; debug and test builds: the threads
        je thread_dump
%endif
.translate:
        mov bl, [kbd_mods]
        call kbd_translate              ; AL = ASCII, AH = scancode
        jmp kbd_put
.modifier:
        test al, SC_RELEASE
        jnz .release
        or [kbd_mods], bl
        ret
.release:
        not bl
        and [kbd_mods], bl
        ret
.caps:
        xor byte [kbd_mods], KBD_CAPS
        ret
.scroll_lock:
        test byte [kbd_mods], KBD_CTRL
        jz .done
        jmp kbd_ctrl_break
.delete:
        mov bl, [kbd_mods]
        and bl, KBD_CTRL | KBD_ALT
        cmp bl, KBD_CTRL | KBD_ALT
        jne .translate
        jmp kbd_reset
.done:
        ret

; ----------------------------------------------------------------------------
; kbd_put - add a key to the ring, or drop it if the ring is full
;   In:       AL = ASCII, AH = scancode; DS = SEL_KDATA
;   Out:      nothing
;   Destroys: BX
; ----------------------------------------------------------------------------
kbd_put:
        mov bl, [kbd_tail]
        inc bl
        and bl, KBD_RING_SIZE - 1
        cmp bl, [kbd_head]
        je .full
        xchg bl, [kbd_tail]             ; BL = the old tail, where the key goes
        xor bh, bh
        shl bx, 1
        mov [kbd_ring + bx], ax
        ret
.full:
        inc word [kbd_dropped]
        ret

; ----------------------------------------------------------------------------
; kbd_get - take the oldest key from the ring
;   In:       DS = SEL_KDATA; interrupts off
;   Out:      ZF clear and AX = the key (AL ASCII, AH scancode); ZF set and
;             AX = 0 if the ring is empty
;   Destroys: nothing
; ----------------------------------------------------------------------------
kbd_get:
        push bx
        mov bl, [kbd_head]
        cmp bl, [kbd_tail]
        je .empty
        xor bh, bh
        shl bx, 1
        mov ax, [kbd_ring + bx]
        shr bx, 1
        inc bl
        and bl, KBD_RING_SIZE - 1
        mov [kbd_head], bl
        or bl, 1                        ; ZF clear
        pop bx
        ret
.empty:
        xor ax, ax                      ; ZF set
        pop bx
        ret

; ----------------------------------------------------------------------------
; kbd_wait_key - wait for a key, sleeping with interrupts on (D15)
;   In:       DS = SEL_KDATA; interrupts off
;   Out:      ZF clear and AX = the key; or ZF set and AX = 0 if a restart
;             of the program was asked for while waiting
;   Destroys: nothing
; ----------------------------------------------------------------------------
kbd_wait_key:
        call kbd_get
        jnz .done
        cmp byte [restart_pending], 0
        jne .abandon
        mov byte [kbd_waiting], KBD_WAIT_FOREVER
        call kwait_unlocked             ; until an interrupt; other threads run
        mov byte [kbd_waiting], 0
        jmp kbd_wait_key
.abandon:
        xor ax, ax                      ; ZF set
.done:
        ret

; ----------------------------------------------------------------------------
; kbd_clear - empty the ring (a restarted program starts with no keys)
;   In:       DS = SEL_KDATA; interrupts off
;   Out:      nothing
;   Destroys: nothing
; ----------------------------------------------------------------------------
kbd_clear:
        push ax
        mov al, [kbd_tail]
        mov [kbd_head], al
        pop ax
        ret

; ----------------------------------------------------------------------------
; kbd_ctrl_break - restart the program now, or when its system call returns
;   In:       BP = the frame of IRQ1; DS = SEL_KDATA
;   Out:      nothing
;   Destroys: AX, BX, CX, DX, SI, DI
; ----------------------------------------------------------------------------
kbd_ctrl_break:
        push si
        mov si, msg_ctrl_break
        call klog
        pop si
        mov bx, [fg_thread]             ; the program the keys are for
        call thread_restart             ; (out of any IPC it waits in)
        cmp bx, [cur_thread]
        jne .later                      ; another thread runs: when it next runs
        test byte [bp + FRAME_CS], CPL_MASK
        jz .later                       ; in the kernel: on the way back to ring 3
        jmp restart_program
.later:
        ret

; ----------------------------------------------------------------------------
; kbd_reset - Ctrl+Alt+Del: a soft reset through the 8042 (IBM 1-42)
;   In:       DS = SEL_KDATA
;   Out:      does not return
;   Destroys: everything
; ----------------------------------------------------------------------------
kbd_reset:
        mov si, msg_reset
        call klog
%ifdef WITH_SERIAL
        call com_drain
%endif
        cli
        mov al, CMOS_SHUTDOWN
        out CMOS_INDEX, al
        xor al, al                      ; shutdown byte 0: a soft reset (the BIOS listing's codes)
        out CMOS_DATA, al
        call kbc_wait_input
        mov al, KBC_CMD_PULSE_RESET
        out KBC_COMMAND, al
.wait:
        hlt
        jmp .wait
