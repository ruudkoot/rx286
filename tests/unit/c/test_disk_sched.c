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
#include <math.h>
#include <stdlib.h>
#include <string.h>
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
    return sched_add(drive, sector, (rx_u16)(sector / TRACK_C), count, 0, 0, now);
}

/* serve - the controller's next, served: its first sector, the Seek sent
 * first in *seek (or SCHED_NONE) */
static rx_u32 serve(unsigned controller, rx_u16 now, unsigned *drive, unsigned *seek)
{
    struct sched_choice ch;
    const struct sched_job *j;
    rx_u32 sector;

    if (sched_pick(controller, now, &ch) != SCHED_SERVE) {
        *drive = SCHED_NONE;
        return 0xFFFFFFFFUL;
    }
    j = sched_job(ch.job);
    sector = j->sector;
    *drive = j->drive;
    if (seek)
        *seek = ch.seek_drive;
    sched_done(ch.job, (rx_u16)((j->sector + j->count - 1) / TRACK_C), now);
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
    for (now = 0; now < SCHED_READ_TICKS + 50; now++) {
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
    sched_add(0, 1000, 33, 1, 0, 0, 0);
    sched_add(1, 90, 5, 1, 0, 0, 0);
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

/* The model of C (E6): 615 x 4 x 17 at 3,600 rpm, at 3:1 (a sector each
 * 2.94 ms); IBM's 20 MB seek curve, 2 ms to the next cylinder, 40 ms a third
 * of the way; half a revolution's latency, but none for a run that goes on
 * from where the last one ended; a call of 1 ms and 0.56 ms of CPU a sector */
#define REV_MS 16.667
#define SECTOR_MS (3.0 * REV_MS / 17.0)
#define PROCS_MAX 2

/* seek_ms - a seek of d cylinders (E6: through 2 ms for one, 40 ms for 205) */
static double seek_ms(unsigned d)
{
    double b = 38.0 / (sqrt(205.0) - 1.0);

    return d == 0 ? 0.0 : 2.0 - b + b * sqrt((double)d);
}

/* A process of the model: its next request's sector, its sectors left, its
 * requests' length, its think time, random (an interactive reader) or not,
 * when it asks next, its request in flight, and what it got */
static struct mproc {
    rx_u32 next, left;
    unsigned run, random;
    double think, at, issued, waited, end;
    unsigned job, requests, done;
} mp[PROCS_MAX];

/* simulate - the processes against the model until all are done, the
 * shares on or off: the time the last ended (ms) */
static double simulate(int fair)
{
    double t = 0.0, busy = 0.0, wait_until = 0.0;
    rx_u32 last_end = 0xFFFFFFFFUL;
    unsigned cyl = 0, k, all, inflight = SCHED_NONE;
    struct sched_choice ch;
    const struct sched_job *j;
    int r;

    sched_init();
    sched_fair = fair;
    srand(7);
    for (;;) {
        all = 1;
        for (k = 0; k < PROCS_MAX; k++) {      /* the processes that ask now */
            if (mp[k].left == 0)
                continue;
            all = 0;
            if (mp[k].job == SCHED_NONE && mp[k].at <= t) {
                rx_u32 sector = mp[k].random ? (rx_u32)(rand() % 41000) : mp[k].next;

                mp[k].job = sched_add(2, sector, (rx_u16)(sector / TRACK_C),
                                      (rx_u16)mp[k].run, 0, k + 1, (rx_u16)(t / 20.0));
                mp[k].issued = t;
                wait_until = 0.0;       /* (a request wakes the controller's thread) */
            }
        }
        if (all)
            return t;
        if (inflight != SCHED_NONE && busy <= t) {     /* the request done */
            j = sched_job(inflight);
            for (k = 0; k < PROCS_MAX; k++)
                if (mp[k].job == inflight) {
                    mp[k].waited += busy - mp[k].issued;
                    mp[k].requests++;
                    mp[k].done += j->count;
                    mp[k].left = mp[k].left > j->count ? mp[k].left - j->count : 0;
                    mp[k].next += j->count;
                    mp[k].at = busy + mp[k].think + 1.0;
                    mp[k].job = SCHED_NONE;
                    if (mp[k].left == 0)
                        mp[k].end = busy;
                }
            sched_done(inflight, (rx_u16)((last_end - 1) / TRACK_C), (rx_u16)(t / 20.0));
            inflight = SCHED_NONE;
        }
        if (inflight == SCHED_NONE && wait_until <= t) {
            r = sched_pick(1, (rx_u16)(t / 20.0), &ch);
            if (r == SCHED_WAIT) {
                wait_until = ch.until * 20.0;
            } else if (r == SCHED_SERVE) {
                j = sched_job(ch.job);
                busy = t + 1.0 + seek_ms(cyl > j->cylinder ? cyl - j->cylinder : j->cylinder - cyl)
                    + (j->sector == last_end ? 0.0 : REV_MS / 2) + j->count * (SECTOR_MS + 0.56);
                last_end = j->sector + j->count;
                cyl = j->cylinder;
                inflight = ch.job;
            }
        }
        t += 0.1;                       /* (time passes: an arrival, a wait's end) */
    }
}

/* reader - process k: sequential or random, from a sector, so many sectors
 * in requests of `run`, a think time between */
static void reader(unsigned k, rx_u32 from, rx_u32 sectors, unsigned run, int random,
                   double think)
{
    memset(&mp[k], 0, sizeof mp[k]);
    mp[k].next = from;
    mp[k].left = sectors;
    mp[k].run = run;
    mp[k].random = (unsigned)random;
    mp[k].think = think;
    mp[k].job = SCHED_NONE;
}

/* x3 - two sequential readers far apart: KB/s, and Jain's index in *jain */
static double x3(int fair, double *jain)
{
    double end, a, b;

    reader(0, 68UL * 50, 512, 8, 0, 1.0);
    reader(1, 68UL * 500, 512, 8, 0, 1.0);
    end = simulate(fair);
    a = mp[0].done / mp[0].end;
    b = mp[1].done / mp[1].end;
    *jain = (a + b) * (a + b) / (2.0 * (a * a + b * b));
    return (mp[0].done + mp[1].done) * 0.5 / (end / 1000.0);
}

/* x4 - an interactive reader beside a greedy scan: its mean wait (ms) */
static double x4(int fair)
{
    reader(0, 68UL * 100, 4096, 17, 0, 0.0);
    reader(1, 0, 8 * 60, 8, 1, 200.0);
    simulate(fair);
    return mp[1].waited / mp[1].requests;
}

/* shares - D5 against C-LOOK alone, as E6 and E10 found */
static void shares(void)
{
    double clook, bfq, jain, j0, wait_clook, wait_bfq;

    clook = x3(0, &j0);
    bfq = x3(1, &jain);
    printf("test_disk_sched: two sequential readers: C-LOOK %.0f KB/s (Jain %.3f), "
           "shares %.0f KB/s (Jain %.3f)\n", clook, j0, bfq, jain);
    CHECK(bfq >= 2.0 * clook && jain >= 0.95, "shares: two readers %.0f against %.0f, Jain %.3f",
          bfq, clook, jain);
    wait_clook = x4(0);
    wait_bfq = x4(1);
    printf("test_disk_sched: an interactive reader beside a scan waits %.0f ms under C-LOOK, "
           "%.0f with shares\n", wait_clook, wait_bfq);
    CHECK(wait_bfq <= 1.2 * wait_clook, "shares: the interactive reader %.0f ms against %.0f",
          wait_bfq, wait_clook);
}

/* main - every case; 0 if all passed */
int main(void)
{
    clook();
    deadline();
    turns();
    seek_first();
    full();
    shares();
    if (failures)
        return 1;
    printf("test_disk_sched: passed\n");
    return 0;
}
