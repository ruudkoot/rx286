; ============================================================================
; rx286 - src/drivers/fixeddisk.asm
; The fixed disk driver (roadmap l4.md L9; storage roadmap D4;
; disk-scheduler.md M2): drives C and D on the AT's fixed disk controller
; (the task file at 1F0h-1F7h), IRQ14, programmed I/O, in ring 1 with IOPL 1.
;
; A run of sectors a call (DRV_DISK_READ, DRV_DISK_WRITE; drivers.inc), by
; cylinder, head and sector, one command for up to DRV_DISK_RUN_MAX: the
; controller crosses heads and cylinders by itself (adapter manual p. 1).
; Each drive's geometry is the BIOS's, from the boot information
; (DRV_SLOT_BOOT_INFO; layout.inc's BI_HD0), or disks.inc's when the BIOS
; gave none. A read interrupts for each sector waiting in the controller's
; buffer, which the driver reads straight into the segment passed; a write
; gives the first sector at once (data request, no interrupt), and the next
; at each interrupt, the last interrupt saying the run is on the disk. A
; run's timer is armed once, for the whole command, so that a sector costs
; one receive and one acknowledgement of the interrupt (dw_run_wait). The
; controller seeks (an implied seek) and retries by itself; the driver tries
; a run once (HD_TRIES), and after a failure resets the controller before
; its next: the disk server tries again (disk-scheduler.md M3, D14). Before
; the first transfer, and after any failure, the controller is reset (the
; fixed disk register's bit 2); before a drive's first transfer the
; controller is told its heads and sectors a track (Set Parameters), and its
; heads are sent to cylinder 0 (Restore), as the BIOS does at start: a
; reset leaves the step rate at 7.5 ms, and
; Restore sets the rate implied seeks use (IBM, Fixed Disk and Diskette
; Adapter, 7-8). A drive that is not there fails with E_TIMEOUT then. The
; drive is selected before the reset as well as after: the AT's controller
; keeps one drive/head register, but an IDE drive (MAME's AT) takes it only
; while not busy, and a reset with a drive not there selected would leave
; the other's status hidden. Reading the status register clears the
; interrupt. DRV_DISK_SEEK sends a Seek, which ends once its steps are
; sent; the drive's heads go on moving, and DRV_DISK_STATUS says when they
; are there (Seek Complete).
; ============================================================================

cpu 286
bits 16
%include "build.inc"
%include "program.inc"
%include "ports.inc"
%include "disks.inc"
%include "layout.inc"
%include "kcalls.inc"
%include "drivers.inc"

RING                equ 1
%define SLOT(n) ((n) * 8 + 4 + RING)    ; a slot of the driver's, as a selector
EP                  equ SLOT(DRV_SLOT_EP)
NOTIFY              equ SLOT(DRV_SLOT_NOTIFY)
IRQ                 equ SLOT(DRV_SLOT_IRQ)
RECV                equ SLOT(DRV_SLOT_RECV)
BOOT_INFO           equ SLOT(DRV_SLOT_BOOT_INFO)
HD_TRIES            equ 1               ; the disk server tries again (D14)
HD_TICKS            equ 300 + 1         ; 6 s: the BIOS's fixed disk timeout
HD_RESET_READS      equ 16              ; the reset held for that many reads of a port
HD_UNITS            equ 2
HD_PRECOMP_NONE     equ 0xFF            ; the precompensation register's "none"

; A drive's entry in units: its geometry
UNIT_CYLINDERS      equ 0
UNIT_HEADS          equ 2
UNIT_TRACK          equ 3               ; sectors a track
UNIT_PRECOMP        equ 4               ; the precompensation cylinder / 4
UNIT_SIZE           equ 6

begin_udata
units:
        dw DISK_C_CYLINDERS
        db DISK_C_HEADS, DISK_C_SECTORS, DISK_C_PRECOMP >> HDC_PRECOMP_SHIFT, 0
        dw DISK_D_CYLINDERS
        db DISK_D_HEADS, DISK_D_SECTORS, DISK_D_PRECOMP >> HDC_PRECOMP_SHIFT, 0
irq_seen            db 0                ; set when IRQ14 came
hd_status           db 0                ; the status IRQ14 read
hd_ready            db 0, 0             ; each drive's parameters set since the last reset
hd_cylinder_now     dw DISK_CYLINDER_UNKNOWN, DISK_CYLINDER_UNKNOWN  ; where each drive's heads go
hd_unit             db 0                ; the command's: its drive (0 or 1)
hd_command          db 0                ; HDC_CMD_READ or HDC_CMD_WRITE
hd_tries            db 0
hd_cylinder         dw 0                ; where the run starts
hd_head             db 0
hd_sector           db 0                ; from 1, as the controller counts
hd_count            db 0                ; the run's sectors
hd_left             db 0                ; those not yet moved
hd_at               dw 0                ; the run's offset in the segment
hd_next             dw 0                ; the next sector's
end_udata

; ----------------------------------------------------------------------------
; entry - the drives' geometry from the boot information; then serve the
;         disk server's (until M3 the OS server's) calls, for ever
;   In:       its start: DS = ES = its data, IOPL 1
;   Out:      does not return
;   Destroys: everything
; ----------------------------------------------------------------------------
entry:
        cld
        mov ax, BOOT_INFO
        mov es, ax
        mov si, BI_HD0
        mov di, units
        mov cx, HD_UNITS
.unit:
        mov ax, [es:si + BIH_CYLINDERS]
        test ax, ax                     ; none given: disks.inc's
        jz .next
        cmp byte [es:si + BIH_HEADS], 0
        je .next
        cmp byte [es:si + BIH_SECTORS], 0
        je .next
        mov [di + UNIT_CYLINDERS], ax
        mov al, [es:si + BIH_HEADS]
        mov [di + UNIT_HEADS], al
        mov al, [es:si + BIH_SECTORS]
        mov [di + UNIT_TRACK], al
        mov ax, [es:si + BIH_PRECOMP]
        shr ax, HDC_PRECOMP_SHIFT
        test ah, ah
        jz .precomp
        mov al, HD_PRECOMP_NONE         ; past 1,020: none (the BIOS's FFFFh)
.precomp:
        mov [di + UNIT_PRECOMP], al
.next:
        add si, BIH_SIZE
        add di, UNIT_SIZE
        loop .unit
        push ds
        pop es
        ; falls through

; ----------------------------------------------------------------------------
; serve - each call, for ever
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
        call dw_bits                    ; a late interrupt or timer: taken
        jmp serve
.call:
        push bp
        call hd_call                    ; BX = 0 or the error; CX, DX the answer
        pop bp
        push bx
        push cx
        push dx
        test bp, bp
        jz .no_segment
        mov dx, RECV                    ; the segment, used: room for the next
        kcall KCALL_DELETE
.no_segment:
        pop dx
        pop cx
        pop bx
        mov si, dx                      ; (the reply's third word)
        mov di, 0
        mov dx, EP
        mov bp, RECV
        kcall KCALL_REPLY_RECV
        jmp .message

; ----------------------------------------------------------------------------
; hd_call - one call
;   In:       AL = the label; BL = the unit; BH = the head; CX = the cylinder;
;             DI = the sector and count; SI = the offset; BP = the segment
;             passed (0: none came)
;   Out:      BX = 0 or the error; CX and DX (sent in SI) its answer
;   Destroys: AX, SI, DI, ES
; ----------------------------------------------------------------------------
hd_call:
        cmp bl, HD_UNITS
        jae .invalid
        mov [hd_unit], bl
        cmp al, DRV_DISK_READ
        je .read
        cmp al, DRV_DISK_WRITE
        je .write
        cmp al, DRV_DISK_SEEK
        je .seek
        cmp al, DRV_DISK_STATUS
        je .status
        cmp al, DRV_DISK_RESET
        je .reset
        cmp al, DRV_DISK_GEOMETRY
        je .geometry
.invalid:
        mov bx, E_INVAL
        xor cx, cx
        xor dx, dx
        ret
.read:
        mov ah, HDC_CMD_READ
        jmp hd_transfer
.write:
        mov ah, HDC_CMD_WRITE
        jmp hd_transfer
.seek:
        jmp hd_seek
.status:
        jmp hd_unit_status
.reset:
        mov word [hd_ready], 0          ; the next command resets
        mov word [hd_cylinder_now], DISK_CYLINDER_UNKNOWN
        mov word [hd_cylinder_now + 2], DISK_CYLINDER_UNKNOWN
        xor bx, bx
        xor cx, cx
        xor dx, dx
        ret
.geometry:
        call hd_entry
        mov cx, [di + UNIT_CYLINDERS]
        mov dl, [di + UNIT_HEADS]
        mov dh, [di + UNIT_TRACK]
        xor bx, bx
        ret

; ----------------------------------------------------------------------------
; hd_entry - the unit's entry in units
;   In:       hd_unit
;   Out:      DI = its entry
;   Destroys: nothing
; ----------------------------------------------------------------------------
hd_entry:
        push ax
        mov al, [hd_unit]
        mov ah, UNIT_SIZE
        mul ah
        mov di, ax
        add di, units
        pop ax
        ret

; ----------------------------------------------------------------------------
; hd_transfer - a run of sectors between the segment passed and a fixed disk
;   In:       AH = HDC_CMD_READ or HDC_CMD_WRITE; hd_unit; BH = the head;
;             CX = the cylinder; DI = the sector (low byte, from 1) and the
;             count (high byte, 0: 1); SI = the offset; BP = the segment
;   Out:      BX = 0, or E_INVAL, E_FAULT, E_IO, E_TIMEOUT; CX = the sectors
;             moved; DX = 0
;   Destroys: AX, SI, DI, ES
; ----------------------------------------------------------------------------
hd_transfer:
        mov [hd_command], ah
        mov [hd_head], bh
        mov [hd_cylinder], cx
        mov ax, di
        mov [hd_sector], al
        test ah, ah
        jnz .counted
        inc ah
.counted:
        mov [hd_count], ah
        mov [hd_at], si
        mov byte [hd_left], 0
        test bp, bp
        jz .fault
        call hd_entry
        cmp ah, DRV_DISK_RUN_MAX
        ja .invalid
        cmp cx, [di + UNIT_CYLINDERS]
        jae .invalid
        cmp bh, [di + UNIT_HEADS]
        jae .invalid
        test al, al
        jz .invalid
        cmp al, [di + UNIT_TRACK]
        ja .invalid
        call hd_room                    ; the sectors from there to the disk's end
        test dx, dx
        jnz .fits
        mov bl, [hd_count]
        xor bh, bh
        cmp ax, bx
        jb .invalid
.fits:
        mov cl, [hd_count]
        xor ch, ch
        shl cx, SECTOR_SHIFT
        mov si, [hd_at]
        call dw_fits                    ; the run within the segment's limit
        jc .fault
        mov byte [hd_tries], HD_TRIES
.try:
        mov al, [hd_count]
        mov [hd_left], al
        mov ax, [hd_at]
        mov [hd_next], ax
        call hd_unit_ready
        cmp byte [bx], 0
        jne .ready
        call hd_setup
        jc .failed
.ready:
        call hd_task_file
        jc .timeout
        mov al, [hd_count]
        mov dx, HDC_SECTOR_COUNT
        out dx, al
        mov byte [irq_seen], 0
        mov cx, HD_TICKS
        call dw_run_start
        mov al, [hd_command]
        mov dx, HDC_COMMAND
        out dx, al
        cmp al, HDC_CMD_READ
        jne .write
.read_sector:
        call dw_run_wait                ; a sector is in the controller's buffer
        jc .timeout
        mov al, [hd_status]
        test al, HDC_STATUS_ERR | HDC_STATUS_WRITE_FAULT
        jnz .error
        test al, HDC_STATUS_DRQ
        jz .error
        mov byte [irq_seen], 0          ; (the next sector's)
        call dw_writable                ; gone while it waited?
        jnz .gone
        push di                         ; (the drive's entry)
        mov es, bp
        mov di, [hd_next]
        mov cx, SECTOR_SIZE / 2
        mov dx, HDC_DATA
        rep insw
        mov [hd_next], di
        pop di
        push ds
        pop es
        dec byte [hd_left]
        jnz .read_sector
        jmp .done
.write:
        call hd_wait_idle               ; then it asks for the first sector
        jc .timeout
        test al, HDC_STATUS_DRQ
        jz .error
.write_sector:
        call dw_readable
        jnz .gone
        push ds
        mov si, [hd_next]
        add word [hd_next], SECTOR_SIZE
        mov ds, bp
        mov cx, SECTOR_SIZE / 2
        mov dx, HDC_DATA
        rep outsw
        pop ds
        call dw_run_wait                ; on the disk: the next one asked for, or the end
        jc .timeout
        mov byte [irq_seen], 0
        mov al, [hd_status]
        test al, HDC_STATUS_ERR | HDC_STATUS_WRITE_FAULT
        jnz .error
        dec byte [hd_left]
        jnz .write_sector
.done:
        call hd_ends_on                 ; where the heads are now
        xor bx, bx
        mov cl, [hd_count]
        xor ch, ch
        xor dx, dx
        ret
.error:
        call hd_forget                  ; reset before the next try
        dec byte [hd_tries]
        jnz .try
        mov bx, E_IO
        jmp .moved
.gone:
        call hd_forget                  ; the sector half done: a reset next time
.fault:
        mov bx, E_FAULT
        jmp .moved
.timeout:
        call hd_forget
        mov ax, E_TIMEOUT
.failed:
        mov bx, ax
        jmp .moved
.invalid:
        mov bx, E_INVAL
.moved:
        mov cl, [hd_count]              ; the sectors done before it failed
        sub cl, [hd_left]
        xor ch, ch
        cmp byte [hd_left], 0
        jne .partly
        xor cx, cx                      ; (failed before it began)
.partly:
        xor dx, dx
        ret

; ----------------------------------------------------------------------------
; hd_room - the sectors from the run's start to the disk's end
;   In:       DI = the drive's entry; hd_cylinder, hd_head, hd_sector
;   Out:      DX:AX = the sectors
;   Destroys: BX, CX
; ----------------------------------------------------------------------------
hd_room:
        mov ax, [di + UNIT_CYLINDERS]
        sub ax, [hd_cylinder]           ; cylinders from this one on
        mov bl, [di + UNIT_HEADS]
        xor bh, bh
        mul bx                          ; tracks (at most 1,024 x 16)
        mov bl, [hd_head]
        sub ax, bx                      ; less the heads before this one
        mov bl, [di + UNIT_TRACK]
        mul bx                          ; DX:AX = sectors from this track's start
        mov bl, [hd_sector]
        dec bx
        sub ax, bx
        sbb dx, 0
        ret

; ----------------------------------------------------------------------------
; hd_task_file - the task file of a run or a seek: its drive and head, its
;                cylinder, its sector, its precompensation
;   In:       DI = the drive's entry; hd_unit, hd_head, hd_cylinder, hd_sector
;   Out:      CF clear; or CF set: the controller stayed busy
;   Destroys: AX, DX
; ----------------------------------------------------------------------------
hd_task_file:
        mov al, [hd_head]
        call hd_drive_head
        push cx
        call hd_wait_idle
        pop cx
        jc .late
        mov al, [di + UNIT_PRECOMP]
        mov dx, HDC_PRECOMP
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
        clc
.late:
        ret

; ----------------------------------------------------------------------------
; hd_seek - DRV_DISK_SEEK: a Seek to a cylinder, done once its steps are sent
;   In:       hd_unit; CX = the cylinder
;   Out:      BX = 0 or E_INVAL, E_IO, E_TIMEOUT; CX = 0; DX = 0
;   Destroys: AX, DI
; ----------------------------------------------------------------------------
hd_seek:
        call hd_entry
        cmp cx, [di + UNIT_CYLINDERS]
        jae .invalid
        mov [hd_cylinder], cx
        mov byte [hd_head], 0
        mov byte [hd_sector], 1
        call hd_unit_ready
        cmp byte [bx], 0
        jne .ready
        call hd_setup
        jc .failed
.ready:
        call hd_task_file
        jc .late
        mov byte [irq_seen], 0
        mov al, HDC_CMD_SEEK
        mov dx, HDC_COMMAND
        out dx, al
        mov cx, HD_TICKS
        call dw_wait_irq
        jc .late
        test byte [hd_status], HDC_STATUS_ERR
        jnz .error
        mov bl, [hd_unit]
        xor bh, bh
        shl bx, 1
        mov ax, [hd_cylinder]
        mov [hd_cylinder_now + bx], ax
        xor bx, bx
        jmp .out
.error:
        call hd_forget
        mov bx, E_IO
        jmp .out
.late:
        call hd_forget
        mov bx, E_TIMEOUT
        jmp .out
.failed:
        mov bx, ax
        jmp .out
.invalid:
        mov bx, E_INVAL
.out:
        xor cx, cx
        xor dx, dx
        ret

; ----------------------------------------------------------------------------
; hd_unit_status - DRV_DISK_STATUS: the cylinder the driver believes, and
;                  whether the drive's seek has ended (Seek Complete)
;   In:       hd_unit
;   Out:      BX = 0 or E_TIMEOUT; CX = the cylinder or DISK_CYLINDER_UNKNOWN;
;             DX = DRV_STATUS_SEEKING or 0
;   Destroys: AX
; ----------------------------------------------------------------------------
hd_unit_status:
        mov bl, [hd_unit]
        xor bh, bh
        shl bx, 1
        mov cx, [hd_cylinder_now + bx]
        xor al, al
        call hd_drive_head
        call hd_wait_idle
        jc .late
        xor dx, dx
        test al, HDC_STATUS_DSC
        jnz .there
        mov dl, DRV_STATUS_SEEKING
.there:
        xor bx, bx
        ret
.late:
        mov bx, E_TIMEOUT
        xor dx, dx
        ret

; ----------------------------------------------------------------------------
; hd_ends_on - where a run left the drive's heads: its last sector's cylinder
;   In:       DI = the drive's entry; hd_unit, hd_cylinder, hd_head,
;             hd_sector, hd_count
;   Out:      hd_cylinder_now
;   Destroys: AX, BX, CX, DX
; ----------------------------------------------------------------------------
hd_ends_on:
        mov al, [hd_head]               ; sectors from the cylinder's start to the
        mul byte [di + UNIT_TRACK]      ;    last: head x track + sector - 1 + count - 1
        mov bl, [hd_sector]
        xor bh, bh
        add ax, bx
        mov bl, [hd_count]
        add ax, bx
        sub ax, 2
        xor dx, dx
        mov bl, [di + UNIT_HEADS]
        mov cl, [di + UNIT_TRACK]
        mov bh, 0
        mov ch, 0
        push ax
        mov ax, bx
        mul cx                          ; sectors a cylinder
        mov cx, ax
        pop ax
        div cx                          ; cylinders past the run's first
        add ax, [hd_cylinder]
        mov bl, [hd_unit]
        xor bh, bh
        shl bx, 1
        mov [hd_cylinder_now + bx], ax
        ret

; ----------------------------------------------------------------------------
; hd_forget - every drive's set-up and cylinder forgotten: the next command
;             resets the controller
;   In:       nothing
;   Out:      nothing
;   Destroys: nothing
; ----------------------------------------------------------------------------
hd_forget:
        mov word [hd_ready], 0
        mov word [hd_cylinder_now], DISK_CYLINDER_UNKNOWN
        mov word [hd_cylinder_now + 2], DISK_CYLINDER_UNKNOWN
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
        xor al, al                      ; this drive, before the reset too: an IDE
        call hd_drive_head              ;    drive takes it only while not busy
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
        cmp byte [di + UNIT_HEADS], 8
        jbe .control
        mov al, HDC_CONTROL_HEADS       ; more than 8 heads (head select 3)
.control:
        out dx, al
.parameters:
        xor al, al                      ; this drive first: the status is the drive's
        call hd_drive_head              ;    selected (one not there: never busy)
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
        mov bl, [hd_unit]
        xor bh, bh
        shl bx, 1
        mov word [hd_cylinder_now + bx], 0
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
%include "dfits.asm"
