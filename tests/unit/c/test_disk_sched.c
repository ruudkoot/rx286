/* ============================================================================
 * rx286 - tests/unit/c/test_disk_sched.c
 * The disk server's order of requests (src/disk/sched.c; roadmap
 * disk-scheduler.md M3, D4, D6) on the host: C-LOOK's sweep and its wrap; a
 * deadline that ends a sequential reader's hold on the drive, and its
 * batch; the turn between C and D, a cylinder's work at a time and
 * SCHED_TURN_SECTORS at most; seek first on the fixed disks and not on the
 * diskettes; and a full queue refused.
 * ============================================================================ */

#include <stdio.h>
#include "sched.h"

#define C 2                             /* drives C and D: controller 1 */
#define D 3
#define TRACK_C 68                      /* C's sectors a cylinder: 4 heads x 17 */

static int failures;

#define CHECK(cond, ...) do { if (!(cond)) { printf(__VA_ARGS__); printf("\n"); \
    failures++; } } while (0)

/* add - a request of C or D by sector, its cylinder from C's geometry */
static unsigned add(unsigned drive, rx_u32 sector, rx_u16 count, rx_u16 now)
{
    return sched_add(drive, sector, (rx_u16)(sector / TRACK_C), count, 0, now);
}

/* serve - the controller's next, served: its first sector, the Seek sent
 * first in *seek (or SCHED_NONE) */
static rx_u32 serve(unsigned controller, rx_u16 now, unsigned *drive, unsigned *seek)
{
    struct sched_choice ch;
    const struct sched_job *j;
    rx_u32 sector;

    if (!sched_pick(controller, now, &ch)) {
        *drive = SCHED_NONE;
        return 0xFFFFFFFFUL;
    }
    j = sched_job(ch.job);
    sector = j->sector;
    *drive = j->drive;
    if (seek)
        *seek = ch.seek_drive;
    sched_done(ch.job, (rx_u16)((j->sector + j->count - 1) / TRACK_C));
    return sector;
}

/* clook - the sweep upward from the last sector served, then the wrap */
static void clook(void)
{
    static const rx_u32 order[] = { 100, 300, 500, 900, 200 };
    unsigned i, drive;
    rx_u32 got;

    sched_init();
    sched_heads(C, 0);
    add(C, 500, 1, 0);
    add(C, 100, 1, 0);
    add(C, 900, 1, 0);
    add(C, 300, 1, 0);
    for (i = 0; i < 5; i++) {
        got = serve(1, 0, &drive, 0);
        CHECK(got == order[i], "C-LOOK: %u-th served %lu, not %lu", i, (unsigned long)got,
              (unsigned long)order[i]);
        if (i == 1)
            add(C, 200, 1, 0);          /* behind the sweep: after the wrap */
    }
    serve(1, 0, &drive, 0);
    CHECK(drive == SCHED_NONE, "C-LOOK: something left");
}

/* deadline - a request far ahead of a sequential reader waits no longer
 * than its deadline, then a batch runs on from it */
static void deadline(void)
{
    rx_u16 now;
    unsigned drive, served_at = 0;
    rx_u32 next = 100, got;

    sched_init();
    sched_heads(C, 1);
    add(C, 20000, 1, 0);                /* far away */
    add(C, next, 1, 0);
    for (now = 0; now < 100; now++) {
        got = serve(1, now, &drive, 0);
        if (got == 20000) {
            served_at = now;
            break;
        }
        CHECK(got == next, "deadline: the reader's %lu, not %lu", (unsigned long)got,
              (unsigned long)next);
        next++;
        add(C, next, 1, now);           /* the reader's next, just ahead of the sweep */
    }
    CHECK(served_at == SCHED_READ_TICKS, "deadline: the far request at tick %u, not %u",
          served_at, SCHED_READ_TICKS);
    got = serve(1, now, &drive, 0);     /* the batch wraps back to the reader */
    CHECK(got == next, "deadline: after it, the reader's %lu: %lu", (unsigned long)next,
          (unsigned long)got);
}

/* turns - C's work on its cylinder, then D's, then C's next cylinder; a
 * turn of SCHED_TURN_SECTORS at most */
static void turns(void)
{
    unsigned drive, k, seek;
    rx_u32 got;

    sched_init();
    sched_heads(C, 10);
    sched_heads(D, 5);
    add(C, 10 * TRACK_C, 4, 0);
    add(C, 10 * TRACK_C + 8, 4, 0);
    add(C, 20 * TRACK_C, 4, 0);
    add(D, 5 * TRACK_C, 4, 0);
    got = serve(1, 0, &drive, &seek);
    CHECK(drive == C && got == 10 * TRACK_C && seek == SCHED_NONE, "turns: C's first");
    got = serve(1, 0, &drive, &seek);
    CHECK(drive == C && got == 10 * TRACK_C + 8, "turns: C's second, its cylinder's");
    got = serve(1, 0, &drive, &seek);
    CHECK(drive == D && got == 5 * TRACK_C, "turns: then D's: %u %lu", drive,
          (unsigned long)got);
    got = serve(1, 0, &drive, &seek);
    CHECK(drive == C && got == 20 * TRACK_C, "turns: then C's next cylinder");
    sched_init();                       /* a long turn ends at SCHED_TURN_SECTORS */
    sched_heads(C, 10);
    sched_heads(D, 5);
    for (k = 0; k < 3; k++)
        add(C, 10 * TRACK_C + k, 64, 0);
    add(D, 5 * TRACK_C, 1, 0);
    sched_heads(C, 10);
    for (k = 0; k < 4; k++) {
        got = serve(1, 0, &drive, &seek);
        if (k < 3)
            sched_heads(C, 10);         /* (each run of 64 kept on cylinder 10 here) */
        CHECK((k == 3) == (drive == D), "turns: the %u-th served on drive %u", k, drive);
    }
}

/* seek_first - a request that needs a seek: its Seek, and the other drive's
 * request meanwhile; then it, at its cylinder. Not on the diskettes */
static void seek_first(void)
{
    unsigned drive, seek;
    rx_u32 got;

    sched_init();
    sched_heads(C, 0);
    sched_heads(D, 5);
    add(C, 100 * TRACK_C, 1, 0);
    add(D, 5 * TRACK_C, 1, 0);
    got = serve(1, 0, &drive, &seek);
    CHECK(drive == D && seek == C, "seek first: D's served while C seeks: %u %u", drive, seek);
    got = serve(1, 0, &drive, &seek);
    CHECK(drive == C && got == 100 * TRACK_C && seek == SCHED_NONE,
          "seek first: then C's, its heads there");
    sched_init();
    sched_heads(0, 0);
    sched_heads(1, 5);
    sched_add(0, 1000, 33, 1, 0, 0);
    sched_add(1, 90, 5, 1, 0, 0);
    serve(0, 0, &drive, &seek);
    CHECK(drive == 0 && seek == SCHED_NONE, "the diskettes: no seek first: %u %u", drive, seek);
}

/* full - SCHED_JOBS queued, then a refusal */
static void full(void)
{
    unsigned k;

    sched_init();
    for (k = 0; k < SCHED_JOBS; k++)
        CHECK(add(C, k, 1, 0) != SCHED_NONE, "full: refused early");
    CHECK(add(C, 999, 1, 0) == SCHED_NONE, "full: not refused");
    CHECK(sched_queued(C) == SCHED_JOBS, "full: the count");
}

/* main - every case; 0 if all passed */
int main(void)
{
    clook();
    deadline();
    turns();
    seek_first();
    full();
    if (failures)
        return 1;
    printf("test_disk_sched: passed\n");
    return 0;
}
