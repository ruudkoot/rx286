# rx286: how long interrupts stay off

A survey of every place where rx286's kernel runs for more than a few
instructions with interrupts off, what each one costs, and what could be
done about it. Written on 2026-11-04 on branch `implementation` (b1e5749),
after the storage and devices work. Nothing here has been changed yet; the
durations are estimates for a real 6 MHz AT with an 8-bit EGA, not
measurements, and on the emulators every stretch is far shorter.

## Status

| | State |
|---|---|
| The survey | done (this document) |
| R0: measure the stretches | not started |
| R1: a limit on the two waits without one | not started |
| R2: scroll and clear the screen in pieces | not started |
| R3: the log sent by interrupt | not started |

## The request

The owner's question, and then the instruction:

> What are all the places where we disable interrupts for more than a few
> instructions?

> note this down in roadmaps/realtime.md

## How rx286 runs with interrupts

The kernel hardly ever executes `cli`. Every gate of its IDT but the double
fault's is an interrupt gate, so the CPU turns interrupts off on the way
into the kernel, and the kernel runs with them off throughout
(`roadmaps/rx286.md` D15, *docs/interrupts.md*). It lets them in at chosen
points only:

- while it waits: `sti; hlt; cli` in `read_key`, `SYS_WAIT` and
  `ksleep_until` (a disk, a sound, a motor);
- after each byte that `SYS_WRITE`, `SYS_PRINT` and `SYS_SERIAL_WRITE` send:
  `sti; nop; cli`;
