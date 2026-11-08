# rx286 - tests/unit/test_buddy.py: the root's buddy allocator (src/root/buddy.c) on the host,
# against a simulation of untyped memory, with the sanitizers (roadmap os-server.md P4, E10).
import os
import subprocess
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


def test_buddy_on_the_host():
    with tempfile.TemporaryDirectory() as tmp:
        exe = os.path.join(tmp, 'test_buddy')
        flags = ['-std=c99', '-Wall', '-Wextra', '-Werror', '-g',
                 '-fsanitize=address,undefined', '-fno-sanitize-recover=all']
        subprocess.run(['gcc'] + flags + ['-I', os.path.join(ROOT, 'src', 'include'),
                        '-I', os.path.join(ROOT, 'src', 'root'), '-o', exe,
                        os.path.join(ROOT, 'src', 'root', 'buddy.c'),
                        os.path.join(ROOT, 'tests', 'unit', 'c', 'test_buddy.c')], check=True)
        run = subprocess.run([exe], capture_output=True, text=True)
        assert run.returncode == 0, run.stdout + run.stderr
