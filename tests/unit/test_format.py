# rx286 - tests/unit/test_format.py: hexadecimal and decimal formatting.
import random

from x86 import Blob

blob = Blob('format')
rng = random.Random(286)


def run(routine, **regs):
    regs.setdefault('di', 0x100)
    out, mem = blob.call(routine, **regs)
    return out, mem[0x100:out['di']].decode('ascii')


def test_hex16():
    for value in [0, 1, 0x7FFF, 0x8000, 0xFFFF, 0xA55A] + [rng.randrange(65536) for _ in range(300)]:
        out, text = run('fmt_hex16', ax=value)
        assert text == '%04X' % value
        assert out['ax'] == value


def test_hex8():
    for value in range(256):
        out, text = run('fmt_hex8', ax=0x1200 | value)
        assert text == '%02X' % value
        assert out['ax'] == 0x1200 | value


def test_dec16():
    for value in [0, 9, 10, 99, 100, 65535] + [rng.randrange(65536) for _ in range(300)]:
        out, text = run('fmt_dec16', ax=value, dx=0x5A5A)
        assert text == str(value)
        assert out['dx'] == 0x5A5A


def test_dec32():
    values = [0, 1, 65535, 65536, 655359, 4294967295, 1000000000] + \
             [rng.randrange(1 << 32) for _ in range(300)]
    for value in values:
        out, text = run('fmt_dec32', ax=value & 0xFFFF, dx=value >> 16, si=0x1234)
        assert text == str(value), value
        assert (out['ax'], out['dx'], out['si']) == (value & 0xFFFF, value >> 16, 0x1234)
