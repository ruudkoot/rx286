; ============================================================================
; rx286 - src/boot-sector/boot-sector.asm
; Sector 0 of the floppy: loads the loader from the reserved sectors 1-3.
;
; The BIOS loads this sector to 0000:7C00h and jumps here with the boot
; drive in DL. mformat writes the BPB (bytes 3-61) around the code. The
; loader is in the FAT's reserved sectors (roadmap D3), at cylinder 0, head
; 0, sectors 2-4 on any floppy, so no file system is read here. The loader
; must start with a short jump over the word LOADER_MAGIC; anything else is
; "no loader". On an error the boot sector prints a message (and copies it
; to the log in debug and test builds), waits for a key and asks the BIOS to
; boot again (INT 19h).
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
; start - load the loader and jump to it
;   In:       DL = boot drive (from the BIOS)
;   Out:      does not return: jumps to 0000:LOADER_PHYS with DL kept
;   Destroys: everything
; ----------------------------------------------------------------------------
start:
        cli
        cld                             ; LODSB below counts up, whatever the BIOS left
        xor ax, ax
        mov ds, ax
        mov es, ax
        mov ss, ax
        mov sp, LOADER_STACK_TOP
        sti
        mov [boot_drive], dl
%ifdef WITH_SERIAL
        call serial_init
%endif
        mov di, BOOT_TRIES
.read:
        mov ax, 0x0200 | LOADER_SECTORS ; INT 13h AH=02h: read AL sectors
        mov bx, LOADER_PHYS             ; to ES:BX = 0000:7E00h
        mov cx, 0x0002                  ; cylinder 0, sector 2
        xor dh, dh                      ; head 0
        mov dl, [boot_drive]
        int 0x13
        jnc .loaded
        xor ah, ah                      ; INT 13h AH=00h: reset the drive
        mov dl, [boot_drive]
        int 0x13
        dec di
        jnz .read
        mov si, msg_read_error
        jmp fail
.loaded:
        cmp word [LOADER_PHYS + 2], LOADER_MAGIC
        mov si, msg_no_loader
        jne fail
        mov dl, [boot_drive]
        jmp 0:LOADER_PHYS

; ----------------------------------------------------------------------------
; fail - print a message, wait for a key, boot again
;   In:       SI = the message (zero-terminated, DS = 0)
;   Out:      does not return
;   Destroys: everything
; ----------------------------------------------------------------------------
fail:
        call print
        mov si, msg_press_key
        call print
        xor ah, ah                      ; INT 16h AH=00h: wait for a key
        int 0x16
        int 0x19                        ; boot again

; ----------------------------------------------------------------------------
; print - write a zero-terminated string on the screen (and the log)
;   In:       SI = the string, DS = 0
;   Out:      nothing
;   Destroys: AX, BX, SI, DX
; ----------------------------------------------------------------------------
print:
        lodsb
        test al, al
        jz .done
        mov ah, 0x0E                    ; INT 10h AH=0Eh: teletype
        mov bx, 0x0007                  ; page 0, light grey
        int 0x10
%ifdef WITH_SERIAL
        mov ah, al
        mov dx, LOG_PORT + UART_LSR
.wait:
        in al, dx
        test al, UART_LSR_THRE
        jz .wait
        mov al, ah
        mov dx, LOG_PORT + UART_THR
        out dx, al
%endif
        jmp print
.done:
        ret

%ifdef WITH_SERIAL
; ----------------------------------------------------------------------------
; serial_init - the log's UART at 115200, 8N1, no interrupt (debug and test builds)
;   In:       nothing
;   Out:      nothing
;   Destroys: AX, DX
; ----------------------------------------------------------------------------
serial_init:
        mov dx, LOG_PORT + UART_LCR
        mov al, UART_LCR_DLAB
        out dx, al
        mov dx, LOG_PORT + UART_DLL
        mov al, UART_DIVISOR_115200
        out dx, al
        mov dx, LOG_PORT + UART_DLM
        xor al, al
        out dx, al
        mov dx, LOG_PORT + UART_LCR
        mov al, UART_LCR_8N1
        out dx, al
        mov dx, LOG_PORT + UART_IER
        xor al, al
        out dx, al
        mov dx, LOG_PORT + UART_MCR
        mov al, UART_MCR_DTR_RTS
        out dx, al
        ret
%endif

msg_read_error  db "rx286: cannot read the loader", 13, 10, 0
msg_no_loader   db "rx286: no loader on this disk", 13, 10, 0
msg_press_key   db "Press a key to try again.", 13, 10, 0
boot_drive      db 0

boot_sector_end:
%if ($ - $$) > 510
  %error "boot-sector.asm: the code does not fit in 510 bytes"
%endif
        times 510 - ($ - $$) db 0
        dw 0xAA55
