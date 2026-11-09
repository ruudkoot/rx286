/* ============================================================================
 * rx286 - src/disk/sched.c
 * The disk server's order of requests (sched.h; roadmap disk-scheduler.md
 * M3, D4, D6). The choices come in this order: a drive's expired deadline
 * starts a batch from the oldest; the controller's turn says which drive;
 * C-LOOK says which of its requests; and a fixed disk's request that needs
 * a seek has its Seek sent first while the other drive is served.
 * (M5's shares between processes come before the turn.)
 * ============================================================================ */

#include "sched.h"

static struct sched_job jobs[SCHED_JOBS];

/* Each drive's: C-LOOK's next sector, after the last one served; where its
 * heads are, or are going (a Seek sent); a deadline's batch, requests left;
 * its requests queued */
static struct {
    rx_u32 sweep;
    rx_u16 cylinder;
    rx_u8 batch, queued;
} drv[SCHED_DRIVES];

/* Each controller's turn: whose; whether it has served yet; the cylinder
 * its work is on; the sectors it has served */
static struct {
    rx_u8 drive, started;
    rx_u16 cylinder, sectors;
} turn[SCHED_DRIVES / 2];

/* sched_init - nothing queued (sched.h) */
void sched_init(void)
{
    unsigned k;

    for (k = 0; k < SCHED_JOBS; k++)
        jobs[k].used = 0;
    for (k = 0; k < SCHED_DRIVES; k++) {
        drv[k].sweep = 0;
        drv[k].cylinder = SCHED_CYLINDER_UNKNOWN;
        drv[k].batch = drv[k].queued = 0;
    }
    for (k = 0; k < SCHED_DRIVES / 2; k++) {
        turn[k].drive = (rx_u8)(k * 2);
        turn[k].started = 0;
        turn[k].sectors = 0;
    }
}

/* sched_add - a request queued (sched.h) */
unsigned sched_add(unsigned drive, rx_u32 sector, rx_u16 cylinder, rx_u16 count, int write,
                   rx_u16 now)
{
    unsigned k;

    if (drive >= SCHED_DRIVES)
        return SCHED_NONE;
    for (k = 0; k < SCHED_JOBS && jobs[k].used; k++)
        ;
    if (k == SCHED_JOBS)
        return SCHED_NONE;
    jobs[k].sector = sector;
    jobs[k].cylinder = cylinder;
    jobs[k].count = count;
    jobs[k].due = (rx_u16)(now + (write ? SCHED_WRITE_TICKS : SCHED_READ_TICKS));
    jobs[k].drive = (rx_u8)drive;
    jobs[k].used = 1;
    drv[drive].queued++;
    return k;
}

/* sched_job - a request's record */
const struct sched_job *sched_job(unsigned job)
{
    return &jobs[job];
}

/* sched_queued - a drive's requests queued */
unsigned sched_queued(unsigned drive)
{
    return drv[drive].queued;
}

/* clook - a drive's next request by C-LOOK: the lowest sector from its
 * sweep on, else the lowest of all */
static unsigned clook(unsigned d)
{
    unsigned k, best = SCHED_NONE, low = SCHED_NONE;

    for (k = 0; k < SCHED_JOBS; k++) {
        if (!jobs[k].used || jobs[k].drive != d)
            continue;
        if (jobs[k].sector >= drv[d].sweep
                && (best == SCHED_NONE || jobs[k].sector < jobs[best].sector))
            best = k;
        if (low == SCHED_NONE || jobs[k].sector < jobs[low].sector)
            low = k;
    }
    return best != SCHED_NONE ? best : low;
}

/* next_of - a drive's next request: once no batch is running, the most
 * overdue of its expired requests starts one, the sweep moved to it */
static unsigned next_of(unsigned d, rx_u16 now)
{
    unsigned k, old = SCHED_NONE;

    if (drv[d].batch == 0) {
        for (k = 0; k < SCHED_JOBS; k++)
            if (jobs[k].used && jobs[k].drive == d && (rx_i16)(now - jobs[k].due) >= 0
                    && (old == SCHED_NONE || (rx_i16)(jobs[k].due - jobs[old].due) < 0))
                old = k;
        if (old != SCHED_NONE) {
            drv[d].sweep = jobs[old].sector;
            drv[d].batch = SCHED_BATCH;
        }
    }
    return clook(d);
}

/* sched_pick - the controller's next (sched.h): the drive whose turn it is,
 * unless the other has work and the turn is over (the next request on
 * another cylinder, or SCHED_TURN_SECTORS served); then C-LOOK; then, on
 * the fixed disks, a request that needs a seek has its Seek sent first and
 * the other drive served meanwhile, if it has work */
int sched_pick(unsigned controller, rx_u16 now, struct sched_choice *choice)
{
    unsigned d = turn[controller].drive, u = d ^ 1, j, k;

    if (!drv[d].queued && !drv[u].queued)
        return 0;
    if (drv[d].queued && drv[u].queued) {
        j = next_of(d, now);
        if (turn[controller].sectors >= SCHED_TURN_SECTORS
                || (turn[controller].started && jobs[j].cylinder != turn[controller].cylinder))
            d = u;
    } else if (!drv[d].queued) {
        d = u;
    }
    if (d != turn[controller].drive) {
        turn[controller].drive = (rx_u8)d;
        turn[controller].started = 0;
        turn[controller].sectors = 0;
    }
    u = d ^ 1;
    j = next_of(d, now);
    choice->job = (rx_u8)j;
    choice->seek_drive = SCHED_NONE;
    choice->seek_cylinder = 0;
    if (controller == 1 && drv[d].cylinder != jobs[j].cylinder && drv[u].queued) {
        k = next_of(u, now);
        choice->seek_drive = (rx_u8)d;
        choice->seek_cylinder = jobs[j].cylinder;
        drv[d].cylinder = jobs[j].cylinder;     /* (on their way) */
        choice->job = (rx_u8)k;
    }
    return 1;
}

/* sched_done - a request served (sched.h); it counts toward the turn if it
 * was its drive's */
void sched_done(unsigned job, rx_u16 end_cylinder)
{
    struct sched_job *p = &jobs[job];
    unsigned d = p->drive, c = d / 2;

    drv[d].sweep = p->sector + p->count;
    drv[d].cylinder = end_cylinder;
    if (drv[d].batch)
        drv[d].batch--;
    if (turn[c].drive == d) {
        turn[c].started = 1;
        turn[c].sectors = (rx_u16)(turn[c].sectors + p->count);
        turn[c].cylinder = end_cylinder;
    }
    p->used = 0;
    drv[d].queued--;
}

/* sched_heads - a drive's heads' cylinder (sched.h) */
void sched_heads(unsigned drive, rx_u16 cylinder)
{
    drv[drive].cylinder = cylinder;
}
