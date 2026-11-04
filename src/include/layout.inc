; ============================================================================
; rx286 - src/include/layout.inc
; The physical memory map, and the fixed layout of KERNEL.BIN.
;
; Everything here is a constant chosen at assembly time (roadmap D6, D7).
; The boot code, the kernel and the program include this file; the program
; uses only its own rooms. docs/memory-map.md explains every number.
; ============================================================================

%ifndef RX286_LAYOUT_INC
%define RX286_LAYOUT_INC

; ---------------------------------------------------------------- real mode
BOOT_SECTOR_PHYS    equ 0x7C00      ; where the BIOS loads sector 0
LOADER_PHYS         equ 0x7E00      ; where the boot sector loads the loader
LOADER_SECTORS      equ 3           ; reserved sectors 1-3 of the floppy
RESERVED_SECTORS    equ 1 + LOADER_SECTORS
LOADER_MAGIC        equ 'LD'        ; the word at LOADER_PHYS + 2, checked by the boot sector
BOOT_TRIES          equ 3           ; reads of the floppy before giving up
LOADER_STACK_TOP    equ 0x7C00      ; both boot stages' stack grows down from here
LOADER_FAT_BUF      equ 0x8400      ; the loader's buffer for one FAT (up to 9 sectors)
LOADER_ROOT_BUF     equ 0x9800      ; the loader's buffer for the root directory (up to 14 sectors)
LOADER_BUF_END      equ 0x10000

; ---------------------------------------------------------------- the kernel's image
KERNEL_PHYS         equ 0x10000     ; KERNEL.BIN is loaded here (64 KB aligned)
KERNEL_SEG          equ KERNEL_PHYS >> 4    ; the same place as a real-mode segment

; Each segment starts at a fixed offset of KERNEL.BIN, so every descriptor's
; base is a constant. NASM stops the build if a segment outgrows its room.
ENTRY_OFF           equ 0x0000      ; real-mode entry
ENTRY_ROOM          equ 0x0100
KTEXT_OFF           equ 0x0100      ; kernel code
KTEXT_ROOM          equ 0x2000
KDATA_OFF           equ 0x2100      ; kernel data: GDT, IDT, TSSs, variables, messages
KDATA_ROOM          equ 0x1000
UTEXT_OFF           equ 0x3100      ; the program's code (incbin)
UTEXT_ROOM          equ 0x2000
UDATA_OFF           equ 0x5100      ; the program's data (incbin)
UDATA_ROOM          equ 0x1000
KERNEL_FILE_SIZE    equ 0x6100      ; KERNEL.BIN is exactly this long

; Zeroed at start, not in the file.
KSTACK_OFF          equ 0x6100      ; the kernel's stack (SS0 in the TSS)
KSTACK_SIZE         equ 0x0400
DFSTACK_OFF         equ 0x6500      ; the double-fault task's stack
DFSTACK_SIZE        equ 0x0200
USTACK_OFF          equ 0x6700      ; the program's stack
USTACK_SIZE         equ 0x0800
KERNEL_END          equ 0x6F00

; Physical addresses of the segments.
KTEXT_PHYS          equ KERNEL_PHYS + KTEXT_OFF
KDATA_PHYS          equ KERNEL_PHYS + KDATA_OFF
UTEXT_PHYS          equ KERNEL_PHYS + UTEXT_OFF
UDATA_PHYS          equ KERNEL_PHYS + UDATA_OFF
KSTACK_PHYS         equ KERNEL_PHYS + KSTACK_OFF
DFSTACK_PHYS        equ KERNEL_PHYS + DFSTACK_OFF
USTACK_PHYS         equ KERNEL_PHYS + USTACK_OFF

; The program's two file sections, as offsets of its own binary.
USER_TEXT_START     equ 0
USER_DATA_START     equ UDATA_OFF - UTEXT_OFF
USER_FILE_SIZE      equ USER_DATA_START + UDATA_ROOM

; ---------------------------------------------------------------- the console
VIDEO_PHYS          equ 0xB8000     ; colour text, page 0
VIDEO_COLUMNS       equ 80
VIDEO_ROWS          equ 25
VIDEO_SIZE          equ VIDEO_COLUMNS * VIDEO_ROWS * 2

%endif
