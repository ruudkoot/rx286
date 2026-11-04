; ============================================================================
; rx286 - src/kernel/gameport.asm
; The game port at 201h: two joysticks' four buttons and four axes;
; SYS_JOYSTICK (devices roadmap D4).
;
; The buttons are read as they are. Each axis is a one-shot: a write to the
; port starts all four, and an axis's bit stays 1 for a time that grows with
; the resistance of its joystick (about 24 us plus 11 us a kilohm). The
; kernel times them with timer channel 0, whose count it latches
; (pit_elapsed), and gives each axis in microseconds. Interrupts stay off
; while it times, JOY_AXIS_MAX_US at most, well under a tick: an axis whose
; bit does not rise at once, or has not fallen by then, has no joystick
; behind it, and is JOY_ABSENT.
; ============================================================================

JOY_AXES            equ 4
JOY_LIMIT_CLOCKS    equ JOY_AXIS_MAX_US * (PIT_INPUT_HZ / 1000) / 1000
JOY_NS_PER_CLOCK    equ 1000000000 / PIT_INPUT_HZ      ; 838

begin_kdata
joy_times           times JOY_AXES dw 0
end_kdata

; ----------------------------------------------------------------------------
; sys_joystick - SYS_JOYSTICK: the buttons pressed and the four axes
;   In:       BP = the frame; DS = ES = SEL_KDATA
;   Out:      the frame's AL = the buttons (bit n set: button n pressed), AH
;             = 0; BX, CX, DX, SI = axes 0-3 in microseconds, or JOY_ABSENT
;   Destroys: AX, BX, CX, DX, SI, DI
; ----------------------------------------------------------------------------
sys_joystick:
        mov dx, GAME_PORT
        in al, dx
        not al
        shr al, GAME_PORT_BUTTON_SHIFT
        xor ah, ah
        mov [bp + FRAME_AX], ax
        call joy_axes
        mov ax, [joy_times]
        mov [bp + FRAME_BX], ax
        mov ax, [joy_times + 2]
        mov [bp + FRAME_CX], ax
        mov ax, [joy_times + 4]
        mov [bp + FRAME_DX], ax
        mov ax, [joy_times + 6]
        mov [bp + FRAME_SI], ax
        ret

; ----------------------------------------------------------------------------
; joy_axes - start the one-shots and time each axis into joy_times
;   In:       DS = ES = SEL_KDATA; interrupts off
;   Out:      joy_times
;   Destroys: AX, BX, CX, DX, SI, DI
; ----------------------------------------------------------------------------
joy_axes:
        mov di, joy_times
        mov ax, JOY_ABSENT
        mov cx, JOY_AXES
        rep stosw
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
        ret
