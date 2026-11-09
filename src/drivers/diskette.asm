; ============================================================================
; rx286 - src/drivers/diskette.asm
; The diskette driver (roadmap l4.md L9; storage roadmap D2, D3): drives A
; and B on the NEC uPD765 of the AT's fixed disk and diskette adapter,
; IRQ6 and DMA channel 2, in ring 1 with IOPL 1.
;
; A run of sectors a call (disk-scheduler.md M2, D2): by cylinder, head and
; sector, one Read or Write Data for the run, going on to head 1 (MT) if it
; does, never past its cylinder; the 8237's channel 2 carries the run
; through a DMA buffer of FD_RUN_MAX sectors, or of fewer, which the root
; gives a machine without extended memory: a run longer than the buffer
; moves what it holds, and says how much (CX). Every wait has a limit
; (dwait.asm), so a missing diskette or a dead controller is an error, never
; a hang. Each
; drive's media is fixed (docs/disks.md): A 1.2 MB at 500 kbit/s, B 360 KB
; at 250 kbit/s, with the gaps of IBM's BIOS (5-170, 5-60). The controller
; has no implied seek: a transfer seeks first, after recalibrating a drive
; whose cylinder is not known. The controller is reset and given its
; timings (Specify) before the first transfer and after any timeout. A
; transfer the controller fails is tried once (FD_TRIES), its drive's
; cylinder forgotten, so that the next recalibrates: the disk server's
; retries (disk-scheduler.md M3, D14) come so. The motor runs FD_MOTOR_OFF_TICKS after
; the last transfer, as the BIOS's does: the driver's timer looks. The 8237's
; channel 2 carries each run to or from the DMA buffer the root gave the
; driver (DRV_SLOT_DEVICE: FD_RUN_MAX sectors that do not cross 64 KB), whose
; physical address the kernel says (KCALL_SEGMENT); the driver copies it
; from or to the segment the OS server passes (DRV_DISK_READ,
; DRV_DISK_WRITE; drivers.inc), and deletes that segment once it is done. At
; its start it resets both DMA controllers, as the kernel did.
; ============================================================================

cpu 286
bits 16
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
DMA_BUFFER          equ SLOT(DRV_SLOT_DEVICE)
FD_UNITS            equ 2
FD_RUN_MAX          equ FD_DMA_SECTORS  ; a run at most: a 1.2 MB cylinder, the DMA buffer's
FDC_CMD_MT          equ 0x80            ; Read or Write Data's multi-track bit: on to head 1
FDC_CMD_READ_ID     equ 0x4A            ; Read ID, MFM
FD_TRIES            equ 1               ; the disk server tries again (D14)
FD_RECALIBRATIONS   equ 2               ; the 765 steps 77 times at most: 80 cylinders may need two
FD_MOTOR_START_TICKS equ 50 + 1         ; more than 1 s: the BIOS's motor start time
FD_MOTOR_OFF_TICKS  equ 100             ; 2 s after the last transfer
FD_SETTLE_TICKS     equ 1 + 1           ; more than the BIOS's 15 ms of head settling
FD_LINE_UNKNOWN     equ 0               ; fd_line: A's change line not yet seen to clear
FD_LINE_WORKS       equ 1               ;    seen to clear: set and not clearing, no diskette
FD_LINE_NONE        equ 2               ;    never clears with a diskette in (DOSBox-X,
                                        ;    whose controller has no DIR): B's rule
FD_TICKS            equ 100 + 1         ; 2 s for a command: the BIOS's diskette timeout
FD_PROBE_TICKS      equ 30 + 1          ; 0.6 s for fd_probe's Read ID: a diskette in a 1.2 MB
                                        ;    drive answers within two turns (0.33 s)
FD_BYTE_TICKS       equ 2               ; for the controller to take or give a byte
FD_RESET_READS      equ 16              ; the reset held for that many reads of a port
FD_SENSES_AFTER_RESET equ 4             ; one Sense Interrupt Status for each drive it polled
FD_UNKNOWN          equ 0xFF            ; a cylinder not known: recalibrate first
FD_TRANSFER_BYTES   equ 9               ; a read's or write's command
FD_RESULT_BYTES     equ 7               ; and its result: ST0, ST1, ST2, C, H, R, N
FD_SENSE_BYTES      equ 2               ; Sense Interrupt Status's result: ST0, PCN

; A drive's entry in units
UNIT_CYLINDERS      equ 0
UNIT_HEADS          equ 2
UNIT_TRACK          equ 3               ; sectors a track
UNIT_RATE           equ 4               ; its data rate (FDC_RATE_*)
UNIT_GAP            equ 5               ; its gap 3
UNIT_SIZE           equ 6

