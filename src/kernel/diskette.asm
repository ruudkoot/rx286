; ============================================================================
; rx286 - src/kernel/diskette.asm
; The diskette drives A and B: the NEC uPD765 of the AT's fixed disk and
; diskette adapter, IRQ6 and DMA channel 2 (storage roadmap D2, D3).
;
; One sector at a time, through the disk buffer (disk.asm), and synchronous:
; the kernel sleeps with interrupts on (ksleep_until) while the drive seeks
; and the controller transfers, and every wait has a limit, so a missing
; diskette or a dead controller is an error, never a hang. Each drive's
; media is fixed (docs/disks.md): A 1.2 MB at 500 kbit/s, B 360 KB at
; 250 kbit/s, with the gaps of IBM's BIOS (5-170, 5-60). The controller has
; no implied seek: a transfer seeks first, after recalibrating a drive whose
; cylinder is not known. The controller is reset and given its timings
; (Specify) before the first transfer and after any timeout. A transfer the
; controller fails is tried FD_TRIES times, recalibrating in between; a
; timeout ends it at once. The motor runs FD_MOTOR_OFF_TICKS after the last
; transfer, as the BIOS's does (fd_tick).
; ============================================================================

FD_TRIES            equ 3
FD_RECALIBRATIONS   equ 2               ; the 765 steps 77 times at most: 80 cylinders may need two
FD_MOTOR_START_TICKS equ 50 + 1         ; more than 1 s: the BIOS's motor start time
FD_MOTOR_OFF_TICKS  equ 100             ; 2 s after the last transfer
FD_SETTLE_TICKS     equ 1 + 1           ; more than the BIOS's 15 ms of head settling
FD_TICKS            equ 100 + 1         ; 2 s for a command: the BIOS's diskette timeout
FD_BYTE_TICKS       equ 2               ; for the controller to take or give a byte
FD_RESET_READS      equ 16              ; the reset held for that many reads of a port
FD_SENSES_AFTER_RESET equ 4             ; one Sense Interrupt Status for each drive it polled
FD_UNKNOWN          equ 0xFF            ; a cylinder not known: recalibrate first
FD_TRANSFER_BYTES   equ 9               ; a read's or write's command
FD_RESULT_BYTES     equ 7               ; and its result: ST0, ST1, ST2, C, H, R, N
FD_SENSE_BYTES      equ 2               ; Sense Interrupt Status's result: ST0, PCN

begin_kdata
fd_irq_seen         db 0                ; set by IRQ6
fd_specified        db 0                ; reset and given its timings
fd_dor              db FDC_DOR_MOTORS_OFF   ; the digital output register as last written
fd_motor_ticks      dw 0                ; ticks until the motor stops; 0: no count
fd_cylinder         db FD_UNKNOWN, FD_UNKNOWN   ; where each drive's heads are
fd_tries            db 0
fd_dma_mode         db 0
fd_transfer_command db 0                ; FDC_CMD_READ or FDC_CMD_WRITE; then:
fd_unit_head        db 0                ; the head (bit 2) and the drive (bits 0-1)
fd_c                db 0
fd_h                db 0
fd_r                db 0
fd_n                db FDC_SIZE_512
fd_eot              db 0
fd_gpl              db 0
fd_dtl              db FDC_DTL
fd_seek_command     db FDC_CMD_SEEK
fd_seek_unit_head   db 0
fd_seek_cylinder    db 0
fd_recal_command    db FDC_CMD_RECALIBRATE
fd_recal_unit       db 0
fd_sense_command    db FDC_CMD_SENSE_INT
fd_specify_command  db FDC_CMD_SPECIFY, FDC_SPECIFY_1, FDC_SPECIFY_2
fd_result           times FD_RESULT_BYTES db 0
end_kdata

