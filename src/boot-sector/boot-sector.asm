; ============================================================================
; rx286 - src/boot-sector/boot-sector.asm
; Placeholder boot sector (M1): proves the image, the runner and the checks.
;
; It prints a line on COM1 through the BIOS and, in test builds, ends Bochs
; through its shutdown port. M2 replaces it with the real boot sector.
; ============================================================================

cpu 286
bits 16
%include "build.inc"
%include "ports.inc"
%include "layout.inc"

        org BOOT_SECTOR_PHYS

        jmp short start
        nop
        times 0x3E - ($ - $$) db 0      ; the BPB, written by mformat -B

; ----------------------------------------------------------------------------
; start - print the placeholder's line on COM1, then stop
;   In:       DL = boot drive (from the BIOS; unused)
;   Out:      does not return
;   Destroys: everything
; ----------------------------------------------------------------------------
start:
        cli
        xor ax, ax
        mov ds, ax
        mov ss, ax
        mov sp, LOADER_STACK_TOP
        mov ah, 0x00                    ; INT 14h: initialise COM1, 9600 8N1
        mov al, 0xE3
        xor dx, dx
        int 0x14
        mov si, message
.next:
        lodsb
        test al, al
        jz .done
        mov ah, 0x01                    ; INT 14h: send AL on COM1
        xor dx, dx
        int 0x14
        jmp .next
.done:
%ifdef WITH_TEST_HOOKS
        mov dx, COM1_BASE + UART_LSR    ; let the last byte go before Bochs ends
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

message         db "rx286 placeholder boot sector", 13, 10, "TEST END", 13, 10, 0
shutdown        db "Shutdown", 0

        times 510 - ($ - $$) db 0
        dw 0xAA55
