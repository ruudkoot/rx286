# rx286: speaker, game port, serial mouse and modem

The third roadmap of rx286, after `roadmaps/rx286.md` and
`roadmaps/storage.md`. The kernel gets drivers for the AT's speaker, its game
port, a serial mouse and a modem's serial line; the shell gets `beep`,
`play`, `joy`, `mouse` and `term`. Written on 2026-11-04 on branch
`implementation`, as the work was done.

## Status

| | State |
|---|---|
| The serial ports: the mouse on COM1, COM2 the log or the modem | done |
| The drivers and their calls; SYS_WAIT | done |
| The shell's commands, the tests | done |
| The documents | done |

## The request

The owner's words, after a table of what rx286 drove and what it did not:

> Add speaker, game port and serial port drivers. Can we have a serial mouse
> on com1 (also a kernel driver for now) and then com2 is either debug or a
> modem

and, while the work went on:

> I guess for consistency we can always put debug on com3. Is there no
> clash with the mouse?

> And then always have a modem on com2

> Can we get all emulators consistent if the log on com2 and modem on com4?

## Decisions

The owner's last word decided the ports; the rest were taken as
recommended, with their reasons.

### D1: the mouse on COM1, a kernel driver

A Microsoft serial mouse: 1200 baud, 7N1, three-byte packets, IRQ4. At
start the kernel holds DTR and RTS low for 100 ms, which resets the mouse,
then raises them; the mouse answers "M", which `SYS_MOUSE` reports. The
kernel keeps a position as DOS's mouse driver does in text mode (0-639,
0-199, eight to a character cell) and the buttons. It draws no cursor: the
console is the program's to write.

### D2: COM2 the log or the modem; COM3 and COM4 unused

The ports went round once while the work went on: the log moved from COM1
to COM2, with COM2 the modem in release builds; then the log was to go to
COM3 and COM2 always be the modem; then the log on COM2 and the modem on
COM4, so that every emulator ran the same image. An independent review
then showed IRQ sharing to be fragile (Bochs drops COM4's pending interrupt
when COM2, on the same line, is touched), and the owner settled it:

- COM1, IRQ4: the mouse, in every build.
- COM2, IRQ3: the log in debug and test builds; the modem's line in
  release builds (`SYS_SERIAL_*` fail with `E_BUSY` where COM2 is the log).
- COM3, COM4: not used; kept quiet, interrupts off and OUT2 clear.

No two ports in use share an interrupt. A test of the modem needs the log
elsewhere, so a test build made with `MODEM_COM2` makes COM2 the modem and
puts the log on COM3: test plumbing only, on Bochs and DOSBox-X, since
MAME's AT has two serial ports. `make run-release` runs the image with the
modem.

The modem's line: 9600 baud, 8N1, DTR and RTS up, a 16550's FIFO where
there is one; received bytes through IRQ3 into a ring of 256 bytes, and
fetched on every tick too, in case an interrupt is lost; sending polled, as
the printer is. `SYS_SERIAL_READ` never waits; `SYS_WAIT` does. A 16450
loses bytes while interrupts stay off for more than a byte's time (1.04 ms
at 9600 baud): the game port's timing, a scroll of the screen on a real AT;
the kernel counts them.

### D3: the speaker, synchronous

`SYS_SOUND` plays a frequency for a number of ticks and returns, like a
disk's sector: timer channel 2 as a square wave, gated to the speaker
through port B, whose other bits are written back as read. A frequency of
0 is a rest. Ctrl+Break ends a sound at once.

- *Rejected: a sound that plays on while the program runs.* A queue of
  notes and the timer stopping them would be more, and nothing asks for it.

### D4: the game port, timed with the timer

`SYS_JOYSTICK` returns the four buttons and the four axes in microseconds.
The kernel starts the one-shots and times each axis with timer channel 0's
latched count (in mode 3 the count falls two a clock, so half the
difference is the clocks), interrupts off for 4 ms at most. An axis that
does not rise, or has not fallen by then, is `JOY_ABSENT`.

- *Rejected: counting loops,* which measure the processor's speed, not the
  joystick's.

### D5: SYS_WAIT

`mouse` and `term` wait for a key or their device, so `SYS_WAIT` sleeps
until any of the events asked for is there (a key, the mouse's news, bytes
from the modem), or a number of ticks pass, or the program is to restart.
With no event it is a sleep. A test build types into it as into
`read_key`; only a wait without a limit ends a test.

### D6: the shell's commands

`beep`, `play` (a tune), `joy` (one reading), `mouse` (the position and
buttons whenever they change, until Esc or both buttons) and `term` (a
terminal on COM4: what comes is shown, what is typed sent, Esc ends).

## How it is tested

| What | How | Where |
|---|---|---|
| A tone's frequency | the kernel's probe (`TEST_SOUND`) counts channel 2's output changes at port B over a tick | all three emulators |
| The game port | no joystick: every axis absent; DOSBox-X's emulated stick: two axes present | all three |
| The mouse's reset | its "M" through the UART and IRQ4 | all three |
| The mouse's packets | the key script's `{mouse DX DY B}`, handed to the driver as IRQ4 would | all three |
| The modem | a Hayes-like peer in the runner on a local port (`modem: hayes`), Bochs on real time; its answer while the kernel writes 1,920 bytes; the buffers it refuses | Bochs, DOSBox-X |
| COM2 as the log | `term` and the calls refuse (`E_BUSY`) | all three |
| A Plug and Play mouse's identity | passed over, not read as packets | all three |
| Bad buffers | the modem test's refusals, the fuzzer's random calls | Bochs, DOSBox-X, MAME |

## Later

- A mouse cursor on the console; a mouse driver in ring 3.
- Sound while the program runs; the speaker's own interrupt-free tunes.
- The modem's speed and line settings as a call; RTS/CTS flow control.
- COM3 and COM4 for the program, beyond the modem.
- A review's points not taken up: a mouse cursor; COM2 overruns at 9600
  baud with a 16450 while interrupts are off.
