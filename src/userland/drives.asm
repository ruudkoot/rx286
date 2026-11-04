; ============================================================================
; rx286 - src/userland/drives.asm
; The shell's drives: the prompt, A: to D:, dir, cd, type and print, on the
; FAT12 library (fat.asm; storage roadmap D8).
;
; As DOS does, the shell keeps a current drive and, for each drive, a
; current directory. A path may start with a drive (C:\DOCS, B:FRAG.TXT); it
; goes from the root after a separator, else from that drive's current
; directory. Every command mounts its drive afresh. The messages are DOS's
; where DOS has one.
; ============================================================================

DIR_TIME            equ 0x16            ; a directory entry's time and date
DIR_DATE            equ 0x18
SIZE_COLUMNS        equ 9               ; dir's columns for a size
COUNT_COLUMNS       equ 9
TOTAL_COLUMNS       equ 11
FREE_COLUMNS        equ COUNT_COLUMNS + 8 + TOTAL_COLUMNS  ; under the total: " file(s)" is 8
STAMP_CHARS         equ 10              ; YYYY-MM-DD, the longer stamp

begin_udata
current_drive       db DRIVE_A
wheres              times DRIVES * WHERE_SIZE db 0  ; each drive's current directory
path_drive          db 0                ; the drive of the command's path
dir_files           dw 0
dir_bytes           dd 0
printed             dd 0
end_udata

; ----------------------------------------------------------------------------
; drives_init - every drive at its root, A the current drive
;   In:       DS = ES = the program's data
;   Out:      nothing
;   Destroys: AX, BX, CX
; ----------------------------------------------------------------------------
drives_init:
        mov byte [current_drive], DRIVE_A
        xor al, al
        mov cx, DRIVES
.drive:
        call where_of
        mov word [bx + WHERE_CLUSTER], 0
        mov word [bx + WHERE_PATH], CHAR_PATH_SEPARATOR    ; "\" and its zero
        inc al
        loop .drive
        ret

; ----------------------------------------------------------------------------
; where_of - a drive's current directory
;   In:       AL = the drive
;   Out:      BX = its record in wheres
;   Destroys: nothing
; ----------------------------------------------------------------------------
where_of:
        push ax
        push dx
        xor ah, ah
        mov bx, WHERE_SIZE
        mul bx
        mov bx, ax
        add bx, wheres
        pop dx
        pop ax
        ret

; ----------------------------------------------------------------------------
; print_prompt - the current drive and directory, as DOS's $p$g: C:\DOCS>
;   In:       DS = ES = the program's data
;   Out:      nothing
;   Destroys: AX, BX, SI
; ----------------------------------------------------------------------------
print_prompt:
        mov al, [current_drive]
        call print_where
        mov al, '>'
        jmp print_char

; ----------------------------------------------------------------------------
; print_where - a drive's letter, a colon and its current directory
;   In:       AL = the drive
;   Out:      nothing
;   Destroys: AX, BX, SI
; ----------------------------------------------------------------------------
print_where:
        call where_of
        add al, 'A'
        call print_char
        mov al, ':'
        call print_char
        lea si, [bx + WHERE_PATH]
        jmp print_str

; ----------------------------------------------------------------------------
; drive_line - is the line a drive and a colon alone ("b:")? then make it
; the current drive
;   In:       SI = the line, past its leading spaces
;   Out:      CF clear if it was such a line (and was done); else CF set
;   Destroys: AX
; ----------------------------------------------------------------------------
drive_line:
        cmp byte [si + 1], ':'
        jne .not
        push si
        add si, 2
        call parse_skip_spaces
        cmp byte [si], 0
        pop si
        jne .not
        call path_drive_letter
        jc .done                        ; reported
        mov al, [path_drive]
        mov [current_drive], al
.done:
        clc
        ret
.not:
        stc
        ret

