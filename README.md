# rx286

A minimal microkernel and operating system for the IBM PC/AT (80286 and
80287, EGA), written in assembly. It boots from a FAT12 floppy, runs its
kernel in 286 protected mode without ever calling the BIOS, and runs one
program, a small shell, in ring 3, where nothing it does can crash the
system. The kernel drives the AT's diskettes, fixed disks and printers, a
sector or a buffer at a time, and its speaker, game port, a serial mouse
and a modem's line; the shell looks like DOS's, on a FAT12 library of its
own.

```
make doctor     # are the tools here?
make            # release and debug images in build/
make run        # boot the debug image in Bochs
make debugger   # the same, stopped at the kernel's entry in Bochs' debugger
make check      # every test and check, on Bochs, DOSBox-X's 286 and MAME's IBM AT
```

In the shell, `help` lists the commands. `dir`, `cd`, `type` and `print`
work on drives A to D (`b:` changes drive), whose sample files `make disks`
puts there (`disks/`); what `print` prints goes to `build/debug/lpt1.txt`.
`beep`, `play`, `joy`, `mouse` and `term` try the speaker, the game port,
the mouse on COM1 (capture it in Bochs' window with Ctrl+F10) and the
modem's line on COM2, which is the log in debug builds (`make run-release`
runs the release image). `crash KIND` tries what no program may, and the
kernel reports it and starts the shell again.

- `roadmaps/rx286.md`: the plan, its decisions, and its milestones;
  `roadmaps/storage.md`: the disks, the printers and the DOS-like shell;
  `roadmaps/devices.md`: the speaker, game port, mouse and modem.
- `docs/`: how it works (start with `docs/README.md`).

Licence: CC0 1.0 (`LICENSE`).
