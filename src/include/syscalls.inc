; ============================================================================
; rx286 - src/include/syscalls.inc
; The system calls: the program's view of the system (roadmap D9; l4.md
; D16), the OS server's services.
;
; The function in AH, through the sys macro (program.inc), which calls the
; stub to the OS server; INT 30h, their gate until l4.md L10, is gone.
; Results come back in registers; an error sets CF and puts its code in AX.
; A call preserves every register it does not return. docs/syscalls.md is
; the reference.
; ============================================================================

%ifndef RX286_SYSCALLS_INC
%define RX286_SYSCALLS_INC

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
; The files, in DOS's way: the OS server's (roadmap l4.md L9, D16)
SYS_FIND            equ 14  ; AL drive, DS:SI a path, ending at a zero or a space (from
                            ;    the drive's current directory, or its root after a
                            ;    separator) -> ES:DI what it names (FIND_SIZE bytes);
                            ;    a directory's entries then come from SYS_DIR_NEXT, a
                            ;    file's sectors from SYS_FILE_NEXT
SYS_CHDIR           equ 15  ; AL drive, DS:SI a path: the drive's current directory
SYS_DRIVE           equ 16  ; AL a drive to make current (DRIVES or more: none)
                            ;    -> AX the current drive
SYS_GETCWD          equ 17  ; AL drive -> ES:DI its current directory (PATH_MAX + 1 bytes)
SYS_DIR_NEXT        equ 18  ; -> AX 1 and ES:DI the next entry (FIND_ENTRY_SIZE bytes) of
                            ;    the directory found last; AX 0 at its end
SYS_FILE_NEXT       equ 19  ; -> ES:DI the next sector of the file found last (SECTOR_SIZE
                            ;    bytes of room), CX its bytes; CX 0 at the end
SYS_FREE            equ 20  ; AL drive -> DX:AX the bytes free on its volume
; The programs, as the root keeps them (roadmap l4.md L11, D19)
SYS_PS              equ 21  ; AL a module's number -> ES:DI what runs it (PS_SIZE bytes);
                            ;    E_INVAL past the last module
SYS_KILL            equ 22  ; AL a module: a background program killed, all made for it
                            ;    revoked and its memory free (E_INVAL, E_BUSY: killed)
SYS_START           equ 23  ; AL a module: a killed background program built again, from
                            ;    its module (E_INVAL, E_BUSY: running, E_IO: no room)
SYSCALL_COUNT       equ 24

PATH_MAX            equ 64  ; DOS's longest path, the drive's letter not counted
FIND_PATH           equ 0   ; SYS_FIND's record: the path found, from the root
FIND_DIR            equ FIND_PATH + PATH_MAX + 1    ; 1 if a directory (the root too)
FIND_ENTRY          equ FIND_DIR + 1                ; its directory entry, unless the root
FIND_ENTRY_SIZE     equ 32                          ;    (FAT's: DIR_* of fat12.asm)
FIND_LABEL          equ FIND_ENTRY + FIND_ENTRY_SIZE    ; the volume's label, space padded
FIND_LABEL_SIZE     equ 11
FIND_SIZE           equ FIND_LABEL + FIND_LABEL_SIZE

PS_NAME             equ 0   ; SYS_PS's record: the module's name, zero-padded
PS_NAME_SIZE        equ 8
PS_KIND             equ 8   ; PS_*, below
PS_STATE            equ 9   ; its main thread's state (kcalls.inc's STATE_*)
PS_PRIORITY         equ 10
PS_RUNS             equ 11  ; word: the times it was switched to (they wrap)
PS_SIZE             equ 13
PS_ROOT             equ 0   ; the kinds: the root
PS_OS               equ 1   ;    the OS server (its control thread)
PS_DRIVER           equ 2
PS_FOREGROUND       equ 3   ;    the program the keys are for
PS_BACKGROUND       equ 4   ;    a background program: SYS_KILL and SYS_START's

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
E_NOT_FAT12         equ 16  ; no FAT12 volume: no partition, or no such BPB
E_NOT_FOUND         equ 17  ; no such file or directory
E_NOT_DIR           equ 18  ; a path goes on through a file; a directory wanted
E_BAD_NAME          equ 19  ; a name DOS does not allow, or a path too long
E_BROKEN            equ 20  ; a cluster outside the volume, or a chain that loops

; Scancodes (set 1) the program may look for in AH when AL = 0.
SC_ESC              equ 0x01
SC_UP               equ 0x48
SC_DOWN             equ 0x50
SC_LEFT             equ 0x4B
SC_RIGHT            equ 0x4D

%endif
