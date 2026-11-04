; ============================================================================
; rx286 - src/boot-loader/fat12.asm
; Pure arithmetic of a FAT12 floppy: the next cluster of a chain, and the
; cylinder, head and sector of a logical sector.
;
; Neither routine touches hardware or the BIOS, so tests/unit runs them on
; the host. The BPB's and a directory entry's field offsets are here too.
; ============================================================================

; The BPB, at the start of the boot sector (offsets in bytes).
BPB_BYTES_PER_SECTOR    equ 0x0B    ; word: must be 512
BPB_SECTORS_PER_CLUSTER equ 0x0D    ; byte
BPB_RESERVED_SECTORS    equ 0x0E    ; word
BPB_FATS                equ 0x10    ; byte
BPB_ROOT_ENTRIES        equ 0x11    ; word
BPB_TOTAL_SECTORS       equ 0x13    ; word
BPB_SECTORS_PER_FAT     equ 0x16    ; word
BPB_SECTORS_PER_TRACK   equ 0x18    ; word
BPB_HEADS               equ 0x1A    ; word

; A directory entry.
DIR_ENTRY_SIZE          equ 32
DIR_NAME                equ 0x00    ; DIR_NAME_LENGTH bytes, space padded, no dot
DIR_NAME_LENGTH         equ 11
DIR_ATTRIBUTES          equ 0x0B
DIR_FIRST_CLUSTER       equ 0x1A    ; word
DIR_FILE_SIZE           equ 0x1C    ; dword
DIR_ATTR_VOLUME         equ 0x08
DIR_ATTR_DIRECTORY      equ 0x10
DIR_END                 equ 0x00    ; a first name byte of 0: no more entries
DIR_DELETED             equ 0xE5

FAT12_FIRST_CLUSTER     equ 2       ; clusters 0 and 1 do not exist
FAT12_RESERVED          equ 0xFF0   ; FF0h-FF6h reserved, FF7h bad, FF8h-FFFh end

; ----------------------------------------------------------------------------
; fat12_next - the cluster after AX in a FAT12 chain
;   In:       AX = a cluster; DS:SI = the FAT
;   Out:      AX = the next cluster (FF8h-FFFh at the chain's end)
;   Destroys: nothing
; ----------------------------------------------------------------------------
fat12_next:
        push bx
        mov bx, ax
        shr bx, 1
        add bx, ax                      ; BX = cluster * 3 / 2: its entry's first byte
        test al, 1
        mov ax, [si + bx]               ; the two bytes that hold the entry
        jz .even
        shr ax, 4                       ; an odd cluster: the upper 12 bits
        jmp .done
.even:
        and ax, 0x0FFF                  ; an even cluster: the lower 12 bits
.done:
        pop bx
        ret

; ----------------------------------------------------------------------------
; chs_from_lba - a logical sector as INT 13h wants it
;   In:       AX = logical sector; BL = sectors per track; BH = heads
;   Out:      CH = cylinder bits 7-0; CL = sector (1-based) in bits 5-0 and
;             cylinder bits 9-8 in bits 7-6; DH = head
;   Destroys: AX
; ----------------------------------------------------------------------------
chs_from_lba:
        push dx
        push bx
        xor dx, dx
        mov cl, bl
        xor ch, ch
        div cx                          ; AX = track, DX = sector within it
        inc dl
        mov cl, dl                      ; CL = sector, 1-based
        xor dx, dx
        mov bl, bh
        xor bh, bh
        div bx                          ; AX = cylinder, DX = head
        mov bl, dl                      ; keep the head
        mov ch, al                      ; cylinder bits 7-0
        shl ah, 6
        or cl, ah                       ; cylinder bits 9-8 into CL bits 7-6
        pop ax                          ; the caller's BX, into AX for a moment
        pop dx
        mov dh, bl                      ; DH = head
        mov bx, ax                      ; the caller's BX back
        ret
