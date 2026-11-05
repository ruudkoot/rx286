; ============================================================================
; rx286 - src/os/files.asm
; The file calls, in DOS's way (roadmap l4.md L9, D16): SYS_FIND to
; SYS_FREE, on the FAT12 library (fat.asm), which came here from the shell.
;
; Each program has a files segment of its own (OS_K_FILES; os.inc's
; FILES_SIZE), which the root makes and gives only to the OS server: its
; current drive and each drive's current directory, as DOS keeps them, and
; the library's state and buffers. So the thread that serves a program
; works in that segment alone, and no program's calls wait for another's or
; disturb them; a program's restart (Ctrl+Break) cannot leave anything
; held. What SYS_FIND found is read by SYS_DIR_NEXT or SYS_FILE_NEXT until
; the program's next SYS_FIND, SYS_CHDIR or SYS_FREE. The sectors come from
; the disk drivers into the segment (disk_call); the path comes in, and the
; results go out, through the transfer segment.
; ============================================================================

%include "fat.asm"

[absolute FAT_STATE_SIZE]
files_ready         resb 1              ; 0 until the program's first file call
current_drive       resb 1
wheres              resb DRIVES * WHERE_SIZE    ; each drive's current directory
find_state          resb 1              ; FIND_*: what SYS_FIND left to read
call_drive          resb 1              ; the call's drive
path_in             resb PATH_IN_MAX + 1
FILES_USED          equ $
__?SECT?__

FIND_NONE           equ 0               ; nothing (or it was forgotten)
FIND_FOUND          equ 1               ; found: its reading not begun
FIND_READING        equ 2

%if FILES_USED > FILES_SIZE
  %error "files.asm: the files segment's layout is larger than FILES_SIZE"
%endif

; ----------------------------------------------------------------------------
; files - a file call, on the program's files segment
;   In:       AL = the function (SYS_FIND to SYS_FREE); DS = the program's
;             transfer segment, its registers in the block
;   Out:      the block's registers and flags
;   Destroys: AX, BX, CX, DX, SI, DI
; ----------------------------------------------------------------------------
files:
        push ds
        push es
        push bp
        mov bp, ds                      ; BP = the transfer segment
        mov bl, al
        sub bl, SYS_FIND
        xor bh, bh
        shl bx, 1
        mov ax, OS_K_FILES
        call program_slot
        mov ds, ax
        mov es, ax
        cmp byte [files_ready], 0
        jne .ready
        call files_init
.ready:
        call xfer_al
        call [cs:file_calls + bx]
        jnc .done
        mov bx, XFER_AX
        call xfer_put                   ; the error
        mov ax, 1                       ; CF
        jmp .flags
.done:
        xor ax, ax
.flags:
        mov bx, XFER_FLAGS
        call xfer_put
        pop bp
        pop es
        pop ds
        ret

file_calls          dw file_find, file_chdir, file_drive, file_getcwd
                    dw file_dir_next, file_file_next, file_free

%if SYS_CHDIR != SYS_FIND + 1 || SYS_DRIVE != SYS_FIND + 2 || SYS_GETCWD != SYS_FIND + 3
  %error "files.asm: file_calls assumes the file calls' numbers"
%endif
%if SYS_DIR_NEXT != SYS_FIND + 4 || SYS_FILE_NEXT != SYS_FIND + 5 || SYS_FREE != SYS_FIND + 6
  %error "files.asm: file_calls assumes the file calls' numbers"
%endif

; ----------------------------------------------------------------------------
; files_init - the program's first file call: drive A current, every drive
; at its root
;   In:       DS = ES = the files segment
;   Out:      nothing
;   Destroys: AX, CX, DI
; ----------------------------------------------------------------------------
files_init:
        mov byte [current_drive], DRIVE_A
        mov di, wheres
        mov cx, DRIVES
.drive:
        mov word [di + WHERE_CLUSTER], 0
        mov word [di + WHERE_PATH], CHAR_PATH_SEPARATOR    ; "\" and its zero
        add di, WHERE_SIZE
        loop .drive
        mov byte [files_ready], 1
        ret

; ----------------------------------------------------------------------------
; file_find - SYS_FIND: what a path names, as a record (FIND_*); its entries
; or its sectors then for SYS_DIR_NEXT or SYS_FILE_NEXT
;   In:       AL = the drive; BP = the transfer segment (the path, the room
;             for the record); DS = ES = the files segment
;   Out:      CF clear; or CF set and AX = the error
;   Destroys: AX, BX, CX, DX, SI, DI
; ----------------------------------------------------------------------------
file_find:
        mov byte [find_state], FIND_NONE
        call drive_checked
        jc .out
        call room_checked
        jc .out
        call path_taken
        jc .out
        call drive_mounted              ; BX = its current directory
        jc .out
        mov si, path_in
        call fat_find
        jc .out
        mov byte [find_state], FIND_FOUND
        mov si, FOUND_RECORD
        mov cx, FIND_SIZE
        call xfer_out
        clc
