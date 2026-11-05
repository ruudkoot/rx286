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
(*docs/kernel-calls.md*) gives it a space of `DRV_SLOTS` slots and,
besides its code, data and stack:

| Slot | Constant | What |
|---|---|---|
| 3 | `DRV_SLOT_EP` | the endpoint it serves |
| 4 | `DRV_SLOT_NOTIFY` | a notification, bound to its thread: its timer signals `DRV_TIMER_BIT` |
| 5 | `DRV_SLOT_IRQ` | its interrupt line, which the root bound to that notification with `DRV_IRQ_BIT` |
| 6 | `DRV_SLOT_RECV` | empty: where a segment passed to it lands |
| 7 | `DRV_SLOT_DEVICE` | what its service needs besides: the console's, the screen's text page; the keyboard's, the OS server's control notification, which it signals with `CONTROL_BREAK`; the diskettes', a 512-byte DMA buffer that crosses no 64 KB boundary |

It starts the driver's thread with IOPL, and handles its faults. The OS
server gets an endpoint to each driver, in slot `OS_SLOT_SERVICE` +
service; and a copy of the sound driver's notification, badged
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
printer is not busy - looking once a tick, for 2 s at most - put the byte
on the data lines, and pulse STROBE (*docs/storage.md*). The OS server asks
it with `DRV_PRINT` for `SYS_PRINT`, after the kernel's checks of the
printer and the count, in the kernel's order, passing the program's
transfer segment, which the driver deletes once it has printed from it. A
printer that stays busy is `E_PAPER` or `E_TIMEOUT`, with the bytes it took
before.

## The mouse driver

At its start it resets the mouse (DTR and RTS low for `MOUSE_RESET_TICKS`)
and turns COM1's receive interrupt on (*docs/devices.md*). At each
interrupt it takes what COM1 has and acknowledges the line; every few
ticks, on its timer, it looks for bytes whose interrupt was lost. In test
builds, a key script's mouse bytes come from the kernel (`KCALL_TEST`,
`TEST_MOUSE_BYTE`) with IRQ4's bits, as IRQ4 would bring them. The OS
server asks it for `SYS_MOUSE` (`DRV_MOUSE_GET`), and, for a `SYS_WAIT`
with `WAIT_MOUSE`, whether the mouse has news (`DRV_MOUSE_NEWS`), once a
tick, while the kernel waits a tick at a time for the other events.

## The console driver

It writes the text page and moves the cursor (roadmap l4.md L8, D19). The
top line is the status line: a background program's writes go to its
field there (`CON_STATUS`, DI the column past the field's end, which the
OS server gives each background program: `CON_FIELD` columns, right
aligned, spaces before; roadmap l4.md L11); the foreground program's to the 24 lines below
(`CON_MAIN`), with CR, LF, BS, TAB and FF as the kernel's console took
them, scrolling those lines. It starts where the kernel's cursor stopped,
below the banner. The OS server asks it with `DRV_CON_WRITE` for
`SYS_WRITE`, after the kernel's write has checked the buffer and written
the log; the kernel's console writes the screen only until the threads
start, and again for a panic.

## The keyboard driver

It owns the 8042 and IRQ1 (roadmap l4.md L8): the modifiers, a ring of
keys, Ctrl+Break, Ctrl+Alt+Del and Sys Req, as the kernel did. The OS
server takes a key with `DRV_KBD_GET`, looks with `DRV_KBD_PEEK`, and drops
the keys waiting with `DRV_KBD_CLEAR` when it starts the foreground program
again; it asks once a tick while a program waits for a key. Ctrl+Break is
never a call (l4.md X13): the driver signals the OS server's control
notification, whose control thread restarts the foreground program.
Ctrl+Alt+Del: the driver says so on the log and resets the machine through
the 8042. Sys Req asks the kernel for the thread dump (`TEST_DUMP`). In
test builds it tells the kernel when it has started (`TEST_KEYS_READY`),
and on MAME takes the script's keys from it (`TEST_KEY_BYTE`).

## The disk drivers

They took the kernel's disk code as it was (roadmap l4.md L9), and wait as
above (*docs/storage.md*). The OS server asks them with `DRV_DISK_READ` and
`DRV_DISK_WRITE`: BX the unit (0 or 1 on the driver's controller), CX the
sector, SI its offset in the segment passed, which is the program's
transfer segment for `SYS_DISK_READ` and `SYS_DISK_WRITE`, or the
program's files segment for the file calls. The reply's BX is 0 or the
error. The server has checked the drive and the sector, as the kernel did;
the driver checks them again. The diskette driver moves the sector through
its DMA buffer, and stops the motor two seconds after its last transfer on
its timer; the fixed disk driver moves the words straight to or from the
segment passed.

## The serial driver

COM2, for a modem (*docs/devices.md*), with the kernel's modem code as it
was (roadmap l4.md L10). In release builds, and test builds made with
`MODEM_COM2`, it sets COM2 to 9600 baud, 8N1, and takes each byte that comes
into a ring of 256, at IRQ3 and on a one-tick timer for an interrupt that
was lost. The OS server asks it with `DRV_SERIAL_WRITE` (CX bytes from SI in
the segment passed, each once the UART takes it, 2 s at most: `E_TIMEOUT`
with the count so far), `DRV_SERIAL_READ` (up to CX bytes of the ring into
the segment passed; it never waits) and `DRV_SERIAL_NEWS` (BX 1 if bytes
wait), for SYS_WAIT once a tick. In debug and test builds COM2 is the
kernel's log: the driver never touches it, and answers `E_BUSY`.

## The sound driver

The speaker and the game port, with the kernel's code for both as it was
(*docs/devices.md*). `DRV_SOUND` (BX hertz, 0 a rest; CX ticks) checks
them as `SYS_SOUND` always did (`E_INVAL`), sets timer channel 2 and opens
the gate, sleeps on its timer for the ticks, and closes the gate before it
answers; a stop the OS server signals (`DRV_STOP_BIT`, on Ctrl+Break) ends
the sound at once, and a stop left over from before a sound is dropped
when it starts. In `TEST_SOUND` builds it asks the kernel to measure the
tone and the silence after it (`KCALL_TEST`). `DRV_JOYSTICK` times the
game port's four axes with timer channel 0's latched count, interrupts off
for 4 ms at most, and puts the buttons and the axes in the block of the
transfer segment passed: five results, more than a reply's four words.

## The RTC driver

`DRV_CLOCK_TIME`: the RTC's date and time in BCD, read by polling
(`src/lib/cmos.asm`), in the reply's four words: BX hours and minutes, CX
century and year, SI month and day, DI seconds. The kernel sets the clock
to 24-hour BCD with its interrupts off at its start; the driver is its one
reader.

