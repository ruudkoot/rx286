# rx286 - tests/unit/test_keymap.py: every scancode under every modifier.
import os
import sys

from x86 import Blob

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', '..', 'tools'))
import rxlib  # noqa: E402

blob = Blob('keymap')
SHIFT, CTRL, ALT, CAPS = 0x03, 0x04, 0x08, 0x10      # SHIFT: either Shift key
SPECIAL = {0x01: 0x1B, 0x0E: 0x08, 0x0F: 0x09, 0x1C: 0x0D, 0x37: ord('*'),
           0x4A: ord('-'), 0x4E: ord('+')}


def expected(code, mods):
    """The ASCII the US AT keyboard gives, from rxlib's own table."""
    plain = {c: ch for ch, (c, shift) in rxlib.KEYS.items() if not shift and len(ch) == 1}
    shifted = {c: ch for ch, (c, shift) in rxlib.KEYS.items() if shift}
    if mods & ALT:
        return 0
    if code in SPECIAL:
        value = SPECIAL[code]
    elif code in plain and plain[code] not in '\n\b\t\x1b':
        letter = plain[code].isalpha()
        use_shift = bool(mods & SHIFT) ^ (letter and bool(mods & CAPS))
        value = ord(shifted[code] if use_shift and code in shifted else plain[code])
    else:
        return 0
    if mods & CTRL:
        ch = chr(value)
        if 'a' <= ch <= 'z' or '@' <= ch <= '_':
            return value & 0x1F
        return 0
    return value


def test_every_scancode_and_modifier():
    for mods in range(0x20):
        for code in range(0x59):
            regs, _ = blob.call('kbd_translate', ax=0xAB00 | code, bx=0x1200 | mods)
            assert regs['ax'] & 0xFF == expected(code, mods), (hex(code), hex(mods))
            assert regs['ax'] >> 8 == 0xAB
            assert regs['bx'] == 0x1200 | mods


def test_beyond_the_table():
    for code in range(0x59, 0x80):
        regs, _ = blob.call('kbd_translate', ax=code, bx=0)
        assert regs['ax'] & 0xFF == 0
