# rx286 - tests/unit/test_caps.py: retype's placement, a selector's slot.
import pytest

from x86 import Blob

blob = Blob('caps')


@pytest.mark.parametrize('water,size,obj,align,place', [
    (0, 0x100, 0x40, 0x40, 0),          # a 1 KB object at the start
    (1, 0x100, 0x40, 0x40, 0x40),       # aligned up past what is used
    (0x40, 0x100, 0x40, 0x40, 0x40),    # exactly at the watermark
    (0x41, 0x100, 1, 1, 0x41),          # alignment 1: no rounding
    (0x30, 0x100, 0x10, 0x20, 0x40),    # 256 bytes, on 512
    (0xC0, 0x100, 0x40, 0x40, 0xC0),    # fits exactly to the end
])
def test_retype_place_fits(water, size, obj, align, place):
    regs, _ = blob.call('retype_place', ax=water, bx=size, cx=obj, dx=align)
    assert regs['cf'] == 0
    assert regs['ax'] == place
    assert regs['dx'] == place + obj
    assert regs['bx'] == size and regs['cx'] == obj


@pytest.mark.parametrize('water,size,obj,align', [
    (0xC1, 0x100, 0x40, 0x40),          # aligned past the room
    (0, 0x10, 0x20, 1),                 # bigger than the untyped
    (0xFFF0, 0xFFFF, 0x20, 0x40),       # the alignment wraps past FFFFh
    (0xFFF0, 0xFFFF, 0x20, 1),          # the end wraps
])
def test_retype_place_full(water, size, obj, align):
    regs, _ = blob.call('retype_place', ax=water, bx=size, cx=obj, dx=align)
    assert regs['cf'] == 1


@pytest.mark.parametrize('selector,slots,slot', [
    (0x07, 8, 0), (0x04, 8, 0), (0x0F, 8, 1), (0x3F, 8, 7), (0x3C, 8, 7), (0xFF, 32, 31),
])
def test_selector_slot(selector, slots, slot):
    regs, _ = blob.call('selector_slot', ax=selector, cx=slots)
    assert regs['cf'] == 0 and regs['ax'] == slot and regs['cx'] == slots


@pytest.mark.parametrize('selector,slots', [
    (0x10, 8),      # the GDT's: never a slot
    (0x08, 8),
    (0x00, 8),      # null
    (0x47, 8),      # one past the table
    (0x107, 32),
])
def test_selector_slot_refused(selector, slots):
    regs, _ = blob.call('selector_slot', ax=selector, cx=slots)
    assert regs['cf'] == 1
