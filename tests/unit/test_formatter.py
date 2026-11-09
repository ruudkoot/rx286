# rx286 - tests/unit/test_formatter.py: the formatter's layouts on the host (src/bin/fmtlay.c;
# roadmap disk-scheduler.md M9, D17): tests/unit/c/test_format.c's checks, then the volumes it
# writes as format would, read by fsck.fat and mtools: DOS's 1.2 MB and 360 KB diskettes, and a
# fixed disk of type 2 whose partition and FAT12 are tools/mkdisks' (its BPB's fields alike).
import os
import shutil
import struct
import subprocess
import tempfile

import pytest

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
FLAGS = ['-std=c99', '-Wall', '-Wextra', '-Werror', '-g', '-fsanitize=address,undefined',
         '-fno-sanitize-recover=all']
ENV = dict(os.environ, MTOOLS_SKIP_CHECK='1')


def bpb(data):
    """The BPB's fields a FAT12 volume's layout rests on."""
    return struct.unpack_from('<HBHBHHBHHH', data, 0x0B)


@pytest.mark.skipif(not shutil.which('fsck.fat') or not shutil.which('mdir'),
                    reason='needs dosfstools and mtools')
def test_format_layouts_on_the_host():
    with tempfile.TemporaryDirectory() as tmp:
        exe = os.path.join(tmp, 'test_format')
        subprocess.run(['gcc'] + FLAGS + ['-I', os.path.join(ROOT, 'src', 'bin'), '-o', exe,
                        os.path.join(ROOT, 'src', 'bin', 'fmtlay.c'),
                        os.path.join(ROOT, 'tests', 'unit', 'c', 'test_format.c')], check=True)
        a, b, c = (os.path.join(tmp, n) for n in ('a.img', 'b.img', 'c.img'))
        run = subprocess.run([exe, a, b, c], capture_output=True, text=True)
        assert run.returncode == 0, run.stdout + run.stderr
        for image in (a, b):
            fsck = subprocess.run(['fsck.fat', '-n', image], capture_output=True, text=True)
            assert fsck.returncode == 0, fsck.stdout + fsck.stderr
            subprocess.run(['mdir', '-i', image, '::'], check=True, env=ENV,
                           capture_output=True)
        assert 'FORMAT A' in subprocess.run(['mlabel', '-i', a, '-s', '::'], env=ENV,
                                            capture_output=True, text=True).stdout
        # the fixed disk's partition, from the boot record's entry
        with open(c, 'rb') as f:
            mbr = f.read(512)
        first, size = struct.unpack_from('<II', mbr, 0x1BE + 8)
        assert mbr[0x1BE + 4] == 0x01 and (first, size) == (17, 615 * 4 * 17 - 17)
        part = os.path.join(tmp, 'c-part.img')
        with open(c, 'rb') as f, open(part, 'wb') as out:
            f.seek(first * 512)
            out.write(f.read(size * 512))
        fsck = subprocess.run(['fsck.fat', '-n', part], capture_output=True, text=True)
        assert fsck.returncode == 0, fsck.stdout + fsck.stderr
        # its layout as tools/mkdisks makes C's, mformat's
        disk = os.path.join(ROOT, 'build', 'disks', 'hd0.img')
        if os.path.exists(disk):
            with open(disk, 'rb') as f:
                f.seek(17 * 512)
                theirs = f.read(512)
            with open(part, 'rb') as f:
                ours = f.read(512)
            assert bpb(ours) == bpb(theirs)
