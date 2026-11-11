"""workloads - processes that make requests (roadmap disk-scheduler.md E6, M10).

A process is a generator of actions: ('io', [Request...]) waits for all of them;
('think', ms) waits. run_process() drives one on a Sim.
"""
import random, re
from model import Request


def run_process(sim, gen, stats):
    def step(_=None):
        try:
            act = next(gen)
        except StopIteration:
            stats['end'] = sim.t
            return
        if act[0] == 'think':
            sim.at(sim.t + act[1], step)
            return
        reqs = act[1]
        left = [len(reqs)]

        def one(req):
            stats['lat'].append(req.done - req.arrival)
            stats['sectors'] += req.count
            left[0] -= 1
            if left[0] == 0:
                step()
        for r in reqs:
            sim.submit(r, one)
    sim.at(sim.t, step)


def sequential(name, drive, start, sectors, run=1, think=0.0):
    """a file read front to back, `run` sectors a request"""
    lba = start
    while lba < start + sectors:
        n = min(run, start + sectors - lba)
        yield ('io', [Request(name, drive, lba, n)])
        lba += n
        if think:
            yield ('think', think)


def random_reads(name, drive, lo, hi, count, run=1, think=0.0, seed=1):
    rnd = random.Random(seed)
    for _ in range(count):
        lba = rnd.randrange(lo, hi - run)
        yield ('io', [Request(name, drive, lba, run)])
        if think:
            yield ('think', think)


def write_burst(name, drive, lbas, run=1):
    """write-behind's flush: every dirty run at once, not waited for one by one"""
    yield ('io', [Request(name, drive, lba, run, op='W', sync=False) for lba in lbas])


def trace(path, merge=False, drive_names='ABCD'):
    """E5's traces as processes, one a thread: each disk call (R, W) a request of one sector,
    one after the other; with merge, consecutive sectors of a thread's calls as one run"""
    by = {}
    for line in open(path, encoding='latin-1'):
        m = re.match(r'dt ([RW]) (\d) (\d+) (\d+) (\d+)', line)
        if m:
            by.setdefault(m.group(4), []).append(
                (m.group(1), drive_names[int(m.group(2))], int(m.group(3))))
    procs = {}
    for thread, calls in by.items():
        runs = []
        for op, d, s in calls:
            if merge and runs and runs[-1][0] == op and runs[-1][1] == d and \
                    runs[-1][2] + runs[-1][3] == s:
                runs[-1][3] += 1
            else:
                runs.append([op, d, s, 1])

        def gen(runs=runs, thread=thread):
            for op, d, s, n in runs:
                yield ('io', [Request('t' + thread, d, s, n, op=op, sync=(op == 'R'))])
        procs['t' + thread] = gen()
    return procs
