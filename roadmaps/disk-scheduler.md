# Roadmap: the disks and their scheduling

**This roadmap redesigns how rx286 drives its disks: the drivers, a disk server that schedules
and caches, and the OS server's side.** Today the OS server reads and writes one sector per
call through two small drivers, with a cache of 32 sectors, under the one lock it holds for
every call. So there is never more than one disk request in the system. After it:

- **the drivers take runs** of sectors and offer every command their controllers have:
  - the fixed disk driver up to 64 sectors a command, across heads and cylinders;
  - the diskette driver a whole cylinder, both heads, through a DMA buffer of 15 KB;
  - seeks, Read ID, formatting and the change line besides.

  They stay two drivers in assembly, one for each controller of the adapter, each holding the
  next run while the current one goes on, as the draft has it, without retries of their own
  (D1, D2);
- **a disk server**, a new server in C, sits between the OS server and the drivers (D3). It
  holds:
  - the volumes: partitions and diskettes, addressed by 32-bit sector numbers;
  - the cache, in memory the root lends it and can ask back;
  - the queues, ordered by C-LOOK within a drive;
  - the turns between the two drives of a controller, with overlapped seeks;
  - fair shares between processes;
  - read-ahead and write-behind;
  - the retries;
- **the OS server waits for the disk without its lock** (D15). Several processes' requests
  can then be queued at once, which is what a scheduler needs to have anything to do;
- **diskettes become volumes,** known by their contents as well as their drive. They are
  tracked after they leave a drive, and they can move between the drives that can read them.
  They appear under `/mnt` by name (D12, D20). FAT names become case-sensitive, as the owner
  asked (D19);
- **a formatter** lays out diskettes, and fixed disks, with the interleave and skew the
  measurements call for (D17).

The plan has ten milestones (M1-M10):
1. the copy and the names;
2. runs through the drivers;
3. the disk server;
4. waiting without the lock;
5. fairness;
6. read-ahead and write-behind;
7. the cache's memory;
8. removable volumes and `/mnt`;
9. the formatter;
10. the simulator in `tools/`, the documents, a review and the close.

Every suite stays green throughout.

**Writing it found:**
- **Today the software, not the disks, sets the pace** (E4, E5):
  - a sector read from C takes about 30 ms on MAME's 6 MHz AT (17 KB/s), and about 20,000
    instructions on Bochs, although the drive turns 17 sectors past the head every 16.8 ms;
  - a diskette sector costs more than a revolution (216-288 ms);
  - the OS server copies each byte of a file with two segment loads, about 9 ms a sector by
    Intel's tables and 17.5 ms on MAME, though `memcpy` with `rep movsw` is in its library.

  A prototype of 233 lines (runs through both drivers, and `memcpy`) reads C 9.4 times and A
  7.9 times faster on MAME (E7).
- **There is never more than one disk request:** the OS server makes every disk call holding
  its one lock (E5). Released around a read, a reader of C beside a reader of A took 3.4 s
  instead of 7.5 s (E8).
- **Drive B cannot tell that its diskette was changed.** IBM's AT 360 KB drive has no change
  line, and the BIOS says so (INT 13h AH=15h answers 01h). Only A's 1.2 MB drive has one. Bochs
  and MAME both give B a line the real drive lacks (E2).
- **A hash of sector 0 does not tell diskettes apart** (E9):
  - before DOS 4 a boot sector has no serial number;
  - from DOS 4 on the serial is the time of FORMAT, which twins formatted in the same second
    share;
  - a fingerprint of sector 0, the FAT and the root directory catches most changes, not all.

  So no dirty data may outlive a diskette's motor.
- **The AT's adapter drives two diskette drives** (DOR bit 0 selects, bit 1 is always 0:
  adapter manual p. 12). IBM supports two fixed disks and one diskette drive, or one and two:
  three drives, where rx286's machine has four (p. 1). And **the diskette drives cannot seek
  at once**: the 765's unit select follows the DOR's (p. 19), so steps reach only the selected
  drive (E1).
- **The fixed disks can seek at once,** but only between commands. The WD1010's Seek "is
  primarily used for overlap seek operations", and ends once the steps are sent, and the
  adapter has one task file. Sent as each request's first command, with the other drive
  served while the heads move, a Seek gains a third with one reader a drive. Sent only for
  the other drive's queued work, it gains nothing then (E6, E10).
- **The driver must hold the next command,** as the draft says. A run the driver issues the
  moment the last one ends reads C at 223 KB/s at 2:1. One taken from its endpoint after its
  reply reads at 119, a revolution lost a run (E10).
- **The interleave depends on the CPU, not the scheduler.** 1:1 cannot work with the
  controller's one sector buffer. 2:1 with runs gives about 200 KB/s in the model, 14 times
  today, but only if a sector's service takes less than a sector's time (0.99 ms). With E7's
  runs it takes about 2,100 instructions on Bochs, about 2.5 ms on a 6 MHz AT (an estimate).
  At 2.2 ms 2:1 falls to 26 KB/s and only 4:1 keeps up, at 112 (E7, E10). So the driver's path
  per sector must shrink, and the interleave must be measured, not assumed.
- **Read-ahead only pays when it is asked for by a sequential reader.** Blind read-ahead of a
  cylinder doubles a random reader's time. On a sequential miss only, it keeps all the gain
  and costs random readers nothing (E6).
- **Two sequential readers on one disk thrash** (40 KB/s) unless the scheduler waits a moment
  for the process it just served. Budgets with that wait give 106 KB/s, fairly (E6). But the
  wait also holds an interactive process behind a greedy reader: 153 ms on average instead of
  85. Letting a process that was idle end the turn keeps both: 105 KB/s, and 92 ms (E10).
- **Taking turns between C and D by the oldest request starves a reader** behind a
  write-behind flush (32 KB/s). The draft's "a cylinder, then the other drive" gives it
  98 KB/s (E6).
- **No emulator models a fixed disk's rotation** (E1):
  - Bochs and MAME answer as fast as their PIO allows;
  - MAME's IDE card takes a geometry of 82 cylinders, 10 heads and 51 sectors a track from the
    image's size;
  - both abort Format Track on a fixed disk.

  CHDs made by `chdman` give MAME the AT's geometry, though not its timing. MAME's diskettes
  do turn, at the drives' speeds. **A simulator** (`sim/`, E6) carries the
  timing the emulators cannot, and its diskette figures agree with MAME's (E7).
- **The OS server's space is full:** 502 of its 512 slots at 48 processes. A cache of 64 KB
  segments needs a space of its own, which is a reason for the disk server (E9).
- **Metadata is written again and again:** fsrand wrote B's FATs 78 times in 400 operations
  (E5). But that is a diskette, which D8 writes at once. On the fixed disks' traces a
  write-behind of 5 s writes 14-22% fewer sectors in 4-10 times fewer commands (E6, E10).
- **Case-sensitive names are ten lines of `vfs.c`.** With them, 118 of the 133 Bochs tests
  pass, and the 15 others fail only because they expect capitals (E9).

The experiments ran in copies of the repository in the scratchpad, on Bochs, MAME's AT and the
simulator; none of their code is in the repository.

## Status

| | State |
|---|---|
| The survey and this roadmap | done (2026-11-08) |
| D1-D21 | decided (2026-11-09): as recommended |
| M1: the copy and the names | done (2026-11-09) |
| M2: runs through the drivers | done (2026-11-09) |
| M3: the disk server | done (2026-11-09) |
| M4: waiting without the lock | not started |
| M5: fairness | not started |
| M6: read-ahead and write-behind | not started |
| M7: the cache's memory | not started |
| M8: removable volumes and `/mnt` | not started |
| M9: the formatter | not started |
| M10: the simulator in `tools/`, the documents, a review and the close | not started |

## The request

The owner's draft, as written. It stood alone in `roadmaps/disk-scheduler.md`, untracked:

> - this is a draft roadmap the (re)design the disk subsystem and scheduling in rx286
>   - you are to critically review all requirements and improve/object where you think needed
> - the disk subsystem will consist of three components:
>   - disk driver
>   - disk scheduler
>   - os/fs/vfs layer
> - the disk driver are the existing floppy and hard disk controller
>   - as these are a single expansion card in the ibm pc/at and share some io ports i suggest combining them into a single driver than can handle two floppy drives and two hard drives
>   - the driver remains written in assembly
>   - the floppy and hard drive should have separate controller chips so can be operated in parallel (e.g. separate threads and sector buffer)
>   - two hard disks can not transfer data in paralel but the can be seeked in parallel according to the datasheet
>   - i did not look into the floppy disk controller in detail but the situation may be similar to the hard disks
>   - the disk driver should be kept simple and the complex logic live in the disk scheduler.
>   - however the disk driver should achieve maximal throughput of the drives. 
>     - i think it may be sufficient to keep one in flight operation in the driver per disk and one or two queued commands. i.e. the real queues live in the scheduler. but having a next command will allow the disk driver to immediately issue a new command to the drive after transfer of a sector is finishes.
>     - to achieve maximal throughput a complete cylinder should be attemted to be processed at a time as the physical disk can be assumed to have been layed out by the low level formatter to achieve optimal throughput. i.e. the driver should issue read and write commands in increasing order of sector and head number within a cylinder. then issue a seek to the next cylinder (not necessarily adjacent). once the seek is issued it may be an oppurtune time to swirch drives and issues command to that other drive (hopefully it will already have been seeked to the correct cylinder earlier by the driver)
>       - it is for you to decided if this can be achieved by the disk scheduler issuing indivual sector read/writes to the driver, or if the driver must accept ranges.
>       - we should try to achieve fairness between the two drives. i am unsure if the naive algoithm above to switch between drive processing at cylinder change guarantees that. so you may need to make some additional improvements here.
>       - a future extension may be for the disk driver to predict which physical sector is closest to the disk head after a seek and issue read/write in e.g. a 5 6 7 8 9 1 2 3 4 sector order if it believes this to be more optimal. this will require extremely careful benchmark on real hardware (we only have emulators at the moment) so will have to be postponed for a future roadmap.
>       - we should probably also keep one or more track or cylinder buffers that can serve a read-ahead/between/behind strategies making good use of the disk's geometry. e.g. if we read sectors 3 4 7 8 on a 9 sectors per track disk, maybe read 3 4 5 6 7 8 9 1 2 in that order (acutally no - probably don't do that - read the whole cylinder ahead before doing the read behind. and maybe only do readahead/behind if nothing else is in the queue? read between is probably free though). and return 3 4 7 8 9 as earlier as possible to the application. though i do wonder how this interacts with the disk controller's track buffer (if they have one). unfortunately we cannot to microbenchmarks on real hardware right now but do read the contemporary controller and drive datasheets and literature on this topic (let me know if you need any additional ones).
>       - since we cannot benchmark real hardware and the emulators are not very accurate when it comes to device timing you should run/build simulations if needed.
>   - the disk drive should assume attached drives are in CHS and their logical CHS geomeotry matches their physical CHS geometry. this is accurate for drives during this era. the disk scheduler will turn the disks into LBA addressable ones.
>   - the disk driver API can be in CHS and should expose all functionality the controllers offers so the disk scheduler can make use of it.
>     - an additional delivery will be a userland low level formatting utility for both floppy and hard drives.
>   - the disk driver should not retry disk operations on failure (other than a drive reset) and just pass the error status along. retry policy belongs in the disk scheduler as it may affact RAID operation.
> - the disk scheduler works together with the disk driver, root process and os server to do disk scheduling at a system level
>   - it contains the disk cache. together with the root server it should be able to use all unallocated memory as a disk cache. and the root process should be able to reclaim when needed. ideally we have a good eviction algoritm both when the cache is full or needs to be shrunk.
>   - the disk scheduler works together with the os server to achieve fair io scheduling at a process and later user level (the multi-user roadmap will follow this one)
>   - the disk scheduler turn the CHS drives into LBA volumes. for fixed disks this is straigtforward. for removable disks the situation is more complicated.
>     - i would like a macos classic like design here where the disk scheduler turns individual phyiscal floppies into separate volumes exposed to the os server. it could identify different physical floppies by hashing sector zero of a floppy. the disk scheduler would keep track of physically ejected floppies until they are eventually logically ejected by the os/user. this would allow it to keep track of the cache and e.g. flush a write behind cache if a floppy is remove but then reinserted later.
>       - this requires the disk driver to respect the disk changed signal. this pc/at floppy drives should have such signal. but it should be verified that the emulators do.
>       - we should also cater for the case where a floppy is moved from one drive to another w/o unmounting. the logical volume can stay the same from userland's point of view.
>       - if reads from a physically ejected floppy can still be satisfied from the cache. for writes we should probably return an error to the application (so they can e.g. ask the user to reinsert the floppy)
>   - for fixed disks the disk scheduler can do write behind caching (it is up to the os and file system to issue syncs). for floppies we can try the same: the disk scheduler should not turn off the drive light (= motor?) until the cache has been written to disk and not delay writing data to disk.
>   - raid support and logical volumen management is for a future roadmap and is not decided at which level this will sit yet. you may give an opinion as part of this roadmap
> - the os server is responsible for providing file system and vfs services on top of the LBA volumes provided by the disk scheduler
> - key requirements of disk scheduling to be balanced are fairness, throughput and latency
>   - also consider code and data size as rx286 runs on memory constrained systems
> - datasheets can be found under /mnt/h/rx286. let me know if you need any more.
> - please research the literature on disk scheduling algorithm to find a good design
> - one additional note: the fat12 driver looks be case insensitive. this is a mistake. we can do a remapping from upper case (how it should be stored on disk) to lower case (to appear more posix like) but then filename passed to the vfs containing uppper case should be rejected outright to remain case sensitivity and compatibility with fat12.
> - as we support volume for removable drives we should put the drive mounts under /mnt instead of root to avoid name clashes with other folders in root

**The owner's answers while this was written (2026-11-08):**
- **What it rests on:** experiments and a simulator, in the scratchpad, none of it in the
  repository; a milestone puts the simulator into `tools/` (M10).
- **The decisions:** left for the owner, each with options and a recommendation.
- **Where:** one commit on `master`, replacing the draft; not pushed.
- **References:** the agent may fetch what is missing. It fetched:
  - NEC's µPD765 datasheet and application note;
  - Western Digital's 1986 *Storage Management Products Handbook* (the WD1010-05);
  - IBM's *Options and Adapters* volumes 1 and 2 (the AT's diskette drives and fixed disks);
  - the disk models of Bochs 2.7 and MAME 0.264.
- **"wait does the at disk controller support four floppies?"** No: two (*Writing it found*;
  W1).
- **"mame-tools installed":** `chdman` made CHDs of the AT's geometry for MAME (E1, D21).
- **After it was written (2026-11-09):** "please record that i take all decisions as per your
  recommendations", and "i have left mame's source code under /home/ruud/mame/mame so you can
  modify it an create a custom build if to e.g. test the formatter. please implement the
  roadmap and all its milestones".

## What the draft leaves open, contradicts, or makes dangerous

The owner asked for every requirement to be reviewed critically. Each line of the draft is
taken up below or in a decision. Where this roadmap agrees, it says so in the decision.

### Wrong, or true only in part

