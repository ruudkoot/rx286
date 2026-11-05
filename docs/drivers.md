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
