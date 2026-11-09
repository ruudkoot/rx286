# The disk server

The disk server (`src/disk/`; roadmap disk-scheduler.md M3, D3) stands
between the OS server and the two disk drivers. The OS server asks it, and
it alone, for sectors. It holds:
- the volumes (D11);
- a cache of sectors (D9);
- the order of the requests (D4, D6);
- the retries (D14).

`src/include/disk.inc` is its interface; *docs/storage.md* has the drives
and the drivers under it.

It is a C module of the image, `disk`, in ring 2 at priority 6, between the
drivers (7) and the OS server (5). It is built as the OS server is (memory.md
M6): C's compact model, a server's start (`src/lib/crt/server.asm`), and a
lock that records its holder. Its cache, its order and its volumes are pure
C (`cache.c`, `sched.c`, `volume.c`), tested on the host too
(`tests/unit/test_disk.py`).

## Its calls

The OS server calls on the endpoint in its slot `OS_SLOT_DISK`. A read or a
write passes a segment: the process's data, or the OS server's cache.

| Label | In | Out |
|---|---|---|
| `DS_VOLUME` | BL a volume | BX 0 or the error; CX the low word of its sectors, SI the high word; DI `DSV_REMOVABLE` for a diskette |
| `DS_READ` | BL a volume; BH the sectors, 1 to `DS_RUN_MAX` (64); CX the low word of the first; SI's low byte its bits 16-23, its high byte the process (the OS server's entry + 1, 0 its own; M5's shares); DI the offset in the segment passed | BX 0 or the error; CX the sectors moved |
| `DS_WRITE` | the same, the sectors from the segment | the same: the sectors on a diskette when the reply comes, in the cache for a fixed disk (M6) |
| `DS_SYNC` | BL a volume, or `DS_ALL` | BX 0, or the first error of its dirty sectors' writes, once they are written |
| `DS_EJECT` | BL a volume | BX 0: its sectors no longer cached, except the dirty ones |
| `DS_GROW` | the root's alone (badged `DS_BADGE_ROOT`): BL the segments it has put in the cache's next slots | BX 0, or `E_INVAL` if one is not a whole segment of 125 blocks |
| `DS_SHRINK` | the root's alone: BL the last segments to give back | BX 0 once none of them is used, or `E_BUSY` if not within `DS_SHRINK_TICKS` (10 s) |

A volume's sectors are numbered from 0, in 32 bits. There are
`DS_VOLUMES` (4) volumes:
- volumes 0 and 1 are diskettes A and B, whole;
- volumes 2 and 3 are the first FAT12 partition of fixed disks C and D.

The disk server reads a fixed disk's master boot record at its first
`DS_VOLUME`. If the disk has no FAT12 partition, the answer is
`E_NOT_FAT12`; if there is no disk, `E_TIMEOUT`. Until M3 the OS server
read the boot record itself (`vol.c`), and only up to 64K sectors. The
process's byte is for M5's fair shares. A fixed disk's writes are written
behind (*Write-behind and read-ahead*), so a write's error may come only at
a later `DS_SYNC`. `DS_EJECT` gets its meaning with M8's removable volumes.

## Its threads

The root starts `DS_THREADS` threads at the server's entry, each with SP
`DS_STACK` times its number in the stack segment, which is the starts' room
of `DS_STACK_SIZE` bytes. Each then runs on a stack segment of its own of
`DS_THREAD_STACK` bytes, of which the tests used 250 at most.

1. **The requests' thread** (`DS_N_REQUESTS`) receives the calls. It
   receives a call's segment into the slots of a free request, one of
   `DS_REQUESTS`. While none is free, it naps a tick, and the callers wait
   in the endpoint's queue.
   - A read that the cache holds whole is copied and answered at once.
   - Any other request is queued. Its reply is saved (`KCALL_SAVE_REPLY`)
     and its controller's thread is woken.
2. **The fixed disks' thread** (`DS_N_FIXED`) serves C and D, and writes
   their dirty sectors behind.
3. **The diskettes' thread** (`DS_N_DISKETTE`) serves A and B.

