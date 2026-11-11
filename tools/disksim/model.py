"""model - a discrete-event model of rx286's AT disks (roadmap disk-scheduler.md E6, M10).

The machine: one CPU; the fixed disk controller (one task file, one sector buffer, C and D
behind it, overlapped seeks by the Seek command; WD1010-05) with PIO; the 765 (A and B, one
selected at a time, DMA, no overlap). The drives: IBM's 20 MB (type 2) and a 10 MB of the
XT's generation (type 1); the AT's 1.2 MB and 360 KB diskette drives. Every figure is the
roadmap's (E1, E4), or marked as an assumption in PARAMS.

A request is (process, drive, lba, count, op). Processes are generators in workloads.py.
A scheduler (policies.py, or rxsched.py's, the disk server's own) orders each controller's
requests. Times are in ms.
"""
import heapq, math, random

# ---------------------------------------------------------------- parameters
PARAMS = {
    # CPU costs (E4): a call through the server to the scheduler and the driver, and back
    'call_ms': 1.0,             # one IPC round trip (l4.md L4: ~1 ms on MAME's AT)
    'hops': 1,                  # IPC round trips per request: 1 (OS server -> driver) or 2
    'per_sector_cpu_ms': 0.56,  # interrupt to the driver's thread + PIO of 512 bytes (E4)
    'copy_ms': 0.26,            # memcpy of a sector to the process (E4); 9.0 for today's loop
    'issue_queued_ms': 0.2,     # the driver issues its next command, already queued
    'today_sector_ms': None,    # if set: a flat CPU cost per sector, as rx286 today (E5: 30)
    # the fixed disk controller (WD1010-05; IBM 20 MB drive manual)
    'step_pulse_ms': 0.035,     # buffered seek: a step pulse every 35 us
    'settle_extra_ms': 0.0,     # added to each seek (sensitivity: the drive's 12 ms "settling")
    # the diskettes (IBM Options and Adapters; rx286's diskette.asm)
    'fd_settle_ms': 30.0,       # diskette.asm: FD_SETTLE_TICKS 2 ticks: 20-40 ms (15 ms is enough)
    'fd_motor_ms': 1020.0,      # FD_MOTOR_START_TICKS 51 ticks
    'fd_motor_off_ms': 2000.0,  # FD_MOTOR_OFF_TICKS
    'fd_cmd_cpu_ms': 0.5,       # issue the 765's 9 bytes, read its 7 (assumption)
    'fd_gap_ms': {'A': 1.6, 'B': 3.2},  # the gap between sectors at 500 / 250 kbit/s (estimate)
    'skew': 0,                  # the formatter's cylinder skew, in slots (0: IBM's FORMAT)
    'zero_latency': False,      # a whole track read from the sector that comes first (Later)
}


class Drive:
    """A drive's geometry and mechanics."""

    def __init__(self, name, cyls, heads, spt, rpm, seek, interleave=1, fixed=True, step_ms=None,
                 phase=0.0):
        self.name, self.cyls, self.heads, self.spt = name, cyls, heads, spt
        self.rev = 60000.0 / rpm
        self.seek_fn = seek
        self.fixed = fixed
        self.step_ms = step_ms
        self.phase = phase
        self.cyl = 0
        self.seek_until = 0.0           # an overlapped seek's end
        self.slot_of = self.interleave_table(interleave)
        self.sectors = cyls * heads * spt

    def interleave_table(self, k):
        """slot_of[logical sector 1..spt] = its physical slot 0..spt-1, as a formatter lays
        them: each next logical sector k slots on, skipping taken ones (IBM's 2:1 example:
        1, 10, 2, 11, ...)"""
        slots = [None] * self.spt
        p = 0
        slot_of = {}
        for s in range(1, self.spt + 1):
            while slots[p] is not None:
                p = (p + 1) % self.spt
            slots[p] = s
            slot_of[s] = p
            p = (p + k) % self.spt
        return slot_of

    def chs(self, lba):
        c, r = divmod(lba, self.heads * self.spt)
        h, s = divmod(r, self.spt)
        return c, h, s + 1

    def seek_ms(self, d):
        if d == 0:
            return 0.0
        if self.fixed:
            return self.seek_fn(d) + PARAMS['settle_extra_ms']
        return d * self.step_ms + PARAMS['fd_settle_ms']

    def sector_ms(self):
        return self.rev / self.spt

    def wait_for(self, t, sector):
        """ms from t until logical sector `sector`'s slot starts under the head"""
        slot = (self.slot_of[sector] + PARAMS['skew'] * self.cyl) % self.spt
        pos = (t / self.rev + self.phase) % 1.0
        want = slot / self.spt
        return ((want - pos) % 1.0) * self.rev


