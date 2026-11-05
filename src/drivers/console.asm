; ============================================================================
; rx286 - src/drivers/console.asm
; The console driver (roadmap l4.md L8, D19): 80x25 colour text on the EGA,
; in ring 1 with IOPL 1.
;
; It writes the text page through the segment the root gave it, and moves
; the hardware cursor through the CRTC. The top line is the status line:
; a background program's writes go to its right end (CON_STATUS); the
; foreground program's to the 24 lines below it (CON_MAIN), where CR, LF,
; BS, TAB and FF are control characters and every other byte is shown as
; its glyph, and a full screen scrolls those lines up. It starts where the
; kernel's cursor left off, below the kernel's banner. The log is not its
; business: the OS server's call of the kernel's write keeps the
; transcript the tests read. The OS server asks it with DRV_CON_WRITE
; (drivers.inc), passing the segment the bytes are in, which the driver
; deletes once it has written them.
; ============================================================================

cpu 286
bits 16
%define RAW_SYSCALLS
%include "build.inc"
%include "program.inc"
%include "ports.inc"
%include "kcalls.inc"
%include "drivers.inc"

RING                equ 1
%define SLOT(n) ((n) * 8 + 4 + RING)    ; a slot of the driver's, as a selector
EP                  equ SLOT(DRV_SLOT_EP)
RECV                equ SLOT(DRV_SLOT_RECV)
VIDEO               equ SLOT(DRV_SLOT_DEVICE)
CON_TAB_WIDTH       equ 8
CON_FIRST           equ VIDEO_COLUMNS   ; the main area's first cell: row 1
CON_LAST_LINE       equ (VIDEO_ROWS - 1) * VIDEO_COLUMNS
CON_CELLS           equ VIDEO_ROWS * VIDEO_COLUMNS
ATTR_NORMAL         equ 0x07            ; light grey on black
ATTR_STATUS         equ 0x70            ; black on light grey: the status line
CHAR_TAB            equ 9

begin_udata
con_pos             dw CON_FIRST        ; the next cell of the main area
end_udata

; ----------------------------------------------------------------------------
; entry - take over the screen where the kernel's cursor is, then serve
;   In:       its start: DS = ES = its data, IOPL 1
;   Out:      does not return
;   Destroys: everything
; ----------------------------------------------------------------------------
entry:
        cld
        mov dx, CRTC_INDEX
        mov al, CRTC_CURSOR_HIGH
        out dx, al
        mov dx, CRTC_DATA
        in al, dx
        mov ah, al
        mov dx, CRTC_INDEX
        mov al, CRTC_CURSOR_LOW
        out dx, al
        mov dx, CRTC_DATA
        in al, dx
        cmp ax, CON_FIRST
        jae .below
        mov ax, CON_FIRST               ; the status line is not the main area's
.below:
        cmp ax, CON_CELLS
        jb .placed
        mov ax, CON_LAST_LINE
.placed:
        mov [con_pos], ax
        ; falls through

; ----------------------------------------------------------------------------
; serve - write what the OS server asks, for ever
;   In:       nothing
;   Out:      does not return
;   Destroys: everything
; ----------------------------------------------------------------------------
serve:
        mov dx, EP
        mov bp, RECV
        kcall KCALL_RECV
.message:
        jc serve
        cmp al, DRV_CON_WRITE
        jne serve
        test bp, bp
        jz .written                     ; no segment came: nothing to write
        cmp bx, CON_STATUS
        je .status
        call write_main
        jmp .written
.status:
        call write_status
.written:
        push cx
        mov dx, RECV                    ; the segment, used: room for the next
        kcall KCALL_DELETE
        pop cx
        mov dx, EP
        mov bp, RECV
        kcall KCALL_REPLY_RECV
        jmp .message

; ----------------------------------------------------------------------------
; write_main - bytes to the main area, then the cursor after them
;   In:       BP:SI = the bytes; CX = how many; DS = its data
;   Out:      CX kept
;   Destroys: AX, BX, DX, SI, DI, ES
; ----------------------------------------------------------------------------
write_main:
        push cx
        mov bx, [con_pos]
        mov ax, VIDEO
        mov es, ax
        push ds
        mov ds, bp
        jcxz .done
