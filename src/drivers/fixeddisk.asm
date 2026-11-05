; ============================================================================
; rx286 - src/drivers/fixeddisk.asm
; The fixed disk driver (roadmap l4.md L9; storage roadmap D4): drives C and
; D on the AT's fixed disk controller (the task file at 1F0h-1F7h), IRQ14,
; programmed I/O, in ring 1 with IOPL 1.
;
; One sector at a time, synchronous, every wait with a limit (dwait.asm).
; Before a drive's first transfer, and after any failure, the controller is
; reset (the fixed disk register's bit 2), told the drive's heads and
; sectors a track (Set Parameters), and the heads are sent to cylinder 0
; (Restore), as the BIOS does at start: a reset leaves the step rate at 7.5
; ms, and Restore sets the rate implied seeks use (IBM, Fixed Disk and
; Diskette Adapter, 7-8). A drive that is not there fails with E_TIMEOUT
; then. The controller seeks (an implied seek) and retries by itself; the
; driver tries a sector HD_TRIES times, a timeout ending it at once. A read
; interrupts when the sector waits in the controller's buffer; a write
; takes its sector first (data request, no interrupt) and interrupts when it
; is on the disk. Reading the status register clears the interrupt. The
; words go straight between the controller and the segment the OS server
; passes (DRV_DISK_READ, DRV_DISK_WRITE; drivers.inc), which the driver
; deletes once it is done.
; ============================================================================

cpu 286
bits 16
%define KERNEL_LOG                      ; its lines: the kernel's log
%include "build.inc"
%include "program.inc"
%include "ports.inc"
%include "disks.inc"
%include "kcalls.inc"
%include "drivers.inc"

RING                equ 1
%define SLOT(n) ((n) * 8 + 4 + RING)    ; a slot of the driver's, as a selector
EP                  equ SLOT(DRV_SLOT_EP)
NOTIFY              equ SLOT(DRV_SLOT_NOTIFY)
IRQ                 equ SLOT(DRV_SLOT_IRQ)
RECV                equ SLOT(DRV_SLOT_RECV)
HD_TRIES            equ 2
HD_TICKS            equ 300 + 1         ; 6 s: the BIOS's fixed disk timeout
HD_RESET_READS      equ 16              ; the reset held for that many reads of a port
HD_UNITS            equ 2

; A drive's entry in units: its geometry
UNIT_SECTORS        equ 0               ; sectors on the disk
UNIT_HEADS          equ 2
UNIT_TRACK          equ 3               ; sectors a track
UNIT_PRECOMP        equ 4               ; the precompensation cylinder / 4
UNIT_SIZE           equ 6

begin_udata
units:
        dw DISK_C_CYLINDERS * DISK_C_HEADS * DISK_C_SECTORS
        db DISK_C_HEADS, DISK_C_SECTORS, DISK_C_PRECOMP >> HDC_PRECOMP_SHIFT, 0
        dw DISK_D_CYLINDERS * DISK_D_HEADS * DISK_D_SECTORS
        db DISK_D_HEADS, DISK_D_SECTORS, DISK_D_PRECOMP >> HDC_PRECOMP_SHIFT, 0
irq_seen            db 0                ; set when IRQ14 came
hd_status           db 0                ; the status IRQ14 read
hd_ready            db 0, 0             ; each drive's parameters set since the last reset
hd_unit             db 0                ; the transfer's: its drive (0 or 1)
hd_command          db 0                ; HDC_CMD_READ or HDC_CMD_WRITE
hd_tries            db 0
hd_cylinder         dw 0                ; where the sector is
hd_head             db 0
hd_sector           db 0                ; from 1, as the controller counts
end_udata

; ----------------------------------------------------------------------------
; entry - serve the OS server's transfers, for ever
;   In:       its start: DS = ES = its data, IOPL 1
;   Out:      does not return
;   Destroys: everything
; ----------------------------------------------------------------------------
entry:
        cld
        ; falls through

; ----------------------------------------------------------------------------
; serve - a sector to or from the segment passed, for each call
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
        jne .call
        call dw_bits                    ; a late interrupt: taken
        jmp serve
.call:
        mov ah, HDC_CMD_READ
        cmp al, DRV_DISK_READ
        je .transfer
        mov ah, HDC_CMD_WRITE
        cmp al, DRV_DISK_WRITE
        je .transfer
        mov bx, E_INVAL
        jmp .reply
.transfer:
        call hd_transfer                ; BX = 0 or the error
.reply:
        push bx
        mov dx, RECV                    ; the segment, used: room for the next
        kcall KCALL_DELETE
        pop bx
        mov dx, EP
        mov bp, RECV
        kcall KCALL_REPLY_RECV
        jmp .message

; ----------------------------------------------------------------------------
; hd_transfer - one sector between the segment passed and a fixed disk
;   In:       AH = HDC_CMD_READ or HDC_CMD_WRITE; BX = the drive (0 or 1);
;             CX = the sector; SI = its offset in the segment; BP = the
;             segment (0: none came)
;   Out:      BX = 0, or E_INVAL, E_FAULT, E_IO, E_TIMEOUT
;   Destroys: AX, CX, DX, SI, DI, ES
; ----------------------------------------------------------------------------
hd_transfer:
        cmp bx, HD_UNITS
        jae .invalid
        test bp, bp
        jz .fault
        mov [hd_command], ah
        mov [hd_unit], bl
        mov di, bx
        mov ax, UNIT_SIZE
        mul di
        mov di, ax
        add di, units                   ; DI = its entry
        cmp cx, [di + UNIT_SECTORS]
        jae .invalid
        mov ax, cx                      ; the sector: cylinder, head, sector
        xor dx, dx
        mov cl, [di + UNIT_TRACK]
        xor ch, ch
        div cx                          ; AX = the track, DX = the sector in it
        inc dx
        mov [hd_sector], dl
        xor dx, dx
        mov cl, [di + UNIT_HEADS]
        div cx                          ; AX = the cylinder, DX = the head
        mov [hd_cylinder], ax
        mov [hd_head], dl
        mov byte [hd_tries], HD_TRIES
.try:
        call hd_unit_ready
        cmp byte [bx], 0
        jne .ready
        call hd_setup
        jc .failed
.ready:
        call hd_wait_idle
        jc .timeout
        mov al, [di + UNIT_PRECOMP]
        mov dx, HDC_PRECOMP
        out dx, al
        mov al, 1
        mov dx, HDC_SECTOR_COUNT
        out dx, al
        mov al, [hd_sector]
        mov dx, HDC_SECTOR
        out dx, al
        mov ax, [hd_cylinder]
        mov dx, HDC_CYLINDER_LOW
        out dx, al
        mov al, ah
        mov dx, HDC_CYLINDER_HIGH
        out dx, al
        mov al, [hd_head]
        call hd_drive_head
        mov byte [irq_seen], 0
        mov al, [hd_command]
        mov dx, HDC_COMMAND
        out dx, al
        cmp al, HDC_CMD_READ
        jne .write
        call hd_wait_irq                ; the sector is in the controller's buffer
        jc .timeout
        test al, HDC_STATUS_ERR | HDC_STATUS_WRITE_FAULT
        jnz .error
        test al, HDC_STATUS_DRQ
        jz .error
        push di
        mov es, bp
        mov di, si
        mov cx, SECTOR_SIZE / 2
        mov dx, HDC_DATA
        rep insw
        pop di
        push ds
        pop es
        xor bx, bx
        ret
.write:
        call hd_wait_idle               ; then it asks for the sector
        jc .timeout
        test al, HDC_STATUS_DRQ
        jz .error
        push si
        push ds
        mov ds, bp
        mov cx, SECTOR_SIZE / 2
        mov dx, HDC_DATA
        rep outsw
        pop ds
        pop si
        call hd_wait_irq                ; the sector is on the disk
        jc .timeout
        test al, HDC_STATUS_ERR | HDC_STATUS_WRITE_FAULT
        jnz .error
        xor bx, bx
        ret
.error:
        mov byte [hd_ready], 0          ; reset before the next try
        mov byte [hd_ready + 1], 0
        dec byte [hd_tries]
        jnz .try
        mov bx, E_IO
        ret
.timeout:
        mov ax, E_TIMEOUT
        mov byte [hd_ready], 0
        mov byte [hd_ready + 1], 0
.failed:
        mov bx, ax
        ret
.invalid:
        mov bx, E_INVAL
        ret
.fault:
        mov bx, E_FAULT
        ret

; ----------------------------------------------------------------------------
; hd_setup - reset the controller if no drive is set up, then set this
; drive's heads and sectors a track, and restore its heads to cylinder 0
;   In:       DI = the drive's entry; hd_unit
;   Out:      CF clear; or CF set, AX = E_IO or E_TIMEOUT, and neither drive
;             set up (the next transfer resets the controller)
;   Destroys: AX, BX, CX, DX
; ----------------------------------------------------------------------------
hd_setup:
        cmp word [hd_ready], 0          ; both drives' bytes
        jne .parameters
        mov dx, HDC_CONTROL
        mov al, HDC_CONTROL_RESET
        out dx, al
        mov cx, HD_RESET_READS
        mov dx, HDC_STATUS
.hold:
        in al, dx
        loop .hold
        mov dx, HDC_CONTROL
        mov al, HDC_CONTROL_RUN
        out dx, al
.parameters:
        call hd_wait_idle
        jc .late
        mov al, [di + UNIT_HEADS]
        dec al                          ; the last head
        call hd_drive_head
        mov al, [di + UNIT_TRACK]
        mov dx, HDC_SECTOR_COUNT
        out dx, al
        mov byte [irq_seen], 0
        mov al, HDC_CMD_SET_PARAMETERS
        mov dx, HDC_COMMAND
        out dx, al
        call hd_wait_irq
        jc .late
        test al, HDC_STATUS_ERR
        jnz .error
        xor al, al                      ; head 0
        call hd_drive_head
        mov byte [irq_seen], 0
        mov al, HDC_CMD_RESTORE
        mov dx, HDC_COMMAND
        out dx, al
        call hd_wait_irq
        jc .late
        test al, HDC_STATUS_ERR
        jnz .error
        call hd_unit_ready
        mov byte [bx], 1
        clc
        ret
.late:
        mov ax, E_TIMEOUT
        jmp .failed
.error:
        mov ax, E_IO
.failed:
        mov word [hd_ready], 0
        stc
        ret

; ----------------------------------------------------------------------------
; hd_drive_head - the drive/head register: this drive, a head
;   In:       AL = the head; hd_unit
;   Out:      nothing
;   Destroys: AL, DX
; ----------------------------------------------------------------------------
hd_drive_head:
        or al, HDC_DRIVE_HEAD_BASE
        cmp byte [hd_unit], 0
        je .write
        or al, HDC_DRIVE_1
.write:
        mov dx, HDC_DRIVE_HEAD
        out dx, al
        ret

; ----------------------------------------------------------------------------
; hd_wait_idle - wait until the controller is not busy
;   In:       nothing
;   Out:      CF clear and AL = the status; or CF set: still busy after
;             HD_TICKS
;   Destroys: AH, CX, DX
; ----------------------------------------------------------------------------
hd_wait_idle:
        mov dx, HDC_STATUS
        mov ah, HDC_STATUS_BSY
        mov al, 0
        mov cx, HD_TICKS
        jmp dw_poll

; ----------------------------------------------------------------------------
; hd_wait_irq - wait for IRQ14
;   In:       irq_seen cleared before the command
;   Out:      CF clear and AL = the status the interrupt read; or CF set
;   Destroys: AX, CX
; ----------------------------------------------------------------------------
hd_wait_irq:
        mov cx, HD_TICKS
        call dw_wait_irq
        mov al, [hd_status]             ; MOV keeps CF
        ret

; ----------------------------------------------------------------------------
; hd_unit_ready - where the drive's "parameters set" byte is kept
;   In:       hd_unit
;   Out:      BX = its byte of hd_ready
;   Destroys: nothing
; ----------------------------------------------------------------------------
hd_unit_ready:
        mov bl, [hd_unit]
        xor bh, bh
        add bx, hd_ready
        ret

; ----------------------------------------------------------------------------
; driver_irq - IRQ14 (dwait.asm): the controller has a sector for us, or has
; finished; reading its status clears the interrupt
;   In:       nothing
;   Out:      hd_status
;   Destroys: AL, DX
; ----------------------------------------------------------------------------
driver_irq:
        mov dx, HDC_STATUS
        in al, dx
        mov [hd_status], al
        ret

%include "dwait.asm"
