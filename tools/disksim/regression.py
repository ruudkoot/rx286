#!/usr/bin/env python3
"""regression - E6's runs of the disk model, with the disk server's own order of requests
(rxsched: src/disk/sched.c) beside E6's first-come-first-served (roadmap disk-scheduler.md E6,
M10). tests/unit/test_disksim.py holds what each must show; run alone it prints the table:

    python3 tools/disksim/regression.py
"""
import copy
import os
import statistics
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import model                            # noqa: E402
import policies                         # noqa: E402
import rxsched                          # noqa: E402
import workloads as W                   # noqa: E402

BASE = copy.deepcopy(model.PARAMS)
C_CYLINDER = 4 * 17                     # C's sectors a cylinder


def simulate(procs, factory, params=None, interleave=3, horizon=600000.0):
    """the processes run on the model's AT, each controller ordered by factory's scheduler:
    each process's latencies, sectors and end; and the end of all"""
    model.PARAMS.clear()
    model.PARAMS.update(copy.deepcopy(BASE))
    model.PARAMS.update(params or {})
    model.Request.n = 0
    sim = model.Sim(model.at_drives(interleave, 1), factory)
    stats = {}
    for name, gen in procs.items():
        stats[name] = {'lat': [], 'sectors': 0, 'end': None}
        W.run_process(sim, gen, stats[name])
    sim.run(horizon)
    ends = [s['end'] for s in stats.values()]
    return stats, (horizon if None in ends else max(ends))


def p95(lat):
    """the 95th percentile of latencies"""
    lat = sorted(lat)
    return lat[int(0.95 * (len(lat) - 1))] if lat else 0.0


def summary(stats, end):
    """KB/s, latencies (mean, p95, and each process's p95), and Jain's index of the
    processes' rates"""
    lat = [x for s in stats.values() for x in s['lat']]
    per = [s['sectors'] / ((s['end'] or end) / 1000.0) for s in stats.values()]
    return {'kbs': sum(s['sectors'] for s in stats.values()) * 0.5 / (end / 1000.0),
            'mean': statistics.mean(lat) if lat else 0.0, 'p95': p95(lat),
            'p95_of': {name: p95(s['lat']) for name, s in stats.items()},
            'jain': sum(per) ** 2 / (len(per) * sum(x * x for x in per)) if any(per) else 0.0}


def runs(lib):
    """the workloads, each under the disk server's order and E6's FCFS: name -> (rx, fcfs)"""
    fcfs = lambda name: policies.Sched(order='fcfs', arb='fifo')    # noqa: E731
    out = {}

    def both(name, procs_of, params=None, interleave=3):
        out[name] = tuple(summary(*simulate(procs_of(), f, params, interleave))
                          for f in (rxsched.factory(lib), fcfs))

    # two processes each reading a file of 600 sectors on C, far apart, a cylinder a call
    both('two readers on C', lambda: {
        'r1': W.sequential('r1', 'C', 0, 600, run=34),
        'r2': W.sequential('r2', 'C', 300 * C_CYLINDER, 600, run=34)})
    # an interactive reader (a sector, 50 ms of thought) beside a scan of 3,000 sectors
    both('a reader beside a scan', lambda: {
        'scan': W.sequential('scan', 'C', 0, 3000, run=64),
        'ia': W.random_reads('ia', 'C', 200 * C_CYLINDER, 600 * C_CYLINDER, 40, think=50.0)})
    # a reader on C and one on D at once: the turn between the drives
    both('C and D at once', lambda: {
        'c': W.sequential('c', 'C', 0, 1200, run=34),
        'd': W.sequential('d', 'D', 0, 1200, run=34)})
    # A read whole in calls of a cylinder, without a skew and with format's 7
    for skew in (0, 7):
        both('A, skew %d' % skew, lambda: {'a': W.sequential('a', 'A', 30, 240, run=30)},
             params={'skew': skew})
    return out


def main():
    with tempfile.TemporaryDirectory() as tmp:
        results = runs(rxsched.build(tmp))
    print('| workload | rx286 KB/s | p95 ms | Jain | FCFS KB/s | p95 ms | Jain |')
    print('|---|---|---|---|---|---|---|')
    for name, (rx, ff) in results.items():
        print('| %s | %.1f | %.0f | %.3f | %.1f | %.0f | %.3f |' % (
            name, rx['kbs'], rx['p95'], rx['jain'], ff['kbs'], ff['p95'], ff['jain']))
    rx, ff = results['a reader beside a scan']
    print('\nthe interactive reader beside the scan: p95 %.0f ms (rx286), %.0f ms (FCFS)'
          % (rx['p95_of']['ia'], ff['p95_of']['ia']))
    return 0


if __name__ == '__main__':
    sys.exit(main())
