; ============================================================================
; rx286 - tests/programs/keys.asm
; Keys, as a program reads them (roadmap l4.md L8): through the OS server
; and the keyboard driver.
;
; It waits for keys and prints each, "key SS AA": its scancode and ASCII in
; hexadecimal. Started again (Ctrl+Break), it says so first; its data
; survives the restart. The kernel's tests of the keyboard run it
; (tests/kernel).
; ============================================================================

cpu 286
bits 16
%include "build.inc"
%include "program.inc"

begin_udata
started             db 0
end_udata

; ----------------------------------------------------------------------------
; entry - print every key read, for ever
;   In:       its start
;   Out:      does not return
;   Destroys: everything
; ----------------------------------------------------------------------------
entry:
        cmp byte [started], 0
        je .first
        PRINT "keys: started again", CHAR_LF
.first:
        mov byte [started], 1
.next:
        mov al, KEY_WAIT
        sys SYS_READ_KEY
        push ax
        PRINT "key "
        pop ax
        push ax
        xchg al, ah
        call print_hex8                 ; the scancode
        mov al, ' '
        call print_char
        pop ax
        call print_hex8                 ; the ASCII
        call print_newline
        jmp .next

%include "uprint.asm"
%include "format.asm"
