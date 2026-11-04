; ============================================================================
; rx286 - src/include/syscalls.inc
; The system calls: the program's only view of the kernel (roadmap D9).
;
; INT 30h with the function in AH. Results come back in registers; an error
; sets CF and puts its code in AX. A call preserves every register it does
; not return. docs/syscalls.md is the reference.
; ============================================================================

%ifndef RX286_SYSCALLS_INC
%define RX286_SYSCALLS_INC

SYSCALL_VECTOR      equ 0x30

SYS_EXIT            equ 0   ; no arguments; does not return: the program starts again
SYS_WRITE           equ 1   ; DS:SI buffer, CX length -> AX bytes written
SYS_READ_KEY        equ 2   ; AL = KEY_WAIT or KEY_POLL -> AL ASCII, AH scancode
SYS_TICKS           equ 3   ; -> DX:AX ticks since start (SYS_TICKS_HZ a second)
SYS_TIME            equ 4   ; -> BCD: CH century, CL year, DH month, DL day,
                            ;    BH hours, BL minutes, AL seconds (roadmap D20)
SYS_DISK_READ       equ 5   ; AL drive, CX sector, ES:DI SECTOR_SIZE bytes to fill
SYS_DISK_WRITE      equ 6   ; AL drive, CX sector, DS:SI SECTOR_SIZE bytes to write
SYS_PRINT           equ 7   ; AL printer, DS:SI buffer, CX length -> AX bytes printed
SYSCALL_COUNT       equ 8

SYS_TICKS_HZ        equ 50
WRITE_MAX           equ 4096
KEY_WAIT            equ 0
KEY_POLL            equ 1

PRINT_MAX           equ 4096

; The drives (roadmap storage D1): a sector is 512 bytes (SECTOR_SIZE),
; numbered from 0 across the whole disk, partitions and all.
DRIVE_A             equ 0   ; 1.2 MB diskette, the boot disk
DRIVE_B             equ 1   ; 360 KB diskette
DRIVE_C             equ 2   ; fixed disk 0
DRIVE_D             equ 3   ; fixed disk 1
DRIVES              equ 4
PRINTER_LPT1        equ 0
PRINTER_LPT2        equ 1
PRINTERS            equ 2

E_FAULT             equ 1   ; a buffer the program may not use so
E_NOSYS             equ 2   ; no such call
E_INVAL             equ 3   ; an argument out of range
E_IO                equ 4   ; the device reported an error
E_TIMEOUT           equ 5   ; the device did not answer: no diskette, no printer
E_PROTECTED         equ 6   ; the diskette is write-protected
E_PAPER             equ 7   ; the printer is out of paper (or not there)

; Scancodes (set 1) the program may look for in AH when AL = 0.
SC_ESC              equ 0x01
SC_UP               equ 0x48
SC_DOWN             equ 0x50
SC_LEFT             equ 0x4B
SC_RIGHT            equ 0x4D

; sys function   - load AH and trap into the kernel
%macro sys 1
    mov ah, (%1)
    int SYSCALL_VECTOR
%endmacro

%endif
