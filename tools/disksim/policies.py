"""policies - the orders a controller's requests are served in, as E6 compared them (roadmap
disk-scheduler.md E6, M10); rxsched.py has the disk server's own.

Sched(order, arb, ...) is one controller's scheduler:
  order:      within a drive: fcfs, sstf, look, clook
  arb:        between the controller's two drives: fifo (the oldest request first), cylinder
              (the draft's: stay while the current cylinder has work, then switch), budget
              (up to `budget` sectors a turn, then switch if the other drive has work)
  fair:       None, or 'bfq': per-process queues served round robin, `budget` sectors a turn,
              with idling for the process in turn (anticipate ms)
  deadline:   None, or (read ms, write ms): an expired request goes first (Linux's deadline)
  anticipate: ms to wait after a process's synchronous read for its next one (Iyer &
              Druschel 2001; rx286's timer makes it a tick, 20 ms, unless the arrival ends it)
  overlap:    the Seek command for the other drive before each command (fixed disks)
  queued_next: the driver holds the next command and issues it at once
"""


class Sched:
    def __init__(self, order='clook', arb='fifo', fair=None, deadline=None, anticipate=0.0,
                 overlap=False, queued_next=False, budget=68):
        self.order, self.arb, self.fair = order, arb, fair
        self.deadline, self.anticipate = deadline, anticipate
        self.overlap, self.queued_next, self.budget = overlap, queued_next, budget
        self.q = {}
        self.pos = {}
        self.dir = {}
        self.current = None
        self.turn_sectors = 0
        self.wait = None                # (proc, drive, until) while anticipating
        self.procs = []                 # bfq: round robin order
        self.active = None
        self.active_left = 0

    def attach(self, ctl):
        self.ctl = ctl
        for d in ctl.drives:
            self.q[d.name] = []
            self.pos[d.name] = 0
            self.dir[d.name] = 1
        self.current = ctl.drives[0].name

    # ------------------------------------------------------------ the queue
    def add(self, req, t):
        self.q[req.drive].append(req)
        if self.fair == 'bfq' and req.proc not in self.procs:
            self.procs.append(req.proc)

    def pending(self):
        return sum(len(v) for v in self.q.values())

    def cyl(self, req):
        return self.ctl.byname[req.drive].chs(req.lba)[0]

    def pick_in(self, drive, reqs=None):
        """the next request of a drive by `order` (and the deadline)"""
        reqs = self.q[drive] if reqs is None else reqs
        if not reqs:
            return None
        if self.deadline:
            now = self.ctl.sim.t
            late = [r for r in reqs
                    if now - r.arrival > (self.deadline[0] if r.op == 'R' else self.deadline[1])]
            if late:
                return min(late, key=lambda r: r.arrival)
        pos = self.pos[drive]
        if self.order == 'fcfs':
            return min(reqs, key=lambda r: r.arrival)
        if self.order == 'sstf':
            return min(reqs, key=lambda r: (abs(r.lba - pos), r.arrival))
        if self.order == 'clook':
            ahead = [r for r in reqs if r.lba >= pos]
            return min(ahead or reqs, key=lambda r: (r.lba, r.arrival))
        if self.order == 'look':
            d = self.dir[drive]
            ahead = [r for r in reqs if (r.lba - pos) * d >= 0]
            if not ahead:
                self.dir[drive] = -d
                d = -d
                ahead = reqs
            return min(ahead, key=lambda r: (abs(r.lba - pos), r.arrival))
        raise ValueError(self.order)

    def next_cylinder(self, drive):
        r = self.pick_in(drive)
        return None if r is None else self.cyl(r)

    def wake_at(self):
        return self.wait[2] if self.wait else None

    # ------------------------------------------------------------ choosing
    def next(self, t):
        if self.wait and t >= self.wait[2] and not any(
                r.proc == self.wait[0] for v in self.q.values() for r in v):
            self.wait = None            # it did not come
            if self.fair == 'bfq':
                self.rotate()
        if not self.pending():
            return None
        if self.wait:
            proc, drive, until = self.wait
            mine = [r for v in self.q.values() for r in v if r.proc == proc]
            if mine:
                self.wait = None
                return self.take(min(mine, key=lambda r: (r.drive != drive, r.lba)))
            if t < until:
                return None
            self.wait = None
            if self.fair == 'bfq':
                self.rotate()
        if self.fair == 'bfq':
            return self.next_bfq(t)
        drive = self.choose_drive()
        return self.take(self.pick_in(drive))

    def choose_drive(self):
        busy = [d for d in self.q if self.q[d]]
        if len(busy) == 1:
            return busy[0]
        if self.arb == 'fifo':
            return min(busy, key=lambda d: min(r.arrival for r in self.q[d]))
        cur = self.current
        other = [d for d in busy if d != cur][0]
        if cur not in busy:
            return other
        if self.arb == 'cylinder':
            r = self.pick_in(cur)
            here = self.ctl.byname[cur].cyl
            return cur if self.cyl(r) == here else other
        if self.arb == 'budget':
            return cur if self.turn_sectors < self.budget else other
        raise ValueError(self.arb)

    def rotate(self):
        if self.active in self.procs:
            i = self.procs.index(self.active)
            self.procs = self.procs[i + 1:] + self.procs[:i + 1]
        self.active = None

    def next_bfq(self, t):
        for _ in range(len(self.procs) + 1):
            if self.active is None:
                backlogged = [p for p in self.procs
                              if any(r.proc == p for v in self.q.values() for r in v)]
                if not backlogged:
                    return None
                self.active = backlogged[0]
                self.active_left = self.budget
            mine = {d: [r for r in self.q[d] if r.proc == self.active] for d in self.q}
            drives = [d for d in mine if mine[d]]
            if drives and self.active_left > 0:
                drive = self.current if self.current in drives else drives[0]
                return self.take(self.pick_in(drive, mine[drive]))
            self.rotate()
        return None

    def take(self, req):
        self.q[req.drive].remove(req)
        if req.drive != self.current:
            self.current = req.drive
            self.turn_sectors = 0
        self.turn_sectors += req.count
        self.pos[req.drive] = req.lba + req.count
        if self.fair == 'bfq':
            self.active_left -= req.count
        return req

    def completed(self, req, t):
        if self.fair == 'bfq' and self.active_left <= 0:
            self.rotate()               # its budget spent: the next process's turn, no idling
            return
        if self.anticipate and req.sync and req.op == 'R':
            if not any(r.proc == req.proc for v in self.q.values() for r in v):
                self.wait = (req.proc, req.drive, t + self.anticipate)