- **W1. "a single expansion card in the ibm pc/at and share some io ports i suggest combining
  them into a single driver than can handle two floppy drives and two hard drives".** The card
  is one, but:
  - IBM supports at most three drives on it: "up to two fixed drives and one diskette drive or
    one fixed drive and two diskette drives" (adapter manual p. 1). rx286's machine has four
    (`docs/hardware.md`), which the card's connectors allow and IBM did not sell. Its DOR
    selects one of two diskette drives (bit 0; bit 1 "set to a logical 0", p. 12): never four.
  - The ports the two halves share are 3F6h and 3F7h:
    - writing 3F6h is the fixed disk's control register;
    - writing 3F7h sets the diskette's data rate;
    - reading 3F7h gives the diskette's change line in bit 7, and the fixed disk's head and
      drive in bits 0-6, which nothing needs.

    No port is shared by both halves for one purpose, so **sharing them asks for no single
    driver** (D1).
- **W2. "two hard disks can not transfer data in paralel but the can be seeked in parallel
  according to the datasheet".** True: "the adapter supports overlapped seeking on two drives"
  (p. 9), and the WD1010-05's Seek "is primarily used for overlap seek operations on multiple
  drives ... After all steps have been issued ... the command is terminated. Seek complete is
  not checked" (WD 1986 handbook 3-11). But a Seek is a command of the one task file, so it can
  be sent only between commands.
  - **Sent as each request's own first command** ("seek first"), with the other drive served
    while the heads move, it gains 36% with one random reader a drive (44 to 60 KB/s) and 9%
    with two (E10).
  - **Sent only for the other drive's queued requests,** it gains 20% with two readers a
    drive and nothing with one (E6, X5).
  - **No interrupt marks the other drive's seek's end,** and the adapter "will not execute any
    command" while its drive's seek is incomplete (p. 7), so the driver polls for Seek
    Complete (D6).
  - **Whether the adapter's Seek ends with the steps is unverified.** The adapter's manual
    says only "an interrupt is generated at the completion of the command" (p. 9). Bochs
    interrupts after the seek, MAME at once. It is checked on a real AT (*Risks*).
- **W3. "i did not look into the floppy disk controller in detail but the situation may be
  similar".** It is not. The 765 can seek four drives at once, but on the AT the drives'
  select lines (DS1-, DS2-) come from the DOR's select bit, FDSEL (the adapter's logic
  diagram, sheet 4). The manual says only that the 765's US0/US1 are "encoded the same as bits
  0 and 1 of the digital output register" (p. 19). So step pulses reach only the selected
  drive. MAME's model connects every unit to the DOR's drive (`set_floppy`). **The diskettes
  cannot seek at once** (E1).
- **W4. "the floppy and hard drive should have separate controller chips so can be operated in
  parallel".** True: "the adapter will allow concurrent data operations on one diskette and one
  fixed disk drive" (p. 1). Both emulators run a cylinder of A by DMA while C reads a
  cylinder (E3). That was shown for timing; neither transfer's data was checked then.
- **W5. "this pc/at floppy drives should have such signal".** Only the 1.2 MB drive has it.
  IBM's AT Double Sided (360 KB) drive has four outputs: Index, Track 00, Write Protect and Read
  Data (Options and Adapters, *Personal Computer AT Double Sided Diskette Drive*, its outputs). The
  BIOS's INT 13h AH=15h answers 01h, "no change line available", for it (Technical Reference,
  Diskette 5-89). **Drive B cannot see a change** (E2, D12).
- **W6. "it could identify different physical floppies by hashing sector zero".** Only by a
  serial number:
  - DOS before 4.0 writes none;
  - DOS 4's and mformat's come from the time of FORMAT, so twins formatted in the same second
    share it;
  - DISKCOPY copies it.

  Sector 0 with the FAT and the root directory tells more apart, but not all (E9, D12).
- **W7. "the disk drive should assume attached drives are in CHS and their logical CHS
  geomeotry matches their physical CHS geometry".** True of the AT's ST-506 drives behind the
  WD1003-class controller, which translate nothing. But:
  - the geometry must come from the BIOS's drive types, not a table fixed in
    `src/include/disks.inc` (D16);
  - MAME's IDE card, which stands in for the controller, takes a geometry of its own from the
    image's size (82/10/51) and translates for the driver's Set Parameters (E1).
- **W8. "keep one in flight operation in the driver per disk and one or two queued commands".**
  - **One in flight a controller, not a disk:** C and D share one task file, and A and B one
    765.
  - **The next command must be in the driver,** as the draft says.
    - A call that waits in the driver's endpoint is taken only with the reply to the first
      (`KCALL_REPLY_RECV`, about half an IPC, 0.5 ms). By then the next sector at 2:1 has gone
      by: 119 KB/s, against 223 when the driver issues the next run itself the moment the
      current one ends (E10).
    - The driver can hold it: its receive returns calls and its interrupt alike
      (*docs/drivers.md*). So it takes the next call while the current one runs, and replies
      to the first after it has issued the second (D2).
- **W9. "a complete cylinder should be attemted to be processed at a time as the physical disk
  can be assumed to have been layed out by the low level formatter to achieve optimal
  throughput".** True of runs, and the controller follows the interleave by itself (a logical
  sector order). But the layout is not yet optimal:
  - **1:1 interleave is impossible** with one sector buffer (E6). Which interleave is best
    depends on the CPU's time per sector, not yet known for a real AT (E10, D17);
  - IBM's formatter lays every cylinder's sector 1 at the index, with no skew, so each
    cylinder's first sector is just missed after the seek. A skew from rx286's formatter gains
    about a quarter on diskettes, 5 on A and 3 on B (E6, E10; D17).
- **W10. "read between is probably free though ... read the whole cylinder ahead before doing
  the read behind".**
  - **Read-between is free** in time, when it fills a run's gaps on a track the head passes.
  - **Read-behind is never free:** a sector behind the head costs the rest of a revolution. It
    is worth doing only when the disk would idle.
  - **Read-ahead of a whole cylinder costs random readers twice their time** unless it is kept
    for sequential misses (E6, X7; D7).
- **W11. "how this interacts with the disk controller's track buffer (if they have one)".**
  Neither has one. The fixed disk controller has "the sector buffer" (adapter p. 2), filled
  by the drive and emptied by PIO, and interrupts once a sector (p. 9). That it holds one
  sector is an inference from those, likely right. The 765 has no buffer at all: DMA moves
  each byte. Any track buffer is the disk server's (D7, D9).
- **W12. "we should try to achieve fairness between the two drives. i am unsure if the naive
  algoithm above ... guarantees that".** The draft's turn, a cylinder's work then the other
  drive, is the best of the policies tried for C and D (E6, X5). But a drive with one long
  run would hold the controller for as long as the run lasts. A cap on a turn (two cylinders'
  sectors) bounds it (D6).

### Ambiguous, or left open

- **A1. Where the disk scheduler runs.** A server of its own, or a part of the OS server. The
  OS server's space has no room for a cache of segments (502 of its 512 slots, E9), so it is a
  server of its own (D3).
- **A2. "use all unallocated memory as a disk cache ... the root process should be able to
  reclaim when needed".** How the root asks, how long it may wait, and what happens to dirty
  sectors, are left open (D10).
- **A3. "fair io scheduling at a process and later user level".** Fair in what: requests,
  bytes, or the disk's time? Sequential readers need time slices to stay efficient (E6, X3).
  The OS server must tag each request with its process, and later its user (D5).
- **A4. "the disk scheduler turn the CHS drives into LBA volumes".** Its width (today's 16 bits
  end at 32 MB), and who reads the partition table, now the OS server's `vol.c` (D11).
- **A5. "keep track of physically ejected floppies until they are eventually logically ejected
  by the os/user".** How the user ejects logically (a command), and what an open file on an
  offline volume does: reads from the cache, writes `ENXIO`, close and unmount (D12).
- **A6. "a floppy is moved from one drive to another w/o unmounting".** Only a 360 KB diskette
  can move, from B to A or back: A reads it at 300 kbit/s, stepping twice a cylinder (D13). A
  1.2 MB diskette never fits B. A 360 KB diskette written in the 1.2 MB drive's narrower track
  may not read back in a 360 KB drive, as DOS's manuals warn, so in A it is read-only by
  default (D12).
- **A7. "not turn off the drive light (= motor?)".** The light is the drive's select: "the
  Drive-in-Use indicator lights when the drive is selected" (*Personal Computer AT High
  Capacity Diskette Drive*). Only one drive is selected at a time, so the light can guard only
  one diskette. The disk server writes a diskette's dirty sectors before it selects the other
  drive, and keeps the motor and the select on until they are written (D8).
- **A8. "raid support and logical volumen management ... you may give an opinion".** D18.
- **A9. "a userland low level formatting utility for both floppy and hard drives".** Its
  safety, and its testing: a fixed disk's Format Track is aborted on both emulators (E1, D17).
- **A10. "the disk driver should not retry disk operations on failure (other than a drive
  reset)".** The fixed disk controller retries inside a command unless told not to (Read
  Sectors with or without retries). Which the driver asks for is part of the policy (D14).
- **A11. "filename passed to the vfs containing uppper case should be rejected outright".**
  Left open:
  - with which error;
  - whether DOS's `C:` counts;
  - whether `/dev` and `/z` follow;
  - what a lower-case name already on a disk becomes (D19).
- **A12. "put the drive mounts under /mnt".** By drive (`/mnt/a`) or by volume? A volume that
  moves between drives "can stay the same from userland's point of view", so its name cannot be
  its drive's (D20).

### Dangerous

- **X1. Write-behind on a diskette.**
  - The user can take a diskette out at any moment.
  - B cannot even tell that it happened (W5).
  - Twins defeat any fingerprint (W6).

  Dirty data kept past the motor's stop could be written onto another diskette. **No dirty
  data may outlive a diskette's motor and select** (D8, D12).
- **X2. A cache that trusts drive B.** After a swap it would serve the old diskette's sectors,
  and write the old FAT over the new diskette. B's cache must be checked once its motor has
  stopped (D12).
- **X3. Letting the OS server's lock go.** Its tables, the cache and the file system's sectors
  are consistent today only because one thread works at a time. E8 released the lock where
  nothing shared was touched. The rest needs a design (D15).
- **X4. Read-ahead of whole cylinders on a fixed disk.** 68 sectors at 2:1 hold the
  controller for about 134 ms, while another process's request waits. Blind, it doubles a
  random reader's time (E6, X7; D7).
- **X5. The root taking memory back by revoking it.** The root can, since it holds the
  untyped, and the dirty sectors in it would be lost. A request and a reply instead (D10).
- **X6. A low-level format of a fixed disk.** It erases the partition table and every volume,
  and no emulator here can test it (D17).
- **X7. Idling for fairness.** Waiting for a sequential reader's next request raised an
  interactive reader's worst wait from 151 to 302 ms (E6, X4). Idling needs a limit (D5).

### Where this roadmap recommends otherwise than the draft

- **Two drivers, not one** (D1): the ports are not shared for one purpose (W1), each
  controller then has its own thread for free, and each driver keeps one controller's state,
  its next run among it.
- **A diskette is known by sector 0, its FAT and its root directory,** and never holds dirty
  data past its motor (D12).
- **Read-ahead only on sequential misses; read-behind only when the disk would idle** (D7).
- **Mounts are named by volume, `/mnt/<name>`,** with DOS's drive letters for what a drive
  holds (D20).

## Where we are

The disks today, on `master` (529a22f), as *docs/storage.md* and *docs/drivers.md* describe
them:

| Part | Today | Source |
|---|---|---|
| the drives | A 1.2 MB, B 360 KB, C type 2 (615/4/17), D type 1 (306/4/17), every geometry fixed | `src/include/disks.inc` |
| the diskette driver | one sector a call, through a 512-byte DMA buffer; three tries, recalibrating between; the change line not read; A only 1.2 MB media, B only 360 KB | `src/drivers/diskette.asm` (730 lines) |
| the fixed disk driver | one sector a call, PIO into the segment passed; two tries; Set Parameters and Restore at first use | `src/drivers/fixeddisk.asm` (393 lines) |
| their waits | a one-tick timer and a receive per wait, a look at the time each tick | `src/drivers/dwait.asm` |
| the call | `DRV_DISK_READ`, `DRV_DISK_WRITE`: BX the unit, CX a 16-bit sector, SI the offset in the segment passed | `src/include/drivers.inc:77` |
| the cache | 32 sectors in one segment, LRU by a 32-bit clock, a linear search; FAT and directory sectors written at the end of each call, data at close, fsync or eviction | `src/os/cache.c` |
| the lock | every cache call, and so every disk call, made with the OS server's one lock held | `src/os/proc.c:342`, `cache.c:13` |
| the copy | file_move copies a byte at a time, two loads of ES a byte | `src/os/vfs.c:1025` |
| the volumes | a drive's first FAT12 partition, or the whole diskette; mounted at first use | `src/os/vol.c` |
| the names | 8.3, matched in any case, kept upper case; `/a` to `/d` at the root beside `/dev` and `/z`; DOS's `c:` accepted | `src/os/vfs.c:6-10, 238` |
| the tests | `tests/posix/drives`, `files`, `fsrand`, `protected`, `edges*`; `tests/sh/*` on the drives; `tests/memory/dma` | |

What that gives, measured (E5):
- **C:** 30 ms a sector on MAME's AT, 17 KB/s. **A and B:** a revolution or more a sector,
  1.7-2.7 KB/s.
- **One disk request at a time**, whatever the processes.
- **Metadata written at the end of every call:** 537 writes of 34 sectors in fsrand's 400
  operations.

## What the AT and its drives give

| | The fixed disks | The diskettes |
|---|---|---|
| controller | IBM's adapter: a WD1010-class controller, task file 1F0h-1F7h, IRQ14, PIO, "the sector buffer" of 512 bytes (p. 2) | the same card: a µPD765, 3F0h-3F7h, IRQ6, DMA channel 2 |
| drives | two, C and D, with overlapped seeks by the Seek command, which ends once its steps are sent (WD1010-05, 3-11) | two, A and B, one selected at a time by the DOR (p. 12); no overlapped seeks (p. 19, the logic diagram) |
| commands | Read and Write Sectors of 1-256 sectors, across heads and cylinders, with or without retries; Seek, Restore, Format Track (an interleave table of 2 bytes a sector), Set Parameters, Verify, Diagnose (adapter pp. 8-10) | Read and Write Data with MT (both heads), Read ID, Format Track, Seek, Recalibrate, Sense Interrupt Status, Specify (µPD765 datasheet) |
| both at once | "concurrent data operations on one diskette and one fixed disk drive" (p. 1) | |
| shared ports | 3F6h (write: the fixed disk's control), 3F7h (read: bit 7 the change line, bits 0-6 the fixed disk's; write: the data rate) | |
| C: IBM's 20 MB | 3,573 rpm, 615 cylinders, 4 heads, 17 sectors; 2 ms track to track, 40 ms average, 85 ms at most, 12 ms settling, 8.4 ms average latency; buffered seek at 35 µs a step | |
| D: type 1, 10 MB | 306 cylinders, 4 heads, 17 sectors, 3,600 rpm. IBM's 10 MB drive (the XT's, 306/4): 3 ms track to track. The simulator took a slower curve, 20/85/200 ms, from IBM's later 306-cylinder, 8-head drive: a mistake that changes D's absolute numbers and none of the rankings (E10) | |
| A: the High Capacity drive | | 1.2 MB: 360 rpm, 500 kbit/s, 80 cylinders, 96 tpi, 3 ms track to track, 18 ms settling, 750 ms motor start, 83 ms average latency; **a change line** |
| B: the Double Sided drive | | 360 KB: 300 rpm, 250 kbit/s, 40 cylinders, 48 tpi, 5 ms track to track, 20 ms settling, 750 ms motor start, 100 ms average latency; **no change line** |
| the light | | "the Drive-in-Use indicator lights when the drive is selected" |
| a sector under the head | 0.99 ms | A 11.1 ms, B 22.2 ms |
| interleave | set by Format Track's table: IBM's example is 2:1 (adapter p. 9) | 1:1 (DMA keeps up) |
| media in the other drive | | a 360 KB diskette in A: 300 kbit/s, two steps a cylinder (the BIOS's "360K in 1.2M drive" state, Diskette 5-89); a 1.2 MB diskette in B: never |

The 286's side (E4):
- a sector's PIO or a `rep movsw` of it, about 0.26 ms at 6 MHz;
- an IPC call and its reply, about 1 ms;
- an interrupt to the driver's thread, 0.1-0.3 ms (estimated). But **the whole path per sector
  in E7's runs** (the interrupt, `dwait.asm`'s wait, the PIO) took about 2,100 instructions on
  Bochs, and about 2.2 ms on MAME (E7, E10). That is about 2.5 ms on a 6 MHz AT;