; ----------------------------------------------------------------------------
; path_drive_letter - the drive a letter names, into path_drive
;   In:       SI = the letter, a colon after it
;   Out:      CF clear; or CF set ("Invalid drive specification" printed)
;   Destroys: AX
; ----------------------------------------------------------------------------
path_drive_letter:
        mov al, [si]
        or al, 'a' - 'A'                ; lower case
        sub al, 'a'
        cmp al, DRIVES
        jae .invalid
        mov [path_drive], al
        clc
        ret
.invalid:
        PRINT "Invalid drive specification", CHAR_LF
        stc
        ret

; ----------------------------------------------------------------------------
; path_argument - a command's path: its drive, which is mounted
;   In:       SI = the rest of the line
;   Out:      CF clear, SI at the path past any "X:", path_drive, and BX =
;             the drive's current directory; or CF set (the trouble printed)
;   Destroys: AX, CX, DX, DI
; ----------------------------------------------------------------------------
path_argument:
        mov al, [current_drive]
        mov [path_drive], al
        cmp byte [si], ' '
        jbe .mount                      ; no argument
        cmp byte [si + 1], ':'
        jne .mount
        call path_drive_letter
        jc .out
        add si, 2
.mount:
        push si
        mov al, [path_drive]
        call fat_mount
        pop si
        jc report_failure
        mov al, [path_drive]
        call where_of
        clc
.out:
        ret

; ----------------------------------------------------------------------------
; path_find - path_argument, then the path followed (fat_find)
;   In:       SI = the rest of the line
;   Out:      CF clear and `found`, found_dir, found_entry; or CF set (the
;             trouble printed)
;   Destroys: AX, BX, CX, DX, SI, DI
; ----------------------------------------------------------------------------
path_find:
        call path_argument
        jc .out
        call fat_find
        jc report_failure
.out:
        ret

; ----------------------------------------------------------------------------
; report_failure - a command's error, as DOS words it
;   In:       AX = the error (the kernel's or the library's); path_drive
;   Out:      CF set
;   Destroys: AX
; ----------------------------------------------------------------------------
report_failure:
        cmp ax, E_TIMEOUT
        jne .io
        PRINT "Not ready reading drive "
        jmp .drive
.io:
        cmp ax, E_IO
        jne .fat12
        PRINT "Error reading drive "
        jmp .drive
.fat12:
        cmp ax, E_NOT_FAT12
        jne .broken
        PRINT "No FAT12 volume on drive "
        jmp .drive
.broken:
        cmp ax, E_BROKEN
        jne .not_found
        PRINT "Damaged FAT on drive "
        jmp .drive
.not_found:
        cmp ax, E_NOT_FOUND
        jne .not_dir
        PRINT "File not found", CHAR_LF
        jmp .out
.not_dir:
        cmp ax, E_NOT_DIR
        jne .bad_name
        PRINT "Path not found", CHAR_LF
        jmp .out
.bad_name:
        cmp ax, E_BAD_NAME
        jne .other
        PRINT "Invalid path", CHAR_LF
        jmp .out
.other:
        PRINT "Error "
        call print_dec
        call print_newline
        jmp .out
.drive:
        mov al, [path_drive]
        add al, 'A'
        call print_char
        call print_newline
.out:
        stc
        ret

; ----------------------------------------------------------------------------
; cmd_drive_help - help's line for the drive letters
;   In:       DS = the program's data
;   Out:      nothing
;   Destroys: nothing
; ----------------------------------------------------------------------------
cmd_drive_help:
        PRINT "  A: B: C: D: make that drive the current one", CHAR_LF
        ret

; ----------------------------------------------------------------------------
; cmd_dir - a directory's entries (or one file's), their count and size,
; and the volume's free space
;   In:       SI = the rest of the line; DS = ES = the program's data
;   Out:      nothing
;   Destroys: everything but DS, ES
; ----------------------------------------------------------------------------
cmd_dir:
        call path_find
        jc .out
        PRINT " Volume in drive "
        mov al, [path_drive]
        add al, 'A'
        call print_char
        mov si, vol_label
        mov di, no_label
        mov cx, DIR_NAME_LENGTH
        repe cmpsb
        jne .label
        PRINT " has no label", CHAR_LF
        jmp .directory