A controller's thread loops:
- it takes its next request, as the scheduler chooses (`sched_pick`);
- if the choice says so, it sends a Seek first, for another request;
- it moves the request's sectors between the cache and the disk, in runs
  the driver takes;
- it copies them to or from the segment passed, and answers on the saved
  reply.

A lock guards the cache, the queues and the requests. No thread holds it
across a driver's call. A thread that faults asks the root to stop the
system (`ROOT_PANIC`), since a request may be half done.

## The cache

The cache's blocks are sectors (`cache.c`; D9). They lie in segments of
`DS_CACHE_PER_SEGMENT` (125), each segment's 12-byte records at its head:
65,500 bytes, `DS_CACHE_BLOCK` (524) bytes a block. A hash and the ghosts
are in an index segment sized to the cache. A small machine's DGROUP thus
pays nothing for a large machine's cache.

The order of eviction is 2Q (Johnson and Shasha):
- blocks seen once are in a FIFO, a quarter of the cache;
- blocks seen again are in an LRU;
- the keys of blocks lately put out of the FIFO are kept as ghosts, half
  the cache's number of blocks. A key that comes back as a ghost goes to
  the LRU.

Dirty and busy blocks are not evicted. A long scan read once does not wash
out a working set used twice.

A driver moves a run to one place in one segment, so a run of missing
sectors needs neighbouring blocks: `dc_window` gives the victim and the
evictable blocks beside it, as many as it finds. A write lands in the cache
too, over the blocks that hold its sectors or in a window of new ones. A
block the driver refused to write is dropped, and the disk's copy counts
again.

## The cache's memory

The cache has a segment of its own, and grows with the blocks of 256 KB
that the root lends it (roadmap disk-scheduler.md M7, D10 A):

| Machine | Its own | Lent | Index |
|---|---|---|---|
| with extended memory | a segment of 125 blocks | up to one block for each 256 KB of extended memory, `DS_LEND_MAX` (56, 14 MB) at most | `DS_INDEX_BYTES`, and `DS_INDEX_PER_LENT` more for each block it may be lent, `DS_INDEX_MOST` (65,520) at most |
| without extended memory | `DS_CACHE_SMALL` (1) block in one segment | none | `DS_INDEX_SMALL` |

The root lends while more than its reserve for the processes would stay
free: an eighth of the extended memory, 64 KB at least. It lends a block
at the end of a call that starts something (a fork, a spawn, a load), which
is slow anyway, and not after an exit, whose waiter it would hold up; and
none in the first 10 s, so that the boot is not held up. The cache grows to
its size as the system works.
For each block it retypes four segments of 65,500 bytes
(`DS_LEND_SEGMENTS`), moves them into the disk server's next slots, and
calls `DS_GROW`; the cache holds `DS_SEGMENTS_MAX` (225) segments at most. The hash and the ghosts
were sized at boot for all the blocks the cache may be lent, within the
index's segment.

