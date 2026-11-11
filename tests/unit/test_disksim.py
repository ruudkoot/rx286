# rx286 - tests/unit/test_disksim.py: the disk model's regression (tools/disksim; roadmap
# disk-scheduler.md E6, M10): the disk server's own order of requests (src/disk/sched.c, through
# ctypes) on E6's model of the AT's drives, against E6's first-come-first-served, holds what
# the roadmap chose it for. The model is deterministic: the bounds leave room for small changes.
import os
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(ROOT, 'tools', 'disksim'))

import regression                       # noqa: E402
import rxsched                          # noqa: E402


def test_the_disk_servers_order_on_the_model():
    with tempfile.TemporaryDirectory() as tmp:
        results = regression.runs(rxsched.build(tmp))
    rx, ff = results['two readers on C']
    assert rx['kbs'] >= 1.15 * ff['kbs']        # C-LOOK and the turns keep each one's runs
    assert rx['jain'] >= 0.95                   # and both get their share (D5)
    rx, ff = results['C and D at once']
    assert rx['jain'] >= 0.95 and rx['kbs'] >= 0.85 * ff['kbs']    # the turn between drives
    rx, ff = results['a reader beside a scan']
    assert rx['p95_of']['ia'] <= 1000.0         # the interactive reader within a second
    plain, skewed = results['A, skew 0'][0], results['A, skew 7'][0]
    assert skewed["kbs"] >= 1.10 * plain["kbs"]     # the formatter's skew (MAME: 11%)