.label:
        PRINT " is "
        mov si, vol_label
        call print_name_part
        call print_newline
.directory:
        PRINT " Directory of "
        mov al, [path_drive]
        add al, 'A'
        call print_char
        mov al, ':'
        call print_char
        cmp byte [found_dir], 0
        jne .whole
        call cut_found_name             ; a file: its directory
.whole:
        mov si, found + WHERE_PATH
        call print_str
        call print_newline
        call print_newline
        mov word [dir_files], 0
        mov word [dir_bytes], 0
        mov word [dir_bytes + 2], 0
        cmp byte [found_dir], 0
        jne .walk
        mov si, found_entry
        call print_entry
        jmp .totals
.walk:
        mov ax, [found + WHERE_CLUSTER]
        call dir_first
        jc .failed
.entry:
        call dir_next
        jc .failed
        jz .totals
        call print_entry
        jmp .entry
.totals:
        mov ax, [dir_files]
        xor dx, dx
        mov cx, COUNT_COLUMNS
        call print_dec32_right
        PRINT " file(s)"
        mov ax, [dir_bytes]
        mov dx, [dir_bytes + 2]
        mov cx, TOTAL_COLUMNS
        call print_dec32_right
        PRINT " bytes", CHAR_LF
        call fat_free
        jc .failed
        mov cx, FREE_COLUMNS
        call print_dec32_right
        PRINT " bytes free", CHAR_LF
.out:
        ret
.failed:
        jmp report_failure

; ----------------------------------------------------------------------------
; cut_found_name - take the last name off found's path (a file's own)
;   In:       found's path, at least one name in it
;   Out:      nothing
;   Destroys: AL, CX, DI
; ----------------------------------------------------------------------------
cut_found_name:
        mov di, found + WHERE_PATH
        xor al, al
        mov cx, PATH_MAX + 1
        repne scasb
        dec di
.back:
        dec di
        cmp byte [di], CHAR_PATH_SEPARATOR
        jne .back
        cmp di, found + WHERE_PATH
        jne .cut
        inc di                          ; the root keeps its separator
.cut:
        mov byte [di], 0
        ret

; ----------------------------------------------------------------------------
; print_entry - a line of dir: name, extension, size or <DIR>, date, time;
; counted into dir_files and dir_bytes
;   In:       SI = the directory entry; DS = ES = the program's data
;   Out:      nothing
;   Destroys: AX, CX, DX, DI
; ----------------------------------------------------------------------------
print_entry:
        push si
        mov cx, FAT_BASE_LENGTH
        sys SYS_WRITE
        PRINT " "
        add si, FAT_BASE_LENGTH
        mov cx, FAT_EXT_LENGTH
        sys SYS_WRITE
        PRINT " "
        pop si
        inc word [dir_files]
        test byte [si + DIR_ATTRIBUTES], DIR_ATTR_DIRECTORY
        jz .file
        PRINT "<DIR>    "
        jmp .stamp
.file:
        mov ax, [si + DIR_FILE_SIZE]
        mov dx, [si + DIR_FILE_SIZE + 2]
        add [dir_bytes], ax
        adc [dir_bytes + 2], dx
        mov cx, SIZE_COLUMNS
        call print_dec32_right
.stamp:
        PRINT "  "
        mov ax, [si + DIR_DATE]
        mov di, stamp
        call fmt_fat_date
        call print_stamp
        PRINT "  "
        mov ax, [si + DIR_TIME]
        mov di, stamp
        call fmt_fat_time
        call print_stamp
        jmp print_newline

; ----------------------------------------------------------------------------
; print_stamp - `stamp` up to DI
;   In:       DI = the end of the text in stamp
;   Out:      nothing
;   Destroys: CX
; ----------------------------------------------------------------------------
print_stamp:
        push si
        mov cx, di
        mov si, stamp
        sub cx, si
        sys SYS_WRITE
        pop si
        ret

begin_udata
stamp               times STAMP_CHARS db 0
end_udata

