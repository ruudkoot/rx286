; ============================================================================
; rx286 - src/boot-loader/boot-loader.asm
; Stub loader (M2): proves the boot sector found and ran it. M3 replaces it.
; ============================================================================

cpu 286
bits 16
%include "build.inc"
%include "ports.inc"
%include "layout.inc"

        org LOADER_PHYS

        jmp short start
        dw LOADER_MAGIC

; ----------------------------------------------------------------------------
; start - print one line on COM1 and end the test
;   In:       DL = boot drive
;   Out:      does not return
;   Destroys: everything
; ----------------------------------------------------------------------------
start:
        mov si, message
.next:
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
        jmp .next
.done:
%ifdef WITH_TEST_HOOKS
        mov dx, COM1_BASE + UART_LSR
.drain:
        in al, dx
        test al, UART_LSR_TEMT
        jz .drain
        mov dx, BOCHS_SHUTDOWN_PORT
        mov si, shutdown
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

message         db "rx286 loader stub", 10, "TEST END", 10, 0
shutdown        db "Shutdown", 0
        times LOADER_SECTORS * 512 - ($ - $$) db 0