When an allocation finds no free block, the root calls `DS_SHRINK` for the
block it lent last, then revokes the block and tries again; only when
nothing more comes back is the allocation refused (`ENOMEM`). The disk
server answers once none of the block's segments is used:
- a busy block (a driver's run) makes it wait for a tick and try again;
- a dirty block's sector, key and state are moved to a free or clean block
  of the segments it keeps, which takes its place in its queue, so nothing
  waits for the disk;
- after `DS_SHRINK_TICKS` (10 s, past write-behind's 5 s) it answers
  `E_BUSY`, and the root refuses the allocation, losing nothing.

The write-behind passes walk only the segments that hold dirty blocks, as
each segment counts its own, so a large cache costs them nothing more.

On a 512 KB machine without extended memory, the disk server costs about
17 KB below 1 MB:
- its code in the boot image, 12 KB;
- its space, 2 KB (`DS_SLOTS` of 32 bytes each);
- its stacks, 1.5 KB;
- its data, 1 KB;
- its cache.

The OS server's cache, 3 sectors there instead of 32, pays for most of it.
Each milestone's code comes out of that machine's memory for processes,
since the image's code runs where it lies: M7's and M8's left the shell no
fork for a command at 512 KB, and the cache there went from 4 blocks to 1,
the OS server's from 4 sectors to 3, the diskette's DMA buffer from 4
sectors to 2, and the OS server's scratch sets from 3 to 2
(`tests/memory/sizes.test` is the canary).

## The order of the requests

Each drive has a queue (`sched.c`; D4, D5, D6). The choices come in this
order:
1. A drive's oldest expired request (2 s for a read, 5 s for a write)
   starts a batch of 16 in sweep order (Linux's deadline scheduler). A
   read's deadline is longer than another process's turn, or the batches
   would undo the shares (roadmap disk-scheduler.md M5).
2. The process whose turn it is (BFQ-lite, M5): each process has a budget
   of 136 sectors a turn, then the next process with work, in turn. After a
   read it waited for, the turn waits for the same process's next request
   to the second tick (20-40 ms), unless a process that had asked nothing
   for 50 ms asks meanwhile: that ends the turn, so an interactive reader
   is not held behind a greedy one. The controller's thread waits on its
   timer, and a new request's signal cuts the wait short.
3. The controller's turn says which drive: a cylinder's work, then the
   other drive's, two cylinders' sectors (136) at most a turn.
4. C-LOOK picks the drive's request: the lowest sector from the sector
   after the last one served, else the lowest of all.
5. On the fixed disks, a request that needs a seek has its Seek sent
   first, and the other drive's request is served while the heads move.

Since M4 the OS server gives its lock up while a call waits for the disk
server, and takes a volume's lock for the call (*docs/processes.md*): a
request of each volume can be queued at once, and a volume's calls follow
one another in the order they asked. The host's test runs the choices
together against a model of C (E6's): two sequential readers far apart
get 113 KB/s against C-LOOK's 41, Jain's index 0.997; an interactive reader
beside a greedy scan waits no longer than under C-LOOK.

## Write-behind and read-ahead

Since roadmap disk-scheduler.md M6 (D7, D8):
- **A fixed disk's write** is answered once its sectors are in the cache,
  dirty. Every `WB_TICKS` (2.5 s) the fixed disks' thread writes the
  sectors that were dirty at its last pass, and marks those dirty now
  (`DC_AGED`). A sector is thus on the disk within 5 s, and a sector written
  again meanwhile keeps its age. A pass writes in the sectors' order, as
  runs of neighbouring blocks of neighbouring sectors, `DRV_DISK_RUN_MAX` at
  most.
- **A diskette's write** goes to the disk at once, while its motor runs:
  a diskette can be taken out at any time, and its change line is not read
  until M8.
- **`DS_SYNC`** is queued as a request. The fixed disks' thread writes all
  the volume's dirty sectors, or both fixed disks' for `DS_ALL`, and then
  answers. A diskette's volume has nothing to write, and is answered at
  once.
- **Read-ahead:** a read that missed the cache and began where the same
  process's last read of the drive ended has the rest of its cylinder read
  after it, into the cache, as the server's own request (`READ_AHEAD`), one
  at a time a drive. It is the reader's, so that it comes next in the
  reader's turn and is charged to its share: as anyone else's, the turn's
  wait for the reader's next read let that read come first and fetch the
  sectors itself. It takes a free request's record, no more than
  `DS_RUN_MAX` sectors, and the blocks the cache can spare; it copies
  nothing and answers no one.

The writes this saves were counted on E5's workloads, against M5, on
Bochs: the fixed disks' write commands fell from 26 to 4 in `rdtime` and
from 100 to 18 in `trace-copy`, and their sectors written from 82 to 67 and
from 105 to 82. Most of the saving is the FAT and the directory, which the
OS server writes at the end of each call that changes them.

The sectors a fixed disk holds dirty are lost if the machine stops before
they are written. Three things write them:
- **`fsync`**, which the OS server turns into a `DS_SYNC` of the file's
  volume after writing the file's sectors (*docs/processes.md*);
- **Ctrl+Alt+Del**, after which the keyboard driver signals the OS server's
  control thread (`CONTROL_REBOOT`). The thread writes all it holds, calls
  `DS_SYNC` with `DS_ALL`, and asks the driver to reset (`DRV_KBD_RESET`).
  The driver resets anyway 10 s after the keys, or at once at a second
  Ctrl+Alt+Del;
- **a test's end** (*docs/testing.md*), in the same way (`CONTROL_SYNC`).

A dirty block is not evicted. Once a fixed disk's write leaves more than
half the cache dirty, both fixed disks' dirty blocks are written at once,
so that reads, and the diskettes, keep room. If every block is still dirty
or busy, a write goes from the process's segment straight to the disk, and
a read straight into it, a sector at a time.

A sector that a write-behind pass fails to write is dropped from the cache,
as any refused write is, and the failure is said on the log. The error is
kept for the volume: its next `DS_SYNC`, and so the next `fsync` of a file
on it, returns it.

## Diskettes

A diskette's volume follows its diskette (roadmap disk-scheduler.md M8,
D12). The disk server knows each diskette drive's diskette by its first two
sectors, the boot sector and the FAT's first, hashed when it first reads
them and again whenever it writes one of them itself. It looks at the
diskette again:
- when the driver refuses a run with `E_CHANGED` (A's change line, or B
  idle past its motor's time: *docs/storage.md*);
- at the first call of a drive that has been silent for 2 s
  (`TRUST_TICKS`), before it answers from its cache: a diskette taken out
  and put back while the motor was off, which no line tells of.

To look, it asks the driver for the medium (`DRV_DISK_MEDIA`, which finds a
360 KB diskette in A by its data rate) and reads the two sectors afresh,
into a sector of its own, since the run that met `E_CHANGED` may hold every
block of the cache:
- **the same diskette**: the cache is kept, and the volume's next answer
  says so with `DSV_TOUCHED`, so that the OS server reads afresh what it
  holds before it writes: a twin, or a directory changed on another
  machine, passes the check;
- **another**: the drive's cached sectors are dropped, and the call is
  answered `E_CHANGED`: the OS server mounts the new volume;
- **none**: `E_OFFLINE`. A read of sectors the cache holds is still
  answered; a write, or a read of others, is refused. `DS_VOLUME` answers
  the volume as it was, so that its cached files can still be read.

A 360 KB diskette in A is read-only (`E_PROTECTED`; D12). `DS_EJECT` also
forgets the drive's diskette, so that the next is taken as new.

## Retries

The drivers try a run once (D14). On a failure they reset the controller,
or forget the diskette's cylinder, before their next. The disk server tries
again:
- a fixed disk's run once more, after a `DRV_DISK_RESET`;
- a diskette's twice more, each recalibrating.

A run that still fails is tried a sector at a time, so that only the bad
sector fails, and the sectors before it are moved. No disk, a
write-protected diskette, or a call the driver refused is not tried again.

## Its slots

| Slot | What |
|---|---|
| 0, 1, 2 | its code, data and the starts' room |
| 3 | its endpoint (`DS_SLOT_EP`) |
| 4 | the root's fault endpoint, badged `ROOT_BADGE_DISK`: `ROOT_PANIC` alone (`DS_SLOT_ROOT`) |
| 5, 6 | the diskette driver's and the fixed disk driver's endpoints (`DS_SLOT_DISKETTE`, `DS_SLOT_FIXED_DISK`) |
| 7 | the cache's index (`DS_SLOT_INDEX`) |
| 8 + n | thread n's notification, which it sleeps on (`DS_SLOT_NOTIFY`) |
| 16 + n | thread n's stack (`DS_SLOT_STACK`) |
| 24 | the cache's own segment, its segment 0 (`DS_SLOT_CACHE`) |
| 32 + n | thread n (`DS_SLOT_THREAD`) |
| 40 + 2r, 41 + 2r | request r's segment and its saved reply (`DS_SLOT_REQUEST`) |
| 64 + k - 1 | the cache's segment k, lent by the root (`DS_SLOT_LENT`) |

Its space has `DS_SLOTS` (64), 2 KB of the kernel's, when the root may lend
it nothing. Otherwise the space is the power of two that holds the slots
for every block it may be lent, 512 at 16 MB (16 KB), made from extended
memory.