.next:
        lodsb
        call emit
        loop .next
.done:
        pop ds
        mov [con_pos], bx
        call cursor
        pop cx
        ret

; ----------------------------------------------------------------------------
; write_status - a background program's bytes, at the status line's right
; end (control characters as spaces; the last VIDEO_COLUMNS at most)
;   In:       BP:SI = the bytes; CX = how many; DS = its data
;   Out:      CX kept
;   Destroys: AX, DX, SI, DI, ES
; ----------------------------------------------------------------------------
write_status:
        push cx
        cmp cx, VIDEO_COLUMNS
        jbe .fits
        add si, cx
        sub si, VIDEO_COLUMNS
        mov cx, VIDEO_COLUMNS
.fits:
        mov di, VIDEO_COLUMNS
        sub di, cx
        shl di, 1                       ; the first cell: right-aligned on row 0
        mov ax, VIDEO
        mov es, ax
        push ds
        mov ds, bp
        jcxz .done
        mov ah, ATTR_STATUS
.next:
        lodsb
        cmp al, ' '
        jae .glyph
        mov al, ' '
.glyph:
        stosw
        loop .next
.done:
        pop ds
        pop cx
        ret

; ----------------------------------------------------------------------------
; emit - one character in the main area
;   In:       AL = the character; BX = the cell; ES = the text page
;   Out:      BX = the next cell
;   Destroys: AX, DX, DI
; ----------------------------------------------------------------------------
emit:
        cmp al, CHAR_LF
        je .newline
        cmp al, CHAR_CR
        je .return
        cmp al, CHAR_BS
        je .backspace
        cmp al, CHAR_TAB
        je .tab
        cmp al, CHAR_FF
        je clear
        mov di, bx
        shl di, 1
        mov ah, ATTR_NORMAL
        mov [es:di], ax
        inc bx
        cmp bx, CON_CELLS
        jb .done
        call scroll
        mov bx, CON_LAST_LINE
        ret
.newline:
        call line_start
        add bx, VIDEO_COLUMNS
        cmp bx, CON_CELLS
        jb .done
        call scroll
        mov bx, CON_LAST_LINE
        ret
.return:
        jmp line_start
.backspace:
        mov ax, bx
        mov dl, VIDEO_COLUMNS
        div dl                          ; AH = the column
        test ah, ah
        jz .done                        ; the line's start: nowhere to go
        dec bx
        ret
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
        call line_start
        add bx, ax
.done:
        ret

; ----------------------------------------------------------------------------
; line_start - the start of the line holding a cell
;   In:       BX = the cell
;   Out:      BX = its line's first cell
;   Destroys: nothing
; ----------------------------------------------------------------------------
line_start:
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
; clear - FF: the main area blank, the cursor at its start
;   In:       ES = the text page
;   Out:      BX = CON_FIRST
;   Destroys: AX
; ----------------------------------------------------------------------------
clear:
        push cx
        push di
        mov di, CON_FIRST * 2
        mov ax, ATTR_NORMAL << 8 | ' '
        mov cx, CON_CELLS - CON_FIRST
        rep stosw
        pop di
        pop cx
        mov bx, CON_FIRST
        ret

; ----------------------------------------------------------------------------
; scroll - the main area's lines up one, its last blank
;   In:       ES = the text page
;   Out:      nothing
;   Destroys: AX
; ----------------------------------------------------------------------------
scroll:
        push cx
        push si
        push di
        push ds
        push es
        pop ds
        mov si, (CON_FIRST + VIDEO_COLUMNS) * 2
        mov di, CON_FIRST * 2
        mov cx, CON_LAST_LINE - CON_FIRST
        rep movsw
        mov ax, ATTR_NORMAL << 8 | ' '
        mov cx, VIDEO_COLUMNS
        rep stosw
        pop ds
        pop di
        pop si
        pop cx
        ret

; ----------------------------------------------------------------------------
; cursor - the hardware cursor at a cell (CRTC registers 0Eh, 0Fh)
;   In:       BX = the cell
;   Out:      nothing
;   Destroys: AX, DX
; ----------------------------------------------------------------------------
cursor:
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
        ret
