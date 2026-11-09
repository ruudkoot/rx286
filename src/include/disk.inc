; ============================================================================
; rx286 - src/include/disk.inc
; The disk server's interface (roadmap disk-scheduler.md M3, D3, D11): the
; OS server's calls on its endpoint, and the slots the root fills.
;
; A volume is a diskette, or a partition of a fixed disk's master boot
; record, its sectors numbered from 0 in 32 bits. Volumes 0 to 3 are what
; drives A to D hold: A and B whole, C and D their first FAT12 partition
; (vol.c's rule until M3). A read or write passes a segment, and moves
; whole sectors between it and the disk through the disk server's cache.
; docs/storage.md describes it.
; ============================================================================

%ifndef RX286_DISK_INC
%define RX286_DISK_INC

DS_VOLUME           equ 1       ; BL a volume -> BX 0 or the error (E_NOT_FAT12: no FAT12
                                ;    partition; E_TIMEOUT: no disk); CX the low word of its
                                ;    sectors, SI the high word; DI DSV_* bits. A fixed disk's
                                ;    master boot record is read at its first DS_VOLUME
DS_READ             equ 2       ; BL a volume, BH the sectors (1 to DS_RUN_MAX), CX the low
                                ;    word of the first, SI's low byte its bits 16-23 and its
                                ;    high byte the process (M5's shares), DI the offset in
                                ;    the segment passed -> BX 0 or the error, CX the sectors
                                ;    moved
DS_WRITE            equ 3       ;    the same, the sectors from the segment: on the disk
                                ;    when the reply comes (write-behind is M6's)
DS_SYNC             equ 4       ; BL a volume, or DS_ALL -> BX 0 or the first error: its
                                ;    dirty sectors written
DS_EJECT            equ 5       ; BL a volume -> BX 0: its sectors no longer cached, but for
                                ;    the dirty ones (M8 gives it its meaning)
DS_RUN_MAX          equ 64      ; a read's or write's sectors at most: 32 KB
DS_ALL              equ 0xFF
DS_VOLUMES          equ 4       ; volumes 0 to 3: drives A to D
DSV_REMOVABLE       equ 1       ; DS_VOLUME's DI: a diskette's

; The disk server's slots, which the root fills (src/root/root.c's
; build_disk): its endpoint; the root's for ROOT_PANIC, badged
; ROOT_BADGE_DISK; each driver's endpoint; the cache's index; thread n's
; notification, stack and thread; the cache's segments, DS_CACHE_SEGMENTS
; at most; and for each
; request at once, the segment passed with it and its saved reply
DS_SLOT_EP          equ 3
DS_SLOT_ROOT        equ 4
DS_SLOT_DISKETTE    equ 5
DS_SLOT_FIXED_DISK  equ 6
DS_SLOT_INDEX       equ 7       ; the cache's index: its hash and its ghosts
DS_SLOT_NOTIFY      equ 8       ; + n, n from 1 to DS_THREADS
DS_SLOT_STACK       equ 16      ; + n
DS_SLOT_CACHE       equ 24      ; + k
DS_CACHE_SEGMENTS   equ 8
DS_SLOT_THREAD      equ 32      ; + n: thread n, kept here
DS_SLOT_REQUEST     equ 40      ; + 2r: its segment; + 2r + 1: its reply
DS_REQUESTS         equ 12      ; (more wait in the endpoint's queue)
DS_SLOTS            equ 64      ; (a slot is 32 bytes of the kernel's: 2 KB; M7's lent
                                ;    blocks will need more)
; Its threads, each started with SP DS_STACK times its number in the stack
; segment, the starts' room (os.inc's model; src/lib/crt/server.asm), and
; each on a stack segment of its own of DS_THREAD_STACK bytes: 1 takes the
; requests, 2 serves the fixed disks' controller, 3 the diskettes'
DS_THREADS          equ 3
DS_N_REQUESTS       equ 1
DS_N_FIXED          equ 2
DS_N_DISKETTE       equ 3
DS_STACK            equ 4
DS_STACK_SIZE       equ (DS_THREADS + 1) * DS_STACK
DS_THREAD_STACK     equ 512     ; (250 bytes used at most: tests/disk, M3)
; Its cache's blocks: in segments of DS_CACHE_PER_SEGMENT (src/disk/cache.h),
; DS_CACHE_SEGMENTS of them with extended memory, else DS_CACHE_SMALL
; blocks in one (the least machine's), and the cache's index of
; DS_INDEX_BYTES, or DS_INDEX_SMALL
DS_CACHE_PER_SEGMENT equ 125
DS_CACHE_BLOCK      equ 524     ; a sector and its record
DS_CACHE_SMALL      equ 4
DS_INDEX_BYTES      equ 4096
DS_INDEX_SMALL      equ 64

%endif
