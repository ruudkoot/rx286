# The speaker, game port, mouse and modem

The devices of `roadmaps/devices.md`, as the kernel drives them and the
program reaches them (*docs/syscalls.md*).

## The serial ports

| Port | Base | IRQ | What |
|---|---|---|---|
| COM1 | 3F8h | 4 | a Microsoft serial mouse, in every build (`mouse.asm`) |
| COM2 | 2F8h | 3 | the log of debug and test builds, polled, its interrupt off (`serial.asm`); the modem's line in release builds (`modem.asm`) |
| COM3 | 3E8h | 4 | not used; kept quiet (`serial_quiet`) |
| COM4 | 2E8h | 3 | not used; kept quiet |

No two serial ports in use share an interrupt. A test of the modem needs
the log somewhere else, so a test build made with `MODEM_COM2` makes COM2
the modem and moves the log to COM3: test plumbing, on Bochs and DOSBox-X
(MAME's AT has only COM1 and COM2). `make run-release` runs the release
image, whose COM2 is the modem's line.

## The mouse

At start the kernel sets COM1 to 1200 baud, 7N1, and holds DTR and RTS
low; 200 ms later at least (`mouse_tick`) it raises them, with OUT2 and the
receive interrupt. A Microsoft mouse resets on that and says "M". Each
movement or button change is then a packet of three bytes, the first with
bit 6 set:

```
1 L R Y7 Y6 X7 X6     0 X5 X4 X3 X2 X1 X0     0 Y5 Y4 Y3 Y2 Y1 Y0
```

The kernel adds the movement to a position it keeps, from 0 to `MOUSE_X_MAX`
(639) and 0 to `MOUSE_Y_MAX` (199), eight to a character cell, starting in
the middle; and keeps the buttons. `SYS_MOUSE` gives them, and whether the
mouse said "M" (`MOUSE_PRESENT`). A Logitech mouse's fourth byte is passed
over, and so is a Plug and Play mouse's identity, which follows its "M"
between parentheses. Nothing is drawn: the console is the program's.

## The modem

In release builds, COM2 at 9600 baud, 8N1, DTR, RTS and OUT2 up, a 16550's
FIFO on where there is one. A byte that comes raises IRQ3; the kernel keeps
it in a ring of 256 bytes, dropping (and counting) what a full ring cannot
take. `SYS_SERIAL_READ` takes what is there, without waiting; `SYS_WAIT`
waits for it. `SYS_SERIAL_WRITE` sends as the printer prints: each byte
once the UART can take it, 2 s at most, interrupts let in after each. In
debug and test builds both calls fail with `E_BUSY`: COM2 is the log.

A 16450 holds one byte, and at 9600 baud one comes every 1.04 ms. The
kernel's longest stretches with interrupts off, the game port's timing (4
ms) and a scroll of the screen (a few ms on a real AT), can lose bytes
there; the kernel counts them (`modem_overruns`). Every tick the kernel also
fetches what COM1 and COM2 hold, so an interrupt that was lost costs a tick
at most: an emulator can lose one, as Bochs does when another UART on the
same line is touched.

## The speaker

`SYS_SOUND` programs timer channel 2 as a square wave of the frequency asked
(`SOUND_MIN_HZ` to `SOUND_MAX_HZ`), opens its gate and the speaker's bit in
port B, sleeps for the ticks asked (`SOUND_MAX_TICKS` at most) with
interrupts on, and closes them. A frequency of 0 is a rest. Ctrl+Break ends
a sound. Port B's other bits are written back as they were read. A test
build with `TEST_SOUND` measures every tone by counting channel 2's output
changes at port B over a tick, checks the gate and speaker bits, and checks
that the speaker is silent after every sound and rest.

## The game port

`SYS_JOYSTICK` reads the four buttons, then writes the port, which starts
the four axes' one-shots, and times each with timer channel 0's latched
count (`pit_elapsed`: in mode 3 the count falls two a clock, so half the
difference of two counts is the clocks between them). Interrupts stay off
for at most `JOY_AXIS_MAX_US` (4 ms). An axis is given in microseconds, or
`JOY_ABSENT` if its bit never rose or had not fallen by then: no joystick.

## Waiting for several things

`SYS_WAIT` sleeps (`sti; hlt; cli`) until one of the events asked for is
there: `WAIT_KEY` (a key in the ring), `WAIT_MOUSE` (a packet since the last
`SYS_MOUSE`), `WAIT_SERIAL` (bytes from the modem, in a build that has
it); or until the ticks asked have passed; or until the program is to
restart. It returns the events that
are there, 0 if none. With no event and a limit, it is a sleep.
