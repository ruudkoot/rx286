# The boot

1. The BIOS loads the floppy's sector 0, the boot sector, to 0000:7C00h and
   jumps there with the drive in DL.
2. The boot sector loads the loader from the reserved sectors 1-3 to
   0000:7E00h.
3. The loader finds `KERNEL.BIN` in the FAT12 root directory, reads it to
   1000:0000h, sets text mode 3, stops the floppy motor, disables interrupts
   and NMI, and jumps to 1000:0000h.
4. The kernel's real-mode entry loads the GDT and IDT and enters protected
   mode; the kernel then programs its devices and starts the program in
   ring 3.

M2-M4 of the roadmap fill in each step.
