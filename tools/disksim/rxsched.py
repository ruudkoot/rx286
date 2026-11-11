"""rxsched - the disk server's own order of requests, src/disk/sched.c, built for the host and
driven through ctypes as a scheduler of the model's (roadmap disk-scheduler.md M10): C-LOOK, the
deadline's batch, the turn between C and D, seek first, and the processes' shares (D4-D6), the
very code rx286 runs, against E6's model of the AT's drives.

    lib = rxsched.build(directory)              # gcc -shared, once
    sim = model.Sim(drives, rxsched.factory(lib))

sched.c keeps one table for all four drives: a factory makes one per simulation, and gives the
model's two controllers (fd: A and B; hd: C and D) a view of it each.
"""
import ctypes
import os
import subprocess

from model import PARAMS

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
DRIVES = {'A': 0, 'B': 1, 'C': 2, 'D': 3}
CONTROLLERS = {'fd': 0, 'hd': 1}
TICK_MS = 20.0                          # the timer's 50 Hz
SCHED_NONE = 0xFF
SCHED_EMPTY, SCHED_SERVE, SCHED_WAIT = 0, 1, 2
OWNERS = 63                             # sched.h's SCHED_OWNERS, less "the server's own"


class Choice(ctypes.Structure):
    """sched.h's struct sched_choice"""
    _fields_ = [('job', ctypes.c_uint8), ('seek_drive', ctypes.c_uint8),
                ('seek_cylinder', ctypes.c_uint16), ('until', ctypes.c_uint16)]


def build(directory):
    """sched.c as a shared library in a directory: the library, loaded"""
    out = os.path.join(directory, 'librxsched.so')
    subprocess.run(['gcc', '-std=c99', '-O2', '-shared', '-fPIC', '-Wall', '-Werror',
                    '-I', os.path.join(ROOT, 'src', 'include'),
                    '-I', os.path.join(ROOT, 'src', 'disk'), '-o', out,
                    os.path.join(ROOT, 'src', 'disk', 'sched.c')], check=True)
    lib = ctypes.CDLL(out)
    lib.sched_add.restype = ctypes.c_uint
    lib.sched_add.argtypes = [ctypes.c_uint, ctypes.c_uint32, ctypes.c_uint16, ctypes.c_uint16,
                              ctypes.c_int, ctypes.c_uint, ctypes.c_uint16]
    lib.sched_pick.restype = ctypes.c_int
    lib.sched_pick.argtypes = [ctypes.c_uint, ctypes.c_uint16, ctypes.POINTER(Choice)]
    lib.sched_done.argtypes = [ctypes.c_uint, ctypes.c_uint16, ctypes.c_uint16]
    lib.sched_queued.restype = ctypes.c_uint
    lib.sched_queued.argtypes = [ctypes.c_uint]
    return lib


def ticks(t):
    """the model's ms as rx286's 16-bit tick count"""
    return int(t / TICK_MS) & 0xFFFF


class Shared:
    """one simulation's table: the jobs in it, the requests the full table holds back, and
    each process's tag"""

    def __init__(self, lib, fair):
        self.lib = lib
        lib.sched_init()
        ctypes.c_int.in_dll(lib, 'sched_fair').value = 1 if fair else 0
        self.jobs = {}
        self.owners = {}

    def owner(self, proc):
        if proc not in self.owners:
            self.owners[proc] = len(self.owners) % OWNERS + 1
        return self.owners[proc]


class RxSched:
    """a controller's view of sched.c, with the model's scheduler's calls"""
    overlap = False                     # sched.c's seek first stands in for it (see next)
    queued_next = False                 # rx286's drivers take each run through a call

    def __init__(self, shared, name):
        self.shared, self.lib, self.c = shared, shared.lib, CONTROLLERS[name]
        self.held = []                  # requests the full table could not take yet
        self.until = None

    def attach(self, ctl):
        self.ctl = ctl

    def cylinder(self, drive, lba):
        return self.ctl.byname[drive].chs(lba)[0]

    def add(self, req, t):
        job = self.lib.sched_add(DRIVES[req.drive], req.lba, self.cylinder(req.drive, req.lba),
                                 req.count, req.op == 'W', self.shared.owner(req.proc), ticks(t))
        if job == SCHED_NONE:
            self.held.append(req)
        else:
            self.shared.jobs[job] = req
            req.rx_job = job

    def pending(self):
        return sum(self.lib.sched_queued(DRIVES[d.name]) for d in self.ctl.drives) + \
            len(self.held)

    def next_cylinder(self, drive):
        return None

    def wake_at(self):
        return self.until

    def next(self, t):
        choice = Choice()
        how = self.lib.sched_pick(self.c, ticks(t), ctypes.byref(choice))
        self.until = None
        if how == SCHED_WAIT:
            self.until = t + ((choice.until - ticks(t)) & 0xFFFF) * TICK_MS
            return None
        if how != SCHED_SERVE:
            return None
        if choice.seek_drive != SCHED_NONE:    # seek first: the other drive's heads move
            name = 'ABCD'[choice.seek_drive]   #    while this one's run goes on
            d = self.ctl.byname[name]
            dist = abs(choice.seek_cylinder - d.cyl)
            if dist:
                d.seek_until = t + dist * PARAMS['step_pulse_ms'] + d.seek_ms(dist)
                d.cyl = choice.seek_cylinder
        return self.shared.jobs.pop(choice.job)

    def completed(self, req, t):
        end = self.cylinder(req.drive, req.lba + req.count - 1)
        self.lib.sched_done(req.rx_job, end, ticks(t))
        while self.held:                # room again: those held back, in their order
            req = self.held.pop(0)
            self.add(req, t)
            if req in self.held:
                break


def factory(lib, fair=True):
    """the model's sched_factory: each controller's view of one table"""
    shared = Shared(lib, fair)
    return lambda name: RxSched(shared, name)
