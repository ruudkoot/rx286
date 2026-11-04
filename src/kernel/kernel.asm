; ============================================================================
; rx286 - src/kernel/kernel.asm
; Stub kernel (M3): proves the loader brought all of KERNEL.BIN and handed
; over with interrupts off. M4 replaces it.
; ============================================================================

cpu 286
bits 16
%include "build.inc"
%include "ports.inc"
%include "layout.inc"

; ----------------------------------------------------------------------------
; start - check the image's last word and the flags, report on COM1
;   In:       CS = KERNEL_SEG, IP = 0
;   Out:      does not return
;   Destroys: everything
; ----------------------------------------------------------------------------
start:
        mov ax, cs
        mov ds, ax
        mov si, msg_complete
        cmp word [KERNEL_FILE_SIZE - 2], 0xA55A
        je .size_ok
        mov si, msg_incomplete
.size_ok:
        call send
        pushf
        pop ax
        mov si, msg_if_off
        test ax, 0x0200
        jz .if_ok
        mov si, msg_if_on
.if_ok:
        call send
%ifdef WITH_TEST_HOOKS
        mov si, msg_end
        call send
        mov dx, COM1_BASE + UART_LSR
.drain:
        in al, dx
        test al, UART_LSR_TEMT
        jz .drain
        mov dx, BOCHS_SHUTDOWN_PORT
        mov si, msg_shutdown
.shut:
        lodsb
        test al, al
        jz .halt
        out dx, al
        jmp .shut
%endif
.halt:
        hlt
        jmp .halt

; ----------------------------------------------------------------------------
; send - a zero-terminated string on COM1
;   In:       DS:SI = the string
;   Out:      nothing
;   Destroys: AX, DX, SI
; ----------------------------------------------------------------------------
send:
        lodsb
        test al, al
        jz .done
        mov ah, al
        mov dx, COM1_BASE + UART_LSR
.wait:
        in al, dx
        test al, UART_LSR_THRE
        jz .wait
        mov al, ah
        mov dx, COM1_BASE + UART_THR
        out dx, al
        jmp send
.done:
        ret

msg_complete    db "rx286 kernel stub: all of KERNEL.BIN is here", 10, 0
msg_incomplete  db "rx286 kernel stub: KERNEL.BIN is incomplete", 10, 0
msg_if_off      db "rx286 kernel stub: interrupts are off", 10, 0
msg_if_on       db "rx286 kernel stub: interrupts are ON", 10, 0
msg_end         db "TEST END", 10, 0
msg_shutdown    db "Shutdown", 0

        times KERNEL_FILE_SIZE - 2 - ($ - $$) db 0
        dw 0xA55A                       ; the last word: the loader brought it all
        incbin USER_BIN, 0, 0           ; the program arrives in M4
