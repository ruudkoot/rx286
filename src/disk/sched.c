/* ============================================================================
 * rx286 - src/disk/sched.c
 * The disk server's order of requests (sched.h; roadmap disk-scheduler.md
 * M3, M5; D4, D5, D6), in the order of the choices: an expired deadline,
 * the process whose turn it is, the controller's turn between its drives,
 * C-LOOK; and on the fixed disks a Seek first while the other drive is
 * served.
 * ============================================================================ */

#include "sched.h"

int sched_fair = 1;

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

/* Each controller's share (D5): the process whose turn it is, or
 * SCHED_NONE, and the last whose turn it was; its budget's sectors left;
 * whether the turn waits for its next read, and until when; whether an
 * idle process asked, which ends the turn */
static struct {
    rx_u8 active, last, waiting, ended;
    rx_u16 left, until;
} share[SCHED_DRIVES / 2];

/* Each process's last request's tick, and whether it has made one */
static rx_u16 last_seen[SCHED_OWNERS];
static rx_u8 seen[SCHED_OWNERS];

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
        share[k].active = share[k].last = SCHED_NONE;
        share[k].waiting = share[k].ended = 0;
    }
    for (k = 0; k < SCHED_OWNERS; k++)
        seen[k] = 0;
}

/* sched_add - a request queued (sched.h). A process that had asked nothing
 * for SCHED_IDLE_TICKS ends another's turn (D5: the interactive one BFQ
 * favours); the process whose turn waits for it ends the wait */
