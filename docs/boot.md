# The boot

## 1. The BIOS

The BIOS loads sector 0 of drive A, the boot sector, to 0000:7C00h and jumps
there with the drive number in DL. It has also set up the 8259As on vectors
08h-0Fh and 70h-77h, the timer at 18.2 Hz and the keyboard; the kernel
relies on none of it.

## 2. The boot sector (`src/boot-sector/boot-sector.asm`)

mformat writes the BPB (bytes 3-61) around its code. It:

1. sets up DS = ES = SS = 0 and a stack below 7C00h;
2. reads the reserved sectors 1-3, the loader, to 0000:7E00h with INT 13h:
   cylinder 0, head 0, sectors 2-4, which hold on every floppy format, so no
   file system is read here. A failed read is retried `BOOT_TRIES` times with
   a drive reset between;
3. checks the word at 7E02h for `LOADER_MAGIC` ("LD"), so a disk without a
   loader is reported instead of run;
4. jumps to 0000:7E00h with DL unchanged.

On an error it prints "rx286: cannot read the loader" or "rx286: no loader
on this disk", waits for a key and asks the BIOS to boot again (INT 19h).
Debug and test builds copy the message to the log, COM2 (115200, 8N1).

## 3. The loader (`src/boot-loader/`)

It reads the BPB the boot sector left at 7C00h and:

1. checks it (512-byte sectors, buffers large enough) and works out where
   the root directory and the data area begin;
2. reads the first FAT into its buffer at 8400h and the root directory into
   its buffer at 9800h;
3. finds `KERNEL  BIN` (not a volume label or a directory), and checks its
   size: at most `IMAGE_MAX`, 192 KB;
4. follows its cluster chain (`fat12.asm`: `fat12_next`), reading **one
   sector at a time** to 1000:0000h onwards, so no INT 13h read crosses a
   64 KB boundary; a cluster outside the disk ends the load with an error;
5. checks the boot image (roadmap l4.md L5; *docs/memory-map.md*): its last
   word is `KERNEL_END_MARK`; its module table's magic and length match the
   file; its first module is the root; every module lies inside it, after
   the table;
6. hands over, using the BIOS for the last time:
   - text mode 3, 80x25 colour (INT 10h AX=0003h);
   - the floppy motor off (DOR = `FDC_DOR_MOTORS_OFF`), since the BIOS's
     timer interrupt, which would switch it off, never runs again;
   - interrupts off (`cli`) and NMI off (port 70h bit 7);
   - a far jump to 1000:0000h.

It hands the kernel nothing else: no registers, no tables. Every read is
retried `BOOT_TRIES` times. The errors are "this disk's format is not one I
can read", "cannot read the disk", "no KERNEL.BIN on this disk",
"KERNEL.BIN is larger than its room", "KERNEL.BIN's cluster chain is
broken", "KERNEL.BIN is incomplete", "KERNEL.BIN's module table is not
sound", "KERNEL.BIN has no root module" and "a module lies outside
KERNEL.BIN", each followed by a key and INT 19h. Debug and test builds trace
"started" and "KERNEL.BIN loaded" on the log (COM2).

## 4. The kernel

The kernel's real-mode entry loads the GDT and IDT and enters protected
mode; *docs/protected-mode.md* and *docs/architecture.md* go on from there:
the kernel builds the root from the image's first module, and the root
starts the rest.
