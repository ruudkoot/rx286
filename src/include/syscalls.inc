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
SYS_SOUND           equ 8   ; BX hertz (0: silence), CX ticks: sounds, then returns
SYS_JOYSTICK        equ 9   ; -> AL buttons; BX, CX, DX, SI the axes in microseconds
SYS_MOUSE           equ 10  ; -> AX MOUSE_PRESENT or 0, BX buttons, CX x, DX y
SYS_SERIAL_WRITE    equ 11  ; DS:SI buffer, CX length -> AX bytes sent on COM2
SYS_SERIAL_READ     equ 12  ; ES:DI buffer, CX room -> AX bytes from COM2 (perhaps 0)
SYS_WAIT            equ 13  ; AL WAIT_* events, CX ticks at most (0: no limit)
                            ;    -> AL the events that are there (0: the time ran out)
SYSCALL_COUNT       equ 14

SYS_TICKS_HZ        equ 50
WRITE_MAX           equ 4096
KEY_WAIT            equ 0
KEY_POLL            equ 1

PRINT_MAX           equ 4096
SERIAL_MAX          equ 4096
SOUND_MIN_HZ        equ 19  ; the 8254's slowest square wave
SOUND_MAX_HZ        equ 20000
SOUND_MAX_TICKS     equ 500 ; ten seconds
JOY_ABSENT          equ 0xFFFF  ; an axis that did not answer
JOY_AXIS_MAX_US     equ 4000    ; how long an axis is timed at most
MOUSE_PRESENT       equ 1   ; the mouse said who it is
MOUSE_LEFT          equ 1   ; buttons
MOUSE_RIGHT         equ 2
MOUSE_X_MAX         equ 639 ; the position, as DOS's mouse driver keeps it in
MOUSE_Y_MAX         equ 199 ; text mode: eight to a character cell
WAIT_KEY            equ 1   ; SYS_WAIT's events
WAIT_MOUSE          equ 2   ; the mouse moved or a button changed
WAIT_SERIAL         equ 4   ; bytes from COM2

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
E_BUSY              equ 8   ; the device is the kernel's: COM2 carries the log

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