- file_move's byte copy: about 9 ms a sector by the clock tables. E7's `memcpy` saved 17.5 ms
  a sector on MAME, so the tables underestimate it;
- the kernel's timer ticks at 50 Hz, so a wait is a multiple of 20 ms unless an event ends it.

What each emulator models (E1):
- **Bochs** has every drive. Its fixed disks have a linear seek and no rotation, and its
  diskettes turn at 300 rpm whatever the drive. It ignores the data rate and changes no media
  at run time.
- **MAME's AT** has diskettes at their drives' real speeds, the data rate checked, and media
  that its Lua script can change. Its IDE card stands in for the fixed disk controller, with
  no rotation, its own geometry, and Seek ended at once.
- **DOSBox-X** has no IRQ6 and no fixed disk.
- **No emulator** models double stepping, a fixed disk's Format Track, or B's missing change
  line.

## What the literature says

The draft asks for the literature on disk scheduling. What this roadmap takes from it:

- **Seek-ordered scheduling.** Denning (1967) gave SSTF and SCAN. Teorey and Pinkerton (1972)
  compared FCFS, SSTF, SCAN, C-SCAN and N-step SCAN:
  - SCAN's family is the best compromise;
  - C-SCAN serves the edges of the disk as well as its middle;
  - SSTF has the best mean and the worst variance.

  Geist and Daniel (1987) put SSTF and SCAN at two ends of one family, V(R). Worthington,
  Ganger and Patt (1994) found LOOK and C-LOOK the best of the seek-based policies on real
  drives. E6
  agrees for the AT: LOOK and C-LOOK keep their maxima bounded, SSTF does not (D4).
- **Rotational position.** Seltzer, Chen and Ousterhout (1990) and Jacobson and Wilkes (1991)
  showed that ordering by access time, seek and rotation together (SATF, SPTF), with aging,
  beats seek-only orders. It needs the head's angle, which the AT can learn only with a Read
  ID. The draft puts this off until a real AT can be measured, and E6 finds the formatter's
  skew gives as much on diskettes (*Later*).
- **Deceptive idleness.** Iyer and Druschel (2001): a process that reads sequentially and
  synchronously leaves the disk idle for a moment between its requests. A work-conserving
  scheduler then moves the heads to another process's request and back. Waiting a few
  milliseconds for the same process ("anticipation") restores sequential throughput. E6 finds
  40 against 116 KB/s for two such readers on C (D5).
- **Proportional shares.**
  - YFQ (Bruno et al., 1999) and SFQ(D) (Jin, Chase and Kaur, 2004) give each client a share
    by fair queuing, with a limit D on requests outstanding at the disk.
  - Cello (Shenoy and Vin, 1998) schedules classes of requests in two levels.
  - Linux's CFQ (Axboe, 2003) gave each process time slices.
  - BFQ (Valente and Checconi, 2010) gives each process a budget of sectors, serves it in
    sector order, idles for it, and favours interactive and soft real-time processes. Its
    budgets are what keeps fairness from costing throughput.

  rx286's "BFQ-lite" (D5) keeps BFQ's budgets and idling and drops its timestamps, which a
  machine with tens of processes does not need.
- **Deadlines.** Linux's deadline scheduler (Axboe, 2002) serves a sorted order but takes any
  request that has waited past its expiry first (reads 500 ms, writes 5 s). Under the heavy
  random load of E6 a short expiry becomes FCFS. So the deadline is a safety net, not the order
  (D4).
- **Disk models.** Ruemmler and Wilkes (1994): a seek curve rising with the square root of the
  distance for short seeks, rotation, the controller's buffer. E6's model follows them.
- **Layout.** The BSD Fast File System (McKusick et al., 1984) placed consecutive blocks
  `rotdelay` apart so that the CPU could keep up. That is the interleave and skew of D17, at
  the file system's level instead of the formatter's.
- **Caching.**
  - LRU-K (O'Neil, O'Neil and Weikum, 1993) and 2Q (Johnson and Shasha, 1994) resist scans: a
    block read once does not push out blocks read often.
  - ARC (Megiddo and Modha, 2003), CAR (Bansal and Modha, 2004), LIRS (Jiang and Zhang, 2002)
    and CLOCK-Pro (Jiang, Chen and Zhang, 2005) adapt the balance themselves. IBM held a patent
    on ARC, which is why PostgreSQL replaced it with 2Q in 2005.
  - E6 finds 2Q and ARC twice LRU's hits in a small cache under scans, and 2Q in 473 bytes of
    code (D9).
- **Read-ahead and write-behind.** Smith (1985) measured disk caches, prefetching sequential
  data, and delayed writes. Ousterhout et al. (1985) found most files read whole and in order,
  and a large part of the data written deleted or overwritten within minutes. That is why
  delaying writes merges them (D7, D8).
- **Volumes.**
  - The classic Mac OS (Inside Macintosh: Files) keeps a volume control block for each mounted
    volume, whether its disk is in a drive or not ("offline"). When an offline volume is
    needed, it asks the user for the disk by name. It could, because the Mac ejected its disks
    itself.
  - AmigaDOS named volumes too ("Please insert volume ... in any drive"), with drives that
    sensed a disk's insertion.
  - MS-DOS, on drives without a change line, has its block driver answer Media Check with
    "don't know". MS-DOS's own diskette driver assumes no change within about two seconds of
    the last access, and otherwise checks the volume's label and serial before it trusts its
    buffers.

  rx286 takes the Mac's volumes and DOS's caution (D12).
- **FAT names.** Microsoft's FAT specification (fatgen103, 2000) stores short names in upper
  case; lower case is not valid in them. Windows NT shows an all-lower-case base or extension
  by two flags in the entry's byte 0Ch (bits 3 and 4), which Linux's `vfat` honours too. They
  are a way to show `readme.txt` without breaking DOS (D19).

## The experiments

Each ran in the scratchpad, against copies of `master` (529a22f), on Bochs 2.7, MAME 0.264's
IBM 5170 and the simulator. Each has a README with its method and result. None of their code
is in the repository.

| | Question | Answer |
|---|---|---|
| E1 | What do the emulators model? | Bochs and MAME: no fixed disk rotation, Format Track aborted, MAME's IDE geometry from the image's size (82/10/51), the AT's with a CHD; MAME's diskettes turn at the drives' speeds; no double stepping anywhere; DOSBox-X has neither controller |
| E2 | The change line and media | only A's drive has one; on MAME an eject sets it and a step with a diskette in clears it; Bochs cannot change media at run time; MAME refuses 360 KB media at 500 kbit/s and reads it at 300 |
| E3 | The controllers' commands | multi-sector reads of 17-120 sectors across heads and cylinders, and whole-cylinder MT reads through a 15 KB DMA buffer, right on both; both controllers at once; Format Track on diskettes only |
| E4 | The 286's costs | an IPC call and reply about 1 ms, a sector's PIO 0.26 ms, file_move's byte copy about 9 ms a sector (estimate) |
| E5 | What rx286 does today | C 30 ms a sector on MAME (17 KB/s), about 20,000 instructions on Bochs; a diskette sector more than a revolution; FAT sectors rewritten 78 times in 400 operations; one request at a time |
| E6 | The simulator | runs at 2:1 about 200 KB/s on C; 1:1 impossible; C-LOOK; anticipation and budgets for sequential readers; the draft's turn between C and D; read-ahead on sequential misses only; write-behind of 5 s; 2Q |
| E7 | Runs through the drivers (a prototype) | C 9.4 times, A 7.9 times faster on MAME, for 233 lines; the memcpy alone 2.5 times on writes |
| E8 | The OS server without its lock (a prototype) | a reader of C beside a reader of A: 7.5 s with the lock, 3.4 s without, 1.5 s alone; all 133 Bochs tests pass |
| E9 | Names, identity, the cache's memory | case-sensitive names: 10 lines, 15 tests to change; sector 0 does not identify a diskette; the cache needs a server of its own |
| E10 | An independent check | 25 findings, all fixed: the interleave rests on the CPU's time a sector, which E7 puts at about 2.5 ms; the next command must be held by the driver; seek first; D5's idling and an idle process's turn; write-behind's evidence was a diskette's; D15's holes; page numbers |

### E1. What the emulators model

**Method.**
- Bochs' `iodev/floppy.cc` and `harddrv.cc`, and MAME's `upd765.cpp`, `isa/fdc.cpp`,
  `atastorage.cpp` and `imagedev/floppy.cpp`, read at the versions installed here.
- A probe: a real-mode boot image that drives both controllers directly, times every command
  with the PIT, and checks every sector it reads against the images. It ran on both emulators.

**Result.**
- **Fixed disks: no rotation anywhere.**
  - Bochs seeks for 5 ms times the LBA distance over the disk's size and reads 68 sectors in
    5.5 ms.
  - MAME's IDE card seeks 13 ms times the cylinders over its own count, plus 1.3 ms, and reads
    68 sectors in 21 ms: its PIO. MAME answers Seek at once.
  - Both abort Format Track (error 04h).
- **MAME takes the geometry from a raw image's size:** C as 82 cylinders, 10 heads, 51
  sectors (IDENTIFY), D as 34/12/51. It translates the driver's CHS after Set Parameters, so
  the data is right. Its seek model then runs on 82 cylinders, and once a read at cylinder
  600 was followed by a failed one.
- **CHDs fix the geometry, not the timing.** The owner installed mame-tools. With CHDs made
  by `chdman createhd -c none -chs 615,4,17` (and 306,4,17):
  - IDENTIFY gives the AT's geometry;
  - the read at cylinder 600 takes 14.4 ms instead of 96, with no failure;
  - rx286's drives, cat and damaged tests pass, the CHDs extracted back to raw images for the
    runner's checks (D21).
- **Diskettes.**
  - MAME's turn at 360 and 300 rpm: a sector 150 ms, a track 306 ms, a cylinder 462 ms on A.
  - Bochs' all turn at 300 rpm: a track 200 ms, at any data rate.
  - Bochs panics on a Format Track of another sector count than the media's.
- **Neither models 48-tpi media in the 96-tpi drive:** cylinder 1 is found at track 1.

### E2. The change line and media

**Method.**
- IBM's drive documents (Options and Adapters vol. 1) and the BIOS listing.
- The probe again. MAME's Lua script unloads and loads an image when the probe asks for it on
  its log line. A 360 KB image goes into A by the same means.

**Result.**
- **The documents:** the High Capacity drive has '-Diskette Change', "active unless a
  diskette is present and a step pulse is received". The Double Sided drive's outputs are
  Index, Track 00, Write Protect and Read Data, and the BIOS reports "no change line available"
  for it.
- **On MAME:**
  - DIR bit 7 is 0 with a diskette after a step. It reads 80h once the diskette is taken out,
    and stays 80h after it is put back until a seek, as the document says. MAME gives B the
    line too.
  - A Read ID on an empty drive fails after a revolution or two (ST0 40h). A seek on the empty
    1.2 MB drive got no interrupt within 3 s.
  - **Media:** a 360 KB diskette in A gives no ID at 500 kbit/s and gives one at 300 kbit/s.
- **On Bochs** the line is set at power-on, on B as well, until the first step.

### E3. The controllers' commands

**Method.** The probe, on both emulators, each sector checked against the images.

**Result.**
- **The fixed disk:** one Read Sectors of 17, 68 and 120 sectors, from a cylinder's start or
  across a cylinder's end, reads the right data.
- **The diskette:**
  - one Read Data of a track (15 sectors) and one of a whole cylinder (30, with MT, 15 KB by
    DMA at 20000h) read the right data;
  - Format Track and a read back work;
  - on MAME A reads a sector in 150 ms, a track in 306, a cylinder in 462; B a track in 374, a
    cylinder in 582.
