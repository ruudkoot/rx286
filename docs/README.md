# rx286's documents

| Document | What |
|---|---|
| [architecture.md](architecture.md) | the parts of rx286 and how they fit |
| [boot.md](boot.md) | from power-on to the shell |
| [memory-map.md](memory-map.md) | every address, and the kernel's image |
| [hardware.md](hardware.md) | the machine: ports, IRQs, DMA |
| [protected-mode.md](protected-mode.md) | the GDT, the TSSs, the way into protected mode |
| [interrupts.md](interrupts.md) | every vector and IRQ line, and what handles it |
| [syscalls.md](syscalls.md) | the system calls, and the OS server that serves them |
| [kernel-calls.md](kernel-calls.md) | the kernel's calls: capabilities, IPC, interrupt lines; the root's start |
| [drivers.md](drivers.md) | the drivers outside the kernel: the printer's, the mouse's |
| [storage.md](storage.md) | the drives, their drivers, the printers, the sample disks |
| [devices.md](devices.md) | the speaker, the game port, the serial mouse, the modem, SYS_WAIT |
| [shell.md](shell.md) | the shell: its commands, drives and paths, its FAT12 library |
| [security.md](security.md) | what no program can do, and how the tests show it |
| [building.md](building.md) | the tools, the Makefile, the builds |
| [testing.md](testing.md) | the layers of tests |
| [debugging.md](debugging.md) | Bochs' debugger, symbols, logs, recipes |
| [emulators.md](emulators.md) | Bochs, DOSBox-X and MAME, and how they differ from the AT |
| [style.md](style.md) | how the sources are written |

The plans behind all of it are `roadmaps/rx286.md`, `roadmaps/storage.md`,
`roadmaps/devices.md` and `roadmaps/l4.md`.