; ----------------------------------------------------------------------------
; fd_transfer - one sector between the disk buffer and a diskette
;   In:       AL = DISK_READ or DISK_WRITE; BX = the drive's entry (disk.asm);
;             disk_cylinder, disk_head, disk_sector; DS = ES = SEL_KDATA;
;             interrupts off
;   Out:      CF clear; or CF set and AX = E_IO, E_TIMEOUT or E_PROTECTED
;   Destroys: AX, CX, DX, SI, DI
; ----------------------------------------------------------------------------
fd_transfer:
        mov ah, FDC_CMD_READ
        mov dl, DMA_MODE_TO_MEMORY
        cmp al, DISK_READ
        je .direction
        mov ah, FDC_CMD_WRITE
        mov dl, DMA_MODE_FROM_MEMORY
.direction:
        mov [fd_transfer_command], ah
        mov [fd_dma_mode], dl
        mov word [fd_motor_ticks], 0    ; the motor runs while the kernel works
        cmp byte [fd_specified], 0
        jne .specified
        call fd_reset
        jc .failed_now
.specified:
        call fd_motor_on
        mov byte [fd_tries], FD_TRIES
.try:
        call fd_seek
        jc .seek_failed
        mov al, [bx + DRIVE_RATE]
        mov dx, FDC_CCR
        out dx, al
        mov al, [fd_dma_mode]
        call dma_diskette
        mov al, [disk_head]
        mov [fd_h], al
        shl al, 2
        or al, [bx + DRIVE_UNIT]
        mov [fd_unit_head], al
        mov al, [disk_cylinder]
        mov [fd_c], al
        mov al, [disk_sector]
        mov [fd_r], al
        mov al, [bx + DRIVE_TRACK]      ; the track's last sector: the DMA's terminal
        mov [fd_eot], al                ; count ends the transfer after one
        mov al, [bx + DRIVE_GAP]
        mov [fd_gpl], al
        mov byte [fd_irq_seen], 0
        mov si, fd_transfer_command
        mov cx, FD_TRANSFER_BYTES
        call fd_send
        jc .timeout
        mov si, fd_irq_seen
        mov cx, FD_TICKS
        call ksleep_until
        jc .timeout
        mov cx, FD_RESULT_BYTES
        call fd_results
        jc .timeout
        test byte [fd_result], FDC_ST0_CODE
        jz .done
        test byte [fd_result + 1], FDC_ST1_NOT_WRITABLE
        mov ax, E_PROTECTED
        jnz .failed_now
        call fd_forget_cylinder         ; recalibrate before the next try
        mov ax, E_IO
.retry:
        dec byte [fd_tries]
        jnz .try
        jmp .failed_now
.seek_failed:
        cmp ax, E_TIMEOUT
        je .failed_now
        call fd_forget_cylinder
        jmp .retry
.timeout:
        call fd_reset                   ; for the next call
        mov ax, E_TIMEOUT
.failed_now:
        stc
        jmp .out
.done:
        clc
.out:
        mov word [fd_motor_ticks], FD_MOTOR_OFF_TICKS   ; MOV keeps CF
        ret

