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

; ---------------------------------------------------------------- the boot image
KERNEL_PHYS         equ 0x10000     ; KERNEL.BIN, the boot image, is loaded here (64 KB aligned)
KERNEL_SEG          equ KERNEL_PHYS >> 4    ; the same place as a real-mode segment
IMAGE_MAX           equ 0x20000     ; its most: up to UMEM_PHYS, the memory for programs

; The kernel's segments start at fixed offsets of the image, so every
; descriptor's base is a constant. NASM stops the build if a segment
; outgrows its room. The module table and the modules follow (roadmap
; l4.md L5, D13): tools/mkimage puts them there.
ENTRY_OFF           equ 0x0000      ; real-mode entry
ENTRY_ROOM          equ 0x0100
KTEXT_OFF           equ 0x0100      ; kernel code (16 KB: the arena's room, os-server.md
KTEXT_ROOM          equ 0x4000      ; P3; 12 KB from l4.md L10 until then)
KDATA_OFF           equ 0x4100      ; kernel data: the boot GDT, IDT, TSSs, variables, messages
KDATA_ROOM          equ 0x1800
MODULE_TABLE_OFF    equ 0x5900      ; the table of the image's modules
MODULE_TABLE_SIZE   equ 0x0200
MODULES_OFF         equ 0x5B00      ; the modules, each on a paragraph
KERNEL_END_MARK     equ 0x286E      ; the image's last word: the loader checks it arrived

