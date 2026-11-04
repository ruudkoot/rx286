; ============================================================================
; rx286 - src/kernel/keymap.asm
; Scancode set 1 to ASCII, for the US layout of the AT keyboard.
;
; A pure routine: tests/unit/test_keymap.py runs it on the host for every
; scancode under every modifier. Its tables are read through CS, so it works
; whatever DS is. Keys without ASCII (the modifiers, F1-F10, the keypad's
; navigation keys) give 0; the program sees them by their scancode.
; ============================================================================

; The modifier bits of kbd_mods (keyboard.asm) that the translation reads.
KBD_SHIFT           equ 0x03            ; either Shift
KBD_LSHIFT          equ 0x01
KBD_RSHIFT          equ 0x02
KBD_CTRL            equ 0x04
KBD_ALT             equ 0x08
KBD_CAPS            equ 0x10            ; Caps Lock is on
KEYMAP_SIZE         equ 0x59            ; scancodes 00h-58h

; ----------------------------------------------------------------------------
; kbd_translate - the ASCII of a key
;   In:       AL = the scancode of a key pressed (bit 7 clear); BL = the
;             modifier bits (KBD_*)
;   Out:      AL = its ASCII, or 0 for a key that has none
;   Destroys: nothing
; ----------------------------------------------------------------------------
kbd_translate:
        push bx
        push cx
        cmp al, KEYMAP_SIZE
        jae .none
        test bl, KBD_ALT
        jnz .none                       ; Alt+key: no ASCII, only the scancode
        mov cl, bl                      ; CL = the modifiers
        xor bh, bh
        mov bl, al                      ; BX = the scancode
        mov al, [cs:keymap_plain + bx]
        xor ch, ch                      ; CH = 1 if the shifted table applies
        test cl, KBD_SHIFT
        jz .caps
        mov ch, 1
.caps:
        test cl, KBD_CAPS
        jz .pick
        cmp al, 'a'
        jb .pick
        cmp al, 'z'
        ja .pick
        xor ch, 1                       ; Caps Lock swaps Shift, for letters only
.pick:
        test ch, ch
        jz .ctrl
        mov al, [cs:keymap_shifted + bx]
.ctrl:
        test cl, KBD_CTRL
        jz .done
        ; Ctrl: letters and @[\]^_ become the control characters 00h-1Fh.
        cmp al, 'a'
        jb .upper
        cmp al, 'z'
        jbe .control
        jmp .none
.upper:
        cmp al, '@'
        jb .none
        cmp al, '_'
        ja .none
.control:
        and al, 0x1F
        jmp .done
.none:
        xor al, al
.done:
        pop cx
        pop bx
        ret

keymap_plain    db 0, 0x1B, "1234567890-=", 0x08, 0x09              ; 00h-0Fh
        db "qwertyuiop[]", 0x0D, 0, "as"                     ; 10h-1Fh
        db "dfghjkl;'`", 0, "\zxcv"                          ; 20h-2Fh
        db "bnm,./", 0, "*", 0, " ", 0                       ; 30h-3Ah (3Ah Caps Lock)
        db 0, 0, 0, 0, 0, 0, 0, 0, 0, 0                      ; 3Bh-44h F1-F10
        db 0, 0, 0, 0, 0, "-", 0, 0, 0, "+", 0, 0, 0, 0, 0   ; 45h-53h keypad
        db 0, 0, 0, 0, 0                                     ; 54h-58h
keymap_shifted  db 0, 0x1B, "!@#$%^&*()_+", 0x08, 0x09
        db "QWERTYUIOP{}", 0x0D, 0, "AS"
        db "DFGHJKL:", '"', "~", 0, "|ZXCV"
        db "BNM<>?", 0, "*", 0, " ", 0
        db 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
        db 0, 0, 0, 0, 0, "-", 0, 0, 0, "+", 0, 0, 0, 0, 0
        db 0, 0, 0, 0, 0
keymap_end:

; Both tables must be KEYMAP_SIZE bytes: a negative TIMES stops the build.
        times KEYMAP_SIZE - (keymap_shifted - keymap_plain) db 0
        times KEYMAP_SIZE - (keymap_end - keymap_shifted) db 0
        times (keymap_shifted - keymap_plain) - KEYMAP_SIZE db 0
        times (keymap_end - keymap_shifted) - KEYMAP_SIZE db 0