- **Both at once:** a cylinder of A and one of C at once run on both emulators (C took
  22.6 ms inside A's 425 ms on MAME). Only the timing was checked, not either transfer's data.
- **MAME was flaky once in three runs:** after the fixed disk's tests, a cylinder read of A
  timed out. The diskette tests alone passed every time. The cause was not found: MAME's IDE
  card answers 3F6h, as the real adapter's fixed disk does, and 3F7h stays the diskette's
  (*Risks*).

### E4. The 286's costs

**Method.** Intel's clock tables (210498-005, appendix B), the AT's bus cycles (Technical
Reference 1-6), l4.md L4's IPC measurement, and file_move's compiled code (`vfs.dis`).

**Result.**
- A sector passes the head in 0.99 ms on C, 11.1 ms on A and 22.2 ms on B.
- `rep insw` or `rep movsw` of a sector takes about 1,540 clocks, 0.26 ms at 6 MHz.
- An IPC call and reply: 872 instructions, about 1 ms on MAME.
- **file_move's copy:** 17 instructions a byte, with two loads of ES at 19 clocks each, about
  106 clocks a byte: **about 9 ms a sector** (estimate). memory-far.asm's `memcpy`, in the same
  library, does it in 0.26.
- **So a call per sector costs about a sector time in IPC alone.** The fixed disk controller,
  with one sector buffer, then loses a revolution per sector at 1:1 and 2:1.

### E5. What rx286 does today

**Method.**
- A trace in the OS server's cache (`TEST_DISK_TRACE`): every hit, read and write, by thread
  and tick.
- Workloads: the shell reading, copying and running two readers at once; fsrand.
- `rdtime`, a test program that times whole files read and written in calls of 512 bytes and
  of 4 KB.

**Result.**
- **C:** 3,380 ms for 113 sectors on MAME (30 ms a sector), 580 ms on Bochs (20,000
  instructions a sector).
- **B:** 216 ms between consecutive sectors read, 288 ms a sector written.
- **fsrand** made 537 writes of 34 sectors, B's two FAT copies' first sectors 78 times each.
- **Hits:** 26-65% for the shell's work, 99.8% for fsrand.
- **Three processes' accesses interleave call by call,** one disk call at a time.

### E6. The simulator

**Method.** `sim/` (Python, no packages) is a discrete-event model of the machine:
- the CPU's costs from E4;
- the fixed disk controller: one task file and one sector buffer, Seek between commands;
- C and D's seek curves and rotation;
- the 765 with A and B, DMA, MT and no overlap.

It runs schedulers, workloads and E5's traces; a cache model compares eviction policies, and
C sketches give their code size.

**Result.**
- **One sequential reader of C, by interleave:**

  | Interleave | today | runs of 4 KB | track runs | cylinder runs |
  |---|---|---|---|---|
  | 1:1 | 14 KB/s | 28 | 28 | 28 |
  | 2:1 | 14 | 119 | 167 | 201 |
  | 3:1 | 14 | 96 | 125 | 144 |

  - One sector a call at 3:1 reaches 155 KB/s, by 0.16 ms of slack, and 25 KB/s once a
    second server adds an IPC hop.
  - **All of it rests on 0.56 ms of CPU a sector** (E4's estimate). E10's runs:

    | CPU a sector | 2:1 | 3:1 | 4:1 |
    |---|---|---|---|
    | 0.56 ms | 201 KB/s | 144 | 112 |
    | 1.2 ms | 26 | 144 | 112 |
    | 2.2 ms (E7's runs, on MAME) | 26 | 25 | 112 |

  - **Queued runs need the next command held by the driver:** 223 KB/s at 2:1, against 119
    when the driver takes it from its endpoint after replying (E10). E6's own row for a queued
    next command had a synchronous reader, so nothing was ever queued.
  - On A, a cylinder a command gives 27 KB/s against 2.8 today. A skew of 5 gives 33.6 KB/s,
    and on B 3 gives 17.2 against 13.8. These hold across rx286's settling of 20-40 ms; the
    skews of 4 and 2 first tried fall below no skew at 40 ms (E10).
- **Random readers on C:** LOOK and C-LOOK give up to 53% more than FCFS, with bounded
  maxima. SSTF's maximum is 1.7 s.
- **Two sequential readers on C:**
  - C-LOOK: 40 KB/s;
  - anticipation: 116 KB/s, one after the other (Jain 0.90);
  - budgets of 136 sectors with one tick's idling: 106 KB/s (Jain 0.997, p95 55 ms, at most
    737 ms).
- **An interactive reader beside a greedy scan:** mean 85 ms and at most 151 whatever the
  order. Idling for the scan raises them to 153 and 504 ms at a budget of 136 (E10). Letting a
  process that was idle for 50 ms end the turn keeps 92 and 158, and the two sequential
  readers' 105 KB/s (E10).
- **C and D:**
  - overlapped seeks for the other drive's queued work add 20% with two readers a drive, and
    nothing with one;
  - each request's own Seek first, the other drive served meanwhile, gives 60 KB/s in both
    cases: +36% with one reader a drive (E10);
  - beside a write-behind flush on D, a reader of C gets 32 KB/s by FIFO between the drives
    and 98 by the draft's turn.
- **Read-ahead** to the cylinder's end, on sequential misses only: a sequential read of C in
  1.37 s against 5.31, random reads unchanged. Blind, random reads take twice as long.
- **Write-behind:**
  - fsrand's 537 writes, all on B, become 206 sectors in 129 runs after 5 s;
  - but D8 writes diskettes at once. On the fixed disks' traces 5 s writes 14-22% fewer
    sectors in 4-10 times fewer commands (E10).
- **Eviction** under scans, at 128 and 512 sectors: LRU 7.4% and 12.2%, 2Q 14.7% and 23.0%,
  ARC 14.5% and 24.4%, out of 26.6% possible. Code: LRU 242 bytes, CLOCK 136, 2Q 473, the hash
  192. A record is 12 bytes a block.
- **What the model leaves out:**
  - contention for the CPU between processes;
  - D's real curve (its 20/85/200 ms are a later, slower drive's: E10);
  - a linear part for long seeks: its longest is 70 ms against IBM's 85.

  X7's reader waits for the whole read-ahead, which is pessimistic. With BFQ on, the drives'
  turn is not modelled; the two were never simulated together (E10).

### E7. Runs through the drivers

**Method.** A prototype of 233 lines in a copy of `master`:
- **the call:** `DRV_DISK_READ` and `DRV_DISK_WRITE` take a count in DI;
- **the fixed disk driver** sends one command for up to 64 sectors;
- **the diskette driver** sends one a cylinder, with MT, through a 15 KB DMA buffer the root
  gives it;
- **the OS server** reads whole sectors straight into the process as a run of contiguous
  clusters, and copies with `memcpy`.

rdtime (6 files) on Bochs and MAME, and the disk tests, ran against it.

**Result (MAME):**

| | master | the prototype |
|---|---|---|
| C, reads of 15 KB | 2,820 ms | 300 ms (190 KB/s) |
| A's KERNEL.BIN, reads of 15 KB | 33,820 ms | 4,300 ms (22 KB/s) |
| B, 48 KB read back | 21,640 ms | 6,720 ms |
| D, 32 KB written | 1,860 ms | 740 ms (memcpy alone) |

- B's writes are unchanged: they still go through the cache a sector at a time.
- The drivers grew by 89 and 137 bytes of code.
- MAME's diskette, the only real rotation, matched the simulator's 21-27 KB/s.
- **The path per sector in a run:** about 2,100 instructions on Bochs (C's 113 sectors in
  60 ms at 4 million instructions a second), mostly `dwait.asm`'s calls for each sector's
  wait. On MAME about 2.2 ms a sector, once the calls' share is solved out of the 4 KB and
  15 KB runs (E10).

### E8. The OS server without its lock

**Method.** The prototype of E7, with the lock given up around the direct reads, which touch
neither the cache nor the file system's tables. `rdpar` reads C ten times alone, then again
while a child reads A's KERNEL.BIN.

**Result (MAME):**

| | C alone | C beside A |
|---|---|---|
| master | 14.0 s | 49.5 s |
| E7 | 1.5 s | 7.5 s |
| E8 | 1.5 s | 3.4 s |

- The 133 Bochs tests all pass.
- What still binds is A's FAT and directory sectors, read under the lock.
- Not shown:
  - the cache's busy slots;
  - two processes changing one directory;
  - a description shared by fork.
- **Holes in the prototype itself** (E10):
  - a truncation by another process can free the clusters a lock-free read is still filling;
  - the process can be killed during the wait, since E8 skips `proc_lend` and `proc_still`,
    which `tty_write` uses around its own release;
  - one static `io_proc` serves every thread.

  D15 closes them.

### E9. Names, identity and the cache's memory

**Method.**
- **Names:** case-sensitive names in a copy of `vfs.c`, then the whole Bochs suite.
- **Identity:** mtools images formatted and changed as another machine would, and their
  fingerprints compared.
- **The cache's memory:** the slots, records and zeroing, from the code and earlier roadmaps.

**Result.**
- **Names:** 118 of 133 pass. The 15 others expect capitals (HELLO.TXT, /c/DOCS$, getcwd's
  /b/MANY), and none fails otherwise.
- **Identity:** sector 0 tells blank diskettes apart only by a serial, which DOS before 4
  never writes and mformat takes from the time. Sector 0 with the FAT and the root tells more
  apart, but not a twin, a change in a subdirectory, or data overwritten in place.
- **The cache's memory:**
  - the OS server's space has 10 slots free, so a cache of segments needs a space of its own;
  - with the records at the head of each 64 KB segment (125 sectors and their 125 records,
    65,500 bytes), DGROUP holds only the hash;
  - zeroing a 64 KB segment costs about 26 ms of CPU, in interruptible pieces.

### E10. An independent check

**Method.** A fresh agent:
- read the draft whole, with every experiment's README and result;
- checked more than 30 of its cited claims against the datasheets, the BIOS listing, the code
  and the results files;
- reran the simulator, in a copy, with changed assumptions:
  - 12 ms more settling;
  - 1.2 and 2.2 ms of CPU a sector;
  - calls of 2 ms and two hops;
  - C's curve on D;
  - another seed;
  - Seek Complete found by a tick's poll;
  - Linux's deadline batches.
- tried fixes: an idle process ending the turn, each request's Seek first, the next command
  held by the driver.

It stopped twice at a rate limit, and its review was finished from its saved results.

**Result:** 25 findings, 4 high (`exp/E10/review.md`). Every one is fixed in this roadmap:
- **The interleave and the headline speed** rested on 0.56 ms of CPU a sector. E7's own runs
  say about 2.2 ms, at which 2:1 gives 26 KB/s and only 4:1 keeps up. So M2 cuts the path and
  measures it, and the formatter measures before it chooses, 3:1 without (D2, D17).
- **Write-behind's evidence was a diskette's,** where D8 writes at once. On the fixed disks
  it is 14-22% fewer sectors and 4-10 times fewer commands (D8, M6).
- **D5's idling raised an interactive reader's worst wait to 504 ms,** and its rule for greedy
  readers either never fired or undid the gain. An idle process now ends the turn (D5).
- **D15 had holes:**
  - a truncation while a lock-free transfer runs;
  - a process killed during the wait;
  - the order of the locks;
  - two caches of one sector.

  D15 now closes each.
- **The medium findings:**
  - **the next command:** held by the driver, as the draft says (W8, D2);
  - **seek first** (W2, D6);
  - **the deadline:** with Linux's batches (D4);
  - **D's seek curve:** the wrong drive's;
  - **M3's cache** without extended memory (M3);
  - **a stale clean cache** after a diskette change (D12);
  - **D4-D6 together:** their composition (*The disk server*);
  - **the test's end:** a sync with interrupts on, and a way to stop without one (*Testing*);
  - **double stepping:** detected by Read ID (D13);
  - **the skews:** 5 and 3, not 4 and 2 (D17).
- **The low findings:** the adapter's page numbers (its numbers are at the foot of each page),
  W3's citation, AH=08h's cylinders (D16), MAME's ports, the cache's arithmetic, D19's trapped
  names, D20's labels, the owner's "return 3 4 7 8 9 as early as possible" (D7), Ctrl+Alt+Del
  (M6).
- **What held:**
  - E6's rankings under every changed assumption, at the interleave the CPU keeps up with;
  - every number the agent checked in E5, E7, E8 and E9;
  - IBM's documents on the drives, the change line and the adapter.

## Constraints

- **Memory.**
  - rx286 must still boot the least machine memory.md found: about 376 KB of base memory for a
    release image, with no extended memory. The disk server then has a cache of a few tens of
    kilobytes and must work with it.
  - On a machine with extended memory it may grow to what the root can spare.
- **Code.**
  - Drivers stay in NASM, in ring 1.
  - Servers are C, Watcom's compact model, on the parts memory.md M5 and M6 built (the
    server's start, its stacks, its lock; memory.md D10, D11).
  - Every part of the server that a test can reach on the host (the scheduler's choices, the
    cache's eviction, the volumes' fingerprints) is C with no rx286 call in it, compiled for
    the host too, as `src/root/buddy.c` is.
- **Time.**
  - Interrupts stay on: the drivers run in ring 1 with interrupts on, and a 15 KB copy is
    about 8 ms of CPU, not of interrupts off.
  - The timer ticks at 50 Hz. A wait the disk server sets ends at an event when one comes,
    otherwise at a tick.
- **Testing.**
  - No emulator gives the fixed disks' timing.
  - MAME is the only one with diskette timing and media changes.
  - The simulator is the timing oracle, and the emulators are the correctness oracle (*Testing*).
- **Compatibility.** The disks stay FAT12 volumes that DOS reads and writes. Nothing rx286
  writes may make a diskette unreadable to DOS. That holds for a formatter's skew, which DOS
  reads; the interleave of a fixed disk too.

## The architecture

```
 processes ── PX calls ──> OS server  (paths, FAT12, the descriptions; a lock per volume
                              │         for its metadata; no lock across a disk wait)
                              │  DS_READ / DS_WRITE / DS_SYNC ... : a volume, a 32-bit
                              │  sector, a count, a segment, the process
                              v
                          disk server (volumes, the cache, the queues, read-ahead,
                              │         write-behind, retries)
                 ┌────────────┴────────────┐
                 v                         v
        the fixed disk driver      the diskette driver
        (C, D: runs, Seek, ...)    (A, B: cylinders, Read ID, the change line, ...)
                 │                         │
        WD1010-class controller     µPD765 + DMA channel 2
```

### The drivers and their calls (M2; D1, D2, D16)

The two drivers stay two (D1). Each drives one controller, with no retries beyond a reset (the
draft's). It holds one run in flight and the next one: its receive returns calls and its
interrupt alike, so it takes the next call while the current run goes on, issues it the
moment the current one ends, and then replies to the first (W8). The calls become (D2):

| Call | In | Out |
|---|---|---|
| `DRV_DISK_READ`, `DRV_DISK_WRITE` | BL the unit, BH the head; CX the cylinder; DI's low byte the sector (from 1), its high byte the count; SI the offset in the segment passed | BX 0 or the error; CX the sectors done |
| `DRV_DISK_SEEK` | BL the unit, CX the cylinder | at once once the steps are sent (fixed disks); after the seek and its sense (diskettes) |
| `DRV_DISK_READ_ID` | BL the unit, BH the head | the ID found: CX the cylinder, DL the head, DH the sector (diskettes) |
| `DRV_DISK_FORMAT` | BL the unit, BH the head, CX the cylinder; the table in the segment passed (2 bytes a sector for the fixed disks, 4 for the diskettes); DI the sectors and the gap | BX 0 or the error |
| `DRV_DISK_STATUS` | BL the unit | the change line (A), write protection, the media's data rate, the cylinder the driver believes, Seek Complete (fixed disks) |
| `DRV_DISK_MEDIA` | BL the unit, BH the media (1.2 MB; 360 KB in A, stepping twice; 360 KB in B) | |
| `DRV_DISK_RESET` | | the controller reset, every unit's cylinder forgotten |

Limits:
- **Runs:**
  - the fixed disk driver takes up to 64 sectors (32 KB), across heads and cylinders, as the
    controller does;
  - the diskette driver takes up to a cylinder (30 sectors on A, 18 on B), through a DMA
    buffer of 15 KB that the root gives it within one 64 KB page;
  - the diskette driver refuses a run past a cylinder, since the disk server splits them.
- **The next command:** the disk server keeps two calls outstanding a controller, and the
  driver holds the second. At 2:1 that is 223 KB/s against 119 for the endpoint's queue
  (E10).
- **The path per sector** must take less than a sector's time for 2:1 (0.99 ms), or two for
  3:1:
  - one receive for the interrupt, its acknowledgement, and the PIO;
  - the timer armed once per command, not per sector;
  - no `KCALL_TICKS` per sector.

  E7's runs, still on `dwait.asm`'s waits, took about 2,100 instructions a sector on Bochs,
  about 2.5 ms on a 6 MHz AT (an estimate).
- **The geometry** comes from the BIOS, through the boot information (D16). The loader asks
  for each fixed disk's parameter table through the INT 41h and 46h vectors: cylinders, heads,
  sectors, the precompensation cylinder and the control byte. AH=08h is not enough: it
  answers two cylinders fewer ("SUB AX,2 ; ADJUST FOR 0-N") and has no precompensation. For
  each diskette drive the loader asks AH=15h for its type and change line. That is memory.md's
  *Later* item, "the drives' geometry".

### The disk server (M3; D3, D4, D6, D11, D14)

A server of its own (D3), in C, with its own space. That gives it room for the cache's
segments: the OS server has 10 slots left (E9). It holds:

- **volumes:** a fixed disk's partitions (the master boot record moves here from `vol.c`), and
  each diskette (D12). Each is addressed by a 32-bit sector from 0 (D11);
- **a queue for each drive,** ordered by C-LOOK (D4), with a deadline as a safety net (reads
  500 ms, writes 5 s, from Linux's deadline scheduler);
- **the controller's turn** (D6): for C and D, a cylinder's work, then the other drive's. A
  request that needs a seek begins with its own Seek command ("seek first", W2). While its
  heads move, the controller serves the other drive. A turn ends after two cylinders'
  sectors. For A and B, a drive's dirty sectors are written before the other drive is
  selected (A7);
- **fair shares** between processes (M5; D5). **The order of the choices:**
  1. an expired deadline first;
  2. then the process whose turn it is (D5);
  3. within its requests, the drive's turn (D6);
  4. within a drive, C-LOOK (D4).

  M5's host test runs them together; E6 simulated each alone;
- **read-ahead and write-behind** (M6; D7, D8);
- **the cache** (D9), in memory the root lends (M7; D10);
- **retries** (D14): the fixed disk controller's own retries inside a command, then one reset
  and one try more. On a diskette, three tries with a recalibration between, as the BIOS does.
  A run that fails is split to find the sector, so that a bad sector costs one sector, not the
  run.

Its threads:
- **one receives** the OS server's calls, saves the replies (`KCALL_SAVE_REPLY`) and queues
  the requests;
- **one for each controller** calls its driver and answers the requests it completes;
- **one wakes** each second for write-behind.

They share the server's lock (memory.md M6's `server_lock`), which none holds across a call
to a driver.

### The OS server's side (M1, M4; D15, D19)

- **The calls to the disk server:** `DS_READ`, `DS_WRITE`, `DS_SYNC`, `DS_VOLUMES` and
  `DS_EJECT`. A read or write carries the volume, the sector, the count, the process's data
  segment and offset (the disk server copies once, from its cache into the process), the
  process (for its share, D5), and whether the process waits for it.
- **The FAT and the directories** stay in the OS server's 32-sector cache. It changes their
  bytes in place, written through to the disk server, which then holds them dirty (write-behind
  of metadata, D8). A file's data never enters the OS server.
- **The lock** (D15): the OS server gives its one lock up while it waits for the disk server.
  - A **lock for each volume** keeps one volume's metadata changes one at a time. A call that
    changes a volume's FAT or directories holds it from start to end.
  - A **read of a file's data holds no lock** while it waits. Two volumes, and the data of two
    files, proceed at once.
  - **Every wait is guarded** as `tty_write` guards its own today: `proc_lend` before,
    `proc_still` after, and a reference on the description across it, so that a process
    killed meanwhile is noticed and its description is not reused under it (E10).
  - **Each file counts its transfers in flight.** A truncation, or freeing its chain, waits
    for them to end, so that no read lands in clusters given to another file and no write
    corrupts it (E10).
  - **The order of the locks:** a thread never waits for a volume's lock while it holds the
    global one; it gives the global lock up first.
  - **Freeing a cluster drops** the OS server's cached sectors of it, so that a directory's
    sectors do not outlive it into another file's data.
  - A **description shared by fork** keeps its offset under the description's own flag, so
    that two reads through it do not take the same bytes.
- **Names** (D19): stored upper case, shown lower case, an upper-case letter refused (EINVAL).
- **The mounts** (D20): every volume under `/mnt/<name>`, by its label; DOS's `a:` to `d:` for
  whatever volume a drive holds now.

### The cache (M3, M7; D9, D10)

- **Blocks of a sector.** The cache lives in segments of 64 KB:
  - 125 sectors, and at the segment's head their 125 records of 12 bytes, 65,500 bytes in
    all;
  - a record holds a 32-bit key of volume and sector, three links, the state and a reference
    bit.
- **The hash:** 2 bytes a bucket (a segment and a slot). It is in DGROUP at a small cache, and
  in a segment of its own once the cache grows past 1,024 buckets, with a bucket for every
  two blocks. At 14 MB (28,000 sectors) that is 28 KB.
- **2Q** (D9): a FIFO of a quarter of the blocks for blocks seen once, an LRU for blocks seen
  twice, and a ghost list of the keys of half the cache's blocks.
  - **The ghosts** are 4 bytes each, in segments of their own like the records, and found by
    the same hash, not by a scan (56 KB at 14 MB).
  - Dirty and busy blocks are not evicted. A busy block (being read) holds its waiters.
- **The root lends memory in blocks of 256 KB,** four segments each (D10). It asks for blocks
  back with a notification; the disk server writes their dirty sectors, deletes its segments
  and answers. The server keeps a reserve of clean blocks so that it can answer at once, and
  the root waits with a deadline, after which the allocation fails (ENOMEM) rather than lose
  data.

### Removable volumes (M8; D12, D13, D20)

- **A diskette's volume** is known by a fingerprint: a hash of sector 0, the first FAT and the
  root directory, with the serial number when there is one.
  - On insertion (A's change line), or on B's first access after its motor stopped, the disk
    server reads sector 0 and the first FAT sector, and the whole fingerprint when those differ.
  - A known volume comes back online with its cache. An unknown one is mounted anew.
- **A volume whose diskette is gone stays known** (offline) until the user ejects it (`eject
  /mnt/<name>`):
  - its clean sectors still serve reads;
  - writes fail with ENXIO.
- **No dirty data outlives a diskette's motor** (D8): a diskette is written before its motor
  stops and before the other drive is selected. So an offline volume never has unwritten data.
- **A 360 KB volume may move from B to A,** read at 300 kbit/s with two steps a cylinder (D13).
  In A it is read-only unless the owner decides otherwise (A6).

### The formatter (M9; D17)

A program, `format`, through the disk server, which refuses a mounted volume.
- **A diskette:** 1.2 MB in A, 360 KB in B (or in A, stepping twice), with Format Track a
  track at a time, a cylinder skew of 5 on A and 3 on B, then a FAT12 volume DOS reads. Those
  skews hold across rx286's settling of 20-40 ms; 4 and 2 lose at 40 ms (E10).
- **A fixed disk:** Format Track a track at a time, a skew, and the tracks the controller
  refuses recorded as bad clusters. Its interleave is measured first: `format` times rx286's
  service of a sector in a run, and takes the smallest interleave whose gap exceeds it, with a
  margin; 3:1 without a measurement (D17). It asks for confirmation, and is tested on the host
  and not on the emulators, which abort it (E1).

### RAID and LVM: an opinion (D18)

They belong in the disk server, below the cache and above the queues:
- a mirror's reads go to the drive whose heads are nearer;
- its retries go to the other drive;
- its writes go to both.

The OS server, which sees volumes, need not know. C and D are on one controller that transfers
one at a time, so a mirror on the AT doubles each write's time and gains only seeks. Striping
gains nothing. The reason would be safety, not speed, and that is for a roadmap of its own.

### Sizes (estimates)

| Part | Today | After (estimate) |
|---|---|---|
| the fixed disk driver | 765 bytes of code | about 1,100 (E7: 854 with runs alone) |
| the diskette driver | 1,221 bytes of code, a 512-byte DMA buffer | about 1,700, a 15 KB DMA buffer |
| the disk server | none | 10-14 KB of code, 4-6 KB of DGROUP, stacks of 1 KB a thread, the cache beside, sized at boot from what the processes' reserve leaves (M3) |
| the OS server | 46,009 bytes of code (release) | about the same: `vol.c`'s partitions out, the calls and the locks in |

## Testing

**Who answers what:**
- **The emulators decide whether it is right:**
  - Bochs runs every drive;
  - MAME runs the diskettes at their real speed and can change media;
  - DOSBox-X runs no disk test.
- **The simulator decides whether it is fast:** no emulator has a fixed disk's timing (E1).
  MAME's diskettes are the one place where the two can be compared, and they agree (E7).
- **The host decides the policies:** the disk server's scheduler, cache and volume code is C
  without rx286 calls (*Constraints*). It is compiled for the host and tested there, as
  `tests/unit/c/test_buddy.c` tests the root's allocator. `tools/disksim` (M10) drives that same
  C, through `ctypes`, against the simulator's drives, so the numbers of E6 become a regression
  test of the real code.

**What the suites gain:**

| Test | What | Where |
|---|---|---|
| `tests/disk/runs.test` | runs of every length, across tracks and cylinders, read and written on every drive, compared with the host's images | Bochs, MAME |
| `tests/disk/speed.test` | `rdtime`'s workload against budgets, in reads of 15 KB: A's 96 KB within 6 s, B's 48 KB within 8 s, C's 58 KB within 0.6 s on MAME; begun in M1 with a 32 KB write to D | MAME |
| `tests/disk/beside.test` | `rdpar`: C beside A at most three times C alone | Bochs, MAME |
| `tests/disk/fair.test` | two sequential readers of one file each on C, both done, neither more than twice the other's time | Bochs, MAME |
| `tests/disk/behind.test` | write, then no fsync: on the host's image within 6 s (the test stopped without its sync, `define: TEST_END_NOSYNC`); fsync: on it at once; at the test's end: on it | Bochs, MAME |
| `tests/disk/eject.test` | MAME's Lua takes A's diskette out and puts it back or another one: offline, back online with its cache, ENXIO for a write, `eject` | MAME |
| `tests/disk/swap-b.test` | B's diskette changed while its motor is off: noticed at the next access, the old cache dropped | MAME |
| `tests/disk/format.test` | `format` of A and B; fsck.fat and mtools read the result on the host; DOS's layout plus a skew | Bochs, MAME |
| `tests/disk/memory.test` | the cache grows with free memory and gives it back when processes need it; no dirty sector lost | Bochs at 16 MB, MAME |
| host tests | the scheduler's orders and shares against the simulator; 2Q; fingerprints; the master boot record's partitions; the formatter's tables | the host |

**What the runner gains:**
- **Media changed mid-run:** a test line such as `media-at: 30 eject A` or `media-at: 40
  insert A other.img`, done by MAME's Lua (`manager.machine.images`), as E2's probe did.
- **MAME's fixed disks as CHDs of the AT's geometry** (D21): made from the run's raw images
  before it, and extracted back after it, as E1 did.
- **A test's end syncs first:** with write-behind, the dirty sectors at `TEST END` would be
  lost, and the `file:` and `fsck:` lines read the host's images after the run.
  - **The kernel's test end runs in the timer's interrupt,** with interrupts off
    (`src/kernel/test.asm`), and a sync needs the servers and the drivers running. So it
    becomes two steps:
    1. the timer's interrupt signals the OS server's control notification;
    2. a server thread syncs, then asks the kernel to end the test (`TEST END`, the shutdown
       port).
  - `TEST_END_NOSYNC` keeps today's end, for behind.test.
  - A panic or a run-test timeout still loses dirty data. Their tests read no volumes after.
  - Ctrl+Alt+Del syncs too (M6).

`make check` grows by the new tests: about a minute on Bochs, and two to three on MAME, whose
diskette tests run at the drives' speed (an estimate from E7's runs).

## Decisions

All are decided (2026-11-09), as recommended: "i take all decisions as per your
recommendations". Each gives the options, the recommendation, and the experiment behind it.

| | Decision | Recommended | Decided |
|---|---|---|---|
| D1 | One driver or two | B: two, as today, one for each controller | as recommended (2026-11-09) |
| D2 | The drivers' calls | A: runs in CHS, every command the controllers have, one run in flight and the next held by the driver | as recommended (2026-11-09) |
| D3 | Where the scheduler and the cache live | A: a disk server of their own | as recommended (2026-11-09) |
| D4 | The order within a drive | C-LOOK, with Linux's batched deadline as a safety net | as recommended (2026-11-09) |
| D5 | Fair shares between processes | A: BFQ-lite: budgets of 136 sectors, idling of a tick ended by an arrival, a process that was idle ending the turn | as recommended (2026-11-09) |
| D6 | The turn between a controller's two drives | A: the draft's, a cylinder's work then the other drive, at most two cylinders a turn; each request's Seek first | as recommended (2026-11-09) |
| D7 | Read-ahead, read-between, read-behind | A: ahead to the cylinder's end on sequential misses only; between within a run; behind only when idle | as recommended (2026-11-09) |
| D8 | Write-behind | A: fixed disks after at most 5 s; diskettes before their motor stops | as recommended (2026-11-09) |
| D9 | The cache | A: sectors, records in each segment, a hash, 2Q | as recommended (2026-11-09) |
| D10 | The cache's memory | A: lent by the root in blocks of 256 KB, given back on request, a clean reserve | as recommended (2026-11-09) |
| D11 | Volumes and their sectors | A: 32-bit sectors; partitions and diskettes as volumes, in the disk server | as recommended (2026-11-09) |
| D12 | Removable volumes | A: known by sector 0, the FAT and the root; offline until ejected; B checked after its motor stops; writes to an offline volume ENXIO | as recommended (2026-11-09) |
| D13 | Media | A: the data rate probed with Read ID; double stepping detected by Read ID, not assumed | as recommended (2026-11-09) |
| D14 | Retries | A: in the disk server, the controllers' own retries inside a command | as recommended (2026-11-09) |
| D15 | The OS server's lock | A: given up across every disk wait; a lock for each volume's metadata | as recommended (2026-11-09) |
| D16 | The drives' geometry | A: from the BIOS, in the boot information | as recommended (2026-11-09) |
| D17 | The formatter | A: a program through the disk server, unmounted volumes only; the interleave measured (3:1 if not), and a skew | as recommended (2026-11-09) |
| D18 | RAID and LVM | later, in the disk server under the cache | as recommended (2026-11-09) |
| D19 | FAT names | A: the draft's: upper case on the disk, lower case shown, capitals refused (EINVAL) | as recommended (2026-11-09) |
| D20 | Mount points | A: `/mnt/<name>` by volume, DOS's `a:` to `d:` for what a drive holds | as recommended (2026-11-09) |
| D21 | The emulators for the disk tests | A: MAME's fixed disks as CHDs of the AT's geometry; media changed by MAME's Lua | as recommended (2026-11-09) |

### D1. One driver or two

**Decided: B** (2026-11-09), as recommended.

- **A. One driver for both controllers,** as the draft has it: one thread waiting on both
  interrupts, with a state machine for each controller so that a diskette transfer and a
  fixed disk transfer run at once.
- **B. Two drivers, as today,** each over one controller, each taking runs and holding the
  next one (D2).

The draft's reason, shared ports, does not hold (W1): no port serves both halves for one
purpose. A gives one fewer space and thread (about 1-2 KB). B gives the controllers' overlap
for nothing, since each driver has its own thread. Each driver keeps one controller's state:
a run in flight and the next, the same machine for every command. A has two of those machines
in one thread, waiting on two interrupts at once: the riskiest code of the roadmap, for
nothing the disk server cannot do.

**Recommended: B.**

### D2. The drivers' calls

**Decided: A** (2026-11-09), as recommended.

- **A. Runs in CHS, and every command:** read and write a run (up to 64 sectors on a fixed
  disk across heads and cylinders, a cylinder on a diskette); Seek, Read ID, Format, Status,
  Media, Reset (*The drivers and their calls*).
  - **The driver holds the next run,** as the draft has it. Its receive returns calls and its
    interrupt alike, so it takes a second call while the first runs, issues it the moment the
    first ends, then replies to the first. The disk server keeps two calls outstanding a
    controller.
  - **Its path per sector** stays under a sector's time: one receive and one acknowledgement
    of the interrupt, the PIO, the timer armed once a command (*The drivers and their calls*).
- **A'. As A, the next call left in the endpoint's queue,** taken with the reply to the first.
  A driver as simple as today's. But a run at 2:1 then waits a revolution: 119 KB/s against
  223 (E10).
- **B. Single sectors,** as today. Each costs an IPC call, about a sector's time on C (E4).
  The fixed disk loses a revolution a sector at 1:1 and 2:1, and a diskette one a sector
  (E5, E6).
- **C. Runs in LBA,** the driver turning them into CHS. The draft asks for CHS, so that the
  driver stays dumb and the scheduler sees cylinders. A keeps that.

**Recommended: A.** E7's prototype of runs alone made C 9.4 times and A 7.9 times faster on
MAME. Holding the next run is what keeps 2:1 at its full speed (E10).

### D3. Where the scheduler and the cache live

**Decided: A** (2026-11-09), as recommended.

- **A. A disk server of their own,** between the OS server and the drivers. It costs an IPC
  hop a request (about 1 ms), which matters only to single-sector requests at 3:1 (E6). It
  gives the cache a space of its own and keeps the scheduler out of the OS server's lock.
- **B. Inside the OS server.** No extra hop. But its space has 10 slots left (E9): the cache
  could not grow past its 32 sectors without a larger space (memory.md's *Later*: 12.9 ms to
  retype 1,024 slots), and the scheduler would share the lock of D15.

**Recommended: A.**

### D4. The order within a drive

**Decided: C-LOOK with the batched deadline** (2026-11-09), as recommended.

| Random 4 KB readers on C, 8 at once (E6, E10) | KB/s | p95 | at most |
|---|---|---|---|
| FCFS | 57 | 680 ms | 0.8 s |
| SSTF | 87 | 885 ms | 1.7 s |
| LOOK | 87 | 762 ms | 1.1 s |
| C-LOOK | 82 | 688 ms | 1.2 s |
| C-LOOK, a deadline of 500 ms served first, oldest first | 64 | 680 ms | 0.8 s |
| C-LOOK, a deadline of 500 ms and Linux's batches of 16 | 80 | 759 ms | 1.2 s |

- **The deadline** is a safety net, as Linux's deadline scheduler has it: reads 500 ms, writes
  5 s. An expired request starts a batch of 16 requests in sweep order from it
  (`fifo_batch`), rather than every expired request going first. Served oldest first, it
  turns into FCFS under load (E6). With the batches it costs 2 KB/s (E10).
- **LOOK or C-LOOK.**
  - LOOK has the better mean and maximum in the model (87 KB/s and 1.1 s against 82 and
    1.2).
  - C-LOOK has the better p95, and sweeps one way, so a sequential reader's runs, and their
    read-ahead, always go forward. It serves the disk's edges as well as its middle (Teorey
    and Pinkerton).

  The difference is small either way.

**Recommended: C-LOOK with the batched deadline.** SATF/SPTF needs the head's angle
(*Later*).

### D5. Fair shares between processes

**Decided: A, at 136 sectors** (2026-11-09), as recommended.

- **A. BFQ-lite:**
  - each process has a budget of sectors (136, two of C's cylinders) and its requests are
    served in C-LOOK order until the budget is spent, then the next process's;
  - after a synchronous read the disk server waits for the same process's next request, up to
    a tick, ending at once when it comes;
  - **a process that was idle** (no request for 50 ms or more: thinking, not reading) ends the
    active process's turn and its wait when it asks. That is the interactive process BFQ
    favours (E10).

  The OS server tags each request with its process, and later its user.
- **A'. A without the last rule.** The wait holds an interactive reader behind a greedy one.
- **A''. A, no waiting for a process while another has a request queued.** It keeps the
  interactive reader's time and loses all the sequential readers' gain (40 KB/s, E10).
- **B. Round robin by requests,** no idling: fair, but two sequential readers fall to
  40 KB/s.
- **C. None:** C-LOOK only. Fast for one process, and a greedy one shuts out the rest.

| Two sequential readers on C (E6, E10) | KB/s | Jain | p95 | at most |
|---|---|---|---|---|
| C-LOOK | 40 | 1.000 | 216 ms | 233 ms |
| anticipation alone | 116 | 0.897 | 48 ms | 2,289 ms |
| BFQ-lite, 68 sectors | 97 | 1.000 | 451 ms | 468 ms |
| BFQ-lite, 136 sectors | 106 | 0.997 | 55 ms | 737 ms |
| A: BFQ-lite, 136, an idle process ends the turn (E10) | 105 | 0.997 | 156 ms | 737 ms |

The maximum of 737 ms is one reader waiting out the other's turn of 136 sectors with its
idling. A budget of 68 halves it, at 9 KB/s less.

| An interactive reader beside a greedy scan on C (E6, E10) | its mean | p95 | at most | the scan |
|---|---|---|---|---|
| C-LOOK | 85 ms | 131 | 151 | 105 KB/s |
| A': BFQ-lite, 136, idling | 153 ms | 354 | 504 | 128 KB/s |
| A'': no waiting while another has a request | 87 ms | 136 | 151 | 106 KB/s |
| A: an idle process ends the turn | 92 ms | 141 | 158 | 97 KB/s |

**Recommended: A, at 136 sectors.** Per user once the multi-user roadmap comes: a budget for
each user first, then for each of the user's processes.

### D6. The turn between a controller's two drives

**Decided: A** (2026-11-09), as recommended.

| A reader of C beside a flush on D (E6) | C's KB/s | the flush |
|---|---|---|
| the oldest request first (FIFO) | 32 | 13.0 s |
| the draft's: a cylinder's work, then the other | 98 | 14.2 s |
| a budget of 68 a turn | 34 | 13.9 s |
| a budget of 17 a turn | 57 | 14.7 s |

- **A. The draft's turn, with each request's Seek first.**
  - A request that needs a seek begins with its own Seek command, which frees the task file
    once its steps are sent.
  - While its heads move, the controller serves the other drive's work.
  - The driver polls for Seek Complete: a burst of reads, then a tick.
  - A turn ends after two cylinders' sectors (136), so that one long run cannot hold the
    controller.
  - On A and B, a drive's dirty sectors are written before the other is selected (A7).
- **A'. As A, but a Seek only for the other drive's queued request** before each command.
- **B. FIFO.** It starves a reader behind a queue of writes.

| (E6, E10) | two random readers a drive | one a drive | a reader of C beside a flush on D |
|---|---|---|---|
| FIFO | 45 KB/s | 44 | 32, the flush 13.0 s |
| A': the draft's turn, the other drive's Seek | 55 | 44 | 98, 14.2 s |
| A: the draft's turn, each request's Seek first | 60 | 60 | 99, 15.4 s |

**Recommended: A.**

### D7. Read-ahead, read-between, read-behind

**Decided: A** (2026-11-09), as recommended.

| (E6) | a sequential read of C | random reads | a random read beside a sequential one |
|---|---|---|---|
| none | 5.31 s | 17.6 s | 122 ms |
| to the cylinder's end, always | 1.35 s | 34.6 s | 138 ms |
| to the cylinder's end, on a sequential miss | 1.37 s | 17.6 s | 66 ms |

- **A. Ahead to the cylinder's end, but only on a sequential miss** (the sector after the last
  one the process read).
  - **Between:** the gaps inside a run on one track, which the head passes anyway.
  - **Behind:** only when the drive would idle, as the draft suggests.
  - **"return 3 4 7 8 9 as early as possible to the application"** (the draft): the disk
    server sends the demanded run, then the read-ahead as the driver's next run (D2). It
    answers the process when the first ends. With the next run held by the driver, the
    read-ahead costs no revolution.
- **B. Blind read-ahead of a track or a cylinder.** It doubles a random reader's time.
- **C. None.**

**Recommended: A.**

### D8. Write-behind

**Decided: A** (2026-11-09), as recommended.

- **A. Fixed disks:** a dirty sector is written within 5 s, or sooner when the cache needs the
  room, the root asks for memory, or a process calls fsync or sync. Writes go out in sorted
  runs. fsync keeps POSIX's meaning: the data and its metadata are on the disk when it
  returns. **Diskettes:** a dirty sector is written at once while the motor runs, and the motor
  and the drive's select stay on until none is dirty (the draft's).
