# rx286 - tests/unit/test_memory.py: the crt's memcpy, memmove, memset and memcmp
# (src/lib/crt/memory.asm), and their versions for C's compact model
# (memory-far.asm; roadmap memory.md M5), against Python's. A far pointer's
# segment is a real-mode segment here, in place of a selector: the data's
# (2000h) or the stack's (3000h), which is not DS, as a server thread's is not.
import random

import pytest

from x86 import Blob, DATA_SEG, STACK_SEG

near = Blob('memory')
far = Blob('memory', defines=('RELEASE', 'FAR_DATA'))
KEPT = {'si': 0x1111, 'di': 0x2222, 'bp': 0x3333}
SPAN = 0x400                    # the bytes each case looks at, from offset 0x100


def segment_bytes(blob, segment):
    return blob.memory[(segment - 0x1000) * 16:(segment - 0x1000) * 16 + 0x10000]


def cases(seed, count=60):
    rng = random.Random(seed)
    for n in [0, 1, 2, 3, 255, 256, 257] + [rng.randrange(0, 300) for _ in range(count)]:
        yield rng, n


def kept(out, ds=DATA_SEG):
    return all(out[r] == v for r, v in KEPT.items()) and out['ds'] == ds and out['df'] == 0


def random_bytes(rng, n):
    return bytes(rng.getrandbits(8) for _ in range(n))


# ---------------------------------------------------------------- near: memory.asm

def test_near_memcpy_and_memset():
    for rng, n in cases(1):
        data = bytearray(random_bytes(rng, 0x1000))
        to, frm = 0x100 + rng.randrange(0, 0x200), 0x800 + rng.randrange(0, 0x200)
        out, mem = near.call('memcpy', data=data, stack=(to, frm, n), es=0x2468, **KEPT)
        want = bytearray(data)
        want[to:to + n] = data[frm:frm + n]
        assert mem[:0x1000] == want and out['ax'] == to and out['es'] == 0x2468 and kept(out)
        c = rng.getrandbits(16)
        out, mem = near.call('memset', data=data, stack=(to, c, n), **KEPT)
        want = bytearray(data)
        want[to:to + n] = bytes([c & 0xFF]) * n
        assert mem[:0x1000] == want and out['ax'] == to and kept(out)


def test_near_memmove_overlaps_both_ways():
    for rng, n in cases(2):
        data = bytearray(random_bytes(rng, 0x1000))
        frm = 0x400
        to = frm + rng.randrange(-n, n + 1) if n else frm
        out, mem = near.call('memmove', data=data, stack=(to, frm, n), **KEPT)
        want = bytearray(data)
        want[to:to + n] = data[frm:frm + n]
        assert mem[:0x1000] == want and out['ax'] == to and kept(out), (to, frm, n)


def test_near_memcmp_orders_as_unsigned_bytes():
    for rng, n in cases(3):
        a = random_bytes(rng, n)
        b = bytearray(a)
        if n and rng.random() < 0.7:
            b[rng.randrange(n)] = rng.getrandbits(8)
        data = bytearray(0x1000)
        data[0x100:0x100 + n] = a
        data[0x800:0x800 + n] = b
        out, _ = near.call('memcmp', data=data, stack=(0x100, 0x800, n), **KEPT)
        got = out['ax'] - 0x10000 if out['ax'] & 0x8000 else out['ax']
        want = (a > bytes(b)) - (a < bytes(b))
        assert (got > 0) - (got < 0) == want and kept(out)


# ---------------------------------------------------------------- far: memory-far.asm

@pytest.mark.parametrize('to_seg, from_seg', [(DATA_SEG, STACK_SEG), (STACK_SEG, DATA_SEG),
                                              (STACK_SEG, STACK_SEG)])
def test_far_memcpy_between_segments(to_seg, from_seg):
    for rng, n in cases(4 + to_seg + from_seg, 30):
        source = random_bytes(rng, SPAN)
        to = 0x100 + rng.randrange(0, 0x100)
        frm = 0x800 + rng.randrange(0, 0x100)
        memory = [(from_seg, frm, source), (to_seg, to, bytes(SPAN))]
        out, _ = far.call('memcpy', memory=memory, stack=(to, to_seg, frm, from_seg, n),
                          ds=0x1800, **KEPT)
        got = segment_bytes(far, to_seg)[to:to + SPAN]
        assert got == source[:n] + bytes(SPAN - n)
        assert (out['dx'], out['ax']) == (to_seg, to) and kept(out, ds=0x1800)


def test_far_memmove_overlaps_in_one_segment():
    for rng, n in cases(5):
        data = bytearray(random_bytes(rng, 0x1000))
        frm = 0x400
        to = frm + rng.randrange(-n, n + 1) if n else frm
        out, _ = far.call('memmove', memory=[(STACK_SEG, 0, data)],
                          stack=(to, STACK_SEG, frm, STACK_SEG, n), **KEPT)
        want = bytearray(data)
        want[to:to + n] = data[frm:frm + n]
        assert segment_bytes(far, STACK_SEG)[:0x1000] == want
        assert (out['dx'], out['ax']) == (STACK_SEG, to) and kept(out)


def test_far_memmove_between_segments():
    for rng, n in cases(6, 20):
        source = random_bytes(rng, SPAN)
        out, _ = far.call('memmove', memory=[(DATA_SEG, 0x300, source)],
                          stack=(0x300, STACK_SEG, 0x300, DATA_SEG, n), **KEPT)
        assert segment_bytes(far, STACK_SEG)[0x300:0x300 + n] == source[:n] and kept(out)


def test_far_memset_and_memcmp():
    for rng, n in cases(7):
        c = rng.getrandbits(16)
        to = 0x100 + rng.randrange(0, 0x100)
        out, _ = far.call('memset', memory=[(STACK_SEG, 0, bytes(0x1000))],
                          stack=(to, STACK_SEG, c, n), **KEPT)
        got = segment_bytes(far, STACK_SEG)
        assert got[to:to + n] == bytes([c & 0xFF]) * n and not any(got[to + n:0x1000])
        assert (out['dx'], out['ax']) == (STACK_SEG, to) and kept(out)
        a = random_bytes(rng, n)
        b = bytearray(a)
        if n and rng.random() < 0.7:
            b[rng.randrange(n)] = rng.getrandbits(8)
        out, _ = far.call('memcmp', memory=[(DATA_SEG, 0x100, a), (STACK_SEG, 0x100, b)],
                          stack=(0x100, DATA_SEG, 0x100, STACK_SEG, n), ds=0x1800, **KEPT)
        got = out['ax'] - 0x10000 if out['ax'] & 0x8000 else out['ax']
        want = (a > bytes(b)) - (a < bytes(b))
        assert (got > 0) - (got < 0) == want and kept(out, ds=0x1800)
