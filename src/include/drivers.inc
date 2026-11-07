; ============================================================================
; rx286 - src/include/drivers.inc
; The drivers outside the kernel (roadmap l4.md L7-L10, D10, D11): their
; slots, and what they are asked.
;
; A driver is a module of ring 1 with IOPL 1 (MF_DRIVER), which the root
; builds with an endpoint it serves, a notification bound to its thread for
; its interrupt and its timer, and the capability of its interrupt line if
; it has one (M_IRQ). The OS server holds an endpoint to each, in the slot
; its service names. A driver's faults go to the root. docs/drivers.md is
; the reference.
; ============================================================================

%ifndef RX286_DRIVERS_INC
%define RX286_DRIVERS_INC

DRV_SLOT_EP         equ 3       ; a driver's slots: the endpoint it serves
DRV_SLOT_NOTIFY     equ 4       ;    its notification, bound to its thread
DRV_SLOT_IRQ        equ 5       ;    its interrupt line, if it has one
DRV_SLOT_RECV       equ 6       ;    where a segment passed to it lands
DRV_SLOT_DEVICE     equ 7       ;    the console's: the screen's text page; the keyboard's:
                                ;    the OS server's control notification, to signal; the
                                ;    diskette's: its DMA buffer (512 bytes within 64 KB)
DRV_SLOT_KEYS       equ 8       ;    the keyboard's: the notification of the OS server's
                                ;    thread for the foreground program, badged
                                ;    KEY_SIGNAL_BIT, signalled whenever the keyboard sent
                                ;    something (os-server.md P5)
DRV_SLOTS           equ 16      ; a driver's space
DRV_TIMER_BIT       equ 1       ; the notification's bits: its timer (its own capability)
DRV_IRQ_BIT         equ 2       ;    its interrupt (the root binds a copy badged so)
DRV_STOP_BIT        equ 4       ;    the sound driver's: Ctrl+Break, from the OS server
KEY_SIGNAL_BIT      equ 2       ; the keyboard, on that notification of the OS server's
                                ;    (its timer's bit is 1)

SERVICE_PRINTER     equ 1       ; M_SERVICE: what a driver serves; the OS server
SERVICE_MOUSE       equ 2       ;    holds its endpoint in slot OS_SLOT_SERVICE + service
SERVICE_CONSOLE     equ 3
SERVICE_KEYBOARD    equ 4
SERVICE_DISKETTE    equ 5
SERVICE_FIXED_DISK  equ 6
SERVICE_SERIAL      equ 7
SERVICE_SOUND       equ 8
SERVICE_CLOCK       equ 9
OS_SLOT_SERVICE     equ 3
CONTROL_BREAK       equ 1       ; the control notification's bits: Ctrl+Break
CONTROL_TIMER       equ 2       ;    the processes' timers (OS_SLOT_TIMER; os-server.md P10)

; The printer driver: one call
DRV_PRINT           equ 1       ; BX the printer, CX bytes, SI their offset in the segment
                                ;    passed -> BX 0 or E_PAPER, E_TIMEOUT; CX bytes printed
; The mouse driver
DRV_MOUSE_GET       equ 1       ; -> BX buttons, CX x, SI y, DI MOUSE_PRESENT or 0;
                                ;    its news taken
DRV_MOUSE_NEWS      equ 2       ; -> BX 1 if the mouse moved or a button changed since
; The console driver
DRV_CON_WRITE       equ 1       ; BL CON_*, BH a page (CON_MAIN), CX bytes, SI their offset
                                ;    in the segment passed -> CX the bytes written
DRV_CON_SHOW        equ 2       ; BL a page: shown (os-server.md P11), BH CON_QUIET or 0 ->
                                ;    BX the pages the EGA holds (VIDEO_PAGES or 4), CX the
                                ;    page shown
CON_QUIET           equ 1       ; DRV_CON_SHOW's BH: TEST_SCREEN builds, the page not logged
CON_MAIN            equ 0       ;    a page's main area, below the status line: the
                                ;    foreground program's, a terminal's
CON_STATUS          equ 1       ;    a background program's field of the status line, DI
                                ;    the column past its end (l4.md L11)
CON_FIELD           equ 20      ; a field's columns
; The keyboard driver
DRV_KBD_GET         equ 1       ; -> BX 1 and CX the key (CL ASCII, CH scancode), or BX 0
DRV_KBD_PEEK        equ 2       ; -> BX 1 if a key waits, not taken
DRV_KBD_CLEAR       equ 3       ;    the keys waiting, dropped (a program started again)
; The disk drivers: the diskettes (A, B) and the fixed disks (C, D)
DRV_DISK_READ       equ 1       ; BX the drive (0 or 1 of the driver's), CX the sector, SI
                                ;    the offset in the segment passed -> BX 0 or the error
DRV_DISK_WRITE      equ 2       ;    the same, the sector from the segment
; The serial driver: COM2, the modem's line (l4.md L10)
DRV_SERIAL_WRITE    equ 1       ; CX bytes, SI their offset in the segment passed -> BX 0
                                ;    or E_TIMEOUT, E_BUSY (COM2 the log); CX bytes sent
DRV_SERIAL_READ     equ 2       ; CX room, SI where in the segment passed -> BX 0 or
                                ;    E_BUSY; CX the bytes the line brought, perhaps 0
DRV_SERIAL_NEWS     equ 3       ; -> BX 1 if bytes wait
; The sound driver: the speaker and the game port
DRV_SOUND           equ 1       ; BX hertz (0: a rest), CX ticks -> BX 0 or E_INVAL, once
                                ;    the sound is over or stopped (DRV_STOP_BIT)
DRV_JOYSTICK        equ 2       ;    the segment passed, a transfer segment: its block's AX
                                ;    the buttons, BX CX DX SI the axes (as SYS_JOYSTICK);
                                ;    with SI not 0, five words at SI there (os-server.md P12)
; The RTC driver
DRV_CLOCK_TIME      equ 1       ; -> BX hours and minutes, CX century and year, SI month
                                ;    and day, DI seconds: BCD, as SYS_TIME's BX, CX, DX, AL

%endif