- between bursts of 64 reads in `kpoll` (a device's status).

An interrupt that comes while they are off waits in the 8259A, which holds
one request per line. So the question is which paths do long work between
those points.

## Where interrupts stay off

### In every build

| Where | When | Off for (estimated) | Notes |
|---|---|---|---|
| `con_scroll` (`src/kernel/console.asm`) | a byte written on the screen's last line, a line feed there | 5-8 ms | 1,920 words moved through the EGA's 8-bit bus: the longest stretch in normal use |
| `con_clear` | a form feed; the start | about 4 ms | 2,000 words written |
| `joy_axes` (`src/kernel/gameport.asm`) | every `SYS_JOYSTICK` | up to 4 ms | by design (`roadmaps/devices.md` D4); the whole 4 ms when an axis has no stick, as on an AT without a game port |
| `kputs` and the lines it prints (`src/kernel/print.asm`) | a program's fault (`fault_program`), "unhandled IRQ n", Ctrl+Break: printed from the handlers | well under 1 ms a line in release builds, plus a scroll | a message is printed whole |
| `rep insw`, `rep outsw` (`src/kernel/fixeddisk.asm`) | every sector of C or D | 0.5-1 ms | 256 words through the controller |
| `rep movsw` (`src/kernel/disk.asm`) | every disk read and write | about 0.3 ms | 512 bytes between the disk buffer and the program |
| `rtc_read` (`src/kernel/rtc.asm`) | `SYS_TIME` | up to about 2 ms | waits for the clock's update to end, 2,000 polls at most |

### In debug and test builds only

Debug and test builds copy everything on the console to the log, COM2 at
115200 baud, polled: 87 us for each character (`com_putc`,
`src/kernel/serial.asm`).

| Where | Off for (estimated) | Notes |
|---|---|---|
| a program's fault: its line and two lines of registers | about 13-15 ms, plus up to three scrolls: 25-35 ms | longer than a tick (20 ms): **a timer tick can be lost**, since the 8259A holds only one |
| any other line of the kernel's | about 5 ms | |
| `SYS_WRITE`, each byte | about 0.1 ms, or 5-8 ms with a scroll | interrupts come in after every byte, so nothing piles up |
| `test_kernel_sum` (`src/kernel/test.asm`), before every restart | about 10 ms | attack and fuzz test builds only |

### Waits without a limit

Normally a matter of microseconds, but nothing ends them:

- `kbc_wait_input` (`src/kernel/keyboard.asm`): until the 8042 can take a
  byte. At start, for Ctrl+Alt+Del, and for typing in test builds.
- `com_putc` and `com_drain` (`src/kernel/serial.asm`): until the log's UART
  can take a byte, or has sent the last. Debug and test builds.

A broken 8042, or a log UART that never empties, would hang the kernel
there, against *docs/security.md*'s "no device can hang the kernel"; every
other wait for a device has a limit in ticks.

### On purpose, or harmless

- A panic, and the double-fault task: interrupts off, the CPU halted, for
  good.
- The start, before interrupts are first let in: the boot code, the
  stacks zeroed, the devices set up, the printers' 50 us reset.

## What it costs

- **The modem's bytes.** A 16450 holds one byte, and at 9600 baud one comes
  every 1.04 ms. Every stretch above that can lose bytes in release builds:
  a scroll, a clear, the game port, a fixed disk's sector. The kernel counts
  them (`modem_overruns`); a 16550's FIFO, which the kernel turns on where
  there is one, holds 16 and so rides out everything above but a scroll.
- **Timer ticks.** Only a fault report in a debug or test build, on a full
  screen, is long enough to lose one. Release builds never are.
- **The promise.** The two waits without a limit are the only places where
  a device could hang the kernel.
- **A document.** `docs/building.md` says debug builds trace "every system
  call"; only `exit` is traced.

## Decisions

### D1: measure first (recommended)

The numbers above are estimates. A test build could time each stretch with
timer channel 0's latched count (`pit_count`, as the game port does) from
the kernel's entry to its first `sti`, and print the longest by place; on
MAME's AT, whose 286 and bus run at the AT's speed, that would replace the
estimates with measurements.

### D2: a limit on every wait (recommended)

`kbc_wait_input`, `com_putc` and `com_drain` poll with a limit, as `kpoll`
does, and give up: a key not typed, a byte of the log lost. Small, and it
makes the promise true.

### D3: the screen in pieces

`con_scroll` and `con_clear` move a few lines at a time with an interrupt
window between. The difficulty: an interrupt handler may print (a fault, an
unhandled IRQ, Ctrl+Break), and must not touch the screen while it is half
moved.

- *A: a console lock* (recommended). While a scroll or clear is under way,
  a handler's message goes to a small buffer, printed when the scroll ends.
- *B: no printing from handlers at all.* Every message queued and printed on
  the way back to ring 3. Simpler to reason about, but a panic must still
  print at once.
- *C: leave it.* 5-8 ms, a few times a second at most while the screen
  scrolls; a 16550 or a slower modem would not notice.

### D4: the log by interrupt

The log's UART interrupts when it can take a byte, and the kernel feeds it
from a ring, so a kernel line costs microseconds instead of 87 us a
character. Debug and test builds only. The log's interrupt would then be on
IRQ3, which in release builds is the modem's: harmless, since the two never
share a build, but the transcript the tests read would depend on the ring
never filling, or on the kernel waiting when it does.

## Milestones

### R0: measure

A test build that records the longest stretch with interrupts off, by
place, and prints it at the end of a test; run on MAME's AT.

Done when: this document's estimates are replaced by measurements, or
shown to be right.

### R1: the waits without a limit

D2, and `docs/building.md`'s claim about tracing corrected.

Done when: a test build that makes the 8042 or the log never ready (a
probe, as `TEST_PROBES` does) ends, and says so, instead of hanging.

### R2: the screen in pieces

D3, whichever way is chosen.

Done when: the longest stretch R0 measures in release builds is under a
millisecond, and `tests/syscalls/calls.test`'s window check still holds.

### R3: the log by interrupt

D4, if wanted.

Done when: a fault report in a debug build no longer loses a tick, by R0's
measure.

## Later

- The game port's 4 ms: time the axes with interrupts on, from the timer's
  count, accepting a little jitter.
- A fixed disk's sector in two halves, with a window between.