; The module table: a header, then an entry a module, the root's first.
MH_MAGIC            equ 0           ; MODULE_MAGIC
MH_COUNT            equ 2           ; the modules
MH_PARAGRAPHS       equ 4           ; the image's length, in paragraphs
MODULE_HEADER_SIZE  equ 32
MODULE_MAGIC        equ 'MT'
MODULE_ENTRY_SIZE   equ 32
MODULE_MAX          equ (MODULE_TABLE_SIZE - MODULE_HEADER_SIZE) / MODULE_ENTRY_SIZE
M_NAME              equ 0           ; lower case, zero-padded: at most M_NAME_SIZE - 1
M_NAME_SIZE         equ 8
M_CODE              equ 8           ; its code: paragraphs from the image's start
M_CODE_SIZE         equ 10          ; bytes
M_DATA              equ 12          ; its data as assembled: paragraphs from the start
M_DATA_SIZE         equ 14          ; bytes (0: none)
M_DATA_ROOM         equ 16          ; its data segment's bytes, the rest zeroed
M_STACK             equ 18          ; its stack's bytes
M_ENTRY             equ 20          ; its IP at a start
M_RING              equ 22          ; 1-3: its code's DPL
M_PRIORITY          equ 23          ; 0-7
M_FLAGS             equ 24
MF_FOREGROUND       equ 1           ; the program the keys are for (the OS server's, L8)
MF_DRIVER           equ 2           ; a driver: IOPL 1, an endpoint, a notification (L7)
MF_IOPL             equ 4           ; a program that asks for IOPL (tests of rings 1 and 2)
MF_ARCHIVE          equ 8           ; no program: its data is /z, an archive of executables
                                    ;    (archive.inc; os-server.md P6), the OS server's
M_IRQ               equ 25          ; a driver's interrupt line, plus one (0: none)
M_SERVICE           equ 26          ; what a driver serves (drivers.inc; 0: nothing)
M_DATA_AT           equ 28          ; where its data as assembled goes in its data segment:
                                    ;    the zeros before it are not in the image (P6)
ROOT_NAME           equ 'ro'        ; the first module's name starts "root"
ROOT_NAME_2         equ 'ot'

; Below the image: the boot code's memory, free once the kernel runs. The
; double fault's stack; the arena; then what only the kernel reaches, in
; its data segment, SEL_KDATA, which starts at KDATA_BASE and whose 64 KB
; reach its one stack, the GDT and its free descriptors, the kernel's
; variables and the module table. The stack's segment, SEL_KSTACK, is the
; same memory at the same offsets, expand-down from KSTACK_BOTTOM, so that
; SS and DS agree and an overflow still faults (roadmap os-server.md P3).
DFSTACK_PHYS        equ 0x00500     ; the double-fault task's stack
DFSTACK_SIZE        equ 0x0200
; The arena: given to the root as untyped memory like any other
; (os-server.md P3; until then only for the kernel's objects, l4.md D7, L3)
ARENA_PHYS          equ 0x00700
ARENA_SIZE          equ 0xB900
KDATA_BASE          equ 0x0C000
KSTACK_PHYS         equ 0x0C100     ; the kernel's one stack (os-server.md P3)
KSTACK_SIZE         equ 0x0400
KSTACK_BOTTOM       equ KSTACK_PHYS - KDATA_BASE        ; its offsets in SEL_KDATA
KSTACK_TOP          equ KSTACK_BOTTOM + KSTACK_SIZE
; The GDT, built here at the start (os-server.md P3): an object's
; descriptor each; then the stack of its pool's free descriptors
GDT_PHYS            equ 0x0C800
GDT_ENTRIES         equ 1024
OBJ_FREE_PHYS       equ GDT_PHYS + GDT_ENTRIES * 8
; Memory for programs' segments, given out as untyped (l4.md L3)
UMEM_PHYS           equ 0x30000
UMEM_SIZE           equ 0x70000     ; to the EGA's memory at A0000h
SPACE_MAX           equ 128         ; spaces (space_list)
THREAD_MAX          equ 192         ; threads (thread_list)

; Physical addresses, and offsets of SEL_KDATA.
KTEXT_PHYS          equ KERNEL_PHYS + KTEXT_OFF
KDATA_PHYS          equ KERNEL_PHYS + KDATA_OFF
MODULE_TABLE_PHYS   equ KERNEL_PHYS + MODULE_TABLE_OFF
KDATA_VSTART        equ KDATA_PHYS - KDATA_BASE         ; the kernel's variables
MODULE_TABLE_VOFF   equ MODULE_TABLE_PHYS - KDATA_BASE  ; the module table
GDT_OFF             equ GDT_PHYS - KDATA_BASE           ; the GDT
OBJ_FREE_OFF        equ OBJ_FREE_PHYS - KDATA_BASE      ; its pool's free descriptors

%if KERNEL_PHYS + IMAGE_MAX > UMEM_PHYS
  %error "layout.inc: the image's room overlaps the memory for programs"
%endif
%if DFSTACK_PHYS + DFSTACK_SIZE > ARENA_PHYS || ARENA_PHYS + ARENA_SIZE > KDATA_BASE
  %error "layout.inc: the double fault's stack, the arena and the kernel's data overlap"
%endif
%if KSTACK_PHYS <= KDATA_BASE || KSTACK_PHYS + KSTACK_SIZE > GDT_PHYS
  %error "layout.inc: the kernel's stack must lie past KDATA_BASE, before the GDT"
%endif
%if OBJ_FREE_PHYS + GDT_ENTRIES * 2 > KERNEL_PHYS
  %error "layout.inc: the GDT and its free descriptors must lie below the image"
%endif
%if MODULE_TABLE_VOFF + MODULE_TABLE_SIZE > 0x10000
  %error "layout.inc: the module table must lie within the kernel data segment's 64 KB"
%endif
%if KDATA_OFF + KDATA_ROOM != MODULE_TABLE_OFF
  %error "layout.inc: the image's parts do not follow each other"
%endif
%if MODULE_TABLE_OFF + MODULE_TABLE_SIZE != MODULES_OFF
  %error "layout.inc: the image's parts do not follow each other"
%endif

; ---------------------------------------------------------------- a program's binary
; A program (src/userland, tests/programs, the root) is assembled on its
; own with its code at offset 0 and its data at USER_DATA_START, each in a
; room; tools/mkimage takes what each holds into the image. It runs with a
; data segment of UDATA_ROOM bytes and a stack of USTACK_SIZE. A C program
; (os-server.md P1) is an rx286 executable instead, whose header gives its
; rooms (exe.inc).
UTEXT_ROOM          equ 0x2000
UDATA_ROOM          equ 0x2000
USTACK_SIZE         equ 0x0800
USER_TEXT_START     equ 0
USER_DATA_START     equ UTEXT_ROOM

; ---------------------------------------------------------------- the console
VIDEO_PHYS          equ 0xB8000     ; colour text, page 0
VIDEO_COLUMNS       equ 80
VIDEO_ROWS          equ 25
VIDEO_SIZE          equ VIDEO_COLUMNS * VIDEO_ROWS * 2

%endif
