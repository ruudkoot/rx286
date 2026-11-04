# rx286: speaker, game port, serial mouse and modem

The third roadmap of rx286, after `roadmaps/rx286.md` and
`roadmaps/storage.md`. The kernel gets drivers for the AT's speaker, its game
port, a serial mouse and a modem's serial line; the shell gets `beep`,
`play`, `joy`, `mouse` and `term`. Written on 2026-11-04 on branch
`implementation`, as the work was done.

## Status

| | State |
|---|---|
| The serial ports: the log on COM2, the mouse on COM1, the modem on COM4 | done |
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

### D2: the log on COM2, the modem on COM4

At first the log moved from COM1 to COM2, and COM2 was to be the modem in
release builds; then the log was to go to COM3 always, and COM2 always the
modem; but MAME's AT has two serial ports and no free slot, so its tests
could not read a log on COM3. The owner's last proposal makes every
emulator alike: the log on COM2 in every debug and test build (no image is
built differently for MAME), the modem on COM4 in every build.

- COM4 shares IRQ3 with COM2, and COM1 IRQ4 with COM3; the log keeps its
  UART's interrupt off (OUT2 clear), so it never drives IRQ3. On IBM's
  cards an UART with OUT2 clear leaves the line alone.
- MAME's AT has no COM4: its modem calls reach no UART, which reads as one
  always ready that never receives. It runs no modem test.
- On a real AT of 1984, COM3 and COM4 are a later convention: the modem
  would need a card that offers COM4.

The modem's line: 9600 baud, 8N1, DTR and RTS up; received bytes through
IRQ3 into a ring of 256 bytes; sending polled, as the printer is.
`SYS_SERIAL_READ` never waits; `SYS_WAIT` does.

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
| The modem | a Hayes-like peer in the runner on a local port (`modem: hayes`), Bochs on real time | Bochs, DOSBox-X |
| Bad buffers | four more attacks, the fuzzer's random calls | Bochs, MAME |

## Later

- A mouse cursor on the console; a mouse driver in ring 3.
- Sound while the program runs; the speaker's own interrupt-free tunes.
- The modem's speed and line settings as a call; RTS/CTS flow control.
- COM3, and serial ports for the program beyond the modem.