- **B. As A, at 30 s** on fixed disks: more merged, but up to 30 s of work is lost to a power
  failure.
- **C. Write-through,** as today: every metadata change written at the end of its call.

**What it gains** (E10, on the fixed disks' parts of E5's traces): 5 s writes 14-22% fewer
sectors and 4-10 times fewer commands, since the sectors go out as sorted runs. fsrand's far
larger merging (537 writes to 206) is on B, a diskette, which A writes at once. There the only
merging left is a sector dirtied again while its write still waits in the queue, which takes
the newer data.

**Recommended: A.** FAT12 has no journal: whatever the delay, a crash may leave a FAT and a
directory that disagree, which today's write-through only makes rarer.

### D9. The cache

**Decided: A** (2026-11-09), as recommended.

- **A. Blocks of a sector,** in 64 KB segments with their records at the segment's head, a
  hash in DGROUP, and 2Q.
- **B. The same with LRU.** 242 bytes against 473, and half the hits once a file is read
  through (E6).
- **C. Blocks of a cluster** (8 KB on C). Fewer records, but a 1 KB cluster on B and a sector
  on A, so the size varies by volume, and the FAT's sectors waste a cluster each.

**Recommended: A.** ARC does as well as 2Q, with more code (E6).

### D10. The cache's memory

