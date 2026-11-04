; ============================================================================
; rx286 - src/kernel/fixeddisk.asm
; The fixed disks C and D: the AT's fixed disk controller (IBM's adapter,
; the task file at 1F0h-1F7h), IRQ14, programmed I/O (storage roadmap D4).
;
; One sector at a time through the disk buffer, synchronous, every wait with
; a limit, as for the diskettes. Before a drive's first transfer, and after
; any failure, the controller is reset (the fixed disk register's bit 2),
; told the drive's heads and sectors a track (Set Parameters), and the heads
; are sent to cylinder 0 (Restore), as the BIOS does at start: a reset
; leaves the step rate at 7.5 ms, and Restore sets the rate implied seeks
; use (IBM, Fixed Disk and Diskette Adapter, 7-8; the BIOS's "recal to reset
; seek speed"). A drive that is not there fails with E_TIMEOUT then. The
; controller seeks (an implied seek) and retries by itself; the kernel tries
; a sector HD_TRIES times, a timeout ending it at once. A read interrupts
; when the sector waits in the controller's buffer; a write takes its sector
; first (data request, no interrupt) and interrupts when it is on the disk.
; Reading the status register clears the interrupt (IBM, Fixed Disk and
; Diskette Adapter, 5-9).
; ============================================================================

HD_TRIES            equ 2
HD_TICKS            equ 300 + 1         ; 6 s: the BIOS's fixed disk timeout
HD_RESET_READS      equ 16              ; the reset held for that many reads of a port

begin_kdata
hd_irq_seen         db 0                ; set by IRQ14
hd_status           db 0                ; the status IRQ14 read
hd_ready            db 0, 0             ; each drive's parameters set since the last reset
hd_command          db 0                ; HDC_CMD_READ or HDC_CMD_WRITE
hd_tries            db 0
end_kdata

; ----------------------------------------------------------------------------
; hd_transfer - one sector between the disk buffer and a fixed disk
;   In:       AL = DISK_READ or DISK_WRITE; BX = the drive's entry (disk.asm);
;             disk_cylinder, disk_head, disk_sector; DS = ES = SEL_KDATA;
;             interrupts off
;   Out:      CF clear; or CF set and AX = E_IO or E_TIMEOUT
;   Destroys: AX, CX, DX, SI, DI
; ----------------------------------------------------------------------------
hd_transfer:
        mov ah, HDC_CMD_READ
        cmp al, DISK_READ
        je .direction
        mov ah, HDC_CMD_WRITE
.direction:
        mov [hd_command], ah
        mov byte [hd_tries], HD_TRIES
.try:
        call hd_unit_ready
        cmp byte [si], 0
        jne .ready
        call hd_setup
        jc .failed
.ready:
        call hd_wait_idle
        jc .timeout
        mov al, [bx + DRIVE_PRECOMP]
        mov dx, HDC_PRECOMP
        out dx, al
        mov al, 1
        mov dx, HDC_SECTOR_COUNT
        out dx, al
        mov al, [disk_sector]
        mov dx, HDC_SECTOR
        out dx, al
        mov ax, [disk_cylinder]
        mov dx, HDC_CYLINDER_LOW
        out dx, al
        mov al, ah
        mov dx, HDC_CYLINDER_HIGH
        out dx, al
        mov al, [disk_head]
        call hd_drive_head
        mov byte [hd_irq_seen], 0
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
        mov di, disk_buffer
        mov cx, SECTOR_SIZE / 2
        mov dx, HDC_DATA
        rep insw
        clc
        ret
.write:
        call hd_wait_idle               ; then it asks for the sector
        jc .timeout
        test al, HDC_STATUS_DRQ
        jz .error
        mov si, disk_buffer
        mov cx, SECTOR_SIZE / 2
        mov dx, HDC_DATA
        rep outsw
        call hd_wait_irq                ; the sector is on the disk
        jc .timeout
        test al, HDC_STATUS_ERR | HDC_STATUS_WRITE_FAULT
        jnz .error
        clc
        ret
.error:
        mov ax, E_IO
        call hd_forget                  ; reset before the next try
        dec byte [hd_tries]
        jnz .try
        stc
        ret
.timeout:
        mov ax, E_TIMEOUT
        call hd_forget
.failed:
        stc
        ret

; ----------------------------------------------------------------------------
; hd_setup - reset the controller if no drive is set up, then set this
; drive's heads and sectors a track, and restore its heads to cylinder 0
;   In:       BX = the drive's entry; DS = ES = SEL_KDATA; interrupts off
;   Out:      CF clear; or CF set, AX = E_IO or E_TIMEOUT, and neither drive
;             set up (the next transfer resets the controller)
;   Destroys: AX, CX, DX, SI
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
        mov al, [bx + DRIVE_HEADS]
        dec al                          ; the last head
        call hd_drive_head
        mov al, [bx + DRIVE_TRACK]
        mov dx, HDC_SECTOR_COUNT
        out dx, al
        mov byte [hd_irq_seen], 0
        mov al, HDC_CMD_SET_PARAMETERS
        mov dx, HDC_COMMAND
        out dx, al
        call hd_wait_irq
        jc .late
        test al, HDC_STATUS_ERR
        jnz .error
        xor al, al                      ; head 0
        call hd_drive_head
        mov byte [hd_irq_seen], 0
        mov al, HDC_CMD_RESTORE
        mov dx, HDC_COMMAND
        out dx, al
        call hd_wait_irq
        jc .late
        test al, HDC_STATUS_ERR
        jnz .error
        call hd_unit_ready
        mov byte [si], 1
        clc
        ret
.late:
        mov ax, E_TIMEOUT
        jmp .failed
.error:
        mov ax, E_IO
.failed:
        call hd_forget
        stc
        ret

; ----------------------------------------------------------------------------
; hd_drive_head - the drive/head register: this drive, a head
;   In:       AL = the head; BX = the drive's entry
;   Out:      nothing
;   Destroys: AL, DX
; ----------------------------------------------------------------------------
hd_drive_head:
        or al, HDC_DRIVE_HEAD_BASE
        cmp byte [bx + DRIVE_UNIT], 0
        je .write
        or al, HDC_DRIVE_1
.write:
        mov dx, HDC_DRIVE_HEAD
        out dx, al
        ret

; ----------------------------------------------------------------------------
; hd_wait_idle - wait until the controller is not busy
;   In:       DS = SEL_KDATA; interrupts off
;   Out:      CF clear and AL = the status; or CF set: still busy after
;             HD_TICKS
;   Destroys: AH, CX, DX
; ----------------------------------------------------------------------------
hd_wait_idle:
        mov dx, HDC_STATUS
        mov ah, HDC_STATUS_BSY
        mov al, 0
        mov cx, HD_TICKS
        jmp kpoll

; ----------------------------------------------------------------------------
; hd_wait_irq - sleep until IRQ14
;   In:       DS = SEL_KDATA; interrupts off
;   Out:      CF clear and AL = the status the interrupt read; or CF set
;   Destroys: AX, CX
; ----------------------------------------------------------------------------
hd_wait_irq:
        push si
        mov si, hd_irq_seen
        mov cx, HD_TICKS
        call ksleep_until
        pop si
        mov al, [hd_status]             ; MOV keeps CF
        ret

; ----------------------------------------------------------------------------
; hd_unit_ready - where the drive's "parameters set" byte is kept
;   In:       BX = the drive's entry
;   Out:      SI = its byte of hd_ready
;   Destroys: nothing
; ----------------------------------------------------------------------------
hd_unit_ready:
        push ax
        mov al, [bx + DRIVE_UNIT]
        cbw
        mov si, hd_ready
        add si, ax
        pop ax
        ret

; ----------------------------------------------------------------------------
; hd_forget - neither drive is set up: the next transfer resets the controller
;   In:       DS = SEL_KDATA
;   Out:      nothing
;   Destroys: nothing
; ----------------------------------------------------------------------------
hd_forget:
        mov word [hd_ready], 0
        ret

; ----------------------------------------------------------------------------
; hd_irq - IRQ14: the controller has a sector for us, or has finished
;   In:       DS = SEL_KDATA
;   Out:      nothing (the dispatcher sends EOI)
;   Destroys: AL, DX
; ----------------------------------------------------------------------------
hd_irq:
        mov dx, HDC_STATUS
        in al, dx                       ; clears the interrupt
        mov [hd_status], al
        mov byte [hd_irq_seen], 1
        ret
