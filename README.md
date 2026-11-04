# rx286

A minimal microkernel and operating system for the IBM PC/AT (80286 and
80287, EGA), written in assembly. It boots from a FAT12 floppy, runs its
kernel in 286 protected mode without ever calling the BIOS, and runs one
program, a small shell, in ring 3, where nothing it does can crash the
system.

```
make doctor     # are the tools here?
make            # release and debug images in build/
make run        # boot the debug image in Bochs
make debugger   # the same, stopped at the kernel's entry in Bochs' debugger
make check      # every test and check, on Bochs, DOSBox-X's 286 and MAME's IBM AT
```

In the shell, `help` lists the commands; `crash KIND` tries what no program
may, and the kernel reports it and starts the shell again.

- `roadmaps/rx286.md`: the plan, its decisions, and its milestones.
- `docs/`: how it works (start with `docs/README.md`).

Licence: CC0 1.0 (`LICENSE`).
