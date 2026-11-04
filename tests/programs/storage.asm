; ============================================================================
; rx286 - tests/programs/storage.asm
; The disk and printer calls, with good and bad arguments (tests/storage).
;
; Each check prints one line; the tests hold the lines it must print, the
; sectors it must have written (checked on the host's images afterwards)
; and what the printers must have printed. A test's define: chooses the
; checks: none, the disks'; STORAGE_PRINTERS, the printers' (MAME's AT
; then has its printer card where the fixed disks' was); STORAGE_MEDIA,
; those of a changed drive (a diskette out of B or write-protected, no fixed
; disk D: the test's media:). The program then waits for a key, which ends
; the test.
; ============================================================================

cpu 286
bits 16
%include "build.inc"
%include "program.inc"

BPB_LABEL           equ 0x2B            ; the volume label in a FAT12 boot sector
BPB_LABEL_LENGTH    equ 11
SIGNATURE           equ 0x1FE           ; 55h AAh ends a boot sector and a master boot record
PARTITION_TYPE      equ 0x1BE + 4       ; the first partition's type and first sector
PARTITION_START     equ 0x1BE + 8
MOTOR_TICKS         equ 50              ; the kernel waits more than 1 s for a motor
UNKNOWN_DRIVE       equ DRIVES

begin_udata
sector              times SECTOR_SIZE db 0
pattern             times SECTOR_SIZE db 0
printed_line        db "printed on LPT1", CHAR_LF
printed_line_end:
drive_letter        db 0
before              dw 0
wrote_text          db "rx286 wrote this to "
wrote_text_end:
sector_text         db ": sector "
sector_text_end:
end_udata

; check drive, sector, routine - read a sector into `sector`, then run the
; routine, or report the error
%macro check 3
        mov al, %1
        mov cx, %2
        call read_sector
        jc %%failed
        call %3
        jmp %%done
%%failed:
        call report_error
%%done:
%endmacro

; ----------------------------------------------------------------------------
; entry - the checks, then wait for a key
;   In:       the kernel's start (program.inc)
;   Out:      does not return
;   Destroys: everything
; ----------------------------------------------------------------------------
entry:
        cld
%ifdef STORAGE_MEDIA
        call check_media
%elifdef STORAGE_PRINTERS
        call check_printers
%else
        call check_reads
        call check_writes
        call check_refusals
%endif
.wait:
        mov al, KEY_WAIT
        sys SYS_READ_KEY
        jmp .wait

; ----------------------------------------------------------------------------
; check_media - what a changed drive gives: B read and written, D read
;   In:       DS = ES = the program's data
;   Out:      nothing
;   Destroys: everything
; ----------------------------------------------------------------------------
check_media:
        PRINT "B: sector 0: "
        check DRIVE_B, 0, show_label
        mov al, DRIVE_B
        mov cx, 700
        call write_pattern
        PRINT "D: sector 0: "
        check DRIVE_D, 0, show_partition
        ret

; ----------------------------------------------------------------------------
; check_reads - each drive's first sector, its partition's, and its last;
; and the ticks that went by while B's motor came up
;   In:       DS = ES = the program's data
;   Out:      nothing
;   Destroys: everything
; ----------------------------------------------------------------------------
check_reads:
        PRINT "A: sector 0: "
        check DRIVE_A, 0, show_label
        sys SYS_TICKS
        mov [before], ax
        PRINT "B: sector 0: "
        check DRIVE_B, 0, show_label
        sys SYS_TICKS
        sub ax, [before]
        PRINT "B: the motor's start: "
        cmp ax, MOTOR_TICKS
        jb .quick
        PRINT "the ticks went on", CHAR_LF
        jmp .fixed
.quick:
        PRINT "TOO QUICK", CHAR_LF
.fixed:
        PRINT "C: sector 0: "
        check DRIVE_C, 0, show_partition
        PRINT "C: sector 17: "
        check DRIVE_C, 17, show_label
        PRINT "D: sector 0: "
        check DRIVE_D, 0, show_partition
        PRINT "D: sector 17: "
        check DRIVE_D, 17, show_label
        PRINT "A: the last sector: "
        check DRIVE_A, 80 * 2 * 15 - 1, report_read
        PRINT "B: the last sector: "
        check DRIVE_B, 40 * 2 * 9 - 1, report_read
        PRINT "C: the last sector: "
        check DRIVE_C, 615 * 4 * 17 - 1, report_read
        PRINT "D: the last sector: "
        check DRIVE_D, 306 * 4 * 17 - 1, report_read
        ret

; ----------------------------------------------------------------------------
; check_writes - a marked sector on each drive, read back; the test checks
; the images on the host too
;   In:       DS = ES = the program's data
;   Out:      nothing
;   Destroys: everything
; ----------------------------------------------------------------------------
check_writes:
        mov al, DRIVE_A
        mov cx, 2000
        call write_pattern
        mov al, DRIVE_B
        mov cx, 700
        call write_pattern
        mov al, DRIVE_C
        mov cx, 615 * 4 * 17 - 1
        call write_pattern
        mov al, DRIVE_D
        mov cx, 20000
        call write_pattern
        ret

; ----------------------------------------------------------------------------
; check_refusals - arguments the kernel must refuse before touching a disk,
; and the registers a disk call keeps
;   In:       DS = ES = the program's data
;   Out:      nothing
;   Destroys: everything
; ----------------------------------------------------------------------------
check_refusals:
        PRINT "read: drive 4: "
        mov al, UNKNOWN_DRIVE
        xor cx, cx
        call read_sector
        call report_error
        PRINT "read: A's sector 2400: "
        mov al, DRIVE_A
        mov cx, 80 * 2 * 15
        call read_sector
        call report_error
        PRINT "read: into CS: "
        push es
        push cs
        pop es
        xor di, di
        mov al, DRIVE_A
        xor cx, cx
        sys SYS_DISK_READ
        pop es
        call report_error
        PRINT "read: across the data's limit: "
        mov di, UDATA_ROOM - SECTOR_SIZE / 2
        mov al, DRIVE_A
        xor cx, cx
        sys SYS_DISK_READ
        call report_error
        PRINT "read: through a null ES: "
        push es
        xor ax, ax
        mov es, ax
        xor di, di
        mov al, DRIVE_A
        xor cx, cx
        sys SYS_DISK_READ
        pop es
        call report_error
        PRINT "write: from a null DS: "
        push ds
        xor ax, ax
        mov ds, ax
        xor si, si
        mov al, DRIVE_B
        mov cx, 700
        sys SYS_DISK_WRITE
        pop ds
        call report_error
        PRINT "write: C's sector 41820: "
        mov si, pattern
        mov al, DRIVE_C
        mov cx, 615 * 4 * 17
        sys SYS_DISK_WRITE
        call report_error
        ; A read returns nothing: every register is kept.
        mov bx, 0x1111
        mov dx, 0x3333
        mov si, 0x4444
        mov bp, 0x6666
        mov di, sector
        mov cx, 1
        mov al, DRIVE_A
        sys SYS_DISK_READ
        PRINT "read: registers "
        cmp ax, (SYS_DISK_READ << 8) | DRIVE_A
        jne .changed
        cmp bx, 0x1111
        jne .changed
        cmp cx, 1
        jne .changed
        cmp dx, 0x3333
        jne .changed
        cmp si, 0x4444
        jne .changed
        cmp di, sector
        jne .changed
        cmp bp, 0x6666
        jne .changed
        PRINT "kept", CHAR_LF
        ret
.changed:
        PRINT "CHANGED", CHAR_LF
        ret

; ----------------------------------------------------------------------------
; check_printers - a line to each printer, and what the kernel refuses
;   In:       DS = ES = the program's data
;   Out:      nothing
;   Destroys: everything
; ----------------------------------------------------------------------------
check_printers:
        PRINT "print: LPT1 took "
        mov al, PRINTER_LPT1
        mov si, printed_line
        mov cx, printed_line_end - printed_line
        sys SYS_PRINT
        call report_count
        mov byte [printed_line_end - 2], '2'
        PRINT "print: LPT2 took "
        mov al, PRINTER_LPT2
        mov si, printed_line
        mov cx, printed_line_end - printed_line
        sys SYS_PRINT
        call report_count
        PRINT "print: nothing: "
        mov al, PRINTER_LPT1
        xor cx, cx
        sys SYS_PRINT
        call report_count
        PRINT "print: printer 2: "
        mov al, PRINTERS
        mov cx, 1
        sys SYS_PRINT
        call report_error
        PRINT "print: too much: "
        mov al, PRINTER_LPT1
        mov si, printed_line
        mov cx, PRINT_MAX + 1
        sys SYS_PRINT
        call report_error
        PRINT "print: across the data's limit: "
        mov al, PRINTER_LPT1
        mov si, UDATA_ROOM - 2
        mov cx, 4
        sys SYS_PRINT
        call report_error
        ret

; ----------------------------------------------------------------------------
; report_read - "read" (a check's routine, for a sector whose bytes are
; not looked at)
;   In:       nothing
;   Out:      nothing
;   Destroys: nothing
; ----------------------------------------------------------------------------
report_read:
        PRINT "read", CHAR_LF
        ret

; ----------------------------------------------------------------------------
; report_count - the bytes a call returned, or its error
;   In:       CF and AX as SYS_PRINT returned them
;   Out:      nothing
;   Destroys: nothing
; ----------------------------------------------------------------------------
report_count:
        jc report_error
        call print_dec
        PRINT " bytes", CHAR_LF
        ret

; ----------------------------------------------------------------------------
; read_sector - SYS_DISK_READ into `sector`
;   In:       AL = the drive; CX = the sector; DS = ES = the program's data
;   Out:      CF and AX as the call returns them
;   Destroys: DI
; ----------------------------------------------------------------------------
read_sector:
        mov di, sector
        sys SYS_DISK_READ
        ret

; ----------------------------------------------------------------------------
; write_pattern - "X: sector N: " and the outcome of writing "rx286 wrote
; this to X: sector N" (zeros after) there, then reading it back
;   In:       AL = the drive; CX = the sector; DS = ES = the program's data
;   Out:      nothing
;   Destroys: everything
; ----------------------------------------------------------------------------
write_pattern:
        push ax
        push cx
        add al, 'A'
        mov [drive_letter], al
        mov di, pattern
        mov cx, SECTOR_SIZE
        push di
        xor al, al
        rep stosb
        pop di
        mov si, wrote_text
        mov cx, wrote_text_end - wrote_text
        rep movsb
        mov al, [drive_letter]
        stosb
        mov si, sector_text
        mov cx, sector_text_end - sector_text
        rep movsb
        pop ax                          ; the sector
        push ax
        call fmt_dec16
        mov al, [drive_letter]
        call print_char
        PRINT ": sector "
        pop ax
        push ax
        call print_dec
        PRINT ": "
        pop cx
        pop ax
        push ax
        push cx
        mov si, pattern
        sys SYS_DISK_WRITE
        jc .write_failed
        pop cx
        pop ax
        mov di, sector
        push cx
        push ax
        mov cx, SECTOR_SIZE
        xor al, al
        rep stosb
        pop ax
        pop cx
        call read_sector
        jc .failed
        mov si, sector
        mov di, pattern
        mov cx, SECTOR_SIZE
        repe cmpsb
        jne .differs
        PRINT "written and read back", CHAR_LF
        ret
.differs:
        PRINT "READ BACK DIFFERS", CHAR_LF
        ret
.write_failed:
        add sp, 4                       ; the drive and sector pushed
        stc                             ; (ADD cleared CF)
.failed:
        jmp report_error

; ----------------------------------------------------------------------------
; show_label - a FAT12 boot sector's volume label and signature, from `sector`
;   In:       DS = ES = the program's data
;   Out:      nothing
;   Destroys: AX, CX, SI
; ----------------------------------------------------------------------------
show_label:
        PRINT "label '"
        mov si, sector + BPB_LABEL
        mov cx, BPB_LABEL_LENGTH
        sys SYS_WRITE
        PRINT "', signature "
        mov ax, [sector + SIGNATURE]
        call print_hex16
        jmp print_newline

; ----------------------------------------------------------------------------
; show_partition - a master boot record's first partition, from `sector`
;   In:       DS = ES = the program's data
;   Out:      nothing
;   Destroys: AX
; ----------------------------------------------------------------------------
show_partition:
        PRINT "partition type "
        mov al, [sector + PARTITION_TYPE]
        call print_hex8
        PRINT " from sector "
        mov ax, [sector + PARTITION_START]
        call print_dec
        PRINT ", signature "
        mov ax, [sector + SIGNATURE]
        call print_hex16
        jmp print_newline

; ----------------------------------------------------------------------------
; report_error - "error N" if CF, else "no error"
;   In:       CF and AX as a system call returned them
;   Out:      nothing
;   Destroys: nothing
; ----------------------------------------------------------------------------
report_error:
        jnc .none
        PRINT "error "
        call print_dec
        call print_newline
        ret
.none:
        PRINT "no error", CHAR_LF
        ret

%include "uprint.asm"
%include "format.asm"