def seek_20mb(d):
    """IBM AT 20 MB: 2 ms track to track, 40 ms average (a third of the stroke), 85 ms max:
    a + b sqrt(d) through (1, 2) and (205, 40)"""
    b = (40.0 - 2.0) / (math.sqrt(205) - 1)
    return 2.0 - b + b * math.sqrt(d)


def seek_10mb(d):
    """an XT-era 306-cylinder drive (IBM: 20 ms track to track, 85 ms average, 200 ms max)"""
    b = (85.0 - 20.0) / (math.sqrt(102) - 1)
    return 20.0 - b + b * math.sqrt(d)


def at_drives(interleave=3, seed=1):
    rnd = random.Random(seed)
    return {
        'A': Drive('A', 80, 2, 15, 360, None, 1, fixed=False, step_ms=3.0, phase=rnd.random()),
        'B': Drive('B', 40, 2, 9, 300, None, 1, fixed=False, step_ms=6.0, phase=rnd.random()),
        'C': Drive('C', 615, 4, 17, 3573, seek_20mb, interleave, phase=rnd.random()),
        'D': Drive('D', 306, 4, 17, 3600, seek_10mb, interleave, phase=rnd.random()),
    }


class Request:
    n = 0

    def __init__(self, proc, drive, lba, count, op='R', sync=True):
        Request.n += 1
        self.id = Request.n
        self.proc, self.drive, self.lba, self.count, self.op, self.sync = \
            proc, drive, lba, count, op, sync
        self.arrival = None
        self.done = None
        self.waiters = []


class Sim:
    def __init__(self, drives, sched_factory, cpu_profile=None):
        self.t = 0.0
        self.events = []
        self.seq = 0
        self.drives = drives
        self.hd = Controller(self, 'hd', [drives['C'], drives['D']], sched_factory('hd'))
        self.fd = Controller(self, 'fd', [drives['A'], drives['B']], sched_factory('fd'))
        self.completed = []
        self.busy = {'hd': 0.0, 'fd': 0.0}

    def at(self, t, fn):
        self.seq += 1
        heapq.heappush(self.events, (t, self.seq, fn))

    def run(self, until):
        while self.events and self.events[0][0] <= until:
            t, _, fn = heapq.heappop(self.events)
            self.t = t
            fn()

    def submit(self, req, on_done):
        req.arrival = self.t
        req.waiters.append(on_done)
        ctl = self.hd if req.drive in ('C', 'D') else self.fd
        # the request reaches the scheduler after the call's way in (half a round trip
        # per hop; the way back is added at completion)
        delay = PARAMS['call_ms'] * PARAMS['hops'] / 2
        self.at(self.t + delay, lambda: ctl.add(req))

    def finish(self, req):
        back = PARAMS['call_ms'] * PARAMS['hops'] / 2
        copy = (PARAMS['copy_ms'] if PARAMS['today_sector_ms'] is None else 0) * req.count \
            if req.op == 'R' and req.sync else 0

        def done():
            req.done = self.t
            self.completed.append(req)
            for w in req.waiters:
                w(req)
        self.at(self.t + back + copy, done)