; ----------------------------------------------------------------------------
; fd_motor_on - select the drive and run its motor (the other's stops); if
; it was not running, wait for it to come up to speed
;   In:       BX = the drive's entry; DS = SEL_KDATA; interrupts off
;   Out:      nothing
;   Destroys: AX, CX, DX
; ----------------------------------------------------------------------------
fd_motor_on:
        mov cl, [bx + DRIVE_UNIT]
        mov ah, FDC_DOR_MOTOR_A
        shl ah, cl                      ; the drive's motor bit
        mov al, FDC_DOR_MOTORS_OFF
        or al, ah
        or al, cl                       ; the drive selected
        mov ch, [fd_dor]                ; the motors as they were
        mov [fd_dor], al
        mov dx, FDC_DOR
        out dx, al
        test ch, ah
        jnz .running
        mov cx, FD_MOTOR_START_TICKS
        call ksleep
.running:
        ret

; ----------------------------------------------------------------------------
; fd_tick - on every tick: stop the motor once its time has run out
;   In:       DS = SEL_KDATA
;   Out:      nothing
;   Destroys: AL, DX
; ----------------------------------------------------------------------------
fd_tick:
        cmp word [fd_motor_ticks], 0
        je .done
        dec word [fd_motor_ticks]
        jnz .done
        mov al, [fd_dor]
        and al, ~FDC_DOR_MOTORS & 0xFF
        mov [fd_dor], al
        mov dx, FDC_DOR
        out dx, al
.done:
        ret

; ----------------------------------------------------------------------------
; fd_seek - the heads over disk_cylinder: recalibrate first if the drive's
; cylinder is not known, seek if it is another, then let the heads settle
;   In:       BX = the drive's entry; disk_cylinder, disk_head;
;             DS = ES = SEL_KDATA; interrupts off
;   Out:      CF clear; or CF set and AX = E_IO or E_TIMEOUT
;   Destroys: AX, CX, DX, SI, DI
; ----------------------------------------------------------------------------
fd_seek:
        call fd_unit_cylinder
        cmp byte [si], FD_UNKNOWN
        jne .known
        call fd_recalibrate
        jc .out
.known:
        call fd_unit_cylinder
        mov al, [disk_cylinder]
        cmp [si], al
        je .there
        mov [fd_seek_cylinder], al
        mov al, [disk_head]
        shl al, 2
        or al, [bx + DRIVE_UNIT]
        mov [fd_seek_unit_head], al
        mov si, fd_seek_command
        mov cx, fd_recal_command - fd_seek_command
        call fd_command_sense
        jc .out
        mov al, [fd_seek_cylinder]
        cmp [fd_result + 1], al         ; the present cylinder
        jne .error
        call fd_unit_cylinder
        mov [si], al
        mov cx, FD_SETTLE_TICKS
        call ksleep
.there:
        clc
.out:
        ret
.error:
        mov ax, E_IO
        stc
        ret

; ----------------------------------------------------------------------------
; fd_recalibrate - the heads to cylinder 0, in up to FD_RECALIBRATIONS tries
;   In:       BX = the drive's entry; DS = ES = SEL_KDATA; interrupts off
;   Out:      CF clear; or CF set and AX = E_IO or E_TIMEOUT
;   Destroys: AX, CX, DX, SI, DI
; ----------------------------------------------------------------------------
fd_recalibrate:
        mov al, [bx + DRIVE_UNIT]
        mov [fd_recal_unit], al
        mov cx, FD_RECALIBRATIONS
.again:
        push cx
        mov si, fd_recal_command
        mov cx, fd_sense_command - fd_recal_command
        call fd_command_sense
        pop cx
        jnc .home
        cmp ax, E_TIMEOUT
        je .failed
        loop .again
.failed:
        stc
        ret
.home:
        cmp byte [fd_result + 1], 0     ; the present cylinder
        jne .error
        call fd_unit_cylinder
        mov byte [si], 0
        clc
        ret
.error:
        mov ax, E_IO
        stc
        ret

; ----------------------------------------------------------------------------
; fd_command_sense - a command that ends with an interrupt but no result
; phase (Seek, Recalibrate): send it, wait for IRQ6, then Sense Interrupt
; Status, whose ST0 must say the seek ended well
;   In:       SI = the command; CX = its length; DS = ES = SEL_KDATA;
;             interrupts off
;   Out:      CF clear and fd_result = ST0, the present cylinder; or CF set
;             and AX = E_IO or E_TIMEOUT (the controller reset)
;   Destroys: AX, CX, DX, SI, DI
; ----------------------------------------------------------------------------
fd_command_sense:
        mov byte [fd_irq_seen], 0
        call fd_send
        jc .timeout
        mov si, fd_irq_seen
        mov cx, FD_TICKS
        call ksleep_until
        jc .timeout
        mov si, fd_sense_command
        mov cx, 1
        call fd_send
        jc .timeout
        mov cx, FD_SENSE_BYTES
        call fd_results
        jc .timeout
        mov al, [fd_result]
        and al, FDC_ST0_CODE | FDC_ST0_SEEK_END
        cmp al, FDC_ST0_SEEK_END
        jne .error
        clc
        ret
.error:
        mov ax, E_IO
        stc
        ret
.timeout:
        call fd_reset
        mov ax, E_TIMEOUT
        stc
        ret

; ----------------------------------------------------------------------------
; fd_reset - reset the controller, acknowledge its interrupt, give it its
; timings; every drive's cylinder is then unknown
;   In:       DS = ES = SEL_KDATA; interrupts off
;   Out:      CF clear; or CF set and AX = E_TIMEOUT
;   Destroys: AX, CX, DX, SI, DI
; ----------------------------------------------------------------------------
fd_reset:
        mov byte [fd_specified], 0
        mov byte [fd_cylinder], FD_UNKNOWN
        mov byte [fd_cylinder + 1], FD_UNKNOWN
        mov byte [fd_irq_seen], 0
        mov dx, FDC_DOR
        mov al, FDC_DOR_RESET
        out dx, al
        mov cx, FD_RESET_READS
        mov dx, FDC_MSR
.hold:
        in al, dx
        loop .hold
        mov al, [fd_dor]
        mov dx, FDC_DOR
        out dx, al
        mov si, fd_irq_seen
        mov cx, FD_TICKS
        call ksleep_until
        jc .late
        mov cx, FD_SENSES_AFTER_RESET
.sense:
        push cx
        mov si, fd_sense_command
        mov cx, 1
        call fd_send
        jc .late_pop
        mov cx, FD_SENSE_BYTES
        call fd_results
        jc .late_pop
        pop cx
        loop .sense
        mov si, fd_specify_command
        mov cx, fd_result - fd_specify_command
        call fd_send
        jc .late
        mov byte [fd_specified], 1
        clc
        ret
.late_pop:
        pop cx
.late:
        mov ax, E_TIMEOUT
        stc
        ret

; ----------------------------------------------------------------------------
; fd_send - bytes of a command to the controller, each when it is ready
;   In:       SI = the bytes; CX = how many; DS = SEL_KDATA; interrupts off
;   Out:      CF clear; or CF set: the controller did not take one
;   Destroys: AX, CX, DX, SI
; ----------------------------------------------------------------------------
fd_send:
        push cx
        mov dx, FDC_MSR
        mov ah, FDC_MSR_RQM | FDC_MSR_DIO
        mov al, FDC_MSR_RQM             ; ready, and the processor's turn
        mov cx, FD_BYTE_TICKS
        call kpoll
        pop cx
        jc .out
        lodsb
        mov dx, FDC_DATA
        out dx, al
        loop fd_send
        clc
.out:
        ret

; ----------------------------------------------------------------------------
; fd_results - bytes of a result phase from the controller into fd_result
;   In:       CX = how many; DS = ES = SEL_KDATA; interrupts off
;   Out:      CF clear; or CF set: the controller did not give one
;   Destroys: AX, CX, DX, DI
; ----------------------------------------------------------------------------
fd_results:
        mov di, fd_result
.byte:
        push cx
        mov dx, FDC_MSR
        mov ah, FDC_MSR_RQM | FDC_MSR_DIO
        mov al, FDC_MSR_RQM | FDC_MSR_DIO   ; ready, and the controller's turn
        mov cx, FD_BYTE_TICKS
        call kpoll
        pop cx
        jc .out
        mov dx, FDC_DATA
        in al, dx
        stosb
        loop .byte
        clc
.out:
        ret

; ----------------------------------------------------------------------------
; fd_unit_cylinder - where the drive's cylinder is kept
;   In:       BX = the drive's entry
;   Out:      SI = its byte of fd_cylinder
;   Destroys: nothing
; ----------------------------------------------------------------------------
fd_unit_cylinder:
        push ax
        mov al, [bx + DRIVE_UNIT]
        cbw
        mov si, fd_cylinder
        add si, ax
        pop ax
        ret

; ----------------------------------------------------------------------------
; fd_forget_cylinder - the drive's cylinder is no longer known
;   In:       BX = the drive's entry; DS = SEL_KDATA
;   Out:      nothing
;   Destroys: SI
; ----------------------------------------------------------------------------
fd_forget_cylinder:
        call fd_unit_cylinder
        mov byte [si], FD_UNKNOWN
        ret

; ----------------------------------------------------------------------------
; fd_irq - IRQ6: the controller has finished a command or left reset
;   In:       DS = SEL_KDATA
;   Out:      nothing (the dispatcher sends EOI)
;   Destroys: nothing
; ----------------------------------------------------------------------------
fd_irq:
        mov byte [fd_irq_seen], 1
        ret