.out:
        ret

; ----------------------------------------------------------------------------
; file_chdir - SYS_CHDIR: a drive's current directory
;   In:       AL = the drive; BP = the transfer segment (the path); DS = ES =
;             the files segment
;   Out:      CF clear; or CF set and AX = the error (E_NOT_DIR: a file)
;   Destroys: AX, BX, CX, DX, SI, DI
; ----------------------------------------------------------------------------
file_chdir:
        mov byte [find_state], FIND_NONE
        call drive_checked
        jc .out
        call path_taken
        jc .out
        call drive_mounted
        jc .out
        mov si, path_in
        call fat_find
        jc .out
        mov ax, E_NOT_DIR
        cmp byte [found_dir], 0
        stc
        je .out
        mov al, [call_drive]
        call where_of
        mov di, bx
        mov si, found
        mov cx, WHERE_SIZE
        rep movsb
        clc
.out:
        ret

; ----------------------------------------------------------------------------
; file_drive - SYS_DRIVE: the current drive, made so if AL names one
;   In:       AL = a drive, or DRIVES or more; DS = ES = the files segment
;   Out:      CF clear (the block's AX the current drive)
;   Destroys: AX, BX
; ----------------------------------------------------------------------------
file_drive:
        cmp al, DRIVES
        jae .tell
        mov [current_drive], al
.tell:
        mov al, [current_drive]
        xor ah, ah
        mov bx, XFER_AX
        call xfer_put
        clc
        ret

; ----------------------------------------------------------------------------
; file_getcwd - SYS_GETCWD: a drive's current directory, its path
;   In:       AL = the drive; BP = the transfer segment (the room); DS = ES =
;             the files segment
;   Out:      CF clear; or CF set and AX = the error
;   Destroys: AX, BX, CX, SI, DI
; ----------------------------------------------------------------------------
file_getcwd:
        call drive_checked
        jc .out
        call room_checked
        jc .out
        call where_of
        lea si, [bx + WHERE_PATH]
        mov cx, PATH_MAX + 1
        call xfer_out
        clc
.out:
        ret

; ----------------------------------------------------------------------------
; file_dir_next - SYS_DIR_NEXT: the next entry of the directory found
;   In:       BP = the transfer segment (the room); DS = ES = the files
;             segment
;   Out:      CF clear (the block's AX 1, or 0 at the end); or CF set and
;             AX = the error (E_NOT_DIR: a file was found; E_INVAL: nothing)
;   Destroys: AX, BX, CX, DX, SI, DI
; ----------------------------------------------------------------------------
file_dir_next:
        call room_checked
        jc .out
        mov ax, E_INVAL
        cmp byte [find_state], FIND_NONE
        je .failed
        mov ax, E_NOT_DIR
        cmp byte [found_dir], 0
        je .failed
        cmp byte [find_state], FIND_READING
        je .walk
        mov ax, [found + WHERE_CLUSTER]
        call dir_first
        jc .out
        mov byte [find_state], FIND_READING
.walk:
        call dir_next
        jc .out
        mov ax, 0
        jz .tell                        ; the end
        mov cx, DIR_ENTRY_SIZE
        call xfer_out
        mov ax, 1
.tell:
        mov bx, XFER_AX
        call xfer_put
        clc
.out:
        ret
.failed:
        stc
        ret

; ----------------------------------------------------------------------------
; file_file_next - SYS_FILE_NEXT: the next sector of the file found
;   In:       BP = the transfer segment (the room); DS = ES = the files
;             segment
;   Out:      CF clear (the block's CX the bytes, 0 at the end); or CF set
;             and AX = the error (E_INVAL: a directory or nothing found)
;   Destroys: AX, BX, CX, DX, SI, DI
; ----------------------------------------------------------------------------
file_file_next:
        call room_checked
        jc .out
        mov ax, E_INVAL
        cmp byte [find_state], FIND_NONE
        je .failed
        cmp byte [found_dir], 0
        jne .failed
        cmp byte [find_state], FIND_READING
        je .read
        call file_first
        jc .out
        mov byte [find_state], FIND_READING
.read:
        call file_next
        jc .out
        mov ax, 0
        jz .tell                        ; the end
        push cx
        mov si, io_sector
        call xfer_out
        pop ax
.tell:
        mov bx, XFER_CX
        call xfer_put
        clc
.out:
        ret
.failed:
        stc
        ret

; ----------------------------------------------------------------------------
; file_free - SYS_FREE: the bytes free on a drive's volume
;   In:       AL = the drive; DS = ES = the files segment
;   Out:      CF clear; or CF set and AX = the error
;   Destroys: AX, BX, CX, DX, SI, DI
; ----------------------------------------------------------------------------
file_free:
        mov byte [find_state], FIND_NONE
        call drive_checked
        jc .out
        call drive_mounted
        jc .out
        call fat_free
        jc .out
        mov bx, XFER_AX
        call xfer_put
        mov ax, dx
        mov bx, XFER_DX
        call xfer_put
        clc
.out:
        ret

; ----------------------------------------------------------------------------
; drive_checked - the call's drive, if there is such a drive
;   In:       AL = the drive
;   Out:      CF clear and call_drive; or CF set and AX = E_INVAL
;   Destroys: nothing else
; ----------------------------------------------------------------------------
drive_checked:
        cmp al, DRIVES
        jae .invalid
        mov [call_drive], al
        clc
        ret
.invalid:
        mov ax, E_INVAL
        stc
        ret

; ----------------------------------------------------------------------------
; drive_mounted - the call's drive mounted
;   In:       call_drive; DS = ES = the files segment
;   Out:      CF clear and BX = the drive's current directory; or CF set
;             and AX = the error
;   Destroys: AX, BX, CX, DX, SI, DI
; ----------------------------------------------------------------------------
drive_mounted:
        mov al, [call_drive]
        call fat_mount
        jc .out
        mov al, [call_drive]
        call where_of
        clc
.out:
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
; room_checked - may the call fill its buffer? (the stub's XFER_BAD: not)
;   In:       BP = the transfer segment
;   Out:      CF clear; or CF set and AX = E_FAULT
;   Destroys: nothing else
; ----------------------------------------------------------------------------
room_checked:
        push ds
        mov ds, bp
        cmp word [XFER_DI], XFER_DATA
        pop ds
        jne .fault
        clc
        ret
.fault:
        mov ax, E_FAULT
        stc
        ret

; ----------------------------------------------------------------------------
; path_taken - the path, from the transfer segment into path_in; it must end
; (a zero or a space) within PATH_IN_MAX bytes
;   In:       BP = the transfer segment; DS = ES = the files segment
;   Out:      CF clear; or CF set and AX = E_FAULT or E_BAD_NAME
;   Destroys: AX, CX, SI, DI
; ----------------------------------------------------------------------------
path_taken:
        push ds
        mov ds, bp
        mov si, [XFER_SI]
        cmp si, XFER_DATA
        jne .fault
        mov di, path_in
        mov cx, PATH_IN_MAX
        rep movsb
        pop ds
        mov byte [di], 0
        mov si, path_in
        mov cx, PATH_IN_MAX
.end:
        lodsb
        cmp al, ' '
        je .ends
        test al, al
        je .ends
        loop .end
        mov ax, E_BAD_NAME
        stc
        ret
.ends:
        clc
        ret
.fault:
        pop ds
        mov ax, E_FAULT
        stc
        ret

; ----------------------------------------------------------------------------
; xfer_al - the call's AL, from the block
;   In:       BP = the transfer segment
;   Out:      AL
;   Destroys: nothing else
; ----------------------------------------------------------------------------
xfer_al:
        push ds
        mov ds, bp
        mov al, [XFER_AX]
        pop ds
        ret

; ----------------------------------------------------------------------------
; xfer_put - a word of the block
;   In:       BX = its offset (XFER_*); AX = the word; BP = the transfer
;             segment
;   Out:      nothing
;   Destroys: nothing
; ----------------------------------------------------------------------------
xfer_put:
        push ds
        mov ds, bp
        mov [bx], ax
        pop ds
        ret

; ----------------------------------------------------------------------------
; xfer_out - bytes of the files segment into the transfer segment's buffer
;   In:       SI = where; CX = how many; BP = the transfer segment; DS = the
;             files segment
;   Out:      nothing
;   Destroys: CX, SI, DI
; ----------------------------------------------------------------------------
xfer_out:
        push es
        mov es, bp
        mov di, XFER_DATA
        rep movsb
        pop es
        ret

; ----------------------------------------------------------------------------
; fat_read - a sector of a drive into the files segment (the library's
; vol_read ends here): through the drive's driver, after the checks of
; SYS_DISK_READ
;   In:       AL = the drive; CX = the sector; DI = SECTOR_SIZE bytes for
;             it; DS = the files segment
;   Out:      CF clear; or CF set and AX = the error
;   Destroys: AX, CX
; ----------------------------------------------------------------------------
fat_read:
        push bx
        push dx
        push si
        push di
        xor ah, ah
        mov bx, ax                      ; BX = the drive
        mov ax, E_INVAL
        cmp bx, DRIVES
        jae .failed
        mov si, bx
        shl si, 1
        cmp cx, [cs:drive_sectors + si]
        jae .failed
        mov si, di
        mov al, DRV_DISK_READ
        call disk_call                  ; BX = 0 or the error
        mov ax, bx
        test ax, ax
        jz .out                         ; (CF clear)
.failed:
        stc
.out:
        pop di
        pop si
        pop dx
        pop bx
        ret
