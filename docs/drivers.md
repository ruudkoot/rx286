# The drivers outside the kernel

Devices leave the kernel one at a time (roadmap l4.md L7-L10, D10, D11).
A driver is a module of the boot image in ring 1, with IOPL 1: it may
touch any port, and is trusted with the machine; it may not load a
descriptor it was not given, nor run the CPU's privileged instructions
(`tests/rings`). `src/include/drivers.inc` holds the interface.

| Driver | Source | Device | Service |
|---|---|---|---|
| the printer driver | `src/drivers/printer.asm` | LPT1 and LPT2, polled | `SERVICE_PRINTER` |
| the mouse driver | `src/drivers/mouse.asm` | a serial mouse on COM1, IRQ4 | `SERVICE_MOUSE` |
| the console driver | `src/drivers/console.asm` | the EGA's text page and cursor | `SERVICE_CONSOLE` |
| the keyboard driver ("kbd") | `src/drivers/keyboard.asm` | the 8042, IRQ1 | `SERVICE_KEYBOARD` |
| the diskette driver ("fd") | `src/drivers/diskette.asm` | the NEC 765, IRQ6, DMA channel 2: drives A and B | `SERVICE_DISKETTE` |
| the fixed disk driver ("hd") | `src/drivers/fixeddisk.asm` | the AT's fixed disk controller, IRQ14: drives C and D | `SERVICE_FIXED_DISK` |
| the serial driver | `src/drivers/serial.asm` | COM2, the modem's line, IRQ3 | `SERVICE_SERIAL` |
| the sound driver | `src/drivers/sound.asm` | the speaker (timer channel 2, port B) and the game port | `SERVICE_SOUND` |
| the RTC driver ("rtc") | `src/drivers/rtc.asm` | the MC146818 real-time clock | `SERVICE_CLOCK` |

Every device has left the kernel (roadmap l4.md L10): it keeps the timer's
channel 0, the interrupt controllers, the 287, NMI and, in debug and test
builds, its log (D15).

## How the root builds one

A driver's module table entry has `MF_DRIVER`, and perhaps an interrupt
line (`M_IRQ`) and a service (`M_SERVICE`; *docs/memory-map.md*). The root
(*docs/kernel-calls.md*) gives it a space of `DRV_SLOTS` (16) slots and,
besides its code, data and stack:

