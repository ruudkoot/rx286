; ============================================================================
; rx286 - src/kernel/disk.asm
; The disks as the program sees them: SYS_DISK_READ and SYS_DISK_WRITE, one
; sector of a drive at a time (storage roadmap D1).
;
; A sector is named by its number from 0 across the whole disk; the kernel
; turns it into a cylinder, head and sector with the drive's fixed geometry
; (disks.inc). Partitions and file systems are the program's business. Every
; sector passes through one buffer of the kernel's, disk_buffer, where the
; diskette controller's DMA lands and the fixed disk's words go: nothing is
; allocated. The program's buffer is checked, with the 286's own
; instructions, before any device is touched. Both calls are synchronous:
; the program waits in the call while the kernel sleeps with interrupts on;
; a restart asked for meanwhile (Ctrl+Break) waits until the sector is done.
; ============================================================================

DISK_READ           equ 0
DISK_WRITE          equ 1

; A drive's entry in drives:
DRIVE_SECTORS       equ 0               ; word: sectors on the disk
DRIVE_HEADS         equ 2
DRIVE_TRACK         equ 3               ; sectors a track
DRIVE_UNIT          equ 4               ; 0 or 1 on its controller
DRIVE_FIXED         equ 5               ; 0 a diskette drive, 1 a fixed disk
DRIVE_RATE          equ 6               ; a diskette's data rate (FDC_RATE_*)
DRIVE_PRECOMP       equ 6               ; a fixed disk's precompensation cylinder / 4
DRIVE_GAP           equ 7               ; a diskette's gap 3
DRIVE_ENTRY_SHIFT   equ 3               ; eight bytes an entry

; drive cylinders, heads, sectors, unit, fixed, rate or precompensation, gap
%macro drive 7
        dw (%1) * (%2) * (%3)
        db %2, %3, %4, %5, %6, %7
%endmacro

begin_kdata
drives:
        drive DISK_A_CYLINDERS, DISK_A_HEADS, DISK_A_SECTORS, 0, 0, FDC_RATE_500K, FDC_GAP_1200K
        drive DISK_B_CYLINDERS, DISK_B_HEADS, DISK_B_SECTORS, 1, 0, FDC_RATE_250K, FDC_GAP_360K
        drive DISK_C_CYLINDERS, DISK_C_HEADS, DISK_C_SECTORS, 0, 1, \
              DISK_C_PRECOMP >> HDC_PRECOMP_SHIFT, 0
        drive DISK_D_CYLINDERS, DISK_D_HEADS, DISK_D_SECTORS, 1, 1, \
              DISK_D_PRECOMP >> HDC_PRECOMP_SHIFT, 0
disk_cylinder       dw 0                ; where the sector is, for the drivers
disk_head           db 0
disk_sector         db 0                ; from 1, as the controllers count
disk_buffer         times SECTOR_SIZE db 0
; The 8237 cannot carry a transfer across a 64 KB boundary: "TIMES value is
; negative" here means the buffer crosses one, and must move.
        times -(((DISK_BUFFER_PHYS + SECTOR_SIZE - 1) >> 16) != (DISK_BUFFER_PHYS >> 16)) db 0
end_kdata

%if DRIVES != 4
  %error "disk.asm: drives does not match DRIVES"
%endif

; ----------------------------------------------------------------------------
; sys_disk_read - SYS_DISK_READ: a sector of a drive into the caller's ES:DI
;   In:       BP = the frame (AL drive, CX sector, ES:DI the buffer);
;             DS = ES = SEL_KDATA
;   Out:      nothing; or an error
;   Destroys: AX, BX, CX, DX, SI, DI, ES
; ----------------------------------------------------------------------------
sys_disk_read:
        call disk_arguments
        jc .fail
        mov ax, [bp + FRAME_ES]
        mov si, [bp + FRAME_DI]
        mov cx, SECTOR_SIZE
        call check_buffer_writable      ; before any device is touched
        jc .fault
        push ds
        pop es
        mov cx, [bp + FRAME_CX]
        mov al, DISK_READ
        call disk_transfer              ; waits, with interrupts in
        jc .fail
        mov ax, [bp + FRAME_ES]         ; so the buffer again: its descriptor
        mov si, [bp + FRAME_DI]         ; may have changed meanwhile (l4.md X2)
        mov cx, SECTOR_SIZE
        call check_buffer_writable      ; ES = the caller's segment
        jc .fault
        mov si, disk_buffer
        mov di, [bp + FRAME_DI]
        mov cx, SECTOR_SIZE / 2
        rep movsw
        ret
.fault:
        mov ax, E_FAULT
.fail:
        jmp sys_fail

; ----------------------------------------------------------------------------
; sys_disk_write - SYS_DISK_WRITE: the caller's DS:SI onto a sector of a drive
;   In:       BP = the frame (AL drive, CX sector, DS:SI the buffer);
;             DS = ES = SEL_KDATA
;   Out:      nothing; or an error
;   Destroys: AX, BX, CX, DX, SI, DI, ES
; ----------------------------------------------------------------------------
sys_disk_write:
        call disk_arguments
        jc .fail
        mov ax, [bp + FRAME_DS]
        mov si, [bp + FRAME_SI]
        mov cx, SECTOR_SIZE
        call check_buffer               ; ES = the caller's segment
        jc .fault
        push ds
        mov ax, es
        mov dx, ds
        mov es, dx
        mov ds, ax
        mov di, disk_buffer
        mov cx, SECTOR_SIZE / 2
        rep movsw
        pop ds
        mov cx, [bp + FRAME_CX]
        mov al, DISK_WRITE
        call disk_transfer
        jc .fail
        ret
.fault:
        mov ax, E_FAULT
.fail:
        jmp sys_fail

; ----------------------------------------------------------------------------
; disk_arguments - a disk call's drive and sector, checked
;   In:       BP = the frame (AL the drive, CX the sector); DS = SEL_KDATA
;   Out:      CF clear and BX = the drive's entry; or CF set and AX = E_INVAL
;   Destroys: AX, CX
; ----------------------------------------------------------------------------
disk_arguments:
        mov al, [bp + FRAME_AX]
        cmp al, DRIVES
        jae .invalid
        xor ah, ah
        mov bx, ax
        shl bx, DRIVE_ENTRY_SHIFT
        add bx, drives
        mov cx, [bp + FRAME_CX]
        cmp cx, [bx + DRIVE_SECTORS]
        jae .invalid
        clc
        ret
.invalid:
        mov ax, E_INVAL
        stc
        ret

; ----------------------------------------------------------------------------
; disk_transfer - one sector between the disk buffer and a drive
;   In:       AL = DISK_READ or DISK_WRITE; BX = the drive's entry; CX = the
;             sector (checked); DS = ES = SEL_KDATA; interrupts off
;   Out:      CF clear; or CF set and AX = the error
;   Destroys: AX, CX, DX, SI, DI
; ----------------------------------------------------------------------------
disk_transfer:
        push ax
        mov ax, cx
        xor dx, dx
        mov cl, [bx + DRIVE_TRACK]
        xor ch, ch
        div cx                          ; AX = the track, DX = the sector in it
        inc dx
        mov [disk_sector], dl
        xor dx, dx
        mov cl, [bx + DRIVE_HEADS]
        div cx                          ; AX = the cylinder, DX = the head
        mov [disk_cylinder], ax
        mov [disk_head], dl
        pop ax
        cmp byte [bx + DRIVE_FIXED], 0
        jne .fixed
        jmp fd_transfer
.fixed:
        jmp hd_transfer
