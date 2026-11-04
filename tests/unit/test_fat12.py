# rx286 - tests/unit/test_fat12.py: the loader's FAT12 entries and CHS arithmetic.
import random

import pytest

from x86 import Blob

blob = Blob('fat12')


def pack_fat12(entries):
    """A FAT12 table holding `entries` (cluster n -> entries[n])."""
    out = bytearray()
    for i in range(0, len(entries), 2):
        a = entries[i]
        b = entries[i + 1] if i + 1 < len(entries) else 0
        out += bytes([a & 0xFF, ((a >> 8) & 0x0F) | ((b & 0x0F) << 4), (b >> 4) & 0xFF])
    return bytes(out)


def test_fat12_next_every_entry():
    rng = random.Random(286)
    entries = [0xFF9, 0xFFF] + [rng.randrange(0x1000) for _ in range(500)]
    fat = pack_fat12(entries) + bytes(4)
    for cluster in range(2, len(entries)):
        regs, _ = blob.call('fat12_next', data=fat, ax=cluster, si=0)
        assert regs['ax'] == entries[cluster], cluster


def test_fat12_next_preserves_registers():
    fat = pack_fat12([0xFF9, 0xFFF, 0x003, 0xFFF])
    regs, _ = blob.call('fat12_next', data=fat, ax=2, si=0, bx=0x1234, cx=0x5678)
    assert (regs['ax'], regs['bx'], regs['cx'], regs['si']) == (3, 0x1234, 0x5678, 0)


def chs(lba, spt, heads):
    track, sector = divmod(lba, spt)
    cylinder, head = divmod(track, heads)
    return cylinder, head, sector + 1


@pytest.mark.parametrize('spt,heads,count', [(15, 2, 2400), (9, 2, 720), (18, 2, 2880),
                                             (17, 4, 615 * 4 * 17)])
def test_chs_from_lba(spt, heads, count):
    for lba in list(range(0, 64)) + list(range(count - 64, count)):
        regs, _ = blob.call('chs_from_lba', ax=lba, bx=(heads << 8) | spt, dx=0x0080)
        cylinder, head, sector = chs(lba, spt, heads)
        cl, ch, dh = regs['cx'] & 0xFF, regs['cx'] >> 8, regs['dx'] >> 8
        assert ch == cylinder & 0xFF
        assert cl & 0x3F == sector
        assert (cl >> 6) == cylinder >> 8
        assert dh == head
        assert regs['dx'] & 0xFF == 0x80            # DL, the drive, kept
        assert regs['bx'] == (heads << 8) | spt     # BX kept