begin_udata
units:
        dw DISK_A_CYLINDERS
        db DISK_A_HEADS, DISK_A_SECTORS, FDC_RATE_500K, FDC_GAP_1200K
        dw DISK_B_CYLINDERS
        db DISK_B_HEADS, DISK_B_SECTORS, FDC_RATE_250K, FDC_GAP_360K
dma_base            dw 0                ; the DMA buffer's physical address
dma_page            db 0
irq_seen            db 0                ; set when IRQ6 came
fd_specified        db 0                ; reset and given its timings
fd_dor              db FDC_DOR_MOTORS_OFF   ; the digital output register as last written
fd_motor_running    db 0                ; a motor runs, and stops FD_MOTOR_OFF_TICKS after
fd_last             dw 0                ; the tick of the last transfer's end
fd_unit             db 0                ; the transfer's drive (0 or 1)
fd_unit_last        dw 0, 0             ; each drive's last transfer's end, in ticks
fd_line             db FD_LINE_UNKNOWN  ; A's change line: seen to clear, or none (M8)
fd_id_ticks         dw FD_TICKS         ; fd_read_id's wait: fd_probe's shorter
fd_double           db 0, 0             ; each drive's: a 360 KB diskette in a 1.2 MB drive,
                                        ;    its cylinder two tracks apart (M8, D13)
fd_cylinder         db FD_UNKNOWN, FD_UNKNOWN   ; where each drive's heads are
fd_moved            db 0                ; fd_seek's: the heads moved, to settle
fd_tries            db 0
fd_dma_mode         db 0
fd_base_command     db 0                ; FDC_CMD_READ or FDC_CMD_WRITE
fd_count            dw 0                ; the run's sectors
fd_run_max          db FD_RUN_MAX       ; the DMA buffer's sectors (entry)
fd_head             db 0                ; where the sector is
fd_track_cylinder   db 0
fd_sector           db 0                ; from 1, as the controller counts
fd_transfer_command db 0                ; fd_base_command, with MT if the run needs it; then:
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
fd_id_command       db FDC_CMD_READ_ID  ; (after fd_result: fd_reset sends Specify up to it)
fd_id_unit_head     db 0
end_udata

; ----------------------------------------------------------------------------
; entry - both DMA controllers reset, the DMA buffer's address asked for;
; then serve
;   In:       its start: DS = ES = its data, IOPL 1
;   Out:      does not return
;   Destroys: everything
; ----------------------------------------------------------------------------
entry:
        cld
        out DMA1_MASTER_CLEAR, al       ; any value: every channel masked
        out DMA2_MASTER_CLEAR, al
        mov al, DMA_MODE_CASCADE        ; channel 0 of controller 2: channel 4
        out DMA2_MODE, al
        xor al, al                      ; and unmask it
        out DMA2_MASK, al
        mov dx, DMA_BUFFER
        kcall KCALL_SEGMENT             ; DL:AX = its physical address, CX its limit
        mov [dma_base], ax
        mov [dma_page], dl
        inc cx
        shr cx, SECTOR_SHIFT
        mov [fd_run_max], cl            ; the sectors it holds: the root's choice
        ; falls through

; ----------------------------------------------------------------------------
; serve - each call, for ever; the motor stopped once its time has run out
;   In:       nothing
;   Out:      does not return
;   Destroys: everything
; ----------------------------------------------------------------------------
serve:
        call fd_motor_timer
        mov dx, EP
        mov bp, RECV
        kcall KCALL_RECV
.message:
        jc serve
        cmp al, NOTIFY_LABEL
        jne .call
        call dw_bits                    ; a late interrupt: taken
        call fd_motor_check             ; the timer: the motor's time?
        jmp serve
.call:
        push bp
        call fd_call                    ; BX = 0 or the error; CX, DX the answer
        pop bp
        push bx
        push cx
        push dx
        test bp, bp
        jz .no_segment
        mov dx, RECV                    ; the segment, used: room for the next
        kcall KCALL_DELETE
