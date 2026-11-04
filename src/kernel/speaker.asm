; ============================================================================
; rx286 - src/kernel/speaker.asm
; The speaker: timer channel 2 as a square wave, gated to the speaker
; through system port B; SYS_SOUND (devices roadmap D3).
;
; A sound is synchronous, like a disk's sector: the call programs channel 2
; to the frequency, opens the gate, sleeps for the ticks asked with
; interrupts on, and closes the gate. Ctrl+Break ends it at once. A
; frequency of 0 is a rest: silence for the ticks, which a program may use
; to wait. Port B is changed bit by bit, the others written back as read,
; as IBM asks (5-10) and its BIOS does. Channel 2 is never used otherwise.
; ============================================================================

; ----------------------------------------------------------------------------
; sys_sound - SYS_SOUND: a tone of BX hertz, or a rest, for CX ticks
;   In:       BP = the frame (BX the frequency, 0 for a rest; CX the ticks);
;             DS = ES = SEL_KDATA
;   Out:      nothing; or an error (E_INVAL)
;   Destroys: AX, BX, CX, DX, SI, DI
; ----------------------------------------------------------------------------
sys_sound:
        mov bx, [bp + FRAME_BX]
        mov cx, [bp + FRAME_CX]
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
        call test_sound
%endif
.wait:
        jcxz .done
        mov si, restart_pending         ; Ctrl+Break ends it
        call ksleep_until
.done:
        call speaker_off
%ifdef TEST_SOUND
        call test_silence
%endif
        ret
.invalid:
        mov ax, E_INVAL
        jmp sys_fail

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