| Slot | Constant | What |
|---|---|---|
| 3 | `DRV_SLOT_EP` | the endpoint it serves |
| 4 | `DRV_SLOT_NOTIFY` | a notification, bound to its thread: its timer signals `DRV_TIMER_BIT` |
| 5 | `DRV_SLOT_IRQ` | its interrupt line, which the root bound to that notification with `DRV_IRQ_BIT` |
| 6 | `DRV_SLOT_RECV` | empty: where a segment passed to it lands |
| 7 | `DRV_SLOT_DEVICE` | what its service needs besides: the console's, the screen's text page; the keyboard's, the OS server's control notification, which it signals with `CONTROL_BREAK` (the server's own timers for the processes ring there as `CONTROL_TIMER`); the diskettes', a DMA buffer of `FD_DMA_SECTORS` sectors, 15 KB, a 1.2 MB cylinder (`FD_DMA_SMALL_SECTORS`, 4, without extended memory), that crosses no 64 KB boundary (roadmap disk-scheduler.md M2) |
| 8 | `DRV_SLOT_KEYS` | the keyboard's: the notification of the OS server's thread for the foreground program, badged `KEY_SIGNAL_BIT`, which it signals after every byte it takes, so that a wait for a key sleeps until the keyboard does something (roadmap os-server.md P5) |
| 9 | `DRV_SLOT_BOOT_INFO` | the disk drivers': the boot information, read-only, for the drives the BIOS knows (*docs/memory-map.md*; roadmap disk-scheduler.md M2) |

It starts the driver's thread with IOPL, and handles its faults. The OS
server gets an endpoint to each driver, in slot `OS_SLOT_SERVICE` +
service, but the disk drivers', which the disk server gets
(*docs/disk-server.md*); and a copy of the sound driver's notification, badged
`DRV_STOP_BIT`, in its slot 13, to end a sound with on Ctrl+Break.

A driver's data segment is of DPL 2, so that the root can fill it from the
module; ring 3 cannot load it, and the driver can. Its stack is of DPL 1.

## Interrupts

The kernel masks a bound line at each interrupt, sends EOI and signals the
notification; a receive on the driver's endpoint then returns with
`NOTIFY_LABEL` and the bits (*docs/kernel-calls.md*). The driver serves its
device and acknowledges with `IRQ_ACK`, which unmasks the line; an
interrupt that came meanwhile waits in the 8259A (*docs/interrupts.md*).

## Waiting

A driver waits on the kernel's timer instead of the kernel's polling with
a limit in ticks: `KCALL_TIMER` on its notification, then a receive on it.
A notification has one timer: setting it again replaces it. The disk
drivers share their waits (`src/drivers/dwait.asm`), which take the place of
the kernel's `ksleep_until`, `ksleep` and `kpoll`: for the interrupt, for
some ticks, or for a port's bits, each with a limit in ticks. Each sets a
one-tick timer and receives on the notification, so it looks at the time
(`KCALL_TICKS`) once a tick, and takes and acknowledges the interrupt when
its bit comes.

## The printer driver

It drives a printer as IBM's BIOS does: for each byte, wait until the
printer is not busy - a burst of reads, then once a tick, for 2 s at most -
put the byte on the data lines, and pulse STROBE (*docs/storage.md*). A
port that reads all ones has no adapter: `E_TIMEOUT` at once (roadmap
os-server.md P15). The OS server asks
it with `DRV_PRINT` (BX the printer, below `PRINTERS`) for a process's write
to `/dev/lpt1` or `/dev/lpt2`, passing the process's data segment, which the
driver deletes once it has printed from it. A printer that stays busy is
`E_PAPER` or `E_TIMEOUT`, with the bytes it took before, which the OS
server answers as a write of so many (P15).

## The mouse driver

At its start it resets the mouse (DTR and RTS low for `MOUSE_RESET_TICKS`)
and turns COM1's receive interrupt on (*docs/devices.md*). At each
interrupt it takes what COM1 has and acknowledges the line; every few
ticks, on its timer, it looks for bytes whose interrupt was lost. In test
builds, a key script's mouse bytes come from the kernel (`KCALL_TEST`,
`TEST_MOUSE_BYTE`) with IRQ4's bits, as IRQ4 would bring them. The OS
server asks it for the state (`DRV_MOUSE_GET`: the buttons, `MOUSE_LEFT`
and `MOUSE_RIGHT`; x and y, to `MOUSE_X_MAX` and `MOUSE_Y_MAX`;
`MOUSE_PRESENT` if the mouse answered its reset) and whether the mouse has
news (`DRV_MOUSE_NEWS`: a packet that moved it or changed a button), for a
process's read of `/dev/mouse` and its `poll`, once a tick while it waits.
A Plug and Play identity is passed over only before the first packet, and
`MOUSE_PNP_MAX` bytes at most: a '(' later is a packet's byte whose first
was lost (P15).

## The console driver

