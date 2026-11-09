# rx286 - tests/unit/test_disk.py: the disk server's pure parts (src/disk/cache.c, sched.c,
# volume.c) on the host, with the sanitizers (roadmap disk-scheduler.md M3): 2Q and its windows,
# the order of the requests, a fixed disk's partitions.
import os
import subprocess
import sys
import tempfile

import pytest

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
FLAGS = ['-std=c99', '-Wall', '-Wextra', '-Werror', '-g', '-fsanitize=address,undefined',
         '-fno-sanitize-recover=all']


@pytest.mark.parametrize('part', ['cache', 'sched', 'volume'])
def test_disk_on_the_host(part):
    with tempfile.TemporaryDirectory() as tmp:
        # drivers.h, for the errors' numbers, as the build makes it (tools/inc2h)
        subprocess.run([sys.executable, os.path.join(ROOT, 'tools', 'inc2h'),
                        os.path.join(ROOT, 'src', 'include', 'drivers.inc'),
                        os.path.join(tmp, 'drivers.h')], check=True)
        exe = os.path.join(tmp, 'test_disk_' + part)
        subprocess.run(['gcc'] + FLAGS + ['-I', os.path.join(ROOT, 'src', 'include'),
                        '-I', tmp, '-I', os.path.join(ROOT, 'src', 'disk'), '-o', exe,
                        os.path.join(ROOT, 'src', 'disk', part + '.c'),
                        os.path.join(ROOT, 'tests', 'unit', 'c', 'test_disk_' + part + '.c'),
                        '-lm'], check=True)
        run = subprocess.run([exe], capture_output=True, text=True)
        assert run.returncode == 0, run.stdout + run.stderr