class Controller:
    """one controller: its drives, its scheduler, one command at a time (seeks aside)"""

    def __init__(self, sim, name, drives, sched):
        self.sim, self.name, self.drives, self.sched = sim, name, drives, sched
        self.byname = {d.name: d for d in drives}
        self.busy = False
        self.selected = drives[0].name
        self.motor_off_at = {d.name: -1e9 for d in drives}     # diskettes
        self.last_end = 0.0
        sched.attach(self)

    def add(self, req):
        self.sched.add(req, self.sim.t)
        self.kick()

    def kick(self):
        if self.busy:
            return
        req = self.sched.next(self.sim.t)
        if req is None:
            when = self.sched.wake_at()
            if when is not None and when > self.sim.t and not getattr(self, 'armed', False):
                self.armed = True

                def wake():
                    self.armed = False
                    self.kick()
                self.sim.at(when, wake)
            return
        self.busy = True
        # the driver had it queued as its next command, or takes it through a call
        lag = PARAMS['issue_queued_ms'] if self.sched.queued_next else PARAMS['call_ms'] / 2
        start = max(self.sim.t, self.last_end + lag)
        self.sim.at(start, lambda: self.serve(req))

    def serve(self, req):
        t = self.sim.t
        d = self.byname[req.drive]
        if self.name == 'hd':
            end = self.serve_hd(d, req, t)
        else:
            end = self.serve_fd(d, req, t)
        self.sim.busy[self.name] += end - t
        self.sim.at(end, lambda: self.complete(req))

    def complete(self, req):
        self.busy = False
        self.last_end = self.sim.t
        self.sched.completed(req, self.sim.t)
        self.sim.finish(req)
        self.kick()

    def pre_seek(self, t, exclude):
        """overlapped seeks: the Seek command for every other drive with work elsewhere"""
        for d in self.drives:
            if d.name == exclude:
                continue
            target = self.sched.next_cylinder(d.name)
            if target is None or target == d.cyl or d.seek_until > t:
                continue
            dist = abs(target - d.cyl)
            t += dist * PARAMS['step_pulse_ms'] + 0.02
            d.seek_until = t + d.seek_ms(dist)
            d.cyl = target
        return t

    def serve_hd(self, d, req, t):
        if self.sched.overlap:
            t = self.pre_seek(t, d.name)
        lba, n = req.lba, req.count
        c, h, s = d.chs(lba)
        if t < d.seek_until:            # its overlapped seek still runs: Seek Complete
            t = d.seek_until
        if c != d.cyl:                  # implied seek
            t += d.seek_ms(abs(c - d.cyl)) + abs(c - d.cyl) * PARAMS['step_pulse_ms']
            d.cyl = c
        host = PARAMS['per_sector_cpu_ms'] if PARAMS['today_sector_ms'] is None else \
            PARAMS['today_sector_ms']
        sec = d.sector_ms()
        buffer_free = t
        if req.op == 'W':
            buffer_free = t + 0.26     # the first sector into the buffer
        for k in range(n):
            c, h, s = d.chs(lba + k)
            if c != d.cyl:              # across a cylinder: a one-cylinder implied seek
                t += d.seek_ms(1)
                d.cyl = c
            t = max(t, buffer_free)
            t += d.wait_for(t, s)
            t += sec                    # the sector passes the head
            buffer_free = t + host      # read: emptied; write: refilled
        if req.op == 'R':
            t = buffer_free             # the last sector's PIO
        return t

    def serve_fd(self, d, req, t):
        # select, motor, rate
        if t > self.motor_off_at[d.name]:
            t += PARAMS['fd_motor_ms']
        if self.selected != d.name:
            self.selected = d.name
        t += PARAMS['fd_cmd_cpu_ms']
        lba, n = req.lba, req.count
        k = 0
        while k < n:
            c, h, s = d.chs(lba + k)
            if c != d.cyl:
                t += d.seek_ms(abs(c - d.cyl))
                d.cyl = c
            # one command: to the end of the cylinder (MT), as far as the request goes
            left_in_cyl = (d.heads - h) * d.spt - (s - 1)
            m = min(n - k, left_in_cyl)
            if PARAMS['zero_latency'] and s == 1 and m >= d.spt:
                t += d.sector_ms() / 2  # Read ID, then from the next sector round to it
            else:
                t += d.wait_for(t, s)
            t += m * d.sector_ms()
            k += m
            if k < n:
                t += PARAMS['fd_cmd_cpu_ms']
        self.motor_off_at[d.name] = t + PARAMS['fd_motor_off_ms']
        return t
