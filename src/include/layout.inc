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
SECTOR_SIZE         equ 512
SECTOR_SHIFT        equ 9           ; log2 of SECTOR_SIZE
LOADER_STACK_TOP    equ 0x7C00      ; both boot stages' stack grows down from here
LOADER_FAT_BUF      equ 0x8400      ; the loader's buffer for one FAT (10 sectors of room)
LOADER_ROOT_BUF     equ 0x9800      ; the loader's buffer for the root directory (26 sectors)
LOADER_BUF_END      equ 0x10000

; ---------------------------------------------------------------- the kernel's image
KERNEL_PHYS         equ 0x10000     ; KERNEL.BIN is loaded here (64 KB aligned)
KERNEL_SEG          equ KERNEL_PHYS >> 4    ; the same place as a real-mode segment

; Each segment starts at a fixed offset of KERNEL.BIN, so every descriptor's
; base is a constant. NASM stops the build if a segment outgrows its room.
ENTRY_OFF           equ 0x0000      ; real-mode entry
ENTRY_ROOM          equ 0x0100
KTEXT_OFF           equ 0x0100      ; kernel code (16 KB while the old calls and the new
KTEXT_ROOM          equ 0x4000      ; kernel live side by side: roadmap l4.md Constraints)
KDATA_OFF           equ 0x4100      ; kernel data: GDT, IDT, TSSs, threads, variables, messages
KDATA_ROOM          equ 0x2000
UTEXT_OFF           equ 0x6100      ; the program's code (incbin)
UTEXT_ROOM          equ 0x2000
UDATA_OFF           equ 0x8100      ; the program's data (incbin)
UDATA_ROOM          equ 0x2000
CTEXT_OFF           equ 0xA100      ; the counter's code (incbin; roadmap l4.md L2)
CTEXT_ROOM          equ 0x0400
CDATA_OFF           equ 0xA500      ; the counter's data (incbin)
CDATA_ROOM          equ 0x0400
KERNEL_FILE_SIZE    equ 0xA900      ; KERNEL.BIN is exactly this long
KERNEL_END_MARK     equ 0x286E      ; its last word: the loader checks it arrived

; Zeroed at start, not in the file.
KSTACK_OFF          equ 0xA900      ; the kernel's own stack: the start's, then the idle loop's
KSTACK_SIZE         equ 0x0400
DFSTACK_OFF         equ 0xAD00      ; the double-fault task's stack
DFSTACK_SIZE        equ 0x0200
USTACK_OFF          equ 0xAF00      ; the program's stack
USTACK_SIZE         equ 0x0800
CSTACK_OFF          equ 0xB700      ; the counter's stack
CSTACK_SIZE         equ 0x0400
KERNEL_END          equ CSTACK_OFF + CSTACK_SIZE

; The arena (roadmap l4.md D7, L3): the kernel's objects - spaces, threads,
; endpoints, notifications - in the upper half of its data segment's 64 KB,
; so the kernel reaches each with DS = SEL_KDATA. Only the kernel maps it:
; it is given out as untyped memory, never as a segment.
ARENA_OFF           equ 0x8000      ; an offset of the kernel's data segment
ARENA_SIZE          equ 0x8000
; Memory for programs' segments, given out as untyped (l4.md L3)
UMEM_PHYS           equ 0x30000
UMEM_SIZE           equ 0x70000     ; to the EGA's memory at A0000h
SPACE_MAX           equ 8           ; LDT descriptors in the GDT's pool
THREAD_MAX          equ 8           ; kernel stack descriptors in the GDT's pool

; Physical addresses of the segments.
KTEXT_PHYS          equ KERNEL_PHYS + KTEXT_OFF
KDATA_PHYS          equ KERNEL_PHYS + KDATA_OFF
UTEXT_PHYS          equ KERNEL_PHYS + UTEXT_OFF
UDATA_PHYS          equ KERNEL_PHYS + UDATA_OFF
CTEXT_PHYS          equ KERNEL_PHYS + CTEXT_OFF
CDATA_PHYS          equ KERNEL_PHYS + CDATA_OFF
KSTACK_PHYS         equ KERNEL_PHYS + KSTACK_OFF
DFSTACK_PHYS        equ KERNEL_PHYS + DFSTACK_OFF
USTACK_PHYS         equ KERNEL_PHYS + USTACK_OFF
CSTACK_PHYS         equ KERNEL_PHYS + CSTACK_OFF
ARENA_PHYS          equ KDATA_PHYS + ARENA_OFF

%if ARENA_PHYS < KERNEL_PHYS + KERNEL_END
  %error "layout.inc: the arena overlaps the kernel's image"
%endif
%if ARENA_OFF + ARENA_SIZE > 0x10000
  %error "layout.inc: the arena must lie within the kernel data segment's 64 KB"
%endif

; The program's two file sections, as offsets of its own binary.
USER_TEXT_START     equ 0
USER_DATA_START     equ UDATA_OFF - UTEXT_OFF
USER_FILE_SIZE      equ USER_DATA_START + UDATA_ROOM

; The counter's, likewise.
COUNTER_DATA_START  equ CDATA_OFF - CTEXT_OFF
COUNTER_FILE_SIZE   equ COUNTER_DATA_START + CDATA_ROOM

; ---------------------------------------------------------------- the console
VIDEO_PHYS          equ 0xB8000     ; colour text, page 0
VIDEO_COLUMNS       equ 80
VIDEO_ROWS          equ 25
VIDEO_SIZE          equ VIDEO_COLUMNS * VIDEO_ROWS * 2

%endif
