; ============================================================================
; rx286 - src/os/fat.asm
; The OS server's FAT12 library (roadmap l4.md L9; storage roadmap D7): a
; drive's volume, its directories and its files, read a sector at a time
; from the disk drivers (fat_read: files.asm). The shell's until L9.
;
; fat_mount reads what a command needs to know of a drive: on a fixed disk,
; the master boot record's first FAT12 partition; then the volume's boot
; sector, whose BPB says where the FATs, the root directory and the clusters
; lie. Each command mounts afresh, so a changed diskette is read as it is.
; fat_find follows a path, dir_first and dir_next walk a directory,
; file_first and file_next read a file. A cluster's successor comes from
; the FAT through a window of two sectors, enough for an entry that
; straddles them (fat12_next). Every cluster number is checked against the
; volume and every chain against looping, so a damaged disk gives an error
; (E_BROKEN), never a hang. Nothing is written. The library's state and
; buffers - a sector for directories and files, two for the FAT - are in
; the files segment of the program it works for (files.asm): the layout
; below, from its offset 0, with DS = ES = that segment.
; ============================================================================

; (Its errors, E_NOT_FAT12 to E_BROKEN, are the file calls': syscalls.inc.)

MBR_SIGNATURE       equ 0x1FE           ; the word 0AA55h
MBR_PARTITIONS      equ 0x1BE           ; four entries
MBR_PARTITION_SIZE  equ 16
MBR_PARTITION_COUNT equ 4
PARTITION_TYPE      equ 4
PARTITION_START     equ 8               ; dword: its first sector on the disk
PARTITION_FAT12     equ 0x01
BOOT_SIGNATURE      equ 0xAA55
NAME_TEXT_MAX       equ FAT_BASE_LENGTH + 1 + FAT_EXT_LENGTH   ; NAME.EXT

; A drive's current directory, kept for each program (files.asm): its first
; cluster (0 the root) and its path ("\" the root), as fat_find takes and
; gives them.
WHERE_CLUSTER       equ 0
WHERE_PATH          equ 2
WHERE_SIZE          equ WHERE_PATH + PATH_MAX + 1

[absolute 0]
vol_drive           resb 1
vol_start           resw 1              ; the volume's first sector on the disk
vol_cluster_sectors resw 1
vol_fat             resw 1              ; the first FAT, from the volume's first sector
vol_root            resw 1              ; the root directory
vol_root_sectors    resw 1
vol_data            resw 1              ; cluster 2
vol_clusters        resw 1              ; clusters 2 to vol_clusters + 1 hold data
fat_window          resb 2 * SECTOR_SIZE
fat_window_first    resw 1              ; the FAT's sector in the window's first half
fat_window_valid    resb 1
io_sector           resb SECTOR_SIZE    ; the sector of a directory or file being read
walk_cluster        resw 1              ; the directory walk: its cluster, 0 the root
walk_next           resw 1              ; the next sector to read
walk_left           resw 1              ; sectors left in the cluster (or the root)
walk_entry          resw 1              ; the next entry's offset in io_sector
walk_steps          resw 1              ; clusters followed: more than the volume has is a loop
file_next_sector    resw 1              ; the file read: as the walk's
file_cluster        resw 1
file_left_sectors   resw 1
file_bytes          resd 1              ; bytes of the file not yet read
file_steps          resw 1
found               resb WHERE_SIZE     ; what fat_find found: its cluster and path,
found_dir           resb 1              ; 1 if a directory (the root too),
found_entry         resb DIR_ENTRY_SIZE ; its entry, unless the root,
vol_label           resb DIR_NAME_LENGTH    ; and the volume's label: SYS_FIND's record
wanted              resb DIR_NAME_LENGTH
name_text           resb NAME_TEXT_MAX
path_rest           resw 1
FAT_STATE_SIZE      equ $
__?SECT?__

FOUND_RECORD        equ found + WHERE_PATH  ; SYS_FIND's record
%if found_dir - FOUND_RECORD != FIND_DIR || found_entry - FOUND_RECORD != FIND_ENTRY
  %error "fat.asm: found, found_dir, found_entry and vol_label must be SYS_FIND's record"
%endif
%if vol_label - FOUND_RECORD != FIND_LABEL
  %error "fat.asm: found, found_dir, found_entry and vol_label must be SYS_FIND's record"
%endif
%if DIR_ENTRY_SIZE != FIND_ENTRY_SIZE || DIR_NAME_LENGTH != FIND_LABEL_SIZE
  %error "fat.asm: SYS_FIND's record does not match FAT's entry"
%endif

; ----------------------------------------------------------------------------
; fat_mount - a drive's FAT12 volume: where it starts, and its BPB
;   In:       AL = the drive; DS = ES = the server's data
;   Out:      CF clear; or CF set and AX = the kernel's error or E_NOT_FAT12
;   Destroys: AX, BX, CX, DX, SI, DI
; ----------------------------------------------------------------------------
fat_mount:
        mov [vol_drive], al
        mov word [vol_start], 0
        mov byte [fat_window_valid], 0
        cmp al, DRIVE_C
        jb .boot_sector
        xor ax, ax                      ; a fixed disk: its master boot record
        mov di, io_sector
        call vol_read
        jc .out
        cmp word [io_sector + MBR_SIGNATURE], BOOT_SIGNATURE
        jne .not_fat12
        mov si, io_sector + MBR_PARTITIONS
        mov cx, MBR_PARTITION_COUNT
.partition:
        cmp byte [si + PARTITION_TYPE], PARTITION_FAT12
        je .found
        add si, MBR_PARTITION_SIZE
        loop .partition
        jmp .not_fat12
.found:
        cmp word [si + PARTITION_START + 2], 0
        jne .not_fat12                  ; past the 16 bits of a sector's number
        mov ax, [si + PARTITION_START]
        mov [vol_start], ax
.boot_sector:
        xor ax, ax
        mov di, io_sector
        call vol_read
        jc .out
        cmp word [io_sector + BPB_BYTES_PER_SECTOR], SECTOR_SIZE
        jne .not_fat12
        mov al, [io_sector + BPB_SECTORS_PER_CLUSTER]
        xor ah, ah
        test ax, ax
        jz .not_fat12
        mov [vol_cluster_sectors], ax
        dec al
        test [io_sector + BPB_SECTORS_PER_CLUSTER], al
        jnz .not_fat12                  ; not a power of two
        mov ax, [io_sector + BPB_RESERVED_SECTORS]
        test ax, ax
        jz .not_fat12
        mov [vol_fat], ax
        mov al, [io_sector + BPB_FATS]
        dec al
        cmp al, 1
        ja .not_fat12                   ; one FAT or two
        inc al
        xor ah, ah
        mul word [io_sector + BPB_SECTORS_PER_FAT]
        test dx, dx
        jnz .not_fat12
        test ax, ax
        jz .not_fat12
        add ax, [vol_fat]
        jc .not_fat12
        mov [vol_root], ax
        mov ax, [io_sector + BPB_ROOT_ENTRIES]
        test ax, (SECTOR_SIZE / DIR_ENTRY_SIZE) - 1
        jnz .not_fat12                  ; whole sectors of entries
        shr ax, SECTOR_SHIFT - 5        ; sixteen entries a sector
        jz .not_fat12
        mov [vol_root_sectors], ax
        add ax, [vol_root]
        jc .not_fat12
        mov [vol_data], ax
        mov ax, [io_sector + BPB_TOTAL_SECTORS]
        add ax, [vol_start]
        jc .not_fat12                   ; it would end past sector FFFFh
        mov ax, [io_sector + BPB_TOTAL_SECTORS]
        sub ax, [vol_data]              ; 0 total sectors (a 32-bit count) fails here too
        jbe .not_fat12
        xor dx, dx
        div word [vol_cluster_sectors]
        cmp ax, FAT12_MAX_CLUSTERS
        ja .not_fat12
        test ax, ax
        jz .not_fat12
        mov [vol_clusters], ax
        mov dx, [io_sector + BPB_SECTORS_PER_FAT]
        cmp dx, FAT12_MAX_FAT_SECTORS
        jae .fat_holds                  ; enough for any FAT12 volume
        add ax, FAT12_FIRST_CLUSTER     ; entries: the clusters and the two before
        mov cx, ax
        shr cx, 1
        add ax, cx
        inc ax                          ; bytes: 1.5 an entry, rounded up
        shl dx, SECTOR_SHIFT
        cmp ax, dx
        ja .not_fat12                   ; a FAT too short for its clusters
.fat_holds:
        mov si, io_sector + BPB_LABEL
        mov di, vol_label
        mov cx, DIR_NAME_LENGTH
        cmp byte [io_sector + BPB_EXTENDED], BPB_EXTENDED_MARK
        jne .no_label
        rep movsb
        clc
.out:
        ret
.no_label:
        mov si, no_label
.no_label_char:
        mov al, [cs:si]
        stosb
        inc si
        loop .no_label_char
        clc
        ret
.not_fat12:
        mov ax, E_NOT_FAT12
        stc
        ret

; ----------------------------------------------------------------------------
; vol_read - a sector of the volume
;   In:       AX = the sector, from the volume's first; DI = SECTOR_SIZE
;             bytes for it; DS = ES = the server's data
;   Out:      CF and AX as SYS_DISK_READ returns them
;   Destroys: AX, CX
; ----------------------------------------------------------------------------
vol_read:
        mov cx, ax
        add cx, [vol_start]
        jc .past                        ; past sector FFFFh: no drive has it
        mov al, [vol_drive]
        jmp fat_read
.past:
        mov ax, E_BROKEN
        ret                             ; CF set by the ADD

; ----------------------------------------------------------------------------
; fat_next - the cluster after a cluster, from the FAT
;   In:       AX = a cluster of the volume (checked); DS = ES = the server's data
;   Out:      CF clear and AX = its FAT entry; or CF set and AX = the error
;   Destroys: nothing else
; ----------------------------------------------------------------------------
fat_next:
        push bx
        push cx
        push dx
        push si
        push di
        mov bx, ax
        shr bx, 1
        add bx, ax                      ; the entry's first byte in the FAT
        shr bx, SECTOR_SHIFT            ; the FAT's sector holding it
        cmp byte [fat_window_valid], 0
        je .load
        cmp bx, [fat_window_first]
        je .loaded
.load:
        mov byte [fat_window_valid], 0
        mov [fat_window_first], bx
        push ax
        mov ax, [vol_fat]
        add ax, bx
        push ax
        mov di, fat_window
        call vol_read
        pop dx
        jc .failed
        mov ax, dx
        inc ax                          ; and the next: an entry may straddle the two
        mov di, fat_window + SECTOR_SIZE
        call vol_read
        jc .failed
        pop ax
        mov byte [fat_window_valid], 1
.loaded:
        mov si, bx                      ; fat12_next indexes the whole FAT: let the
        shl si, SECTOR_SHIFT            ; window stand at its place in it (the
        neg si                          ; offsets wrap at 64 KB)
        add si, fat_window
        call fat12_next
        clc
        jmp .out
.failed:
        add sp, 2                       ; the cluster
        stc
.out:
        pop di
        pop si
        pop dx
        pop cx
        pop bx
        ret

; ----------------------------------------------------------------------------
; cluster_check - is a cluster one of the volume's data clusters?
;   In:       AX = the cluster
;   Out:      CF clear; or CF set (AX = E_BROKEN)
;   Destroys: nothing else
; ----------------------------------------------------------------------------
cluster_check:
        cmp ax, FAT12_FIRST_CLUSTER
        jb .broken
        push ax
        sub ax, FAT12_FIRST_CLUSTER
        cmp ax, [vol_clusters]
        pop ax
        jae .broken
        clc
        ret
.broken:
        mov ax, E_BROKEN
        stc
        ret

; ----------------------------------------------------------------------------
; cluster_sector - a data cluster's first sector, from the volume's first
;   In:       AX = the cluster (checked)
;   Out:      AX = the sector
;   Destroys: nothing else
; ----------------------------------------------------------------------------
cluster_sector:
        push dx
        sub ax, FAT12_FIRST_CLUSTER
        mul word [vol_cluster_sectors]
        add ax, [vol_data]
        pop dx
        ret

; ----------------------------------------------------------------------------
; chain_next - the next cluster of a chain, checked
;   In:       AX = a cluster; BX = the chain's count of clusters followed
;   Out:      CF clear and ZF set at the chain's end; CF, ZF clear and AX =
;             the next cluster, BX counted; or CF set and AX = the error
;   Destroys: nothing else
; ----------------------------------------------------------------------------
chain_next:
        call fat_next
        jc .out
        cmp ax, FAT12_END
        jae .end
        call cluster_check
        jc .out
        inc bx
        cmp bx, [vol_clusters]
        ja .loop                        ; more clusters than the volume has
        or bx, bx                       ; ZF clear (BX is at least 1)
        clc
.out:
        ret
.end:
        cmp ax, ax                      ; ZF set, CF clear
        ret
.loop:
        mov ax, E_BROKEN
        stc
        ret

; ----------------------------------------------------------------------------
; dir_first - start walking a directory
;   In:       AX = its first cluster, 0 for the root directory
;   Out:      CF clear; or CF set and AX = E_BROKEN
;   Destroys: AX
; ----------------------------------------------------------------------------
dir_first:
        mov [walk_cluster], ax
        mov word [walk_steps], 0
        mov word [walk_entry], SECTOR_SIZE  ; a sector to read first
        test ax, ax
        jnz .cluster
        mov ax, [vol_root]
        mov [walk_next], ax
        mov ax, [vol_root_sectors]
        mov [walk_left], ax
        clc
        ret
.cluster:
        call cluster_check
        jc .out
        call cluster_sector
        mov [walk_next], ax
        mov ax, [vol_cluster_sectors]
        mov [walk_left], ax
        clc
.out:
        ret

; ----------------------------------------------------------------------------
; dir_next - the directory's next entry for a file or directory (deleted
; entries, volume labels and long names passed over)
;   In:       a walk dir_first began; DS = ES = the server's data
;   Out:      CF set and AX = an error; or CF clear and ZF set at the end; or
;             CF, ZF clear and SI = the entry, in io_sector
;   Destroys: AX, BX, CX, DI
; ----------------------------------------------------------------------------
dir_next:
        cmp word [walk_entry], SECTOR_SIZE
        jb .entry
        cmp word [walk_left], 0
        jne .read
        mov ax, [walk_cluster]
        test ax, ax
        jz .end                         ; the root directory has no more sectors
        mov bx, [walk_steps]
        call chain_next
        jc .out
        jz .end
        mov [walk_steps], bx
        mov [walk_cluster], ax
        call cluster_sector
        mov [walk_next], ax
        mov ax, [vol_cluster_sectors]
        mov [walk_left], ax
.read:
        mov ax, [walk_next]
        inc word [walk_next]
        dec word [walk_left]
        mov di, io_sector
        call vol_read
        jc .out
        mov word [walk_entry], 0
.entry:
        mov si, io_sector
        add si, [walk_entry]
        add word [walk_entry], DIR_ENTRY_SIZE
        mov al, [si + DIR_NAME]
        cmp al, DIR_END
        je .end
        cmp al, DIR_DELETED
        je dir_next
        test byte [si + DIR_ATTRIBUTES], DIR_ATTR_VOLUME   ; labels, long names
        jnz dir_next
        or si, si                       ; ZF clear: io_sector is not at 0
        clc
.out:
        ret
.end:
        mov word [walk_entry], SECTOR_SIZE
        mov word [walk_left], 0
        mov word [walk_cluster], 0      ; and stay at the end
        cmp ax, ax                      ; ZF set, CF clear
        ret

; ----------------------------------------------------------------------------
; fat_find - follow a path to what its last name names
;   In:       DS:SI = the path, ending at zero or a space: names between
;             separators (\ or /), from the root if it starts with one, else
;             from the directory BX names; "." and ".." as in DOS;
;             BX = a directory: WHERE_CLUSTER and WHERE_PATH; the volume
;             mounted; DS = ES = the server's data
;   Out:      CF clear, SI past the path, and `found` = its first cluster and
;             path, found_dir, found_entry (unless it is the root); or CF set
;             and AX = an error
;   Destroys: AX, BX, CX, DX, DI
; ----------------------------------------------------------------------------
fat_find:
        push si
        mov si, bx                      ; start where BX is
        mov di, found
        mov cx, WHERE_SIZE
        rep movsb
        pop si
        mov byte [found_dir], 1
        mov al, [si]
        cmp al, CHAR_PATH_SEPARATOR
        je .from_root
        cmp al, CHAR_PATH_OTHER
        jne .next
.from_root:
        mov word [found + WHERE_CLUSTER], 0
        mov word [found + WHERE_PATH], CHAR_PATH_SEPARATOR   ; "\" and its zero
.next:
        call skip_separators
        call fat_name_ends
        je .done
        cmp byte [found_dir], 0
        je .not_dir
        mov di, wanted
        call fat_name_parse
        jc .bad_name
        mov [path_rest], si
        cmp word [wanted], '. '         ; "." is where we are
        je .next
        mov ax, [found + WHERE_CLUSTER]
        call dir_first
        jc .failed
.search:
        call dir_next
        jc .failed
        jz .not_found
        mov di, wanted
        mov cx, DIR_NAME_LENGTH
        push si
        repe cmpsb
        pop si
        jne .search
        mov di, found_entry
        mov cx, DIR_ENTRY_SIZE
        rep movsb
        mov ax, [found_entry + DIR_FIRST_CLUSTER]
        mov [found + WHERE_CLUSTER], ax
        mov byte [found_dir], 0
        test byte [found_entry + DIR_ATTRIBUTES], DIR_ATTR_DIRECTORY
        jz .path
        mov byte [found_dir], 1
.path:
        call found_path_add
        jc .bad_name
        mov si, [path_rest]
        jmp .next
.done:
        clc
        ret
.not_dir:
        mov ax, E_NOT_DIR
        stc
        ret
.not_found:
        mov ax, E_NOT_FOUND
        stc
        ret
.bad_name:
        mov ax, E_BAD_NAME
.failed:
        stc
        ret

; ----------------------------------------------------------------------------
; found_path_add - the path in `found` after a step to `wanted`: ".." takes
;   its last name off, another name goes on the end
;   In:       wanted; found_entry (its name); DS = ES = the server's data
;   Out:      CF clear; or CF set: it would be longer than PATH_MAX (and is
;             unchanged)
;   Destroys: AX, CX, SI, DI
; ----------------------------------------------------------------------------
found_path_add:
        mov di, found + WHERE_PATH
        xor al, al
        mov cx, PATH_MAX + 1
        repne scasb
        dec di                          ; DI at its zero
        cmp word [wanted], '..'
        jne .add
.back:
        dec di                          ; to the separator before the last name
        cmp byte [di], CHAR_PATH_SEPARATOR
        jne .back
        cmp di, found + WHERE_PATH
        jne .cut
        inc di                          ; the root keeps its separator
.cut:
        mov byte [di], 0
        clc
        ret
.add:
        push di
        mov si, found_entry + DIR_NAME
        mov di, name_text
        call fat_name_text
        mov cx, di
        sub cx, name_text               ; CX = the name's length
        pop di
        mov ax, di                      ; AX = where the path's zero would go:
        add ax, cx                      ; after the name, and a separator
        cmp di, found + WHERE_PATH + 1  ; unless the path is the root's
        je .room
        inc ax
.room:
        cmp ax, found + WHERE_PATH + PATH_MAX
        ja .long                        ; checked before anything is written
        cmp di, found + WHERE_PATH + 1
        je .name
        mov al, CHAR_PATH_SEPARATOR
        stosb
.name:
        mov si, name_text
        rep movsb
        xor al, al
        stosb
        clc
        ret
.long:
        stc
        ret

; ----------------------------------------------------------------------------
; skip_separators - move past \ and /
;   In:       DS:SI = the text
;   Out:      SI at the first character that is neither
;   Destroys: nothing
; ----------------------------------------------------------------------------
skip_separators:
        cmp byte [si], CHAR_PATH_SEPARATOR
        je .skip
        cmp byte [si], CHAR_PATH_OTHER
        jne .done
.skip:
        inc si
        jmp skip_separators
.done:
        ret

; ----------------------------------------------------------------------------
; file_first - start reading the file found_entry names
;   In:       found_entry; DS = ES = the server's data
;   Out:      CF clear; or CF set and AX = E_BROKEN
;   Destroys: AX
; ----------------------------------------------------------------------------
file_first:
        mov ax, [found_entry + DIR_FILE_SIZE]
        mov [file_bytes], ax
        mov ax, [found_entry + DIR_FILE_SIZE + 2]
        mov [file_bytes + 2], ax
        mov word [file_steps], 0
        mov word [file_left_sectors], 0
        mov ax, [file_bytes]
        or ax, [file_bytes + 2]
        jz .done                        ; empty: no cluster
        mov ax, [found_entry + DIR_FIRST_CLUSTER]
        call cluster_check
        jc .out
        mov [file_cluster], ax
        call cluster_sector
        mov [file_next_sector], ax
        mov ax, [vol_cluster_sectors]
        mov [file_left_sectors], ax
.done:
        clc
.out:
        ret

; ----------------------------------------------------------------------------
; file_next - the file's next sector, into io_sector
;   In:       a read file_first began; DS = ES = the server's data
;   Out:      CF set and AX = an error; or CF clear and ZF set at the end;
;             or CF, ZF clear and CX = the bytes of io_sector that are the
;             file's
;   Destroys: AX, BX, DX, DI
; ----------------------------------------------------------------------------
file_next:
        mov ax, [file_bytes]
        or ax, [file_bytes + 2]
        jz .end
        cmp word [file_left_sectors], 0
        jne .read
        mov ax, [file_cluster]
        mov bx, [file_steps]
        call chain_next
        jc .out
        jz .short                       ; the chain ends before the file does
        mov [file_steps], bx
        mov [file_cluster], ax
        call cluster_sector
        mov [file_next_sector], ax
        mov ax, [vol_cluster_sectors]
        mov [file_left_sectors], ax
.read:
        mov ax, [file_next_sector]
        inc word [file_next_sector]
        dec word [file_left_sectors]
        mov di, io_sector
        call vol_read
        jc .out
        mov cx, SECTOR_SIZE
        cmp word [file_bytes + 2], 0
        jne .whole
        cmp [file_bytes], cx
        jae .whole
        mov cx, [file_bytes]
.whole:
        sub [file_bytes], cx
        sbb word [file_bytes + 2], 0
        or cx, cx                       ; ZF clear: CX is at least 1
        clc
.out:
        ret
.end:
        cmp ax, ax                      ; ZF set, CF clear
        ret
.short:
        mov ax, E_BROKEN
        stc
        ret

; ----------------------------------------------------------------------------
no_label            db "NO NAME    "     ; a volume's label when its BPB has none

; ----------------------------------------------------------------------------
; fat_free - the volume's free space: its clusters whose FAT entry is 0
;   In:       the volume mounted; DS = ES = the server's data
;   Out:      CF clear and DX:AX = bytes; or CF set and AX = an error
;   Destroys: BX, CX
; ----------------------------------------------------------------------------
fat_free:
        xor bx, bx                      ; free clusters
        mov cx, FAT12_FIRST_CLUSTER
.next:
        mov ax, cx
        call fat_next
        jc .out
        test ax, ax
        jnz .used
        inc bx
.used:
        inc cx
        mov ax, cx
        sub ax, FAT12_FIRST_CLUSTER
        cmp ax, [vol_clusters]
        jb .next
        mov ax, bx
        mul word [vol_cluster_sectors]  ; DX:AX = sectors (DX is 0)
        mov cx, SECTOR_SHIFT
.bytes:
        shl ax, 1
        rcl dx, 1
        loop .bytes
        clc
.out:
        ret