**Decided: A, with B as its first step** (2026-11-09), as recommended.

- **A. Lent by the root in blocks of 256 KB.** The disk server retypes four segments of each,
  and the root asks for blocks back with a notification. The server answers after writing
  their dirty sectors. It keeps a reserve of clean blocks for that, and the root waits with a
  deadline, then fails the allocation with ENOMEM. The cache grows when the root has free
  blocks beyond a reserve for processes.
- **B. A fixed size,** set at boot from the memory there is.
- **C. Revoked by the root** without asking. It loses dirty data (X5).

**Recommended: A, with B as its first step** (M3 has a fixed cache, M7 the protocol).

### D11. Volumes and their sectors

**Decided: A** (2026-11-09), as recommended.

- **A. 32-bit sectors from 0 for each volume,** and the volumes in the disk server: each
  partition of a fixed disk's master boot record (FAT12, and later FAT16), and each diskette.
  The OS server mounts a file system on a volume and no longer reads partition tables
  (`vol.c`).
- **B. 16-bit sectors of a whole drive,** as today. They end at 32 MB, and AT drive types reach
  1,024 cylinders by 16 heads (136 MB).

**Recommended: A.**

### D12. Removable volumes

**Decided: A** (2026-11-09), as recommended.

- **A. The draft's volumes, made safe:**
  - **a fingerprint:** a hash of sector 0, the first FAT and the root directory, and the
    serial number when there is one;
  - **A's change line,** and on B a check after its motor stopped: sector 0 and the first FAT
    sector, and the whole fingerprint if they differ;
  - **an offline volume keeps its clean cache** for reads; writes fail with ENXIO;
  - **after A's change line or B's motor stop,** the volume's cached FAT and directory sectors
    are read again before its first write. A twin, or a subdirectory changed elsewhere, passes
    the fingerprint, and a stale directory sector written back would undo the change made
    elsewhere (E10). Cached sectors stay good for reads;
  - **`eject`** forgets the volume;
  - **no dirty data past the motor** (D8), so an offline volume never holds unwritten data;
  - **a 360 KB volume may move between B and A,** read-only in A unless the owner decides
    otherwise (A6).
- **B. Volumes by drive,** as today, each diskette change remounting. Simple, and a moved
  diskette is a new volume.
- **C. As A with write-behind held for offline volumes,** as the Mac did. Not safe on a PC: the
  user pulls the diskette, B cannot tell, and twins fool the fingerprint (E9; X1).

**Recommended: A.** ENXIO is POSIX's "no such device or address", the error the volume's
absence fits. EIO would hide it among failures.

### D13. Media

**Decided: A** (2026-11-09), as recommended.

- **A. The data rate probed** by Read ID at 500 kbit/s then 300, as the BIOS's state machine
  does (Diskette 5-89).
  - **Double stepping is detected, not assumed:** step two tracks and read an ID. Cylinder 1
    there means a 360 KB diskette's 48-tpi tracks, so the driver steps twice; cylinder 2 means
    single steps. That is right on an AT, and passes on the emulators, which put cylinder 1 at
    track 1 (E10).
  - The result is kept until the change line, or B's check, says the diskette may have
    changed.
- **B. Fixed media,** as today: 1.2 MB in A, 360 KB in B.

**Recommended: A.** No emulator here can show real double stepping (E2): it stays a risk until
a real AT runs it.

### D14. Retries

**Decided: A** (2026-11-09), as recommended.

