; ============================================================================
; rx286 - src/drivers/console.asm
; The console driver (roadmap l4.md L8, D19; os-server.md P11): 80x25
; colour text on the EGA, in ring 1 with IOPL 1.
;
; It writes the text pages through the segment the root gave it, the 32 KB
; at B8000h, and moves the hardware cursor through the CRTC. Mode 3 has a
; page every 4 KB (VIDEO_PAGE); at its start the driver finds how many the
; EGA holds, eight or four (64 KB), with a word written past each page's
; text and read back, and blanks those past the first. The top line of
; every page is the status line: a background program's writes go to its
; field there, on every page (CON_STATUS). The 24 lines below are a
; terminal's (CON_MAIN, the page in BH): CR, LF, BS, TAB and FF are control
; characters, ESC [ begins one of ANSI's sequences it knows - the cursor's
; moves (A, B, C, D, H and f), erasing (J, K) and attributes (m) - and
; every other byte is shown as its glyph; a full page scrolls its 24 lines
; up. Each page has its cursor, attribute and escape state. DRV_CON_SHOW
; shows a page: the CRTC's start address, and the hardware cursor at the
; page's cursor. Page 0 starts where the kernel's cursor left off, below
; its banner. The log is not its business but in TEST_SCREEN builds, which
; put the page DRV_CON_SHOW shows on the log for the tests to read. The OS
; server asks it with DRV_CON_WRITE (drivers.inc), passing the segment the
; bytes are in, which the driver deletes once it has written them.
; ============================================================================

cpu 286
bits 16
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
CHUNK               equ 64              ; the bytes taken from a write at a time
PROBE_AT            equ VIDEO_PAGE - 2  ; a page's last word, past its text
PROBE_MARK          equ 0xA5C0          ; and the mark written there, the page's added

begin_udata
con_pages           dw 1                ; the pages the EGA holds
con_shown           dw 0                ; the page shown
con_page            dw 0                ; the page being written:
con_base            dw 0                ;    its offset in the segment,
con_pos             dw CON_FIRST        ;    its cursor's cell,
con_attr            db ATTR_NORMAL      ;    its attribute,
esc_state           db 0                ;    its escape's state (ESC_*),
esc_n               db 0                ;    the parameter being given (0, 1),
esc_p               db 0, 0             ;    and the parameters
page_pos            times VIDEO_PAGES dw CON_FIRST      ; each page's, kept
page_attr           times VIDEO_PAGES db ATTR_NORMAL
page_esc            times VIDEO_PAGES * 4 db 0          ; state, n, p0, p1
status_page         dw 0
show_quiet          db 0                ; DRV_CON_SHOW's BH (CON_QUIET)
chunk_buf           times CHUNK db 0
ansi_colours        db 0, 4, 2, 6, 1, 5, 3, 7      ; ANSI's black, red, green, yellow,
                                                    ; blue, magenta, cyan, white
%ifdef TEST_SCREEN
dump_buf            times 16 + VIDEO_COLUMNS * 5 db 0
msg_pages           db "console: N pages", CHAR_LF
msg_pages_end:
msg_shown           db "screen N: shown", CHAR_LF
msg_shown_end:
%endif
end_udata

ESC_NONE            equ 0
ESC_ESC             equ 1               ; ESC seen
ESC_CSI             equ 2               ; ESC [ seen: parameters, then the final byte

; ----------------------------------------------------------------------------
; entry - the pages counted and blanked, page 0's cursor where the kernel's
; is, then serve
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
        mov [page_pos], ax
        call probe
        call blank_pages
%ifdef TEST_SCREEN
        mov al, [con_pages]
        add al, '0'
        mov [msg_pages + 9], al
        mov si, msg_pages
        mov cx, msg_pages_end - msg_pages
        kcall KCALL_LOG
%endif
        xor ax, ax
        call page_load
        ; falls through

; ----------------------------------------------------------------------------
; serve - write and show what the OS server asks, for ever
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
        cmp al, NOTIFY_LABEL
        je serve                        ; its notification's bits: nothing to answer
        cmp al, DRV_CON_SHOW
        je .show
        cmp al, DRV_CON_WRITE
        jne .unknown
        test bp, bp
        jz .written                     ; no segment came: nothing to write
        verr bp                         ; (gone already: a program killed, l4.md L12)
        jnz .unknown
        cmp bl, CON_STATUS
        je .status
        call write_main
        jmp .written
.status:
        call write_status
        jmp .written
.unknown:
        xor cx, cx                      ; nothing written
.written:
        push cx
        mov dx, RECV                    ; the segment, used: room for the next
        kcall KCALL_DELETE
        pop cx
.reply:
        mov dx, EP
        mov bp, RECV
        kcall KCALL_REPLY_RECV
        jmp .message
.show:
        call show
        jmp .reply

; ----------------------------------------------------------------------------
; probe - how many pages the EGA holds: a mark written past each page's
; text, the last page's first, then read back; a page there reads its own,
; one that is not reads otherwise, or its write landed on a lower page's
;   In:       DS = its data
;   Out:      con_pages
;   Destroys: AX, BX, CX, ES
; ----------------------------------------------------------------------------
probe:
        mov ax, VIDEO
        mov es, ax
        mov cx, VIDEO_PAGES
.write:
        dec cx
        mov bx, cx
        shl bx, VIDEO_PAGE_SHIFT
        mov ax, PROBE_MARK
        add ax, cx
        mov [es:bx + PROBE_AT], ax
        jcxz .read
        jmp .write
.read:
        mov cx, 1                       ; page 0 is there
.check:
        cmp cx, VIDEO_PAGES
        je .counted
        mov bx, cx
        shl bx, VIDEO_PAGE_SHIFT
        mov ax, PROBE_MARK
        add ax, cx
        cmp [es:bx + PROBE_AT], ax
        jne .counted
        inc cx
        jmp .check
.counted:
        cmp cx, VIDEO_PAGES / 2         ; a 64 KB EGA's four, or eight
        jae .set
        mov cx, 1
.set:
        mov [con_pages], cx
        ret

; ----------------------------------------------------------------------------
; blank_pages - every page but the first blank, its status line too
;   In:       DS = its data
;   Out:      nothing
;   Destroys: AX, BX, CX, DI, ES
; ----------------------------------------------------------------------------
blank_pages:
        mov ax, VIDEO
        mov es, ax
        mov bx, 1
.page:
        cmp bx, [con_pages]
        jae .done
        mov di, bx
        shl di, VIDEO_PAGE_SHIFT
        mov ax, ATTR_STATUS << 8 | ' '
        mov cx, VIDEO_COLUMNS
        rep stosw
        mov ax, ATTR_NORMAL << 8 | ' '
        mov cx, CON_CELLS - VIDEO_COLUMNS
        rep stosw
        inc bx
        jmp .page
.done:
        ret

; ----------------------------------------------------------------------------
; page_load - a page's state, to be written
;   In:       AX = the page; DS = its data
;   Out:      con_page, con_base, con_pos, con_attr, esc_*
;   Destroys: AX, DI
; ----------------------------------------------------------------------------
page_load:
        mov [con_page], ax
        mov di, ax
        shl ax, VIDEO_PAGE_SHIFT
        mov [con_base], ax
        mov al, [page_attr + di]
        mov [con_attr], al
        shl di, 1
        mov ax, [page_pos + di]
        mov [con_pos], ax
        shl di, 1
        mov ax, [page_esc + di]
        mov [esc_state], ax             ; esc_state, esc_n
        mov ax, [page_esc + di + 2]
        mov [esc_p], ax
        ret

; ----------------------------------------------------------------------------
; page_save - the page written's state, kept
;   In:       DS = its data
;   Out:      nothing
;   Destroys: AX, DI
; ----------------------------------------------------------------------------
page_save:
        mov di, [con_page]
        mov al, [con_attr]
        mov [page_attr + di], al
        shl di, 1
        mov ax, [con_pos]
        mov [page_pos + di], ax
        shl di, 1
        mov ax, [esc_state]
        mov [page_esc + di], ax
        mov ax, [esc_p]
        mov [page_esc + di + 2], ax
        ret

; ----------------------------------------------------------------------------
; write_main - bytes to a page's main area, then the cursor after them
;   In:       BP:SI = the bytes; CX = how many; BH = the page; DS = its data
;   Out:      CX kept (0 for a page the EGA does not hold)
;   Destroys: AX, BX, DX, SI, DI, ES
; ----------------------------------------------------------------------------
write_main:
        mov al, bh
        xor ah, ah
        cmp ax, [con_pages]
        jb .page
        xor cx, cx
        ret
.page:
        push cx
        call page_load
.chunk:
        jcxz .done
        mov dx, cx
        cmp dx, CHUNK
        jbe .take
        mov dx, CHUNK
.take:
        sub cx, dx
        push cx
        push ds
        pop es
        mov di, chunk_buf
        mov cx, dx
        push ds
        mov ds, bp
        rep movsb                       ; the next of them, into its own data
        pop ds
        push si
        mov cx, dx
        mov si, chunk_buf
        mov ax, VIDEO
        mov es, ax
        mov bx, [con_pos]
.next:
        lodsb
        call emit
        loop .next
        mov [con_pos], bx
        pop si
        pop cx
        jmp .chunk
.done:
        call page_save
        mov ax, [con_page]
        cmp ax, [con_shown]
        jne .hidden
        mov bx, [con_pos]
        call cursor
.hidden:
        pop cx
        ret

; ----------------------------------------------------------------------------
; write_status - a background program's bytes, in its field of the status
; line of every page: right-aligned, spaces before them (control characters
; as spaces; the field's last CON_FIELD at most)
;   In:       BP:SI = the bytes; CX = how many; DI = the column past the
;             field's end (CON_FIELD to VIDEO_COLUMNS); DS = its data
;   Out:      CX kept
;   Destroys: AX, BX, DX, SI, DI, ES
; ----------------------------------------------------------------------------
write_status:
        push cx
        cmp di, CON_FIELD
        jb .done_early
        cmp di, VIDEO_COLUMNS
        ja .done_early
        cmp cx, CON_FIELD
        jbe .fits
        add si, cx
        sub si, CON_FIELD
        mov cx, CON_FIELD
.fits:
        mov dx, di
        sub dx, cx                      ; DX = the text's first column
        sub di, CON_FIELD
        shl di, 1                       ; DI = the field's first cell, on row 0
        mov ax, VIDEO
        mov es, ax
        mov word [status_page], 0
.page:
        push si
        push cx
        push di
        mov ax, [status_page]
        shl ax, VIDEO_PAGE_SHIFT
        add di, ax
        mov bx, di
        sub bx, ax                      ; BX = the cell's offset in its page
        mov ax, ATTR_STATUS << 8 | ' '
.blank:
        push bx
        shr bx, 1
        cmp bx, dx
        pop bx
        jae .text
        stosw
        add bx, 2
        jmp .blank
.text:
        push ds
        mov ds, bp
        jcxz .written
        mov ah, ATTR_STATUS
.next:
        lodsb
        cmp al, ' '
        jae .glyph
        mov al, ' '
.glyph:
        stosw
        loop .next
.written:
        pop ds
        pop di
        pop cx
        pop si
        inc word [status_page]
        mov ax, [status_page]
        cmp ax, [con_pages]
        jb .page
.done_early:
        pop cx
        ret

; ----------------------------------------------------------------------------
; emit - one byte in the page's main area: a glyph, a control character, or
; part of an escape sequence
;   In:       AL = the byte; BX = the cell; ES = the video; DS = its data
;   Out:      BX = the next cell
;   Destroys: AX, DX, DI
; ----------------------------------------------------------------------------
emit:
        cmp byte [esc_state], ESC_NONE
        jne escape
        cmp al, CHAR_ESC
        je .escape
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
        add di, [con_base]
        mov ah, [con_attr]
        mov [es:di], ax
        inc bx
        cmp bx, CON_CELLS
        jb .done
        call scroll
        mov bx, CON_LAST_LINE
        ret
.escape:
        mov byte [esc_state], ESC_ESC
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
; escape - a byte of an escape sequence: after ESC, '[' or the sequence
; dropped; after ESC [, a digit or ';' of the two parameters at most, or the
; final byte, which acts
;   In:       AL = the byte; BX = the cell; ES = the video; DS = its data
;   Out:      BX = the cell after
;   Destroys: AX, DX, DI
; ----------------------------------------------------------------------------
escape:
        cmp byte [esc_state], ESC_ESC
        jne .csi
        mov byte [esc_state], ESC_NONE
        cmp al, '['
        jne .done                       ; ESC and anything else: dropped
        mov byte [esc_state], ESC_CSI
        mov byte [esc_n], 0
        mov word [esc_p], 0
        ret
.csi:
        cmp al, '0'
        jb .not_digit
        cmp al, '9'
        ja .not_digit
        push bx
        push cx
        mov bl, [esc_n]
        xor bh, bh
        sub al, '0'
        mov cl, al
        mov al, [esc_p + bx]
        mov ah, 10
        mul ah                          ; AX = the parameter so far, times 10
        add al, cl
        adc ah, 0
        test ah, ah
        jz .fits
        mov al, 255
.fits:
        mov [esc_p + bx], al
        pop cx
        pop bx
        ret
.not_digit:
        cmp al, ';'
        jne .final
        cmp byte [esc_n], 1
        jae .done                       ; past the second: dropped
        inc byte [esc_n]
        ret
.final:
        mov byte [esc_state], ESC_NONE
        mov dl, [esc_p]                 ; DL = the first parameter
        cmp al, 'm'
        je attributes
        cmp al, 'J'
        je erase_display
        cmp al, 'K'
        je erase_line
        cmp al, 'H'
        je move_to
        cmp al, 'f'
        je move_to
        test dl, dl
        jnz .counted
        mov dl, 1                       ; a count of 0, or none: 1
.counted:
        cmp al, 'A'
        je .up
        cmp al, 'B'
        je .down
        cmp al, 'C'
        je .right
        cmp al, 'D'
        je .left
.done:
        ret                             ; any other: dropped
.up:
        call row_column
        sub al, dl
        jc .top
        cmp al, 1
        jae .moved
.top:
        mov al, 1
        jmp .moved
.down:
        call row_column
        add al, dl
        jc .bottom
        cmp al, VIDEO_ROWS - 1
        jbe .moved
.bottom:
        mov al, VIDEO_ROWS - 1
        jmp .moved
.right:
        call row_column
        add ah, dl
        jc .last
        cmp ah, VIDEO_COLUMNS - 1
        jbe .moved
.last:
        mov ah, VIDEO_COLUMNS - 1
        jmp .moved
.left:
        call row_column
        sub ah, dl
        jnc .moved
        xor ah, ah
.moved:
        jmp cell_of

; ----------------------------------------------------------------------------
; row_column - a cell's row and column
;   In:       BX = the cell
;   Out:      AL = its row, AH = its column
;   Destroys: nothing else
; ----------------------------------------------------------------------------
row_column:
        push dx
        mov ax, bx
        mov dl, VIDEO_COLUMNS
        div dl
        pop dx
        ret

; ----------------------------------------------------------------------------
; cell_of - the cell of a row and column
;   In:       AL = the row, AH = the column
;   Out:      BX = the cell
;   Destroys: AX
; ----------------------------------------------------------------------------
cell_of:
        push dx
        mov dl, ah
        mov ah, VIDEO_COLUMNS
        mul ah
        xor dh, dh
        add ax, dx
        mov bx, ax
        pop dx
        ret

; ----------------------------------------------------------------------------
; move_to - ESC [ row ; column H: the cursor there, rows from the main
; area's first (1, as the column), each 1 if not given
;   In:       BX = the cell; DS = its data
;   Out:      BX = the cell there
;   Destroys: AX
; ----------------------------------------------------------------------------
move_to:
        mov al, [esc_p]
        mov ah, [esc_p + 1]
        cmp al, 1
        jae .row
        mov al, 1
.row:
        cmp al, VIDEO_ROWS - 1
        jbe .column
        mov al, VIDEO_ROWS - 1
.column:
        cmp ah, 1
        jae .high
        mov ah, 1
.high:
        cmp ah, VIDEO_COLUMNS
        jbe .there
        mov ah, VIDEO_COLUMNS
.there:
        dec ah
        jmp cell_of

; ----------------------------------------------------------------------------
; erase_display - ESC [ J: the main area blank from the cursor (0) or all of
; it (2); the cursor stays
;   In:       BX = the cell; DL = the parameter; ES = the video; DS = its data
;   Out:      BX kept
;   Destroys: AX, DI
; ----------------------------------------------------------------------------
erase_display:
        push cx
        mov di, bx
        mov cx, CON_CELLS
        sub cx, bx
        cmp dl, 2
        jne blank_cells
        mov di, CON_FIRST
        mov cx, CON_CELLS - CON_FIRST
        jmp blank_cells

; ----------------------------------------------------------------------------
; erase_line - ESC [ K: the line blank from the cursor (0) or all of it (2);
; the cursor stays
;   In:       BX = the cell; DL = the parameter; ES = the video; DS = its data
;   Out:      BX kept
;   Destroys: AX, DI
; ----------------------------------------------------------------------------
erase_line:
        push cx
        push bx
        call line_start
        mov di, bx                      ; DI = the line's first cell
        pop bx
        mov cx, VIDEO_COLUMNS
        cmp dl, 2
        je blank_cells                  ; all of it
        add cx, di
        sub cx, bx                      ; from the cursor to the line's end
        mov di, bx
        ; falls through

; ----------------------------------------------------------------------------
; blank_cells - cells blank, with the normal attribute (CX pushed before)
;   In:       DI = the first cell; CX = how many; ES = the video; DS = its
;             data; the stack: the caller's CX
;   Out:      CX as the caller had it
;   Destroys: AX, DI
; ----------------------------------------------------------------------------
blank_cells:
        shl di, 1
        add di, [con_base]
        mov ax, ATTR_NORMAL << 8 | ' '
        rep stosw
        pop cx
        ret

; ----------------------------------------------------------------------------
; attributes - ESC [ ... m: each parameter given: 0 normal, 1 bright, 7
; reversed, 30-37 a colour of the text, 40-47 of its background, 39 and
; 49 their defaults
;   In:       DS = its data
;   Out:      con_attr
;   Destroys: AX, DX
; ----------------------------------------------------------------------------
attributes:
        mov al, [esc_p]
        call attribute
        cmp byte [esc_n], 0
        je .done
        mov al, [esc_p + 1]
        call attribute
.done:
        ret

; ----------------------------------------------------------------------------
; attribute - one parameter of ESC [ m
;   In:       AL = the parameter; DS = its data
;   Out:      con_attr
;   Destroys: AX, DX
; ----------------------------------------------------------------------------
attribute:
        mov dl, [con_attr]
        cmp al, 0
        jne .bright
        mov dl, ATTR_NORMAL
        jmp .set
.bright:
        cmp al, 1
        jne .reverse
        or dl, 0x08
        jmp .set
.reverse:
        cmp al, 7
        jne .text
        mov dh, dl
        and dl, 0x0F
        shl dl, 4
        shr dh, 4
        and dh, 0x07
        or dl, dh
        jmp .set
.text:
        cmp al, 39
        jne .colour
        and dl, 0xF8
        or dl, ATTR_NORMAL & 0x07
        jmp .set
.colour:
        cmp al, 49
        jne .colours
        and dl, 0x8F
        jmp .set
.colours:
        cmp al, 30
        jb .done
        cmp al, 47
        ja .done
        cmp al, 38
        je .done
        cmp al, 39
        jae .background
        sub al, 30
        call colour
        and dl, 0xF8
        or dl, al
        jmp .set
.background:
        cmp al, 40
        jb .done
        sub al, 40
        call colour
        shl al, 4
        and dl, 0x8F
        or dl, al
.set:
        mov [con_attr], dl
.done:
        ret

; ----------------------------------------------------------------------------
; colour - ANSI's colour as the EGA's
;   In:       AL = 0 to 7
;   Out:      AL = the EGA's
;   Destroys: nothing else
; ----------------------------------------------------------------------------
colour:
        push bx
        mov bx, ansi_colours
        xlatb
        pop bx
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
; clear - FF: the page's main area blank, the cursor at its start
;   In:       ES = the video; DS = its data
;   Out:      BX = CON_FIRST
;   Destroys: AX
; ----------------------------------------------------------------------------
clear:
        push cx
        push di
        mov di, CON_FIRST * 2
        add di, [con_base]
        mov ax, ATTR_NORMAL << 8 | ' '
        mov cx, CON_CELLS - CON_FIRST
        rep stosw
        pop di
        pop cx
        mov bx, CON_FIRST
        ret

; ----------------------------------------------------------------------------
; scroll - the page's main area's lines up one, its last blank
;   In:       ES = the video; DS = its data
;   Out:      nothing
;   Destroys: AX
; ----------------------------------------------------------------------------
scroll:
        push cx
        push si
        push di
        mov si, (CON_FIRST + VIDEO_COLUMNS) * 2
        add si, [con_base]
        mov di, CON_FIRST * 2
        add di, [con_base]
        push ds
        push es
        pop ds
        mov cx, CON_LAST_LINE - CON_FIRST
        rep movsw
        pop ds
        mov ax, ATTR_NORMAL << 8 | ' '
        mov cx, VIDEO_COLUMNS
        rep stosw
        pop di
        pop si
        pop cx
        ret

; ----------------------------------------------------------------------------
; show - DRV_CON_SHOW: a page shown, the CRTC's start address at it and the
; hardware cursor at its cursor (TEST_SCREEN: the page on the log, but with
; CON_QUIET)
;   In:       BL = the page; BH = CON_QUIET or 0; DS = its data
;   Out:      BX = the pages the EGA holds; CX = the page shown
;   Destroys: AX, DX, SI, DI, ES
; ----------------------------------------------------------------------------
show:
        mov [show_quiet], bh
        xor bh, bh
        cmp bx, [con_pages]
        jae .answer
        mov [con_shown], bx
        mov ax, bx
        shl ax, VIDEO_PAGE_SHIFT - 1    ; in words
        mov cx, ax
        mov dx, CRTC_INDEX
        mov al, CRTC_START_HIGH
        out dx, al
        mov dx, CRTC_DATA
        mov al, ch
        out dx, al
        mov dx, CRTC_INDEX
        mov al, CRTC_START_LOW
        out dx, al
        mov dx, CRTC_DATA
        mov al, cl
        out dx, al
        mov si, bx
        shl si, 1
        mov ax, bx
        mov bx, [page_pos + si]
        push ax
        call cursor_on                  ; (CX = the page's start, in words)
        pop bx
%ifdef TEST_SCREEN
        cmp byte [show_quiet], CON_QUIET
        je .answer
        call dump
%endif
.answer:
        mov bx, [con_pages]
        mov cx, [con_shown]
        ret

; ----------------------------------------------------------------------------
; cursor - the hardware cursor at a cell of the page being written
; (CRTC registers 0Eh, 0Fh: from the video memory's start)
;   In:       BX = the cell; DS = its data
;   Out:      nothing
;   Destroys: AX, CX, DX
; ----------------------------------------------------------------------------
cursor:
        mov cx, [con_base]
        shr cx, 1
        ; falls through

; ----------------------------------------------------------------------------
; cursor_on - the hardware cursor at a cell of a page
;   In:       BX = the cell; CX = the page's start, in words
;   Out:      nothing
;   Destroys: AX, CX, DX
; ----------------------------------------------------------------------------
cursor_on:
        add cx, bx
        mov dx, CRTC_INDEX
        mov al, CRTC_CURSOR_HIGH
        out dx, al
        mov dx, CRTC_DATA
        mov al, ch
        out dx, al
        mov dx, CRTC_INDEX
        mov al, CRTC_CURSOR_LOW
        out dx, al
        mov dx, CRTC_DATA
        mov al, cl
        out dx, al
        ret

%ifdef TEST_SCREEN
; ----------------------------------------------------------------------------
; dump - TEST_SCREEN builds: a page's lines on the log, those not blank,
; after "screen P: shown": "screen P R: text", an attribute other than the
; normal one said as <XX> where it starts, and the normal one again as <07>
;   In:       BX = the page; DS = its data
;   Out:      nothing
;   Destroys: AX, BX, CX, DX, SI, DI, ES
; ----------------------------------------------------------------------------
dump:
        mov al, bl
        add al, '0'
        mov [msg_shown + 7], al
        push bx
        mov si, msg_shown
        mov cx, msg_shown_end - msg_shown
        kcall KCALL_LOG
        pop bx
        mov ax, VIDEO
        mov es, ax
        mov si, bx
        shl si, VIDEO_PAGE_SHIFT        ; SI = the page's first cell
        mov dl, bl
        add dl, '0'                     ; DL = the page's digit
        xor dh, dh                      ; DH = the row
.row:
        mov di, dump_buf
        mov byte [di], 's'
        mov word [di + 1], 'cr'
        mov word [di + 3], 'ee'
        mov word [di + 5], 'n '
        mov [di + 7], dl
        mov byte [di + 8], ' '
        mov al, dh
        aam                             ; AH = tens, AL = units
        add ax, '00'
        mov [di + 9], ah
        mov [di + 10], al
        mov word [di + 11], ': '
        add di, 13
        mov bx, di                      ; BX = past the line's last glyph
        mov ah, ATTR_NORMAL             ; AH = the attribute said
        mov cx, VIDEO_COLUMNS
.cell:
        mov al, [es:si + 1]
        cmp al, ah
        je .glyph
        mov ah, al
        mov byte [di], '<'
        push ax
        shr al, 4
        call hex_digit
        mov [di + 1], al
        pop ax
        push ax
        and al, 0x0F
        call hex_digit
        mov [di + 2], al
        pop ax
        mov byte [di + 3], '>'
        add di, 4
        mov bx, di
.glyph:
        mov al, [es:si]
        mov [di], al
        inc di
        cmp al, ' '
        je .next
        mov bx, di
.next:
        add si, 2
        loop .cell
        cmp bx, dump_buf + 13
        je .blank                       ; nothing on the row
        mov byte [bx], CHAR_LF
        inc bx
        push si
        push dx
        mov si, dump_buf
        mov cx, bx
        sub cx, si
        kcall KCALL_LOG
        pop dx
        pop si
.blank:
        inc dh
        cmp dh, VIDEO_ROWS
        jb .row
        ret

; ----------------------------------------------------------------------------
; hex_digit - a hexadecimal digit
;   In:       AL = 0 to 15
;   Out:      AL = its digit
;   Destroys: nothing else
; ----------------------------------------------------------------------------
hex_digit:
        add al, '0'
        cmp al, '9'
        jbe .done
        add al, 'A' - '9' - 1
.done:
        ret
%endif