.no_segment:
        call fd_motor_timer             ; the motor's time: no wait's timer is left
        pop dx                          ;    to make the driver look (P15)
        pop cx
        pop bx
        mov si, dx                      ; (the reply's third word)
        mov di, 0
        mov dx, EP
        mov bp, RECV
        kcall KCALL_REPLY_RECV
        jmp .message

; ----------------------------------------------------------------------------
; fd_call - one call
;   In:       AL = the label; BL = the unit; BH = the head; CX = the cylinder;
;             DI = the sector and count; SI = the offset; BP = the segment
;             passed (0: none came)
;   Out:      BX = 0 or the error; CX and DX (sent in SI) its answer
;   Destroys: AX, SI, DI, ES
; ----------------------------------------------------------------------------
fd_call:
        cmp bl, FD_UNITS
        jae .invalid
        mov [fd_unit], bl
        mov [fd_head], bh
        push ax
        mov al, bl
        mov ah, UNIT_SIZE
        mul ah
        add ax, units
        mov dx, ax                      ; DX = the drive's entry
        pop ax
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
        cmp al, DRV_DISK_READ_ID
        je .read_id
        cmp al, DRV_DISK_MEDIA
        je .media
.invalid:
        mov bx, E_INVAL
        xor cx, cx
        xor dx, dx
        ret
.read:
        mov ah, FDC_CMD_READ
        mov al, DMA_MODE_TO_MEMORY
        jmp fd_transfer
.write:
        mov ah, FDC_CMD_WRITE
        mov al, DMA_MODE_FROM_MEMORY
        jmp fd_transfer
.seek:
        mov di, dx
        cmp cx, [di + UNIT_CYLINDERS]
        jae .invalid
        mov [fd_track_cylinder], cl
        mov byte [fd_head], 0
        call fd_ready
        jc .failed
        call fd_seek
        jc .failed
        call fd_done
        xor bx, bx
        xor cx, cx
        xor dx, dx
        ret
.failed:
        call fd_done
        mov bx, ax
        xor cx, cx
        xor dx, dx
        ret
.status:
        call fd_unit_cylinder
        mov cl, [si]
        xor ch, ch
        cmp cl, FD_UNKNOWN
        jne .known
        mov cx, DISK_CYLINDER_UNKNOWN
.known:
        xor bx, bx
        xor dx, dx                      ; (the change line: M8)
        ret
.reset:
        call fd_reset
        mov bx, 0
        jnc .reset_done
        mov bx, ax
.reset_done:
        xor cx, cx
        xor dx, dx
        ret
.geometry:
        mov di, dx
        mov cx, [di + UNIT_CYLINDERS]
        mov dl, [di + UNIT_HEADS]
        mov dh, [di + UNIT_TRACK]
        xor bx, bx
        ret
.read_id:
        mov di, dx
        cmp bh, [di + UNIT_HEADS]
        jae .invalid
        jmp fd_read_id
.media:
        mov di, dx
        jmp fd_media

; ----------------------------------------------------------------------------
; fd_ready - the controller reset and given its timings if it needs it, the
;            drive selected and its motor up to speed, its data rate set
;   In:       DI = the drive's entry; fd_unit
;   Out:      CF clear; or CF set and AX = E_TIMEOUT
;   Destroys: AX, CX, DX, SI
; ----------------------------------------------------------------------------
fd_ready:
        mov byte [fd_motor_running], 0  ; the motor runs while the driver works
        cmp byte [fd_specified], 0
        jne .specified
        call fd_reset
        jc .out
.specified:
        call fd_motor_on
        mov al, [di + UNIT_RATE]        ; before any seek: the step rate scales
        mov dx, FDC_CCR                 ;    with the data rate (IBM's SRT table,
        out dx, al                      ;    and the BIOS's order)
        clc
.out:
        ret

; ----------------------------------------------------------------------------
; fd_done - the motor's time from now (serve arms its timer)
;   In:       nothing
;   Out:      nothing
;   Destroys: nothing (flags kept)
; ----------------------------------------------------------------------------
fd_done:
        pushf
        push ax
        push bx
        call dw_ticks
        mov [fd_last], ax
        mov bl, [fd_unit]
        xor bh, bh
        shl bx, 1
        mov [fd_unit_last + bx], ax
        mov byte [fd_motor_running], 1
        pop bx
        pop ax
        popf
        ret

; ----------------------------------------------------------------------------
;
; fd_changed - may the drive's diskette have changed since the driver last
; looked (disk-scheduler.md M8, D12)? A's change line set: a step, which
; clears it if a diskette is in. A line never yet seen to clear that stays
; set, with a diskette in (fd_probe): the drive has none (DOSBox-X), and
; is treated as B is from then on. B, whose drive has no change line: its
; last transfer longer ago than its motor's time
;   In:       DI = the drive's entry; fd_unit, fd_head, fd_track_cylinder;
;             the drive selected, its motor on
;   Out:      CF clear; or CF set and AX = E_CHANGED, or E_TIMEOUT (no diskette)
;   Destroys: AX, CX, DX, SI
; ----------------------------------------------------------------------------
fd_changed:
        cmp byte [fd_unit], 0
        jne .by_time
        cmp byte [fd_line], FD_LINE_NONE
        je .by_time
        mov dx, FDC_DIR
        in al, dx
        test al, FDC_DIR_CHANGED
        jz .clear
        mov al, [fd_track_cylinder]     ; (the run's, kept)
        mov ah, [fd_head]
        push ax
        call fd_forget_cylinder
        mov byte [fd_track_cylinder], 1 ; a step pulse clears it, with a diskette in:
        call fd_seek                    ;    a recalibrate at cylinder 0 gives none
        jc .stepped
        call fd_cleared                 ; (MAME's a moment late: again, then a step back)
        jnc .stepped
        mov byte [fd_track_cylinder], 0
        call fd_seek
        jc .stepped
        call fd_cleared
        jnc .stepped
        cmp byte [fd_line], FD_LINE_WORKS
        stc
        je .stepped
        push bx
        call fd_probe                   ; a diskette in a drive with no line?
        cmp bx, E_TIMEOUT
        pop bx
        stc
        je .stepped
        mov byte [fd_line], FD_LINE_NONE
        clc
.stepped:
        pop cx
        mov [fd_track_cylinder], cl
        mov [fd_head], ch
        jc .none
        cmp byte [fd_line], FD_LINE_NONE
        je .changed
        mov byte [fd_line], FD_LINE_WORKS
.changed:
        mov ax, E_CHANGED
        stc
        ret
.none:
        mov ax, E_TIMEOUT
        stc
        ret
.by_time:
        push bx
        mov bl, [fd_unit]
        xor bh, bh
        shl bx, 1
        call dw_ticks
        mov cx, ax
        sub ax, [fd_unit_last + bx]
        cmp ax, FD_MOTOR_OFF_TICKS
        jb .same_pop
        mov [fd_unit_last + bx], cx     ; (the check's own reads come at once)
        pop bx
        mov ax, E_CHANGED
        stc
        ret
.same_pop:
        pop bx
        clc
        ret
.clear:
        mov byte [fd_line], FD_LINE_WORKS
        clc
        ret

; ----------------------------------------------------------------------------
; fd_cleared - has the change line cleared? Looked at again a tick later if not
;   In:       the drive selected
;   Out:      CF clear if it has; CF set if it has not
;   Destroys: AX, CX, DX
; ----------------------------------------------------------------------------
fd_cleared:
        mov dx, FDC_DIR
        in al, dx
        test al, FDC_DIR_CHANGED
        jz .yes
        mov cx, 1 + 1
        call dw_sleep
        mov dx, FDC_DIR
        in al, dx
        test al, FDC_DIR_CHANGED
        jz .yes
        stc
        ret
.yes:
        clc
        ret

; ----------------------------------------------------------------------------
; fd_media - DRV_DISK_MEDIA: A's diskette by Read ID, at 500 kbit/s (1.2 MB)
; and then 300 (360 KB), the drive's entry set for it; a 360 KB one is read
; again on its second track, and its cylinder there says whether the
; drive steps twice (D13). B's is a 360 KB drive's
;   In:       DI = the drive's entry; fd_unit
;   Out:      BX = 0 or the error; CX the cylinders; DX the heads (low) and
;             the sectors a track (high)
;   Destroys: AX, SI
; ----------------------------------------------------------------------------
fd_media:
        cmp byte [fd_unit], 0
        jne .found
        mov byte [fd_double], 0
        mov word [di + UNIT_CYLINDERS], DISK_A_CYLINDERS
        mov word [di + UNIT_TRACK], DISK_A_SECTORS | (FDC_RATE_500K << 8)
        mov byte [di + UNIT_GAP], FDC_GAP_1200K
        call fd_forget_cylinder
        mov byte [fd_head], 0
        mov byte [fd_track_cylinder], 0 ; from track 0, recalibrated to: DOSBox-X's
        call fd_ready                   ;    765 keeps the ST0 of an invalid command,
        jc .failed                      ;    as after a reset, for a Read ID's
        call fd_seek
        jc .failed
        call fd_read_id
        test bx, bx
        jz .found
        mov word [di + UNIT_CYLINDERS], DISK_B_CYLINDERS
        mov word [di + UNIT_TRACK], DISK_B_SECTORS | (FDC_RATE_300K << 8)
        mov byte [di + UNIT_GAP], FDC_GAP_360K
        call fd_read_id
        test bx, bx
        jnz .out
        mov byte [fd_track_cylinder], 2 ; its second track, stepped once a track
        call fd_ready
        jc .failed
        call fd_seek
        jc .failed
        call fd_read_id
        test bx, bx
        jnz .out
        call fd_forget_cylinder         ; (its tracks counted anew)
        cmp cl, 1
        jne .found
        mov byte [fd_double], 1         ; cylinder 1 there: 48-tpi tracks
.found:
        mov cx, [di + UNIT_CYLINDERS]
        mov dl, [di + UNIT_HEADS]
        mov dh, [di + UNIT_TRACK]
        xor bx, bx
.out:
        ret
.failed:
        call fd_done
        mov bx, ax
        ret

; ----------------------------------------------------------------------------
; fd_probe - is a diskette in the drive? One Read ID at the drive's data rate,
; within FD_PROBE_TICKS: a diskette answers within two turns, with an ID or,
; at another rate, with none found; no diskette gives no index pulse, and
; the controller no answer (then reset)
;   In:       DI = the drive's entry; fd_unit, fd_head
;   Out:      BX = E_TIMEOUT if none; else 0 or E_IO
;   Destroys: AX, CX, DX, SI
; ----------------------------------------------------------------------------
fd_probe:
        mov word [fd_id_ticks], FD_PROBE_TICKS
        call fd_read_id
        mov word [fd_id_ticks], FD_TICKS
        ret

; ----------------------------------------------------------------------------
; fd_read_id - DRV_DISK_READ_ID: the first ID the head finds, on the
;              cylinder the heads are on
;   In:       DI = the drive's entry; fd_unit, fd_head
;   Out:      BX = 0 or the error; CX = its cylinder; DX = its head (low)
;             and sector (high)
;   Destroys: AX, SI
; ----------------------------------------------------------------------------
fd_read_id:
        call fd_ready
        jc .failed
        mov al, [fd_head]
        shl al, 2
        or al, [fd_unit]
        mov [fd_id_unit_head], al
        mov byte [irq_seen], 0
        mov si, fd_id_command
        mov cx, 2
        call fd_send
        jc .late
        mov cx, [fd_id_ticks]
        call dw_wait_irq
        jc .late
        mov cx, FD_RESULT_BYTES
        call fd_results
        jc .late
        call fd_done
        test byte [fd_result], FDC_ST0_CODE
        jnz .error
        mov cl, [fd_result + 3]         ; C, H, R
        xor ch, ch
        mov dl, [fd_result + 4]
        mov dh, [fd_result + 5]
        xor bx, bx
        ret
.error:
        mov bx, E_IO
        jmp .none
.late:
        call fd_reset
        call fd_done
        mov ax, E_TIMEOUT
.failed:
        mov bx, ax
.none:
        xor cx, cx
        xor dx, dx
        ret

; ----------------------------------------------------------------------------
; fd_transfer - a run of sectors between the segment passed and a diskette,
;               one command, through the DMA buffer
;   In:       AH = FDC_CMD_READ or FDC_CMD_WRITE; AL = the DMA's mode; DX =
;             the drive's entry; fd_unit, fd_head; CX = the cylinder; DI =
;             the sector (low byte, from 1) and the count (high byte, 0: 1);
;             SI = the offset; BP = the segment (0: none came)
;   Out:      BX = 0, or E_INVAL, E_FAULT, E_IO, E_TIMEOUT, E_PROTECTED; CX =
;             the sectors moved; DX = 0
;   Destroys: AX, SI, DI, ES
; ----------------------------------------------------------------------------
fd_transfer:
        mov [fd_base_command], ah
        mov [fd_dma_mode], al
        mov ax, di
        mov di, dx                      ; DI = the drive's entry
        test ah, ah
        jnz .counted
        inc ah
.counted:
        mov [fd_sector], al
        mov [fd_count], ah
        mov byte [fd_count + 1], 0
        test bp, bp
        jz .fault
        cmp ah, [fd_run_max]
        jbe .held
        mov ah, [fd_run_max]            ; more than the buffer holds: what it holds,
        mov [fd_count], ah              ;    the caller told so (CX)
.held:
        cmp cx, [di + UNIT_CYLINDERS]
        jae .invalid
        mov [fd_track_cylinder], cl
        mov bl, [fd_head]
        cmp bl, [di + UNIT_HEADS]
        jae .invalid
        test al, al
        jz .invalid
        cmp al, [di + UNIT_TRACK]
        ja .invalid
        ; the run within the cylinder: (heads - head) x track - (sector - 1)
        push ax
        mov al, [di + UNIT_HEADS]
        sub al, [fd_head]
        mul byte [di + UNIT_TRACK]
        mov cl, [fd_sector]
        xor ch, ch
        dec cx
        sub ax, cx
        cmp ax, [fd_count]
        pop ax
        jb .invalid
        mov ah, [fd_base_command]       ; MT if the run goes on to head 1
        mov al, [fd_sector]
        dec al
        add al, [fd_count]
        cmp al, [di + UNIT_TRACK]
        jbe .one_track
        or ah, FDC_CMD_MT
.one_track:
        mov [fd_transfer_command], ah
        mov cx, [fd_count]
        shl cx, SECTOR_SHIFT
        call dw_fits                    ; the run within the segment's limit
        jc .fault
        cmp byte [fd_base_command], FDC_CMD_WRITE
        jne .moved_in
        call dw_readable                ; (a program killed meanwhile: l4.md L12)
        jnz .fault
        call buffer_in                  ; a write: its bytes into the DMA buffer
.moved_in:
        push si                         ; (the controller's commands use SI)
        call fd_do
        pop si
        mov bx, ax                      ; (0 if done)
        jc .out
        xor bx, bx
        cmp byte [fd_base_command], FDC_CMD_READ
        jne .whole
        call dw_writable                ; gone while it waited?
        jnz .fault
        call buffer_out                 ; a read: its bytes to the segment passed
.whole:
        mov cx, [fd_count]
        xor dx, dx
        ret
.invalid:
        mov bx, E_INVAL
        jmp .out
.fault:
        mov bx, E_FAULT
.out:
        xor cx, cx
        xor dx, dx
        ret

; ----------------------------------------------------------------------------
; buffer_in - a write's sectors (fd_count), from the segment passed into the
; DMA buffer
;   In:       BP:SI = the sectors in the segment passed
;   Out:      nothing
;   Destroys: AX, CX
; ----------------------------------------------------------------------------
buffer_in:
        push di                         ; (the drive's entry, for fd_do)
        push si
        mov cx, [fd_count]
        shl cx, SECTOR_SHIFT - 1        ; words
        push ds
        mov ax, DMA_BUFFER
        mov es, ax
        mov ds, bp
        xor di, di
        rep movsw
        pop ds
        pop si
        pop di
        push ds
        pop es
        ret

; ----------------------------------------------------------------------------
; buffer_out - a read's sectors (fd_count), from the DMA buffer into the
; segment passed
;   In:       BP:SI = where the sectors go in the segment passed
;   Out:      nothing
;   Destroys: AX, CX, ES
; ----------------------------------------------------------------------------
buffer_out:
        push di
        push si
        mov cx, [fd_count]
        shl cx, SECTOR_SHIFT - 1
        push ds
        mov es, bp
        mov di, si
        mov ax, DMA_BUFFER
        mov ds, ax
        xor si, si
        rep movsw
        pop ds
        pop si
        pop di
        push ds
        pop es
        ret

; ----------------------------------------------------------------------------
; fd_do - the transfer the command bytes describe, with its tries
;   In:       DI = the drive's entry; fd_unit, fd_head, fd_track_cylinder,
;             fd_sector, fd_transfer_command, fd_dma_mode
;   Out:      CF clear; or CF set and AX = E_IO, E_TIMEOUT or E_PROTECTED
;   Destroys: AX, CX, DX, SI
; ----------------------------------------------------------------------------
fd_do:
        mov byte [fd_motor_running], 0  ; the motor runs while the driver works
        cmp byte [fd_specified], 0
        jne .specified
        call fd_reset
        jc .failed_now
.specified:
        call fd_motor_on
        call fd_changed                 ; (the run not done: the disk server checks first)
        jc .failed_now
        mov byte [fd_tries], FD_TRIES
.try:
        mov al, [di + UNIT_RATE]        ; before the seek: the step rate
        mov dx, FDC_CCR                 ; scales with the data rate (IBM's
        out dx, al                      ; SRT table, and the BIOS's order)
        call fd_seek
        jc .seek_failed
        call fd_dma
        mov al, [fd_head]
        mov [fd_h], al
        shl al, 2
        or al, [fd_unit]
        mov [fd_unit_head], al
        mov al, [fd_track_cylinder]
        mov [fd_c], al
        mov al, [fd_sector]
        mov [fd_r], al
        mov al, [di + UNIT_TRACK]       ; the track's last sector: the DMA's terminal
        mov [fd_eot], al                ; count ends the transfer after one
        mov al, [di + UNIT_GAP]
        mov [fd_gpl], al
        mov byte [irq_seen], 0
        mov si, fd_transfer_command
        mov cx, FD_TRANSFER_BYTES
        call fd_send
        jc .timeout
        mov cx, FD_TICKS
        call dw_wait_irq
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
        jmp fd_done                     ; the motor's time from now (serve arms its timer)

; ----------------------------------------------------------------------------
; fd_motor_timer - while the motor runs, the driver's timer for when it is
; to stop (a wait's timer may have taken its place)
;   In:       nothing
;   Out:      nothing
;   Destroys: AX, CX, DX
; ----------------------------------------------------------------------------
fd_motor_timer:
        cmp byte [fd_motor_running], 0
        je .done
        call dw_ticks
        sub ax, [fd_last]
        mov cx, FD_MOTOR_OFF_TICKS + 1
        sub cx, ax
        ja .arm
        mov cx, 1                       ; its time past: a look at once (P15)
.arm:
        mov dx, NOTIFY
        kcall KCALL_TIMER
.done:
        ret

; ----------------------------------------------------------------------------
; fd_dma - channel 2 ready for the run between the controller and the DMA
; buffer
;   In:       fd_dma_mode, fd_count
;   Out:      nothing
;   Destroys: AL
; ----------------------------------------------------------------------------
fd_dma:
        mov al, DMA_MASK_SET | DMA_CHANNEL_DISKETTE
        out DMA1_MASK, al
        out DMA1_CLEAR_FLIPFLOP, al     ; any value
        mov al, [fd_dma_mode]
        or al, DMA_CHANNEL_DISKETTE
        out DMA1_MODE, al
        mov al, [dma_base]
        out DMA1_CH2_ADDRESS, al
        mov al, [dma_base + 1]
        out DMA1_CH2_ADDRESS, al
        mov al, [dma_page]
        out DMA_PAGE_CH2, al
        push cx
        mov cx, [fd_count]              ; the run's bytes, less one
        shl cx, SECTOR_SHIFT
        dec cx
        mov al, cl
        out DMA1_CH2_COUNT, al
        mov al, ch
        out DMA1_CH2_COUNT, al
        pop cx
        mov al, DMA_CHANNEL_DISKETTE    ; unmasked
        out DMA1_MASK, al
        ret

; ----------------------------------------------------------------------------
; fd_motor_on - select the drive and run its motor (the other's stops); if
; it was not running, wait for it to come up to speed
;   In:       fd_unit
;   Out:      nothing
;   Destroys: AX, CX, DX
; ----------------------------------------------------------------------------
fd_motor_on:
        mov cl, [fd_unit]
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
        call dw_sleep
.running:
        ret

; ----------------------------------------------------------------------------
; fd_motor_check - the driver's timer came: stop the motor if its time has
; run out since the last transfer
;   In:       nothing
;   Out:      nothing
;   Destroys: AX, DX
; ----------------------------------------------------------------------------
fd_motor_check:
        cmp byte [fd_motor_running], 0
        je .done
        call dw_ticks
        sub ax, [fd_last]
        cmp ax, FD_MOTOR_OFF_TICKS
        jb .done                        ; an earlier timer's: not yet
        mov byte [fd_motor_running], 0
        mov al, [fd_dor]
        and al, ~FDC_DOR_MOTORS & 0xFF
        mov [fd_dor], al
        mov dx, FDC_DOR
        out dx, al
.done:
        ret

; ----------------------------------------------------------------------------
; fd_seek - the heads over the transfer's cylinder: recalibrate first if the
; drive's cylinder is not known, seek if it is another, then let the heads
; settle if they moved, by either (P15: a recalibrate to the cylinder of
; the transfer, 0, settled not)
;   In:       fd_unit, fd_track_cylinder, fd_head
;   Out:      CF clear; or CF set and AX = E_IO or E_TIMEOUT
;   Destroys: AX, CX, DX, SI
; ----------------------------------------------------------------------------
fd_seek:
        mov byte [fd_moved], 0
        call fd_unit_cylinder
        cmp byte [si], FD_UNKNOWN
        jne .known
        call fd_recalibrate
        jc .out
        mov byte [fd_moved], 1
.known:
        call fd_unit_cylinder
        mov al, [fd_track_cylinder]
        push bx
        mov bl, [fd_unit]
        xor bh, bh
        cmp byte [fd_double + bx], 0
        pop bx
        je .single
        shl al, 1                       ; (48-tpi tracks: two steps a cylinder, D13)
.single:
        cmp [si], al
        je .there
        mov [fd_seek_cylinder], al
        mov al, [fd_head]
        shl al, 2
        or al, [fd_unit]
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
        mov byte [fd_moved], 1
.there:
        cmp byte [fd_moved], 0
        je .settled
        mov cx, FD_SETTLE_TICKS
        call dw_sleep
.settled:
        clc
.out:
        ret
.error:
        mov ax, E_IO
        stc
        ret

; ----------------------------------------------------------------------------
; fd_recalibrate - the heads to cylinder 0, in up to FD_RECALIBRATIONS tries
;   In:       fd_unit
;   Out:      CF clear; or CF set and AX = E_IO or E_TIMEOUT
;   Destroys: AX, CX, DX, SI
; ----------------------------------------------------------------------------
fd_recalibrate:
        mov al, [fd_unit]
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
;   In:       SI = the command; CX = its length
;   Out:      CF clear and fd_result = ST0, the present cylinder; or CF set
;             and AX = E_IO or E_TIMEOUT (the controller reset)
;   Destroys: AX, CX, DX, SI
; ----------------------------------------------------------------------------
fd_command_sense:
        mov byte [irq_seen], 0
        call fd_send
        jc .timeout
        mov cx, FD_TICKS
        call dw_wait_irq
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
;   In:       nothing
;   Out:      CF clear; or CF set and AX = E_TIMEOUT
;   Destroys: AX, CX, DX, SI
; ----------------------------------------------------------------------------
fd_reset:
        mov byte [fd_specified], 0
        mov byte [fd_cylinder], FD_UNKNOWN
        mov byte [fd_cylinder + 1], FD_UNKNOWN
        push bx
        mov dx, NOTIFY                  ; a late interrupt of the command before,
        kcall KCALL_POLL                ;    taken now, not for the reset's (P15)
        jc .drained
        call dw_bits
.drained:
        pop bx
        mov byte [irq_seen], 0
        mov dx, FDC_DOR                 ; the motors and DMA and IRQ6 kept, as the
        mov al, [fd_dor]                ;    BIOS does (P15)
        and al, ~FDC_DOR_RUN & 0xFF
        out dx, al
        mov cx, FD_RESET_READS
        mov dx, FDC_MSR
.hold:
        in al, dx
        loop .hold
        mov al, [fd_dor]
        mov dx, FDC_DOR
        out dx, al
        mov cx, FD_TICKS
        call dw_wait_irq
        jc .late
        mov cx, FD_SENSES_AFTER_RESET
.sense:
        push cx
        mov si, fd_sense_command
        mov cx, 1
        call fd_send
        jc .late_pop
        mov cx, 1                       ; ST0 first: an invalid command's says no
        call fd_results                 ;    drive has an interrupt pending, and no
        jc .late_pop                    ;    PCN follows (DOSBox-X's 765 has one to
        mov al, [fd_result]             ;    sense, not four)
        and al, FDC_ST0_CODE
        cmp al, FDC_ST0_INVALID
        je .sensed
        mov cx, FD_SENSE_BYTES - 1      ; its present cylinder
        call fd_results
        jc .late_pop
        pop cx
        loop .sense
        jmp .specify
.sensed:
        pop cx
.specify:
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
;   In:       SI = the bytes; CX = how many
;   Out:      CF clear; or CF set: the controller did not take one
;   Destroys: AX, CX, DX, SI
; ----------------------------------------------------------------------------
fd_send:
        push cx
        mov dx, FDC_MSR
        mov ah, FDC_MSR_RQM | FDC_MSR_DIO
        mov al, FDC_MSR_RQM             ; ready, and the processor's turn
        mov cx, FD_BYTE_TICKS
        call dw_poll
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
;   In:       CX = how many
;   Out:      CF clear; or CF set: the controller did not give one
;   Destroys: AX, CX, DX
; ----------------------------------------------------------------------------
fd_results:
        push di
        mov di, fd_result
.byte:
        push cx
        mov dx, FDC_MSR
        mov ah, FDC_MSR_RQM | FDC_MSR_DIO
        mov al, FDC_MSR_RQM | FDC_MSR_DIO   ; ready, and the controller's turn
        mov cx, FD_BYTE_TICKS
        call dw_poll
        pop cx
        jc .out
        mov dx, FDC_DATA
        in al, dx
        stosb
        loop .byte
        clc
.out:
        pop di
        ret

; ----------------------------------------------------------------------------
; fd_unit_cylinder - where the drive's cylinder is kept
;   In:       fd_unit
;   Out:      SI = its byte of fd_cylinder
;   Destroys: nothing
; ----------------------------------------------------------------------------
fd_unit_cylinder:
        push ax
        mov al, [fd_unit]
        xor ah, ah
        mov si, fd_cylinder
        add si, ax
        pop ax
        ret

; ----------------------------------------------------------------------------
; fd_forget_cylinder - the drive's cylinder is no longer known
;   In:       fd_unit
;   Out:      nothing
;   Destroys: SI
; ----------------------------------------------------------------------------
fd_forget_cylinder:
        call fd_unit_cylinder
        mov byte [si], FD_UNKNOWN
        ret

; ----------------------------------------------------------------------------
; driver_irq - IRQ6 (dwait.asm): the controller has finished a command or
; left reset; nothing to read at once
;   In:       nothing
;   Out:      nothing
;   Destroys: nothing
; ----------------------------------------------------------------------------
driver_irq:
        ret

%include "dwait.asm"
%include "dfits.asm"
