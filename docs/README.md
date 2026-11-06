# rx286's documents

| Document | What |
|---|---|
| [architecture.md](architecture.md) | the parts of rx286 and how they fit |
| [boot.md](boot.md) | from power-on to the shell |
| [memory-map.md](memory-map.md) | every address, and the kernel's image |
| [hardware.md](hardware.md) | the machine: ports, IRQs, DMA |
| [protected-mode.md](protected-mode.md) | the GDT, the TSSs, the way into protected mode |
| [interrupts.md](interrupts.md) | every vector and IRQ line, and what handles it |
| [syscalls.md](syscalls.md) | the system calls, as a program makes them |
| [kernel-calls.md](kernel-calls.md) | the kernel's calls: capabilities, IPC, interrupt lines, delete and revoke, the log |
| [root.md](root.md) | the root: how it builds the system, its faults, kill and start |
| [os-server.md](os-server.md) | the OS server: its threads and slots, where each call goes, the files, the status line |
| [processes.md](processes.md) | the processes: their calls, fork, exec, wait and kill, their files and descriptors, `/z`, init |
| [drivers.md](drivers.md) | the drivers outside the kernel: printer, mouse, console, keyboard, disks, serial line, sound, RTC |
| [storage.md](storage.md) | the drives, their drivers, the files, the printers, the sample disks |
| [devices.md](devices.md) | the speaker, the game port, the serial mouse, the modem, SYS_WAIT |
| [shell.md](shell.md) | the shell: its commands, drives and paths; the clock and the counter beside it |
| [security.md](security.md) | what no program can do, and how the tests show it |
| [building.md](building.md) | the tools, the Makefile, the builds |
| [testing.md](testing.md) | the layers of tests |
| [debugging.md](debugging.md) | Bochs' debugger, symbols, logs, recipes |
| [emulators.md](emulators.md) | Bochs, DOSBox-X and MAME, and how they differ from the AT |
| [style.md](style.md) | how the sources are written |
| [c.md](c.md) | C: the compilers, the conventions with NASM, the libraries, the executable format |

The plans behind all of it are `roadmaps/rx286.md`, `roadmaps/storage.md`,
`roadmaps/devices.md`, `roadmaps/l4.md`, `roadmaps/realtime.md` and
`roadmaps/os-server.md`.
