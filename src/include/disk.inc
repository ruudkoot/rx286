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
DS_WRITE            equ 3       ;    the same, the sectors from the segment: when the reply
                                ;    comes, a diskette's on the disk, a fixed disk's in the
                                ;    cache, written within 5 s (M6)
DS_SYNC             equ 4       ; BL a volume, or DS_ALL -> BX 0 or the first error: its
                                ;    dirty sectors written
DS_EJECT            equ 5       ; BL a volume -> BX 0: its sectors no longer cached, but for
                                ;    the dirty ones (M8 gives it its meaning)
DS_GROW             equ 6       ; the root's alone (DS_BADGE_ROOT; M7): BL segments it has put
                                ;    in the cache's next slots, from DS_SLOT_CACHE + those
                                ;    it had -> BX 0, or E_INVAL (one of them is not a whole
                                ;    segment of DS_CACHE_PER_SEGMENT blocks)
DS_SHRINK           equ 7       ;    BL the last segments to give back -> BX 0 once none of
                                ;    them is used, their dirty sectors moved to the others,
                                ;    or E_BUSY if not within DS_SHRINK_TICKS: the root then
                                ;    revokes them
DS_BADGE_ROOT       equ 0x5244  ; the root's copy of the disk server's endpoint
DS_SHRINK_TICKS     equ 500     ; 10 s: past write-behind's 5 s, and a busy block's run
DS_RUN_MAX          equ 64      ; a read's or write's sectors at most: 32 KB
DS_ALL              equ 0xFF
DS_VOLUMES          equ 4       ; volumes 0 to 3: drives A to D
DSV_REMOVABLE       equ 1       ; DS_VOLUME's DI: a diskette's
DSV_TOUCHED         equ 2       ; DS_READ's and DS_WRITE's DI: the diskette was found again
                                ;    after its change line or its motor's stop, the same
                                ;    by its first two sectors: what the caller holds of it
                                ;    to be read again before it writes (M8, D12). Another
                                ;    diskette is E_CHANGED, none E_OFFLINE

; The disk server's slots, which the root fills (src/root/root.c's
; build_disk): its endpoint; the root's for ROOT_PANIC, badged
; ROOT_BADGE_DISK; each driver's endpoint; the cache's index; thread n's
; notification, stack and thread; the cache's own segment; for each request
; at once, the segment passed with it and its saved reply; and the segments
; the root lends the cache (M7), DS_SEGMENTS_MAX - 1 at most, past the 64
; slots a space has that may be lent none
DS_SLOT_EP          equ 3
DS_SLOT_ROOT        equ 4
DS_SLOT_DISKETTE    equ 5
DS_SLOT_FIXED_DISK  equ 6
DS_SLOT_INDEX       equ 7       ; the cache's index: its hash and its ghosts
DS_SLOT_NOTIFY      equ 8       ; + n, n from 1 to DS_THREADS
DS_SLOT_STACK       equ 16      ; + n
DS_SLOT_CACHE       equ 24      ; the cache's segment 0, its own
DS_SLOT_THREAD      equ 32      ; + n: thread n, kept here
DS_SLOT_REQUEST     equ 40      ; + 2r: its segment; + 2r + 1: its reply
DS_REQUESTS         equ 12      ; (more wait in the endpoint's queue)
DS_SLOTS            equ 64      ; its space's slots, 2 KB of the kernel's; with blocks to
                                ;    lend, a power of two past DS_LEND_SEGMENTS for each
DS_SLOT_LENT        equ 64      ; + k - 1: the cache's segment k, the root's lent (M7)
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
; Its cache's blocks: in segments of DS_CACHE_PER_SEGMENT (src/disk/cache.h).
; With extended memory, a segment of its own, and blocks of 256 KB the root
; lends beyond its reserve for the processes, DS_LEND_SEGMENTS segments
; each, DS_LEND_MAX at most (M7); the index of DS_INDEX_BYTES, and
; DS_INDEX_PER_LENT more for each block it may lend, DS_INDEX_MOST at most.
; A TEST_DISK_FEW build's cache is DS_CACHE_FEW blocks, none lent
; (tests/disk/behind-small.test: write-behind's bound)
DS_CACHE_PER_SEGMENT equ 125
DS_CACHE_BLOCK      equ 524     ; a sector and its record
DS_CACHE_FEW        equ 1       ; (the cache without extended memory, until M8b)
DS_LEND_SEGMENTS    equ 4       ; 4 * 65,500 bytes: a block of 256 KB
DS_LEND_MAX         equ 56      ; 14 MB
DS_SEGMENTS_MAX     equ 1 + DS_LEND_SEGMENTS * DS_LEND_MAX
DS_INDEX_BYTES      equ 4096
DS_INDEX_PER_LENT   equ 2000    ; 500 blocks: a bucket and a ghost for two
DS_INDEX_MOST       equ 65520

%endif
