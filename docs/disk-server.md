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

The cache's size is fixed at boot (D10 B; M7 lends it more):

| Machine | Cache | Index |
|---|---|---|
| with extended memory | a segment of 125 blocks for each 256 KB of it, one at least and `DS_CACHE_SEGMENTS` (8, 512 KB) at most | `DS_INDEX_BYTES` |
| without extended memory | `DS_CACHE_SMALL` (4) blocks in one segment | `DS_INDEX_SMALL` |

On a 512 KB machine without extended memory, the disk server costs about
16 KB below 1 MB:
- its code in the boot image, 9.6 KB;
- its space, 2 KB (`DS_SLOTS` of 32 bytes each);
- its stacks, 1.5 KB;
- its data, 1 KB;
- its cache.

The OS server's cache, 4 sectors there instead of 32, pays for most of it.

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
| 24 + k | the cache's segment k (`DS_SLOT_CACHE`) |
| 32 + n | thread n (`DS_SLOT_THREAD`) |
| 40 + 2r, 41 + 2r | request r's segment and its saved reply (`DS_SLOT_REQUEST`) |

Its space has `DS_SLOTS` (64), 2 KB of the kernel's. M7's lent memory will
need more.