It writes the text pages and moves the cursor (roadmap l4.md L8, D19;
os-server.md P11). Its segment is the 32 KB at B8000h: mode 3 has a page
every `VIDEO_PAGE` bytes (4 KB), `VIDEO_PAGES` (8) of them, or four on an
EGA of 64 KB. At its start the driver writes a mark past each page's text,
the last page's first, and reads them back to count the pages; it blanks
those past the first. The top line of every page is the status line: a
background program's writes go to its field there, on every page
(`CON_STATUS`, DI the column past the field's end, which the OS server
gives each background program: `CON_FIELD` columns, right aligned, spaces
before; roadmap l4.md L11). The 24 lines below are a page's main area
(`CON_MAIN`, BH the page): the foreground program's, or a terminal's. CR,
LF, BS, TAB and FF are control characters, as the kernel's console took
them; ESC [ begins one of ANSI's sequences it knows (ECMA-48 5.4: up to
four parameters, the final byte 40h-7Eh): the cursor's moves (`A`, `B`,
`C`, `D`, and `H` or `f` to a row and column of the main area), erasing
(`J` and `K`: 0 from the cursor, 1 to it, 2 all) and attributes (`m`, each
parameter: 0, 1 bright, 7 reversed, the colours swapped, 30-37 and 40-47
the colours, 39 and 49 their defaults). A sequence with a private or
intermediate byte (`ESC [ ? 25 l`) is dropped whole, as is one it does not
know; ESC in a sequence begins another, and CR, LF, BS, TAB and FF in one
are carried out (P15). Every other byte is shown as its glyph, and a full
page scrolls its 24 lines.
Each page keeps its cursor, attribute and escape. `DRV_CON_SHOW` (BL a
page) shows a page: the CRTC's start address (`CRTC_START_HIGH`,
`CRTC_START_LOW`) and the hardware cursor at its cursor; it answers with
the pages there are (BH `CON_QUIET`: a `TEST_SCREEN` build does not log
the page, as for the server's first call, which asks how many). Page 0 starts where the kernel's cursor stopped,
below the banner. The OS server asks it with `DRV_CON_WRITE` for the
terminals' output and the writes of the programs the root builds, after
the kernel's log has the first terminal's; the kernel's console writes the
screen only until the threads start, and again for a panic, which shows
page 0 whatever page the driver showed. In `TEST_SCREEN` builds the
driver says how many pages there are, and puts the page `DRV_CON_SHOW`
shows on the log, its lines as text and its attributes as `<XX>`, for the
tests to read.

## The keyboard driver

It owns the 8042 and IRQ1 (roadmap l4.md L8): the modifiers, a ring of
keys, Ctrl+Break, Ctrl+Alt+Del and Sys Req, as the kernel did. The OS
server takes a key with `DRV_KBD_GET`, looks with `DRV_KBD_PEEK`, and drops
the keys waiting with `DRV_KBD_CLEAR` when it starts the foreground program
again; `DRV_KBD_PEEK` says too how many keys a full ring dropped since it
was asked last. A key without ASCII has 0 there and its scancode (`SC_ESC`,
`SC_UP`, `SC_DOWN`, `SC_LEFT`, `SC_RIGHT` among them, which the terminal
makes ANSI's sequences): the keypad's and an enhanced keyboard's grey keys
after E0h alike, and the keypad's Enter and '/' are the keys they are. The
right Ctrl and Alt are each a bit of their own, so that letting one go
keeps the other's chord; Caps Lock turns over once a press, not with each
repeat (roadmap os-server.md P15). Alt+F1 to F8 come as the BIOS gives them,
scancodes 68h to 6Fh without ASCII, which the OS server's terminal takes
for its pages
(os-server.md P11). While the foreground program waits for a key, the server's thread
sleeps until the driver signals it (`DRV_SLOT_KEYS`), which the driver does
after every byte the keyboard sends (roadmap os-server.md P5). Ctrl+Break is
never a call (l4.md X13): the driver signals the OS server's control
notification, whose control thread restarts the foreground program.
Ctrl+Alt+Del: the driver says so on the log and resets the machine through
the 8042. Sys Req asks the kernel for the thread dump (`TEST_DUMP`). In
test builds it tells the kernel when it has started (`TEST_KEYS_READY`),
and on MAME takes the script's keys from it (`TEST_KEY_BYTE`).

## The disk drivers

They took the kernel's disk code (roadmap l4.md L9), and since roadmap
disk-scheduler.md M2 move runs of sectors by cylinder, head and sector
(*docs/storage.md*). Since M3 the disk server alone calls them: the root
gives it their endpoints, not the OS server. A unit is 0 or 1 on the driver's controller: drives
`DRIVE_A` and `DRIVE_B`, or `DRIVE_C` and `DRIVE_D`, of `DRIVES`. Every
reply's BX is 0 or the error.

| Call | Asks | Answers |
|---|---|---|
| `DRV_DISK_READ` | BL the unit, BH the head, CX the cylinder, DI's low byte the sector (from 1) and its high byte the count (0 for 1), SI the offset in the segment passed | CX the sectors moved |
| `DRV_DISK_WRITE` | the same, the sectors from the segment | the same |
| `DRV_DISK_SEEK` | BL the unit, CX the cylinder | a fixed disk's heads go on moving after the reply |
| `DRV_DISK_STATUS` | BL the unit | CX the cylinder the driver believes the heads on (`DISK_CYLINDER_UNKNOWN`), SI `DRV_STATUS_CHANGED` (A's change line) and `DRV_STATUS_SEEKING` (a fixed disk's seek not complete) |
| `DRV_DISK_RESET` | | the controller reset, every unit's cylinder forgotten |
| `DRV_DISK_GEOMETRY` | BL the unit | CX the cylinders, SI's low byte the heads and its high byte the sectors a track (`E_INVAL`: no such unit) |
| `DRV_DISK_READ_ID` | BL the unit, BH the head (diskettes) | CX the cylinder, SI's low byte the head and its high byte the sector of the first ID the 765 found |

A fixed disk's run goes on across heads and cylinders, `DRV_DISK_RUN_MAX`
(64) sectors at most; a diskette's ends with its cylinder, and moves as
many sectors as its DMA buffer holds (`FD_DMA_SECTORS`, 30, or 4 without
extended memory), CX saying how many. The disk server turns a drive's
sector numbers into these (*docs/disk-server.md*), asking each drive's
geometry at its start (`DRV_DISK_GEOMETRY`). The driver checks every number
again. The fixed
disk driver takes its drives' geometry from the boot information
(`DRV_SLOT_BOOT_INFO`), or `disks.inc`'s where the BIOS gave none. The
diskette driver moves a run through its DMA buffer, and stops the motor two
seconds after its last transfer on its timer; the fixed disk driver moves
the words straight to or from the segment passed. Each tries a run once,
then resets its controller or forgets the diskette's cylinder before its
next: the disk server, their only caller, tries again (*docs/disk-server.md*;
roadmap disk-scheduler.md M3, D14).

## The serial driver

COM2, for a modem (*docs/devices.md*), with the kernel's modem code as it
was (roadmap l4.md L10). In release builds, and test builds made with
`MODEM_COM2`, it sets COM2 to 9600 baud, 8N1, and takes each byte that comes
into a ring of 256, at IRQ3 and on a one-tick timer for an interrupt that
was lost. The OS server asks it with `DRV_SERIAL_WRITE` (CX bytes from SI in
the segment passed, each once the UART takes it, 2 s at most: `E_TIMEOUT`
with the count so far; at once if no UART answers),
`DRV_SERIAL_READ` (up to CX bytes of the ring into the segment passed; it
never waits) and `DRV_SERIAL_NEWS` (BX 1 if bytes wait; CX the bytes lost
since it was asked last), for a process's reads, writes and `poll` of
`/dev/com2`, at most `SERIAL_MAX` bytes a call (more: `E_INVAL`, P15). In debug and test builds COM2 is the kernel's
log: the driver never touches it, and answers `E_BUSY` (`DRV_SERIAL_NEWS`:
BX 0, no news).

## The sound driver

The speaker and the game port, with the kernel's code for both as it was
(*docs/devices.md*). `DRV_SOUND` (BX hertz, 0 a rest; CX ticks) checks
them (`SOUND_MIN_HZ` to `SOUND_MAX_HZ`, `SOUND_MAX_TICKS` at most; else
`E_INVAL`), sets timer channel 2 and opens
the gate, sleeps on its timer for the ticks, and closes the gate before it
answers; a stop the OS server signals (`DRV_STOP_BIT`, on Ctrl+Break) ends
the sound at once, and a stop left over from before a sound is dropped
when it receives the call, before it sets anything: the driver runs above
the server, so no stop for this sound comes before it looks (P15). In
`TEST_SOUND` builds it asks the kernel to measure the tone and the silence
after it (`KCALL_TEST`). `DRV_JOYSTICK` reads the buttons, then times the
game port's four axes with timer channel 0's latched count, interrupts off
for `JOY_AXIS_MAX_US` (4 ms) at most, and writes the buttons and the axes,
in microseconds or `JOY_ABSENT`, as five words at SI of the segment passed,
more than a reply's four words: a process's read of `/dev/joystick`
(os-server.md P12); BX 0, or `E_FAULT` if the segment cannot take them
(P15).

## The RTC driver

`DRV_CLOCK_TIME`: the RTC's date and time in BCD, read by polling
(`src/lib/cmos.asm`), in the reply's four words: BX hours and minutes, CX
century and year, SI month and day, DI seconds. DI's high byte is
`DRV_CLOCK_INVALID` when the clock has no time to give: its battery failed
(register D), or a field is no BCD, as a clock that is not there reads FFh
(roadmap os-server.md P15); the OS server then takes the time as unknown.
The kernel sets the clock to 24-hour BCD with its interrupts off at its
start; the driver is its one reader.

## Errors

A driver's reply says how a call went in BX: 0, or one of these
(`drivers.inc`), which the volumes' code and the root's services use too. A
call a driver does not know is `E_INVAL`, from every driver (P15). Each
checks the bytes a call moves against the segment's limit (`dw_fits`),
before it uses them and again after each wait: `E_FAULT`, never a fault of
the driver's own.
The OS server makes them POSIX's for a process: `E_PROTECTED` is `EROFS`,
the rest mostly `EIO` (*docs/processes.md*). Until roadmap os-server.md P14
they were the old system calls' errors too.

| Code | Constant | Meaning |
|---|---|---|
| 1 | `E_FAULT` | a segment passed that the driver may not use so, or that went while it waited |
| 3 | `E_INVAL` | an argument out of range |
| 4 | `E_IO` | the device reported an error, on every try |
| 5 | `E_TIMEOUT` | the device did not answer in time: no diskette, no fixed disk, a printer that stays busy |
| 6 | `E_PROTECTED` | the diskette is write-protected |
| 7 | `E_PAPER` | the printer is out of paper, or not there |
| 8 | `E_BUSY` | the device is the kernel's: COM2 carries the log |
| 16 | `E_NOT_FAT12` | no FAT12 volume: no partition, or no such BPB |
| 17 | `E_NOT_FOUND` | no such file, or no such code (`ROOT_FIND`) |
| 20 | `E_BROKEN` | a cluster outside the volume, or a chain that loops |
| 21 | `E_NOMEM` | no memory, or no room in a table (the root's services) |
