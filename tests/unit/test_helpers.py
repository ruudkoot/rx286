# rx286 - tests/unit/test_helpers.py: the 32-bit multiply and divide the compilers call
# (src/lib/crt/helpers.asm; roadmap os-server.md P1, E2), against Python's.
import random

from x86 import Blob

blob = Blob('helpers')
M32 = 0xFFFFFFFF


def regs32(value):
    return value & 0xFFFF, (value >> 16) & 0xFFFF


def signed(v):
    return v - (1 << 32) if v & 0x80000000 else v


def cases():
    rng = random.Random(286)
    edge = [0, 1, 2, 0xFFFF, 0x10000, 0x7FFFFFFF, 0x80000000, M32, 1000003, 70000]
    for a in edge:
        for b in edge:
            yield a, b
    for _ in range(300):
        yield rng.getrandbits(32), rng.getrandbits(rng.choice((8, 16, 24, 32)))


def test_u4m_i4m():
    for a, b in cases():
        for routine in ('__U4M', '__I4M'):
            ax, dx = regs32(a)
            bx, cx = regs32(b)
            out, _ = blob.call(routine, ax=ax, dx=dx, bx=bx, cx=cx)
            assert out['dx'] << 16 | out['ax'] == a * b & M32, (routine, a, b)


def test_u4d():
    for a, b in cases():
        if b == 0:
            continue
        ax, dx = regs32(a)
        bx, cx = regs32(b)
        out, _ = blob.call('__U4D', ax=ax, dx=dx, bx=bx, cx=cx)
        assert (out['dx'] << 16 | out['ax'], out['cx'] << 16 | out['bx']) == (a // b, a % b)


def test_i4d_truncates_as_c():
    for a, b in cases():
        sa, sb = signed(a), signed(b)
        if sb == 0 or (sa == -2**31 and sb == -1):
            continue
        q = abs(sa) // abs(sb) * (1 if (sa < 0) == (sb < 0) else -1)
        r = sa - q * sb
        ax, dx = regs32(a)
        bx, cx = regs32(b)
        out, _ = blob.call('__I4D', ax=ax, dx=dx, bx=bx, cx=cx)
        assert (signed(out['dx'] << 16 | out['ax']), signed(out['cx'] << 16 | out['bx'])) == \
            (q, r), (sa, sb)