unsigned sched_add(unsigned drive, rx_u32 sector, rx_u16 cylinder, rx_u16 count, int write,
                   unsigned owner, rx_u16 now)
{
    unsigned k, c = drive / 2;

    if (drive >= SCHED_DRIVES)
        return SCHED_NONE;
    for (k = 0; k < SCHED_JOBS && jobs[k].used; k++)
        ;
    if (k == SCHED_JOBS)
        return SCHED_NONE;
    owner %= SCHED_OWNERS;
    jobs[k].sector = sector;
    jobs[k].cylinder = cylinder;
    jobs[k].count = count;
    jobs[k].due = (rx_u16)(now + (write ? SCHED_WRITE_TICKS : SCHED_READ_TICKS));
    jobs[k].drive = (rx_u8)drive;
    jobs[k].owner = (rx_u8)owner;
    jobs[k].read = (rx_u8)!write;
    jobs[k].used = 1;
    drv[drive].queued++;
    if (share[c].active != SCHED_NONE && owner != share[c].active
            && (!seen[owner] || (rx_u16)(now - last_seen[owner]) >= SCHED_IDLE_TICKS))
        share[c].ended = 1;
    if (owner == share[c].active)
        share[c].waiting = 0;
    seen[owner] = 1;
    last_seen[owner] = now;
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

/* mine - is a request of a drive's, and the owner's (SCHED_NONE: anyone's)? */
static int mine(unsigned k, unsigned d, unsigned owner)
{
    return jobs[k].used && jobs[k].drive == d && (owner == SCHED_NONE || jobs[k].owner == owner);
}

/* clook - a drive's next request of an owner's by C-LOOK: the lowest sector
 * from its sweep on, else the lowest of all; SCHED_NONE if it has none */
static unsigned clook(unsigned d, unsigned owner)
{
    unsigned k, best = SCHED_NONE, low = SCHED_NONE;

    for (k = 0; k < SCHED_JOBS; k++) {
        if (!mine(k, d, owner))
            continue;
        if (jobs[k].sector >= drv[d].sweep
                && (best == SCHED_NONE || jobs[k].sector < jobs[best].sector))
            best = k;
        if (low == SCHED_NONE || jobs[k].sector < jobs[low].sector)
            low = k;
    }
    return best != SCHED_NONE ? best : low;
}

/* expired - once no batch is running on a drive, the most overdue of its
 * expired requests starts one, the sweep moved to it: is a batch running? A
 * batch ends with its drive's queue (M10's review: one that outlived it
 * kept the shares off, and sent a pick to the empty drive) */
static int expired(unsigned d, rx_u16 now)
{
    unsigned k, old = SCHED_NONE;

    if (!drv[d].queued)
        drv[d].batch = 0;
    if (drv[d].batch == 0) {
        for (k = 0; k < SCHED_JOBS; k++)
            if (mine(k, d, SCHED_NONE) && (rx_i16)(now - jobs[k].due) >= 0
                    && (old == SCHED_NONE || (rx_i16)(jobs[k].due - jobs[old].due) < 0))
                old = k;
        if (old != SCHED_NONE) {
            drv[d].sweep = jobs[old].sector;
            drv[d].batch = SCHED_BATCH;
        }
    }
    return drv[d].batch != 0;
}

/* owned - has an owner (SCHED_NONE: anyone) requests on a controller's
 * drives? */
static int owned(unsigned c, unsigned owner)
{
    return clook(c * 2, owner) != SCHED_NONE || clook(c * 2 + 1, owner) != SCHED_NONE;
}

/* next_owner - the controller's next process with requests after the one
 * whose turn ended, in turn, or SCHED_NONE: one look at each request, the
 * owner nearest after it (a look at each owner's cost the AT 60 ms) */
static unsigned next_owner(unsigned c, unsigned after)
{
    unsigned k, gap, least = SCHED_OWNERS, best = SCHED_NONE;
    unsigned base = after == SCHED_NONE ? SCHED_OWNERS - 1 : after;

    for (k = 0; k < SCHED_JOBS; k++)
        if (jobs[k].used && jobs[k].drive / 2 == c) {
            gap = (jobs[k].owner + SCHED_OWNERS - base - 1) % SCHED_OWNERS;
            if (gap < least) {
                least = gap;
                best = jobs[k].owner;
            }
        }
    return best;
}

/* sched_pick - the controller's next (sched.h) */
int sched_pick(unsigned controller, rx_u16 now, struct sched_choice *choice)
{
    unsigned d = turn[controller].drive, u = d ^ 1, j, k, owner = SCHED_NONE;
    unsigned c = controller;

    if (!drv[d].queued && !drv[u].queued)
        return SCHED_EMPTY;
    /* 1. an expired deadline: its batch, whoever's turn it is */
    if (expired(d, now) || expired(u, now)) {
        if (!drv[d].batch) {
            d = u;                      /* (the other drive's batch: and u this one, */
            u = d ^ 1;                  /*    or step 3 sent the pick nowhere: M10) */
        }
    } else if (sched_fair) {
        /* 2. the process whose turn it is: on, or waiting for its next read */
        if (share[c].ended || (share[c].active != SCHED_NONE && share[c].left == 0))
            share[c].active = SCHED_NONE;
        if (share[c].active != SCHED_NONE && !owned(c, share[c].active)) {
            if (share[c].waiting && (rx_i16)(now - share[c].until) < 0) {
                choice->until = share[c].until;
                return SCHED_WAIT;
            }
            share[c].active = SCHED_NONE;
        }
        if (share[c].active == SCHED_NONE) {
            share[c].active = (rx_u8)next_owner(c, share[c].last);
            share[c].last = share[c].active;
            share[c].left = SCHED_BUDGET;
        }
        share[c].ended = 0;
        share[c].waiting = 0;
        owner = share[c].active;
        if (clook(d, owner) == SCHED_NONE)
            d = u;                      /* (its work is the other drive's alone) */
        u = d ^ 1;
    }
    /* 3. the controller's turn between its drives */
    if (!drv[d].batch && clook(d, owner) != SCHED_NONE && clook(u, owner) != SCHED_NONE) {
        j = clook(d, owner);
        if (turn[c].sectors >= SCHED_TURN_SECTORS
                || (turn[c].started && jobs[j].cylinder != turn[c].cylinder))
            d = u;
    } else if (clook(d, owner) == SCHED_NONE) {
        d = u;
    }
    if (d != turn[c].drive) {
        turn[c].drive = (rx_u8)d;
        turn[c].started = 0;
        turn[c].sectors = 0;
    }
    u = d ^ 1;
    /* 4. C-LOOK; and a Seek first on the fixed disks */
    j = clook(d, drv[d].batch ? SCHED_NONE : owner);
    if (j == SCHED_NONE)                /* (never, by the steps above: but no pick is */
        j = clook(d, SCHED_NONE);       /*    made without a request, M10) */
    if (j == SCHED_NONE)
        return SCHED_EMPTY;
    choice->job = (rx_u8)j;
    choice->seek_drive = SCHED_NONE;
    choice->seek_cylinder = 0;
    choice->until = now;
    if (c == 1 && drv[d].cylinder != jobs[j].cylinder
            && (k = clook(u, drv[u].batch ? SCHED_NONE : owner)) != SCHED_NONE) {
        choice->seek_drive = (rx_u8)d;
        choice->seek_cylinder = jobs[j].cylinder;
        drv[d].cylinder = jobs[j].cylinder;     /* (on their way) */
        choice->job = (rx_u8)k;
    }
    return SCHED_SERVE;
}

/* sched_done - a request served (sched.h): it counts toward the drive's
 * turn if it was its drive's, and the process's budget; after a read, the
 * process's turn waits for its next one, if it has none queued */
void sched_done(unsigned job, rx_u16 end_cylinder, rx_u16 now)
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
    if (p->owner == share[c].active) {
        share[c].left = (rx_u16)(share[c].left > p->count ? share[c].left - p->count : 0);
        if (p->read && share[c].left && !owned(c, p->owner)) {
            share[c].waiting = 1;
            share[c].until = (rx_u16)(now + SCHED_ANTICIPATE);
        }
    }
    last_seen[p->owner] = now;
}

/* sched_heads - a drive's heads' cylinder (sched.h) */
void sched_heads(unsigned drive, rx_u16 cylinder)
{
    drv[drive].cylinder = cylinder;
}
