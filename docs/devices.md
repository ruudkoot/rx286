# The speaker, game port, mouse and modem

The devices of `roadmaps/devices.md`, as their drivers drive them, in
ring 1 since roadmap l4.md L7-L10 (*docs/drivers.md*), and as a process
reaches them through `/dev` (roadmap os-server.md P12; *docs/processes.md*,
*The devices*).

## The serial ports

| Port | Base | IRQ | What |
|---|---|---|---|
| COM1 | 3F8h | 4 | a Microsoft serial mouse, in every build (the mouse driver, `src/drivers/mouse.asm`) |
| COM2 | 2F8h | 3 | the log of debug and test builds, polled, its interrupt off (the kernel's `serial.asm`); the modem's line in release builds (the serial driver, `src/drivers/serial.asm`) |
| COM3 | 3E8h | 4 | not used; kept quiet (`serial_quiet`) |
| COM4 | 2E8h | 3 | not used; kept quiet |

No two serial ports in use share an interrupt. A test of the modem needs
the log somewhere else, so a test build made with `MODEM_COM2` makes COM2
the modem and moves the log to COM3: test plumbing, on Bochs and DOSBox-X
(MAME's AT has only COM1 and COM2). `make run-release` runs the release
image, whose COM2 is the modem's line.

## The mouse

The mouse driver, in ring 1 since roadmap l4.md L7 (*docs/drivers.md*),
sets COM1 to 1200 baud, 7N1, at its start and holds DTR and RTS low; 200
ms later at least, on the kernel's timer, it raises them, with OUT2 and the
receive interrupt. A Microsoft mouse resets on that and says "M". Each
movement or button change is then a packet of three bytes, the first with
bit 6 set:

```
1 L R Y7 Y6 X7 X6     0 X5 X4 X3 X2 X1 X0     0 Y5 Y4 Y3 Y2 Y1 Y0
```

The driver adds the movement to a position it keeps, from 0 to `MOUSE_X_MAX`
(639) and 0 to `MOUSE_Y_MAX` (199), eight to a character cell, starting in
the middle; and keeps the buttons. A read of `/dev/mouse` waits for a
packet and gives them, `ioctl`'s `RXIO_MOUSE` at once; without a mouse
that said "M" (`MOUSE_PRESENT`) its open is `ENXIO`. A Logitech mouse's fourth byte is passed
over, and so is a Plug and Play mouse's identity, which follows its "M"
between parentheses. Nothing is drawn: the console is the program's.

## The modem

In release builds, COM2 at 9600 baud, 8N1, DTR, RTS and OUT2 up, a 16550's
FIFO on where there is one. A byte that comes raises IRQ3; the serial
driver keeps it in a ring of 256 bytes, dropping (and counting) what a full
ring cannot take. A read of `/dev/com2` waits for bytes and takes what is
there; `poll` waits for them too. A write sends as the printer prints:
each byte once the UART can take it, 2 s at most. In debug and test builds
`/dev/com2`'s open fails with `EBUSY`: COM2 is the log.

A 16450 holds one byte, and at 9600 baud one comes every 1.04 ms. The
longest stretches with interrupts off, the game port's timing (4 ms) and
the kernel's work for a kernel call (3.5 ms at most on MAME's AT, 6.5 ms
for a pass of a kill: roadmap realtime.md R0), can lose bytes there; the
driver counts them, with those a full ring drops, and `DRV_SERIAL_NEWS`
answers how many since it was asked last (roadmap os-server.md P15). A
16550's FIFO rides them all out. A port that reads all ones has no UART:
a write fails at once. Every tick the serial driver also fetches what COM2
holds, and every 5 ticks the mouse driver what COM1 holds, so an interrupt
that was lost costs a tick at most, or 5: an emulator can lose
one, as Bochs does when another UART on the same line is touched.

## The speaker

`/dev/speaker`'s `ioctl` (`RXIO_TONE`): the sound driver programs timer
channel 2 as a square wave of
the frequency asked (`SOUND_MIN_HZ` to `SOUND_MAX_HZ`), opens its gate and
the speaker's bit in port B, sleeps on its timer for the ticks asked
(`SOUND_MAX_TICKS` at most), and closes them. A frequency of 0 is a rest.
Ctrl+Break ends a sound: the OS server signals the driver. Port B's other
bits are written back as they were read. A test build with `TEST_SOUND`
measures every tone by counting channel 2's output changes at port B over
a tick (the kernel's probe, which the driver asks for), checks the gate and
speaker bits, and checks that the speaker is silent after every sound and
rest.

## The game port

A read of `/dev/joystick`: the sound driver reads the four buttons, then
writes the
port, which starts the four axes' one-shots, and times each with timer
channel 0's latched count (`pit_elapsed`: in mode 3 the count falls two a
clock, so half the difference of two counts is the clocks between them).
Interrupts stay off for at most `JOY_AXIS_MAX_US` (4 ms): the one stretch a
driver turns them off for. An axis is given in microseconds, or
`JOY_ABSENT` if its bit never rose or had not fallen by then: no joystick.

## Waiting for several things

A process waits for several devices at once with `poll` (roadmap
os-server.md P12; *docs/processes.md*): its terminal, whose line discipline
wakes it, and the mouse and the modem's line, whose drivers do not signal
their news, so the OS server asks them again each tick. Until P14 a
program's `SYS_WAIT` did the same for keys, the mouse and the modem.
