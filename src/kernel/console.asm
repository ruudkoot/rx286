; ============================================================================
; rx286 - src/kernel/console.asm
; The console: 80x25 colour text on the EGA, through SEL_VIDEO.
;
; Characters go to text page 0 at B8000h with the current attribute. CR,
; LF, BS, TAB and FF are control characters; every other byte is shown as
; its glyph. Scrolling copies 24 lines up. The hardware cursor is moved
; through the CRTC once per call of con_putc, not per character. Debug and
; test builds copy every byte to the log (COM2), the transcript the tests
; read. The loader set text mode 3 through the BIOS (roadmap D14); this
; module programs only the cursor.
; ============================================================================

CON_TAB_WIDTH       equ 8
CON_LAST_LINE       equ (VIDEO_ROWS - 1) * VIDEO_COLUMNS
CON_CELLS           equ VIDEO_ROWS * VIDEO_COLUMNS
CHAR_BS             equ 8
CHAR_TAB            equ 9
CHAR_LF             equ 10
CHAR_FF             equ 12
CHAR_CR             equ 13

begin_kdata
con_pos             dw 0                ; the next cell, 0 .. CON_CELLS - 1
con_attr            db ATTR_NORMAL
end_kdata

; ----------------------------------------------------------------------------
; con_init - the console's attribute, an empty screen, the cursor home
;   In:       DS = SEL_KDATA
;   Out:      nothing
;   Destroys: nothing
; ----------------------------------------------------------------------------
con_init:
        mov byte [con_attr], ATTR_NORMAL
        jmp con_clear

; ----------------------------------------------------------------------------
; con_clear - fill the screen with spaces of the current attribute
;   In:       DS = SEL_KDATA
;   Out:      nothing
;   Destroys: nothing
; ----------------------------------------------------------------------------
con_clear:
        push ax
        push cx
        push di
        push es
        mov ax, SEL_VIDEO
        mov es, ax
        xor di, di
        mov ah, [con_attr]
        mov al, ' '
        mov cx, CON_CELLS
        rep stosw
        mov word [con_pos], 0
        pop es
        pop di
        pop cx
        pop ax
        jmp con_cursor

; ----------------------------------------------------------------------------
; con_set_attr - the attribute of the characters written from now on
;   In:       AL = the attribute; DS = SEL_KDATA
;   Out:      nothing
;   Destroys: nothing
; ----------------------------------------------------------------------------
con_set_attr:
        mov [con_attr], al
        ret

; ----------------------------------------------------------------------------
; con_putc - write one character and move the cursor
;   In:       AL = the character; DS = SEL_KDATA
;   Out:      nothing
;   Destroys: nothing
; ----------------------------------------------------------------------------
con_putc:
        call con_emit
        jmp con_cursor

; ----------------------------------------------------------------------------
; con_emit - write one character, without moving the hardware cursor
;   In:       AL = the character; DS = SEL_KDATA
;   Out:      nothing
;   Destroys: nothing
; ----------------------------------------------------------------------------
con_emit:
        push ax
        push bx
        push dx
%ifdef WITH_SERIAL
        call com_putc
%endif
        mov bx, [con_pos]
        cmp al, CHAR_LF
        je .newline
        cmp al, CHAR_CR
        je .return
        cmp al, CHAR_BS
        je .backspace
        cmp al, CHAR_TAB
        je .tab
        cmp al, CHAR_FF
        je .clear
        push es
        push di
        mov dx, SEL_VIDEO
        mov es, dx
        mov di, bx
        shl di, 1
        mov ah, [con_attr]
        mov [es:di], ax
        pop di
        pop es
        inc bx
        cmp bx, CON_CELLS
        jb .store
        call con_scroll
        mov bx, CON_LAST_LINE
        jmp .store
.newline:
        call .line_start
        add bx, VIDEO_COLUMNS
        cmp bx, CON_CELLS
        jb .store
        call con_scroll
        mov bx, CON_LAST_LINE
        jmp .store
.return:
        call .line_start
        jmp .store
.backspace:
        mov ax, bx
        mov dl, VIDEO_COLUMNS
        div dl                          ; AH = the column
        test ah, ah
        jz .done                        ; the line's start: nowhere to go
        dec bx
        jmp .store
.tab:
        mov ax, bx
        mov dl, VIDEO_COLUMNS
        div dl
        mov al, ah                      ; AL = the column
        xor ah, ah
        add ax, CON_TAB_WIDTH
        and ax, ~(CON_TAB_WIDTH - 1)
        cmp ax, VIDEO_COLUMNS
        jae .newline
        call .line_start
        add bx, ax
        jmp .store
.clear:
        pop dx
        pop bx
        pop ax
        jmp con_clear_keep_cursor
.store:
        mov [con_pos], bx
.done:
        pop dx
        pop bx
        pop ax
        ret
; BX = the start of the line holding cell BX
.line_start:
        push ax
        push dx
        mov ax, bx
        mov dl, VIDEO_COLUMNS
        div dl
        mov bl, al
        mov al, VIDEO_COLUMNS
        mul bl
        mov bx, ax
        pop dx
        pop ax
        ret

; ----------------------------------------------------------------------------
; con_clear_keep_cursor - clear the screen; the cursor moves at the next
; con_cursor (FF in the middle of a write)
;   In:       DS = SEL_KDATA
;   Out:      nothing
;   Destroys: nothing
; ----------------------------------------------------------------------------
con_clear_keep_cursor:
        push ax
        push cx
        push di
        push es
        mov ax, SEL_VIDEO
        mov es, ax
        xor di, di
        mov ah, [con_attr]
        mov al, ' '
        mov cx, CON_CELLS
        rep stosw
        mov word [con_pos], 0
        pop es
        pop di
        pop cx
        pop ax
        ret

; ----------------------------------------------------------------------------
; con_scroll - move every line up one, and blank the last
;   In:       DS = SEL_KDATA
;   Out:      nothing
;   Destroys: nothing
; ----------------------------------------------------------------------------
con_scroll:
        push ax
        push cx
        push si
        push di
        push ds
        push es
        mov ah, [con_attr]
        mov cx, SEL_VIDEO
        mov ds, cx
        mov es, cx
        mov si, VIDEO_COLUMNS * 2
        xor di, di
        mov cx, CON_LAST_LINE
        rep movsw
        mov al, ' '
        mov cx, VIDEO_COLUMNS
        rep stosw
        pop es
        pop ds
        pop di
        pop si
        pop cx
        pop ax
        ret

; ----------------------------------------------------------------------------
; con_cursor - put the hardware cursor at con_pos (CRTC registers 0Eh, 0Fh)
;   In:       DS = SEL_KDATA
;   Out:      nothing
;   Destroys: nothing
; ----------------------------------------------------------------------------
con_cursor:
        push ax
        push bx
        push dx
        mov bx, [con_pos]
        mov dx, CRTC_INDEX
        mov al, CRTC_CURSOR_HIGH
        out dx, al
        mov dx, CRTC_DATA
        mov al, bh
        out dx, al
        mov dx, CRTC_INDEX
        mov al, CRTC_CURSOR_LOW
        out dx, al
        mov dx, CRTC_DATA
        mov al, bl
        out dx, al
        pop dx
        pop bx
        pop ax
        ret
