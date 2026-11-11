# rx286

A minimal microkernel and operating system for the IBM PC/AT (80286 and
80287, EGA), written in assembly and C. It boots from a FAT12 floppy, runs
its kernel in 286 protected mode without ever calling the BIOS, and runs
its programs in ring 3 as POSIX-like processes, where nothing they do can
crash the system: a shell on each of eight terminals, its commands, and
two daemons on the status line. Drivers outside the kernel drive the AT's
diskettes, fixed disks and printers, its speaker, game port, a serial
mouse and a modem's line; the drives' FAT12 volumes are in `/mnt`, by their labels.

```
make doctor     # are the tools here?
make            # release and debug images in build/
make run        # boot the debug image in Bochs
make debugger   # the same, stopped at the kernel's entry in Bochs' debugger
make check      # every test and check, on Bochs, DOSBox-X's 286 and MAME's IBM AT
```

In the shell, `help` lists the commands. `ls`, `cd`, `cat` and `lp` (or
DOS's `dir`, `type` and `print`) work on the drives' volumes, `/mnt/rx286` to
`/mnt/rx286d` (`b:` changes to B's), whose sample files `make disks` puts there (`disks/`); `make
run` puts the commands in C's `/BIN`; what `lp` prints goes to
`build/debug/lpt1.txt`. `beep`, `play`, `joy`, `mouse` and `term` try the
speaker, the game port, the mouse on COM1 (capture it in Bochs' window
with Ctrl+F10) and the modem's line on COM2, which is the log in debug
builds (`make run-release` runs the release image). `crash KIND` tries
what no process may: the kernel stops it, and the shell goes on. Alt+F1 to
F8 show the terminals.

- `roadmaps/rx286.md`: the plan, its decisions, and its milestones;
  `roadmaps/storage.md`: the disks, the printers and the DOS-like shell;
  `roadmaps/devices.md`: the speaker, game port, mouse and modem;
  `roadmaps/l4.md`: the kernel made a microkernel; `roadmaps/os-server.md`:
  the POSIX-like OS server in C, its processes and the shell in C;
  `roadmaps/realtime.md`: how long interrupts stay off; `roadmaps/memory.md`:
  all of the memory, extended memory for the processes too.
- `docs/`: how it works (start with `docs/README.md`).

Licence: CC0 1.0 (`LICENSE`).
