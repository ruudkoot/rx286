; ============================================================================
; rx286 - src/kernel/serial.asm
; The log, polled: the debug and test builds' log and transcript, on
; LOG_PORT (build.inc): COM2. COM2 shares IRQ3 with the modem's COM4, but
; with OUT2 clear its UART never drives the line.
;
; 115200 baud, 8N1, the UART's interrupt off (OUT2 clear), so its IRQ never
; fires for it. Transmit only. Release builds assemble none of this.
; ============================================================================

%ifdef WITH_SERIAL

; ----------------------------------------------------------------------------
; com_init - the log's UART at 115200, 8N1, no interrupt
;   In:       nothing
;   Out:      nothing
;   Destroys: nothing
; ----------------------------------------------------------------------------
com_init:
        push ax
        push dx
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
        pop dx
        pop ax
        ret

; ----------------------------------------------------------------------------
; com_putc - send one byte on the log
;   In:       AL = the byte
;   Out:      nothing
;   Destroys: nothing
; ----------------------------------------------------------------------------
com_putc:
        push ax
        push dx
        mov ah, al
        mov dx, LOG_PORT + UART_LSR
.wait:
        in al, dx
        test al, UART_LSR_THRE
        jz .wait
        mov al, ah
        mov dx, LOG_PORT + UART_THR
        out dx, al
        pop dx
        pop ax
        ret

; ----------------------------------------------------------------------------
; com_puts - send a zero-terminated string on the log
;   In:       DS:SI = the string
;   Out:      nothing
;   Destroys: nothing
; ----------------------------------------------------------------------------
com_puts:
        push ax
        push si
.next:
        lodsb
        test al, al
        jz .done
        call com_putc
        jmp .next
.done:
        pop si
        pop ax
        ret

; ----------------------------------------------------------------------------
; com_drain - wait until the last byte has left the UART
;   In:       nothing
;   Out:      nothing
;   Destroys: nothing
; ----------------------------------------------------------------------------
com_drain:
        push ax
        push dx
        mov dx, LOG_PORT + UART_LSR
.wait:
        in al, dx
        test al, UART_LSR_TEMT
        jz .wait
        pop dx
        pop ax
        ret

%endif
