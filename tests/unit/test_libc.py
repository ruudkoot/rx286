# rx286 - tests/unit/test_libc.py: rx286's libc (src/lib/c/) built and run on the host by gcc,
# with the sanitizers (roadmap os-server.md P1, D22): the second compiler at every check.
import os
import subprocess
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SOURCES = ['src/lib/c/string.c', 'src/lib/c/printf.c', 'tests/unit/c/test_libc.c']


def test_libc_on_the_host():
    with tempfile.TemporaryDirectory() as tmp:
        inc = os.path.join(tmp, 'inc')
        os.mkdir(inc)
        for name in ('kcalls', 'drivers', 'build'):
            subprocess.run(['python3', os.path.join(ROOT, 'tools', 'inc2h'),
                            os.path.join(ROOT, 'src', 'include', name + '.inc'),
                            os.path.join(inc, name + '.h')], check=True)
        exe = os.path.join(tmp, 'test_libc')
        flags = ['-std=c99', '-Wall', '-Wextra', '-Werror', '-g', '-fno-builtin',
                 '-fsanitize=address,undefined', '-fno-sanitize-recover=all']
        objs = []
        for src in SOURCES:
            obj = os.path.join(tmp, os.path.basename(src) + '.o')
            subprocess.run(['gcc'] + flags + ['-ffreestanding', '-nostdinc', '-isystem',
                            os.path.join(ROOT, 'src', 'include', 'c'), '-I',
                            os.path.join(ROOT, 'src', 'include'), '-I', inc, '-include',
                            os.path.join(ROOT, 'tests', 'unit', 'c', 'rename.h'),
                            '-c', '-o', obj, os.path.join(ROOT, src)], check=True)
            objs.append(obj)
        host = os.path.join(tmp, 'host.o')
        subprocess.run(['gcc'] + flags + ['-c', '-o', host,
                        os.path.join(ROOT, 'tests', 'unit', 'c', 'host.c')], check=True)
        subprocess.run(['gcc'] + flags + ['-o', exe, host] + objs, check=True)
        run = subprocess.run([exe], capture_output=True, text=True)
        assert run.returncode == 0, run.stdout + run.stderr
