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

## How the root builds one

A driver's module table entry has `MF_DRIVER`, and perhaps an interrupt
line (`M_IRQ`) and a service (`M_SERVICE`; *docs/memory-map.md*). The root
(*docs/kernel-calls.md*) gives it, besides its code, data and stack:

| Slot | Constant | What |
|---|---|---|
| 3 | `DRV_SLOT_EP` | the endpoint it serves |
| 4 | `DRV_SLOT_NOTIFY` | a notification, bound to its thread: its timer signals `DRV_TIMER_BIT` |
| 5 | `DRV_SLOT_IRQ` | its interrupt line, which the root bound to that notification with `DRV_IRQ_BIT` |
| 6 | `DRV_SLOT_RECV` | empty: where a segment passed to it lands |
| 7 | `DRV_SLOT_DEVICE` | what its service needs besides: the console's, the screen's text page; the keyboard's, the OS server's control notification, which it signals with `CONTROL_BREAK` |

It starts the driver's thread with IOPL, and handles its faults. The OS
server gets an endpoint to each driver, in slot `OS_SLOT_SERVICE` +
service.

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
right end (`CON_STATUS`); the foreground program's to the 24 lines below
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