; ----------------------------------------------------------------------------
; print_name_part - a padded name or label without its trailing spaces
;   In:       SI = DIR_NAME_LENGTH bytes
;   Out:      nothing
;   Destroys: CX, DI
; ----------------------------------------------------------------------------
print_name_part:
        mov cx, DIR_NAME_LENGTH
.trim:
        mov di, si
        add di, cx
        cmp byte [di - 1], ' '
        jne .write
        loop .trim
        ret
.write:
        sys SYS_WRITE
        ret

; ----------------------------------------------------------------------------
; cmd_cd - show a drive's current directory, or change it
;   In:       SI = the rest of the line; DS = ES = the program's data
;   Out:      nothing
;   Destroys: everything but DS, ES
; ----------------------------------------------------------------------------
cmd_cd:
        mov al, [current_drive]
        cmp byte [si], 0
        je .show
        cmp byte [si + 1], ':'
        jne .change
        cmp byte [si + 2], ' '          ; "cd b:", nothing after: B's directory
        ja .change
        call path_drive_letter
        jc .out
        mov al, [path_drive]
.show:
        call print_where
        jmp print_newline
.change:
        call path_argument
        jc .out
        call fat_find
        jnc .found
        cmp ax, E_NOT_FOUND             ; DOS says the same of all three
        je .invalid
        cmp ax, E_NOT_DIR
        je .invalid
        cmp ax, E_BAD_NAME
        je .invalid
        jmp report_failure
.found:
        cmp byte [found_dir], 0
        je .invalid
        mov al, [path_drive]
        call where_of
        mov si, found
        mov di, bx
        mov cx, WHERE_SIZE
        rep movsb
.out:
        ret
.invalid:
        PRINT "Invalid directory", CHAR_LF
        ret

; ----------------------------------------------------------------------------
; file_argument - path_find for a command that needs a file
;   In:       SI = the rest of the line
;   Out:      CF clear and the file ready to read (file_first); or CF set
;             (the trouble printed)
;   Destroys: everything but DS, ES
; ----------------------------------------------------------------------------
file_argument:
        cmp byte [si], 0
        je .missing
        call path_find
        jc .out
        cmp byte [found_dir], 0
        jne .directory
        call file_first
        jc report_failure
.out:
        ret
.missing:
        PRINT "Required parameter missing", CHAR_LF
        stc
        ret
.directory:
        PRINT "Access denied", CHAR_LF
        stc
        ret

; ----------------------------------------------------------------------------
; cmd_type - a file's bytes to the console
;   In:       SI = the rest of the line; DS = ES = the program's data
;   Out:      nothing
;   Destroys: everything but DS, ES
; ----------------------------------------------------------------------------
cmd_type:
        call file_argument
        jc .out
.sector:
        call file_next
        jc report_failure
        jz .out
        mov si, io_sector
        sys SYS_WRITE
        jmp .sector
.out:
        ret

; ----------------------------------------------------------------------------
; cmd_print - a file's bytes to the printer on LPT1
;   In:       SI = the rest of the line; DS = ES = the program's data
;   Out:      nothing
;   Destroys: everything but DS, ES
; ----------------------------------------------------------------------------
cmd_print:
        call file_argument
        jc .out
        mov word [printed], 0
        mov word [printed + 2], 0
.sector:
        call file_next
        jc report_failure
        jz .done
        mov si, io_sector
        mov al, PRINTER_LPT1
        sys SYS_PRINT
        jc .printer
        add [printed], ax
        adc word [printed + 2], 0
        jmp .sector
.done:
        PRINT "printed "
        mov ax, [printed]
        mov dx, [printed + 2]
        call print_dec32
        PRINT " bytes on LPT1", CHAR_LF
.out:
        ret
.printer:
        cmp ax, E_PAPER
        jne .not_answering
        PRINT "Printer out of paper", CHAR_LF
        ret
.not_answering:
        cmp ax, E_TIMEOUT
        jne .other
        PRINT "Printer not answering", CHAR_LF
        ret
.other:
        PRINT "Error "
        call print_dec
        jmp print_newline
