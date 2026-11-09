/* ============================================================================
 * rx286 - src/disk/sched.h
 * The disk server's order of requests (roadmap disk-scheduler.md M3, D4, D6):
 * a queue for each drive, served C-LOOK (by sector, upward, from the
 * sector after the last one served, then from the lowest again); a
 * deadline as a safety net, which starts a batch of SCHED_BATCH in sweep
 * order from the oldest expired request (Linux's deadline scheduler); and
 * the turn between a controller's two drives: a cylinder's work, then the
 * other drive's, SCHED_TURN_SECTORS at most a turn. A fixed disk's request
 * that needs a seek begins with its own Seek, and the controller serves
 * the other drive while the heads move (seek first).
 *
 * Pure C with no rx286 call (tests/unit/c/test_disk_sched.c): the disk
 * server keeps the requests' records, and tells the scheduler each one's
 * drive, first sector, cylinder, length and deadline.
 * ============================================================================ */

#ifndef RX_DISK_SCHED_H
#define RX_DISK_SCHED_H

#include "rx/compiler.h"

#define SCHED_JOBS 16                   /* requests queued at once, every drive's: the disk
                                           server's DS_REQUESTS at least */
#define SCHED_DRIVES 4                  /* A, B on controller 0; C, D on controller 1 */
#define SCHED_NONE 0xFF
#define SCHED_BATCH 16                  /* Linux's fifo_batch */
#define SCHED_TURN_SECTORS 136          /* two cylinders of C */
#define SCHED_READ_TICKS 25             /* a read's deadline: 500 ms */
#define SCHED_WRITE_TICKS 250           /* a write's: 5 s */
#define SCHED_CYLINDER_UNKNOWN 0xFFFFu

/* What the scheduler knows of a request */
struct sched_job {
    rx_u32 sector;                      /* its drive's first sector */
    rx_u16 cylinder, count, due;        /* that sector's cylinder; its sectors; its deadline */
    rx_u8 drive, used;
};

/* A choice: the request to serve; and perhaps a Seek to send first, for
 * another drive's request (seek_drive SCHED_NONE: none) */
struct sched_choice {
    rx_u8 job, seek_drive;
    rx_u16 seek_cylinder;
};

/* sched_init - nothing queued, every drive's heads where nobody knows */
void sched_init(void);
/* sched_add - a request queued: its drive, first sector, cylinder, count,
 * whether it writes, the tick now; its number, or SCHED_NONE if the queue
 * is full */
unsigned sched_add(unsigned drive, rx_u32 sector, rx_u16 cylinder, rx_u16 count, int write,
                   rx_u16 now);
/* sched_job - a queued request's record */
const struct sched_job *sched_job(unsigned job);
/* sched_queued - the requests queued for a drive */
unsigned sched_queued(unsigned drive);
/* sched_pick - the controller's next (0: A and B; 1: C and D) at tick now,
 * or 0 if it has nothing queued */
int sched_pick(unsigned controller, rx_u16 now, struct sched_choice *choice);
/* sched_done - a request served and out of the queue; the drive's heads
 * left at a cylinder, and its sweep after the request's last sector */
void sched_done(unsigned job, rx_u16 end_cylinder);
/* sched_heads - a drive's heads are at a cylinder (or unknown: after a
 * failure, say) */
void sched_heads(unsigned drive, rx_u16 cylinder);

#endif