- **A. In the disk server.**
  - **Fixed disks:** the controller's own retries inside each command (Read Sectors with
    retries), then a reset and one more try by the disk server.
  - **Diskettes:** three tries with a recalibration between.
  - **A failed run** is split, so that the bad sector is found and only it fails.
  - **The drivers** retry nothing but a reset (the draft's).
  - **A mirror** (D18) would retry on the other drive.
- **B. In the drivers,** as today. Simpler, but the disk server could not split a run or try
  another drive.

**Recommended: A.**

### D15. The OS server's lock

**Decided: A** (2026-11-09), as recommended.

- **A. Given up across every disk wait.** A lock for each volume keeps its metadata changes
  one at a time, held across the whole call that changes them. A read of a file's data holds
  no lock while it waits, and an open file description keeps a flag for its offset. E8's
  prototype of the easy part passed every Bochs test.
- **B. Kept,** as today. Then the disk server only ever has one request, and has nothing to
  order or share.
- **C. Locks for every table.** More parallelism, much more risk, for a server of 48
  processes.

**Recommended: A.**

### D16. The drives' geometry

**Decided: A** (2026-11-09), as recommended.

- **A. From the BIOS,** in the boot information memory.md M2 began.
  - **For each fixed disk,** the parameter table the INT 41h and 46h vectors point to:
    cylinders, heads, sectors, the precompensation cylinder, the control byte.
  - **Not INT 13h AH=08h:** it answers two cylinders fewer ("SUB AX,2 ; ADJUST FOR 0-N", 613
    for type 2's 615) and gives no precompensation (E10).
  - **For each diskette drive,** AH=15h gives its type and whether it has a change line.
  - `disks.inc` keeps defaults for a missing answer.
- **B. Fixed,** as today.

**Recommended: A.** The loader has 232 bytes free (memory.md *At the close*); the three
queries take an estimated 40-60.

### D17. The formatter

**Decided: A** (2026-11-09), as recommended.

- **A. A program, `format`,** through the disk server's exclusive use of an unmounted volume:
  - **diskettes** as DOS lays them out, plus a cylinder skew of 5 on A and 3 on B, which hold
    across rx286's settling of 20-40 ms (E10);
  - **fixed disks** with an interleave and a skew, the tracks that fail recorded as bad
    clusters of the new FAT, after a confirmation.
  - **The interleave is measured,** not assumed:
    - `format` first times rx286's service of a sector, by reading a run of the drive at the
      interleave it has;
    - it takes the smallest interleave whose gap between logical sectors exceeds that time,
      with a margin;
    - with no measurement it takes 3:1.

    At 0.56 ms a sector 2:1 gives 201 KB/s and 3:1 144. At 1.2 ms 2:1 gives 26 and 3:1 144.
    At 2.2 ms only 4:1 keeps up, at 112 (E6, E10). A wrong 2:1 costs seven times more than a
    wrong 3:1.

  Tested on Bochs and MAME for diskettes, on the host for the fixed disks' tables.
- **B. Diskettes only,** fixed disks left to DOS's tools.

**Recommended: A,** with the fixed disk's part marked untested until a real AT.

### D18. RAID and LVM

**Decided: a roadmap of its own, later** (2026-11-09), as recommended.

**An opinion, not a milestone** (A8): in the disk server, below the cache and above the
queues, so that a mirror can choose the nearer heads and retry on the other drive. On one
controller that transfers one drive at a time, a mirror doubles a write and gains only seeks,
and striping gains nothing (*The architecture*). **Recommended:** a roadmap of its own, after
this one, built on D11's volumes.

### D19. FAT names

**Decided: A** (2026-11-09), as recommended.

- **A. The draft's:** names stored upper case, shown lower case, a name with an upper-case
  letter refused with EINVAL. `/dev` and `/z` become case-sensitive too. A lower-case name
  found on a disk (another system's, against FAT's rules) is shown as is. It cannot be opened,
  but unlink and rename find it when it has no upper-case twin, so that it can be put right.
- **B. As A, but ENOENT** for a name with capitals: what a lookup of a missing name says.
- **C. As today:** any case.
- **D. NT's flags** (byte 0Ch's bits 3 and 4) for names written in lower case, so that DOS
  sees `README.TXT` and rx286 `readme.txt`. It is what A already shows, so it adds nothing
  until mixed case is wanted.

**Recommended: A.** E9: ten lines of `vfs.c`, 15 tests' expectations. EINVAL says why ("a name
FAT cannot hold"), as `fat_name` already does for a forbidden character. DOS's drive letters
stay, `C:` and `c:` alike: a drive, not a name (D20).

### D20. Mount points

**Decided: A** (2026-11-09), as recommended.

- **A. `/mnt/<name>` for every volume.**
  - **Its name** is the volume label in lower case (`rx286c`), its spaces made `-` and the
    characters a name refuses dropped. Without a label it is the drive and the volume's
    number (`a1`).
  - **On a clash** the name gets the volume's serial, or else its fingerprint's first hex
    digits, so that a volume keeps its name from session to session whatever the order of
    insertion.
  - **DOS's `a:` to `d:`** (or `A:` to `D:`) name whatever volume each drive holds now, so the
    shell's habits keep working. The
  shell's start, init's working directory and the tests move from `/a` to `/mnt/...`. 35 files
  name `/a` to `/d` today (E9).
- **B. `/mnt/a` to `/mnt/d`,** by drive. A volume that moves would change its name, against
  the draft's "the logical volume can stay the same".

**Recommended: A.**

### D21. The emulators for the disk tests

**Decided: A** (2026-11-09), as recommended.

- **A. CHDs** for MAME's fixed disks, made by `chdman createhd -chs 615,4,17` (and 306,4,17),
  so that MAME's IDE card has the AT's geometry (E1). And media changed mid-run by MAME's Lua
  from a test's `media-at:` lines (*Testing*). `chdman` comes with Debian's `mame-tools`,
  which the owner installed (2026-11-08). The CHDs gave the AT's geometry, and three of
  rx286's disk tests passed with them, the CHDs extracted back to raw images after the run
  for the `file:` and `fsck:` checks (E1).
- **B. Raw images, as today,** and media changes on MAME only by a probe's own requests.

**Recommended: A.**

## The milestones

Each ends with `make check` and `make check-ia16` green. Sizes are estimates: S a day's work or
less, M a few, L a week.

### M1. The copy and the names (S)

- **What:**
  - **the copy:** file_move copies with `memcpy` and `memset` (memory-far.asm's `rep movsw`)
    instead of a byte at a time (E4, E7);
  - **the names** (D19):
    - stored upper case, shown lower case, refused with EINVAL when they hold a capital;
    - `/dev` and `/z` matched exactly;
    - the drive's component lower case;
    - DOS's `C:` still accepted.

    The 15 Bochs tests that expect capitals change, with their MAME and DOSBox-X runs (E9).
  - `tests/posix/names.test`:
    - `a.txt` created is `A.TXT` on the host's image;
    - `ls` shows `a.txt`;
    - `open("A.TXT")` and `mkdir("Docs")` fail with EINVAL;
    - `readme.txt` opens the sample disk's `README.TXT`.
- **Done when:** names.test passes on all three emulators. A 32 KB write to D takes at most
  1 s on MAME (1.86 s today, 0.74 s in E7), checked by `tests/disk/speed.test`, which M1 begins
  with that line and M2 extends.
- **Decisions:** D19.
- **Done** (2026-11-09). `vfs.c` copies with `memcpy` and matches every name byte for byte;
  `tests/posix/names.test` and `names-lowercase.test` (`media: B lowercase`, a new change of
  the runner's) pass; `tests/disk/speed.test` writes D's 32 KB in 780 ms on MAME (1,860 before).
  The 15 tests that expected capitals now expect lower case, and `cd.test` and
  `listing.test` type the refused capitals on purpose. Not as planned:
  - **names.test runs on Bochs and MAME,** not DOSBox-X, which has no disk controller
    rx286 can use (docs/emulators.md).
  - **Two tests had a race,** which M1's new timing on MAME exposed: `sh/break.test` and
    `sh/jobs.test` typed on at once after Ctrl+Break or ^C, and the keys could reach `cat`'s
    read before the signal ended it. They now wait a moment, as a person would.

### M2. Runs through the drivers (M)

- **What:**
  - **the drivers' calls** of D2: runs, Seek, Read ID, Status and Reset (Format in M9, Media
    in M8);
  - **each driver holds the next run** (D2), and its path per sector shrinks:
    - one receive and one acknowledgement of the interrupt, and the PIO;
    - the timer armed once a command;
    - `dwait.asm`'s per-wait `KCALL_TICKS` and timer gone from the sector loop;
  - the fixed disk driver's runs of up to 64 sectors;
  - the diskette driver's runs of a cylinder with MT, through a 15 KB DMA buffer the root
    gives it within one 64 KB page;
  - **the geometry** in the boot information (D16): the loader asks INT 13h, and the root fills
    each driver's table of units from it, as it fills a driver's data today;
  - **the OS server** reads whole sectors as runs into the process (E7's direct path) and
    writes its dirty sectors in sorted runs.

  The drivers keep their retries until M3.
- **Done when:**
  - `tests/disk/runs.test` passes on Bochs and MAME;
  - `tests/disk/speed.test` holds on MAME: A's 96 KB within 6 s (4.3 in E7), B's 48 KB within
    8 s (6.7), C's 58 KB within 0.6 s (0.3);
  - the drivers' sizes are recorded against E7's;
  - **the path per sector is measured and recorded:**
    - instructions a sector in a run, on Bochs (E7: about 2,100);
    - time a sector on MAME, whose IDE card has no rotation, so its time is the CPU's.

    The target is under a sector's time, 0.99 ms on a 6 MHz AT (about 900 instructions), so
    that 2:1 can work; under two, for 3:1, at the least.
- **Decisions:** D1, D2, D16.
- **Done** (2026-11-09). The drivers take runs by cylinder, head and sector, and answer Seek,
  Status, Reset, Geometry and Read ID (`drivers.inc`). The fixed disk driver sends one
  command for up to 64 sectors, and the diskette driver one Read or Write Data a cylinder,
  with MT, through a DMA buffer of 15 KB. The loader puts the diskette drives' types and the
  fixed disks' tables (INT 41h and 46h, if CMOS 12h gives a type) in the boot information,
  now 40 bytes. The OS server asks each drive's geometry, turns its sector numbers into runs
  (`os.c`'s `disk_run`), and moves a process's whole sectors straight between the disk and
  its data, reads and writes alike. Its cache writes in the order of the sectors, neighbours
  as one run. `tests/disk/runs.test` passes on Bochs and MAME, `geometry.test` on Bochs.
  - **speed.test on MAME:**
    - A's 100,144 bytes in 5.9 s (6 s allowed; 4.3 s in E7). The 15 KB reads do not fall on
      A's cylinders, so each read leaves one sector at a cylinder's end, read alone a
      revolution later. M6's read-ahead removes that.
    - B's 45 KB written in 6.8 s and read back in 3.4 s (8 s each).
    - C's NUMBERS.TXT, 29,000 bytes, in 140-160 ms (0.6 s). The roadmap's 58 KB was E7's two
      reads of it.
    - D's 32 KB written in 420 ms (780 after M1).
  - **The sizes:**

    | | master | E7 | M2 |
    |---|---|---|---|
    | fixeddisk.asm, code and data | 765 and 23 | 854 and 31 | 1,438 and 37 |
    | diskette.asm, code and data | 1,221 and 55 | 1,358 and 62 | 1,699 and 64 |
    | the OS server's code | 46,175 | 47,851 (the file) | 47,508 |

    The calls E7 left out (Seek, Status, Reset, Geometry, Read ID) and the geometry from the
    boot information make up the difference.
  - **The path per sector:** C's NUMBERS.TXT read 20 times in calls of 15 KB costs 511 µs a
    sector on Bochs, about 2,040 instructions. That counts each read's share of its open,
    its close and its three calls; E7 measured about 2,100 the same way. MAME takes 2.4 ms
    a sector. **The target is not met:** 900 instructions would let 2:1 work, and 1,800 is
    3:1's limit. The kernel's path stays: the interrupt, the receive, the acknowledgement
    and the timer. M3 measures again with the disk server in the path.
  - Not as planned:
    - **Neither driver holds a next run.** One request reaches a driver at a time while the
      OS server holds its lock, so the queue waits for the disk server (M3).
    - **The timer is still armed at each wait.** `dw_run_wait` no longer asks the ticks
      until the timer rings, but it arms a one-tick timer before each receive. Without it
      MAME's AT woke the driver about 13 ms after a write's interrupt: D's 32 KB took 900 ms
      instead of 420. MAME's ATA model writes a sector in 100 µs (`atastorage.cpp`), so the
      delay is its scheduling, and the cause is not understood. Arming the timer once a
      run saved 7% on Bochs. It is left for a real AT (*At the close*).
    - **Only the fixed disk driver reads the geometry** from the boot information. The
      diskettes keep `disks.inc`'s until M8's media detection.
    - **The DMA buffer is 15 KB only with extended memory.** Without it the root gives 4
      sectors (`FD_DMA_SMALL_SECTORS`), and a run moves what the buffer holds. At 512 KB
      a buffer of 15 or 8 sectors cost `tests/memory/many-small.test`'s 16th fork: M2's
      code left 2-3 KB to spare there. M3's disk server meets the same limit.
    - **A direct read falls back to the cache** when a sector of its run is dirty there; a
      direct write drops the cache's copies of the sectors it covers.
    - **MAME's fixed disks are CHDs** (from M8, D21): `chdman` makes them with the AT's
      geometry, since MAME's IDE card guessed a raw image's geometry from its size, which
      the BIOS's types did not match. MAME's CMOS still names no fixed disk: with types 2
      and 1, IBM's BIOS on MAME's IDE card did not boot again after Ctrl+Alt+Del
      (`tests/kernel/reset.test`). So the BIOS's tables are seen on Bochs alone, and on
      MAME the driver takes `disks.inc`'s geometry, the same.
    - **Two tests had races of their own,** which M2's timing exposed:
      - `tests/posix/devices.test`'s speaker probe counts over a tick, but it can begin
        only once that tick's timer interrupt has returned. A slower handler, with one
        more timer due, lost three changes at 2000 Hz on MAME. The probe now also allows
        1 ms of handler for a count that comes up short.
      - `tests/caps/review-retype.test` (gcc-ia16's build) took for the race a thread B
        that saw `in_retype` just after the call had returned. It now tries again.

### M3. The disk server (L)

- **What:**
  - **a new server**, `src/disk/`, in C on memory.md's server parts, which the root builds
    between the OS server and the two drivers;
  - **volumes** with 32-bit sectors (D11), the master boot record read here and no longer in
    `vol.c`;
  - **a cache of a fixed size** (D9; D10 B), set at boot from what the processes' reserve
    leaves: 512 KB with extended memory. Without it, what is left of the memory below 1 MB,
    with a floor of 8 KB. At 512 KB a 64 KB cache with the server's own 30-40 KB would leave
    no room for `tests/memory/many-small`'s child (E10);
  - **C-LOOK with deadlines** (D4);
  - **the turn between C and D,** with overlapped seeks (D6), and the diskettes' writes before
    the other drive is selected;
  - **retries** moved out of the drivers (D14);
  - **its threads:** one takes requests, one each controller;
  - **the calls** DS_READ, DS_WRITE, DS_SYNC, DS_VOLUMES and DS_EJECT;
  - **the OS server's cache** keeps the FAT and the directories only, written through;
  - **host tests** of the orders, the cache's 2Q and the partitions (`tests/unit/c/test_disk*.c`).
- **Done when:**
  - every suite passes with the OS server calling only the disk server;
  - the host tests pass;
  - speed.test holds;
  - `tests/memory/*` pass at every size the memory suite runs, the least machine among them;
  - the disk server's sizes are recorded against the estimate (10-14 KB of code).
- **Decisions:** D3, D4, D6, D9, D11, D14.
- **Done** (2026-11-09). The disk server (`src/disk/`, *docs/disk-server.md*) stands between
  the OS server and the disk drivers, whose endpoints the root gives it alone. It has three
  threads: one takes the calls (`DS_VOLUME`, `DS_READ`, `DS_WRITE`, `DS_SYNC`, `DS_EJECT`;
  `disk.inc`), and one serves each controller. Volumes have 32-bit sectors, and a fixed
  disk's master boot record is read there (`volume.c`). The cache is 2Q in segments of 125
  blocks with their records at each head (`cache.c`). Requests are ordered by C-LOOK, with
  the deadline's batches, the turn between C and D, and Seek first (`sched.c`). The
  retries have moved out of the drivers, which try a run once. `tests/unit/test_disk.py`
  runs the three pure parts on the host. `make check` passes on Bochs (137), DOSBox-X (62)
  and MAME (113), with 212 host tests, and `make check-ia16` passes (137). gcc-ia16 needed
  one cast: 125 × 524 overflows its 16-bit `int`.
  - **The sizes:** 9.6 KB of code (9,567 bytes, against the estimate of 10-14 KB) and
    1 KB of DGROUP. The OS server's code went from 47,508 bytes to 47,164.
  - **speed.test on MAME** now checks every budget, not D's alone, as M2 meant it to. A's
    budget is 96 KB in 6 s, scaled to KERNEL.BIN's size (110 KB now: the image grows
    with each milestone). A took 6.5 s of 6.7. D's 32 KB written took 820 ms of 1 s (420
    at M2): each call's FAT and directory sectors now take the extra hop too. C's sector of
    a run, read 20 times, costs 441 µs on Bochs (476 at M2) and 2.2 ms on MAME, served from
    the cache. B's 45 KB read back takes 200 ms, from the cache, against 3.4 s at M2.
  - Not as planned:
    - **The least machine's memory.** On a 512 KB machine without extended memory, the
      disk server costs about 16 KB below 1 MB: its code in the boot image, its space,
      its stacks, its data and its cache. M2 had left 2-3 KB to spare there. To make
      room:
      - the OS server's cache has 4 sectors there instead of 32, since the disk server
        caches below it (the root gives the OS server the boot information,
        `OS_SLOT_BOOT_INFO`);
      - the disk server's cache is 4 blocks there (`DS_CACHE_SMALL`), not the 8 KB floor
        planned;
      - its hash and ghosts sit in an index segment sized to the cache, not in DGROUP;
      - its space has 64 slots (2 KB: a slot is 32 bytes of the kernel's), so 12
        requests at once, and the rest wait in the endpoint's queue;
      - its stacks are 512 bytes (250 used at most).

      `tests/memory/many-small.test` still runs a 60 KB child at 512 KB beside the
      others, but with 12 children (`TEST_MANY_FEWER`), not 16: the sixteenth fork's last
      2 KB went to the disk server. Each later milestone's code costs that machine again.
    - **The cache with extended memory** is a segment of 125 blocks for each 256 KB of
      extended memory, one at least and 8 at most. MAME's default machine of 1 MB gets
      256 KB, and 2 MB or more gets the planned 512 KB.
    - **Neither driver holds a next run yet.** With the OS server's lock (until M4) one
      request reaches the disk server at a time; M6's read-ahead gives the second call
      its use.
    - **A file's partial sectors** still go through the OS server's cache, written
      through; whole sectors go straight between the disk server and the process.
    - **Writes go through to the disk** before the reply, until M6's write-behind, so
      `DS_SYNC` has nothing to write yet.
    - **Four volumes,** drives A to D. A fixed disk's other partitions wait for M8's `/mnt`.
    - **Tests that list the modules and threads** (`tests/root/modules.test`,
      `tests/threads/*`) show the disk server's; `tests/caps/review-spaces.test`'s program
      makes 114 spaces, not 115; `tests/sh/clock.test` allows the minute that the larger
      image's slower boot now passes on Bochs.

### M4. Waiting without the lock (M)

- **What:** D15:
  - the OS server gives its lock up across every call to the disk server;
  - a lock for each volume for its metadata, held across a call that changes it;
  - a flag for a description's offset;
  - a busy state in the OS server's metadata cache, which other threads wait on;
  - every wait guarded by `proc_lend` and `proc_still`, with a reference on the description;
  - a count of each file's transfers in flight, which truncation and freeing its chain wait
    for;
  - the locks' order, and freed clusters dropped from the metadata cache (*The OS server's
    side*).

  Tests:
  - **`tests/disk/beside.test`** (rdpar);
  - **`tests/posix/fsrand2.test`:** fsrand on B and on C at once, by two processes;
  - **`tests/posix/onedir.test`:** two processes creating and removing files in one directory,
    every entry accounted for and fsck.fat clean;
  - **`tests/posix/truncrace.test`:** a process truncates a file of C while another's read of
    it is in flight. The reader gets the old bytes or fewer, never another file's, and
    fsck.fat is clean;
  - **`tests/posix/killread.test`:** a process killed while its read of A waits. The server
    goes on and the description is freed.
- **Done when:**
  - beside.test: C beside A at most three times C alone (E8: 2.3);
  - fsrand2, onedir, truncrace and killread pass on Bochs and MAME;
  - every suite passes.
- **Decisions:** D15.

### M5. Fair shares (M)

- **What:** each request tagged with its process; BFQ-lite in the disk server (D5); its host
  test against a small drive model in C; `tests/disk/fair.test`.
- **Done when:**
  - fair.test passes;
  - the host test runs D4, D5 and D6 together, in the order *The disk server* gives, and
    reproduces E6's and E10's results:
    - two sequential readers get at least twice C-LOOK's throughput, with Jain at least 0.95;
    - an interactive reader beside a greedy scan waits at most 20% longer than under C-LOOK.
- **Decisions:** D5.

### M6. Read-ahead and write-behind (M)

- **What:**
  - **read-ahead** on sequential misses, to the cylinder's end; read-between inside runs;
    read-behind when idle (D7);
  - **write-behind:** a thread that writes what has been dirty for 5 s, in sorted runs; fsync
    and sync as POSIX says; diskettes written while their motor runs (D8);
  - **the test's end syncs** before it stops the machine;
  - **Ctrl+Alt+Del** asks the OS server for a sync, waits for the commands in flight and the
    sync, and resets once they are done, or after 10 s. A diskette's cylinder takes about
    0.5 s, a motor's start 1 s, and there are retries. A second Ctrl+Alt+Del resets at once;
  - **the test's end in two steps** (*Testing*), and `TEST_END_NOSYNC`;
  - `tests/disk/behind.test`.
- **Done when:**
  - behind.test passes;
  - fsck.fat finds every test's volumes sound;
  - on the fixed disks' traces (E5's rdtime and trace-copy), the sectors written fall by 15% or
    more and the write commands by four times or more (E10: 14-22% and 4-10 times);
  - speed.test's budgets are tightened to what M6 reaches.
- **Decisions:** D7, D8.

### M7. The cache's memory (M)

- **What:** D10 A:
  - the root lends blocks of 256 KB beyond a reserve for processes, and asks for them back
    with a notification and a deadline;
  - the disk server grows and shrinks its cache, keeping a reserve of clean blocks;
  - `tests/disk/memory.test`:
    - the cache grows on Bochs at 16 MB;
    - then 40 processes of 60 KB take its memory back, with no dirty sector lost (fsck.fat,
      the files compared);
    - and again on MAME at 1 MB.
- **Done when:**
  - memory.test passes;
  - `tests/memory/*` pass at every size the memory suite runs;
  - the least machine boots with the small cache.
- **Decisions:** D10.

### M8. Removable volumes and `/mnt` (L)

- **What:**
  - **the volumes:** A's change line and B's check, fingerprints, offline volumes, `eject` (a
    program, through a new PX call), ENXIO for writes to an offline volume (D12);
  - **media** probed (D13);
  - **`/mnt/<name>`** and DOS's letters (D20);
  - **the runner's `media-at:`** lines for MAME, and its CHDs (D21);
  - `tests/disk/eject.test`, `swap-b.test`;
  - every test and document moved from `/a` to `/mnt/...`.
- **Done when:**
  - eject.test and swap-b.test pass on MAME;
  - a 360 KB volume moves from B to A and reads there, read-only. The driver detects whether
    to step twice by Read ID (D13), so the test passes on MAME, which needs single steps, and
    the code is right for an AT;
  - every suite passes.
- **Decisions:** D12, D13, D20, D21.

### M9. The formatter (M)

- **What:**
  - `DRV_DISK_FORMAT` in both drivers;
  - the disk server's exclusive use of an unmounted volume;
  - `format`: diskettes as DOS lays them out plus a skew (5 on A, 3 on B), fixed disks with
    an interleave it measures (3:1 without), a skew and bad tracks (D17);
  - `tests/disk/format.test`;
  - host tests of the fixed disks' tables.
- **Done when:**
  - format.test passes on Bochs and MAME;
  - a formatted diskette reads in mtools and fsck.fat on the host, and in rx286;
  - on MAME rdtime reads A's KERNEL.BIN, copied onto a skewed diskette, at least 15% faster
    than from an unskewed one (E10: 23% at a skew of 5, across settling of 20-40 ms).
- **Decisions:** D17.

### M10. The simulator in `tools/`, the documents, a review and the close (M)

- **What:**
  - **`tools/disksim`:** E6's simulator, which drives the disk server's own C policies through
    `ctypes`, with E6's experiments as a regression run in `make check`;
  - **the documents:** `docs/storage.md`, `drivers.md`, `root.md`, `processes.md`,
    `emulators.md` and `testing.md`, and a new `docs/disk-server.md`;
  - **an independent review** of M1-M9, its findings fixed;
  - **At the close.**
- **Done when:** `make check` runs disksim's regression; the review's findings are fixed and
  recorded.
- **Decisions:** none.

### Later

Each needs a roadmap of its own, or a real AT:
- **Rotational position** (the draft's "5 6 7 8 9 1 2 3 4"): a Read ID to learn the head's
  angle, then SATF ordering, or a whole track read from the sector that comes first. E6 finds
  it gains as much as the formatter's skew on diskettes, so it waits for a real AT's
  measurements, as the draft says.
- **A real AT:** the time a sector's service takes, and so the interleave; settling, double
  stepping, B's missing change line, the fixed disk's Format Track.
- **RAID and LVM** (D18).
- **FAT16 and VFAT long names:** volumes past 32 MB, mixed case.
- **Shares per user,** with the multi-user roadmap (D5).

### Why this order

- **M1 first:** small and independent, and the copy is the largest cost per sector (E4).
- **M2 before M3:** runs pay at once (E7) and need no new server; the disk server is built on
  the new calls.
- **M3 before M4:** the lock can go only once the cache is out of the OS server and a server
  can hold more than one request.
- **M4 before M5 and M6:** shares and read-ahead need several processes' requests queued at
  once.
- **M7 after M3,** whose cache has a fixed size until then.
- **M8 after M3 and M6:** volumes are M3's, and the diskettes' writes before the motor stops
  are M6's.
- **M9 after M8:** it needs the media and the volumes' exclusive use.
- **M10 last.**

## Risks

- **No real AT.**
  - The emulators give no fixed-disk timing (E1), and the simulator's numbers rest on IBM's
    figures and E4's estimates.
  - **The time a sector's service takes is the most important number not measured.** It
    decides the interleave:
    - 2:1 at under 0.99 ms;
    - 3:1 at under 1.98;
    - 4:1 beyond that.

    E7's runs took about 2,100 instructions a sector on Bochs, about 2.5 ms on a 6 MHz AT (an
    estimate), so M2 must cut the driver's path before 2:1 is worth having. A wrong 2:1 costs
    seven times what a wrong 3:1 does (E10). The formatter measures before it chooses (D17).
- **Double stepping and B's missing change line** cannot be tested on any emulator here: both
  give B a change line, and neither models 48-tpi tracks (E1, E2). Code for them is checked
  only by review and the host until a real AT.
- **MAME's IDE card stands in for the fixed disk controller.** It has its own geometry,
  answers Seek at once, and once failed a read after a long seek (E1). A diskette read once
  timed out after the fixed disk's tests (E3), for a reason not found: the IDE card answers
  only 3F6h, the fixed disk's port on the real adapter too. CHDs of the AT's geometry (D21)
  fix the geometry, and the failed read did not recur with them (E1). The timing stays
  MAME's. The flaky read is watched for in the suites.
- **The adapter's Seek.** The WD1010-05 ends a Seek once its steps are sent; IBM's manual says
  only "an interrupt is generated at the completion of the command" (p. 9), and the adapter
  runs it through its own control processor. If the adapter waits for the seek, seek first
  (D6) gains nothing on an AT, and costs nothing either. A real AT decides.
- **Write-behind and power.** FAT12 has no journal. With up to 5 s of fixed-disk writes held,
  a power failure or a reset may leave a FAT and a directory that disagree. Today's
  write-through makes that rarer, not impossible. The test's end and Ctrl+Alt+Del sync (M6).
  The power switch does not.
- **Diskettes taken out while their light is on.** Nothing stops a user. The light guards the
  selected drive only (A7), and B cannot tell (W5). D8 and D12 keep a diskette's dirty data to
  the shortest time, and no shorter time exists.
- **Giving up the OS server's lock** changes the invariants of a server of 7,300 lines (D15).
  E8 showed the easy part. M4's tests (onedir, fsrand2) look for the rest, and the risk is
  what they do not exercise.
- **The disk server's size.** 10-14 KB of code is an estimate. On the least machine its
  stacks and cache come out of the processes' memory.
- **Fairness against throughput.** BFQ-lite's budget, its idling and its rule for idle
  processes were tuned on the model's workloads (E6, E10). A real workload (a compiler, an
  editor) is not among E5's traces. With a slow path per sector the same policies give far
  less (E10: two sequential readers 26 KB/s at 2:1 with 1.2 ms a sector).

## Left open for the owner

- **None of the decisions:** all are decided as recommended (2026-11-09). D1, D7, D12, D19 and
  D20 are where the roadmap departs from the draft or makes a choice the draft left open.
- **A real AT,** for the interleave, the drives' settling, double stepping and B's diskette
  changes.
- **Four drives on a card that IBM sold for three** (W1): rx286's machine, kept as it is.

## References

- IBM, *Personal Computer AT Fixed Disk and Diskette Drive Adapter* (Options and Adapters,
  August 1984), in `/mnt/h/rx286`:
  - p. 1: the drives it supports, "concurrent data operations", multiple-sector operations;
  - pp. 7-10: the task file and its commands (Seek and overlapped seeking, Read and Write
    Sector, Format Track and its interleave table);
  - pp. 12-13: the DOR and the DIR;
  - p. 19: the 765's unit select and the DOR; the logic diagram, sheet 4: the drives' selects.
- IBM, *Personal Computer AT 20MB Fixed Disk Drive* (Options and Adapters), in `/mnt/h/rx286`:
  the access times, rotation, buffered and overlapped seeks.
- IBM, *Technical Reference Options and Adapters*, volume 1 (April 1984 and updates):
  - *Personal Computer AT High Capacity Diskette Drive*: its signals, the change line, the
    Drive-in-Use indicator, its performance;
  - *Personal Computer AT Double Sided Diskette Drive*: its signals and performance;
  - the XT's fixed disk drive: its access times.
- IBM, *Technical Reference, Personal Computer AT* (1502494, March 1984), in `/mnt/h/rx286`:
  - 1-6: the bus cycles and wait states;
  - the BIOS listing, Diskette 5-88 and 5-89: INT 13h AH=15h and the media state machine
    (40:90h, "360K in 1.2M drive", double stepping).
- Intel, *80286 and 80287 Programmer's Reference Manual* (210498-005, 1987), in
  `/mnt/h/rx286`, appendix B: the instructions' clocks.
- Western Digital, *WD1002/WD1003 User's Guide* (800-1910, 1987), in `/mnt/h/rx286`.
- Western Digital, *1986 Storage Management Products Handbook*: the WD1010-05, 3-1 to 3-24
  (Seek, 3-11).
- NEC, *µPD765 Data Sheet* (December 1978) and *Application Note* (March 1979).
- Microsoft, *FAT: General Overview of On-Disk Format* (fatgen103, 2000).
- Apple, *Inside Macintosh: Files* (1992): volumes, the drive queue, offline volumes.
- The papers of *What the literature says*:
  - **Scheduling:**
    - Denning, AFIPS SJCC 1967;
    - Teorey and Pinkerton, CACM 15(3) 1972;
    - Geist and Daniel, ACM TOCS 5(1) 1987;
    - Seltzer, Chen and Ousterhout, USENIX Winter 1990;
    - Jacobson and Wilkes, HP Labs HPL-CSP-91-7 1991;
    - Worthington, Ganger and Patt, SIGMETRICS 1994;
    - Iyer and Druschel, SOSP 2001;
    - Valente and Checconi, IEEE Trans. Computers 59(9) 2010;
    - Bruno et al., IEEE ICMCS 1999;
    - Jin, Chase and Kaur, SIGMETRICS 2004;
    - Shenoy and Vin, SIGMETRICS 1998.
  - **Disk models and layout:** Ruemmler and Wilkes, IEEE Computer 27(3) 1994; McKusick et al.,
    ACM TOCS 2(3) 1984.
  - **Caching:**
    - O'Neil, O'Neil and Weikum, SIGMOD 1993;
    - Johnson and Shasha, VLDB 1994;
    - Megiddo and Modha, FAST 2003;
    - Bansal and Modha, FAST 2004;
    - Jiang and Zhang, SIGMETRICS 2002;
    - Jiang, Chen and Zhang, USENIX 2005;
    - Smith, ACM TOCS 3(3) 1985;
    - Ousterhout et al., SOSP 1985.
- Bochs 2.7 (`iodev/floppy.cc`, `iodev/harddrv.cc`); MAME 0.264 (`machine/upd765.cpp`,
  `bus/isa/fdc.cpp`, `machine/atastorage.cpp`, `imagedev/floppy.cpp`).
- `src/drivers/diskette.asm`, `fixeddisk.asm`, `dwait.asm`; `src/include/drivers.inc`,
  `disks.inc`, `layout.inc`; `src/os/cache.c`, `vol.c`, `vfs.c`, `os.c`, `proc.c`;
  `src/root/root.c` (`driver_device`); `src/lib/crt/memory-far.asm`; `tools/run-test`,
  `tools/rxlib.py`, `mame/rx286.lua`.
- roadmaps/storage.md (D2-D4, *Later*), os-server.md (P7, P14, P15, E4, E9), memory.md (M2,
  M6, M7, *Later*), l4.md (E4, L4).
