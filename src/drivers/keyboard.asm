; ============================================================================
; rx286 - src/drivers/keyboard.asm
; The keyboard driver (roadmap l4.md L8): the 8042, IRQ1, the modifiers, a
; ring of keys, and the three keys that are not the program's; in ring 1
; with IOPL 1.
;
; The 8042 translates the AT keyboard's codes to set 1 (its command byte,
; written here: roadmap D14). Each key pressed is put in a ring of
; KBD_RING_SIZE as its ASCII (src/lib/keymap.asm) and scancode; a full ring
; drops the key, and counts it (DRV_KBD_PEEK's CX, P15). The E0h prefix of
; an enhanced keyboard is followed for the right Ctrl and Alt (each its own
; bit, so that letting one go keeps the other: P15), the grey arrows,
; Home, End, Insert, Delete, Page Up and Page Down, the keypad's Enter and
; '/', and Ctrl+Pause; the E1h sequence (Pause) is skipped. Caps Lock turns
; over once a press, not with each of its repeats (P15). The keyboard's
; LEDs are left alone.
;
; Whatever the keyboard sent - a key, a release, a modifier - is signalled
; on the notification of the OS server's thread for the foreground program
; (DRV_SLOT_KEYS), which then looks for a key again: a wait for a key sleeps
; until the keyboard does something (os-server.md P5).
;
; Ctrl+Break (Ctrl+Scroll Lock on the AT keyboard, Ctrl+Pause on an
; enhanced one) is never a call (l4.md X13): the driver signals the OS
; server's control notification, and the OS server restarts the foreground
; program. Ctrl+Alt+Del resets the machine through the 8042, as the kernel
; did. Sys Req, in debug and test builds, asks the kernel for its thread
; dump. IRQ1 comes as the root bound it (DRV_IRQ_BIT); the driver reads what
; the 8042 has, then acknowledges the line. In MAME's test builds the
; script's keys come from the kernel (KCALL_TEST), since IBM's 8042 cannot
; take them. The OS server asks for keys with DRV_KBD_GET, looks with
; DRV_KBD_PEEK, and drops them with DRV_KBD_CLEAR when it restarts a program.
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
CONTROL             equ SLOT(DRV_SLOT_DEVICE)
KEYS                equ SLOT(DRV_SLOT_KEYS)
KBD_RING_SIZE       equ 16              ; a power of two
KBD_E1_SEQUENCE     equ 5               ; the bytes after E1h in Pause's sequence
KBD_IRQ_BYTES       equ 16              ; bytes taken at most in one look
KBD_RESET_TICKS     equ 2               ; for the log to have said so, before a reset
SC_RELEASE          equ 0x80            ; set in a key's release code
SC_PREFIX_E0        equ 0xE0
SC_PREFIX_E1        equ 0xE1
SC_CTRL             equ 0x1D
SC_F1               equ 0x3B
SC_F8               equ 0x42
SC_ALT_F1           equ 0x68            ; Alt+F1's, as the BIOS gives it
SC_LSHIFT           equ 0x2A
SC_RSHIFT           equ 0x36
SC_ALT              equ 0x38
SC_CAPS_LOCK        equ 0x3A
SC_SCROLL_LOCK      equ 0x46            ; Break, with Ctrl, on the AT keyboard
SC_DELETE           equ 0x53            ; keypad . and Del
SC_SYSRQ            equ 0x54            ; the AT keyboard's Sys Req
SC_HOME             equ 0x47            ; the grey keys after E0h, as the keypad's
SC_PGUP             equ 0x49
SC_END              equ 0x4F
SC_PGDN             equ 0x51
SC_INSERT           equ 0x52
SC_ENTER            equ 0x1C            ; the keypad's Enter after E0h
SC_SLASH            equ 0x35            ; and its '/'
KBC_FLUSH_LIMIT     equ 32              ; bytes read at most when emptying the 8042
KBC_WAIT_READS      equ 0xFFFF          ; the 8042's status read at most, waiting for it
                                        ;    to take a byte: 60 ms or so (P15)

begin_udata
kbd_ring            times KBD_RING_SIZE dw 0
kbd_head            db 0                ; the next key to take
kbd_tail            db 0                ; where the next key goes
kbd_mods            db 0                ; KBD_* of keymap.asm (the left Ctrl and Alt's)
kbd_right           db 0                ; the right Ctrl and Alt's, KBD_CTRL and KBD_ALT
kbd_caps_held       db 0                ; 1 from Caps Lock's press to its release
kbd_e0              db 0                ; 1 after an E0h prefix
kbd_e1_skip         db 0                ; bytes of Pause's sequence still to skip
kbd_dropped         dw 0                ; keys lost to a full ring since the last
                                        ;    DRV_KBD_PEEK; it stays at FFFFh
msg_reset           db "rx286: Ctrl+Alt+Del: resetting", CHAR_LF
msg_reset_end:
end_udata

; ----------------------------------------------------------------------------
; entry - the 8042's command byte, then serve
;   In:       its start: DS = ES = its data, IOPL 1
;   Out:      does not return
;   Destroys: everything
; ----------------------------------------------------------------------------
entry:
        cld
        call kbd_flush
        call kbc_wait_input
        mov al, KBC_CMD_WRITE_CB
        out KBC_COMMAND, al
        call kbc_wait_input
        mov al, KBC_COMMAND_BYTE
        out KBC_DATA, al
        call kbd_flush
%ifdef WITH_TEST_HOOKS
        mov al, TEST_KEYS_READY         ; a test's keys may come now
        kcall KCALL_TEST
%endif
        ; falls through

; ----------------------------------------------------------------------------
; serve - the keyboard's bytes as they come, and the OS server's questions
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
        xor bx, bx
        cmp al, DRV_KBD_GET
        je .get
        cmp al, DRV_KBD_PEEK
        je .peek
        cmp al, DRV_KBD_CLEAR
        jne .unknown
        mov al, [kbd_tail]
        mov [kbd_head], al
        jmp .reply
.unknown:
        mov bx, E_INVAL                 ; a call it does not know (P15)
        jmp .reply
.peek:
        xor cx, cx                      ; CX = the keys dropped since (P15)
        xchg cx, [kbd_dropped]
        mov al, [kbd_head]
        cmp al, [kbd_tail]
        je .reply
        inc bx
        jmp .reply
.get:
        call kbd_get                    ; ZF clear and AX = the key
        jz .reply
        mov cx, ax
        inc bx
.reply:
        mov dx, EP
        xor bp, bp
        kcall KCALL_REPLY_RECV
        jmp .message
.news:
        push bx                         ; the bits
        call kbd_take
        mov dx, KEYS                    ; the OS server looks again (no OS server:
        kcall KCALL_SIGNAL              ; KE_CAP, nothing)
        pop bx
        test bx, DRV_IRQ_BIT
        jz serve
        mov dx, IRQ
        mov al, IRQ_ACK
        kcall KCALL_IRQ                 ; the line on again
        jmp serve

; ----------------------------------------------------------------------------
; kbd_take - the bytes the 8042 has (and, in MAME's test builds, the keys a
; script typed)
;   In:       DS = its data
;   Out:      nothing
;   Destroys: AX, BX, CX, DX, SI, DI
; ----------------------------------------------------------------------------
kbd_take:
        mov cx, KBD_IRQ_BYTES
.next:
        in al, KBC_STATUS
        test al, KBC_STATUS_OBF
        jz .script
        in al, KBC_DATA
        push cx
        call kbd_byte
        pop cx
        loop .next
.script:
%ifdef WITH_TEST_HOOKS
        mov al, TEST_KEY_BYTE
        kcall KCALL_TEST
        jc .done
        mov al, bl
        call kbd_byte
        jmp .script
.done:
%endif
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
; kbc_wait_input - wait until the 8042 can take a byte, KBC_WAIT_READS
; reads at most: a controller that never takes one is not waited for for
; ever (P15)
;   In:       nothing
;   Out:      CF clear if it can; CF set if it never could
;   Destroys: AL
; ----------------------------------------------------------------------------
kbc_wait_input:
        push cx
        mov cx, KBC_WAIT_READS
.read:
        in al, KBC_STATUS
        test al, KBC_STATUS_IBF
        jz .ready
        loop .read
        pop cx
        stc
        ret
.ready:
        pop cx
        clc
        ret

; ----------------------------------------------------------------------------
; kbd_byte - one byte from the keyboard, as port 60h gives it
;   In:       AL = the byte; DS = its data
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
        mov bl, KBD_CTRL
        cmp ah, SC_CTRL                 ; the right Ctrl
        je .right
        mov bl, KBD_ALT
        cmp ah, SC_ALT                  ; the right Alt
        je .right
        cmp ah, SC_SCROLL_LOCK          ; Ctrl+Pause sends E0h 46h
        je kbd_scancode
        cmp ah, SC_DELETE
        je kbd_scancode
        cmp ah, SC_ENTER                ; the keypad's Enter and '/' (P15)
        je kbd_scancode
        cmp ah, SC_SLASH
        je kbd_scancode
        cmp ah, SC_UP
        je .navigation
        cmp ah, SC_DOWN
        je .navigation
        cmp ah, SC_LEFT
        je .navigation
        cmp ah, SC_RIGHT
        je .navigation
        cmp ah, SC_HOME                 ; the grey keys (P15)
        je .navigation
        cmp ah, SC_END
        je .navigation
        cmp ah, SC_INSERT
        je .navigation
        cmp ah, SC_PGUP
        je .navigation
        cmp ah, SC_PGDN
        je .navigation
        ret                             ; the other extended keys: ignored
.right:
        test al, SC_RELEASE             ; the right Ctrl or Alt: a bit of its own
        jnz .right_up
        or [kbd_right], bl
        ret
.right_up:
        not bl
        and [kbd_right], bl
        ret
.navigation:
        test al, SC_RELEASE
        jnz .done
        xor al, al                      ; no ASCII; the scancode in AH
        jmp kbd_put
.done:
        ret

; ----------------------------------------------------------------------------
; kbd_scancode - a set-1 byte: the modifiers, the keys that are not the
; program's, or a key
;   In:       AL = the byte; DS = its data
;   Out:      nothing
;   Destroys: AX, BX, CX, DX, SI, DI
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
        cmp ah, SC_CAPS_LOCK
        je .caps
        test al, SC_RELEASE
        jnz .done                       ; a key released: nothing more
        cmp ah, SC_SCROLL_LOCK
        je .scroll_lock
        cmp ah, SC_DELETE
        je .delete
        cmp ah, SC_SYSRQ                ; debug and test builds: the threads
        je .sysrq
.translate:
        mov bl, [kbd_mods]
        or bl, [kbd_right]              ; either side's Ctrl and Alt
        call kbd_translate              ; AL = ASCII, AH = scancode
        test bl, KBD_ALT
        jz .put
        cmp ah, SC_F1                   ; Alt+F1 to F8: 68h to 6Fh, as the BIOS
        jb .put                         ; has them (os-server.md P11)
        cmp ah, SC_F8
        ja .put
        add ah, SC_ALT_F1 - SC_F1
.put:
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
        test al, SC_RELEASE
        jnz .caps_up
        cmp byte [kbd_caps_held], 0
        jne .done                       ; a repeat of a key held: nothing (P15)
        mov byte [kbd_caps_held], 1
        xor byte [kbd_mods], KBD_CAPS
        ret
.caps_up:
        mov byte [kbd_caps_held], 0
        ret
.scroll_lock:
        mov bl, [kbd_mods]
        or bl, [kbd_right]
        test bl, KBD_CTRL
        jz .done
        mov dx, CONTROL                 ; Ctrl+Break: the OS server's
        kcall KCALL_SIGNAL
        ret
.delete:
        mov bl, [kbd_mods]
        or bl, [kbd_right]
        and bl, KBD_CTRL | KBD_ALT
        cmp bl, KBD_CTRL | KBD_ALT
        jne .translate
        jmp kbd_reset
.sysrq:
        mov al, TEST_DUMP
        kcall KCALL_TEST                ; (release builds: KE_NOSYS, nothing)
.done:
        ret

; ----------------------------------------------------------------------------
; kbd_put - add a key to the ring, or drop it if the ring is full
;   In:       AL = ASCII, AH = scancode; DS = its data
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
        inc word [kbd_dropped]          ; (staying at FFFFh, not wrapping to none)
        jnz .counted
        dec word [kbd_dropped]
.counted:
        ret

; ----------------------------------------------------------------------------
; kbd_get - take the oldest key from the ring
;   In:       DS = its data
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
; kbd_reset - Ctrl+Alt+Del: a soft reset through the 8042 (IBM 1-42), once
; the log has said so
;   In:       DS = its data
;   Out:      does not return
;   Destroys: everything
; ----------------------------------------------------------------------------
kbd_reset:
        mov si, msg_reset
        mov cx, msg_reset_end - msg_reset
        kcall KCALL_LOG
        mov dx, NOTIFY
        mov cx, KBD_RESET_TICKS
        kcall KCALL_TIMER
.wait_log:
        mov dx, NOTIFY                  ; until the timer's bit: the keys' (MAME's
        kcall KCALL_RECV                ;    test builds) are not the time (P15)
        jc .wait_log
        test bx, DRV_TIMER_BIT
        jz .wait_log
        cli
        mov al, CMOS_SHUTDOWN
        out CMOS_INDEX, al
        xor al, al                      ; shutdown byte 0: a soft reset (the BIOS listing's codes)
        out CMOS_DATA, al
        call kbc_wait_input
        mov al, KBC_CMD_PULSE_RESET
        out KBC_COMMAND, al
.wait:
        jmp .wait

%include "keymap.asm"
