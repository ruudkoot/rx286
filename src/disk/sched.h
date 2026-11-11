/* ============================================================================
 * rx286 - src/disk/sched.h
 * The disk server's order of requests (roadmap disk-scheduler.md M3, M5;
 * D4, D5, D6). The choices come in this order:
 * 1. a drive's oldest expired request (reads SCHED_READ_TICKS, writes
 *    SCHED_WRITE_TICKS) starts a batch of SCHED_BATCH in sweep order from
 *    it (Linux's deadline scheduler);
 * 2. the process whose turn it is (BFQ-lite, D5): each has a budget of
 *    SCHED_BUDGET sectors a turn, then the next process with work in turn;
 *    after a read it waited for, the turn waits up to SCHED_ANTICIPATE
 *    ticks for the same process's next request, unless another process
 *    that had asked nothing for SCHED_IDLE_TICKS asks meanwhile, which
 *    ends the turn;
 * 3. the controller's turn between its two drives (D6): a cylinder's work,
 *    then the other drive's, SCHED_TURN_SECTORS at most a turn;
 * 4. C-LOOK within a drive (D4): the lowest sector from the sector after
 *    the last one served, else the lowest of all;
 * and on the fixed disks, a request that needs a seek has its Seek sent
 * first while the other drive is served.
 *
 * Pure C with no rx286 call (tests/unit/c/test_disk_sched.c, and its drive
 * model): the disk server keeps the requests' records, and tells the
 * scheduler each one's drive, first sector, cylinder, length, process and
 * deadline. Time is in the kernel's ticks, 50 a second.
 * ============================================================================ */

#ifndef RX_DISK_SCHED_H
#define RX_DISK_SCHED_H

#include "rx/compiler.h"

#define SCHED_JOBS 16                   /* requests queued at once, every drive's: the disk
                                           server's DS_REQUESTS at least */
#define SCHED_DRIVES 4                  /* A, B on controller 0; C, D on controller 1 */
#define SCHED_OWNERS 64                 /* the processes a request may be tagged with */
#define SCHED_NONE 0xFF
#define SCHED_BATCH 16                  /* Linux's fifo_batch */
#define SCHED_TURN_SECTORS 136          /* two cylinders of C */
#define SCHED_BUDGET 136                /* a process's turn: two cylinders of C (D5) */
#define SCHED_ANTICIPATE 2              /* a reader's next request waited for: to the second
                                           tick, so a whole one at least, 20-40 ms */
#define SCHED_IDLE_TICKS 3              /* 50 ms or more without a request: idle (D5) */
#define SCHED_READ_TICKS 100            /* a read's deadline: 2 s, longer than another
                                           process's turn (M5: 500 ms undid the shares) */
#define SCHED_WRITE_TICKS 250           /* a write's: 5 s */
#define SCHED_CYLINDER_UNKNOWN 0xFFFFu

/* sched_pick's answers */
#define SCHED_EMPTY 0                   /* nothing queued */
#define SCHED_SERVE 1                   /* serve choice.job */
#define SCHED_WAIT 2                    /* wait until choice.until, or a new request */

/* What the scheduler knows of a request */
struct sched_job {
    rx_u32 sector;                      /* its drive's first sector */
    rx_u16 cylinder, count, due;        /* that sector's cylinder; its sectors; its deadline */
    rx_u8 drive, used, owner, read;     /* its process; a read the process waits for */
};

/* A choice: the request to serve, and perhaps a Seek to send first, for
 * another drive's request (seek_drive SCHED_NONE: none); or the tick to
 * wait until */
struct sched_choice {
    rx_u8 job, seek_drive;
    rx_u16 seek_cylinder, until;
};

/* sched_fair - processes' shares on (1, the default) or off (0: C-LOOK
 * with deadlines alone; the host's test compares them) */
extern int sched_fair;

/* sched_init - nothing queued, every drive's heads where nobody knows */
void sched_init(void);
/* sched_add - a request queued: its drive, first sector, cylinder, count,
 * whether it writes, its process, the tick now; its number, or SCHED_NONE
 * if the queue is full */
unsigned sched_add(unsigned drive, rx_u32 sector, rx_u16 cylinder, rx_u16 count, int write,
                   unsigned owner, rx_u16 now);
/* sched_job - a queued request's record */
const struct sched_job *sched_job(unsigned job);
/* sched_queued - the requests queued for a drive */
unsigned sched_queued(unsigned drive);
/* sched_pick - the controller's next (0: A and B; 1: C and D) at tick now:
 * SCHED_EMPTY, SCHED_SERVE or SCHED_WAIT */
int sched_pick(unsigned controller, rx_u16 now, struct sched_choice *choice);
/* sched_done - a request served and out of the queue at tick now; the
 * drive's heads left at a cylinder, and its sweep after the request */
void sched_done(unsigned job, rx_u16 end_cylinder, rx_u16 now);
/* sched_heads - a drive's heads are at a cylinder (or unknown) */
void sched_heads(unsigned drive, rx_u16 cylinder);

#endif
