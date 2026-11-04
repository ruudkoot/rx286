# rx286 - tests/unit/test_fatname.py: FAT names and time stamps as text.
import random

import pytest

from x86 import Blob

blob = Blob('fatname')
TEXT, NAME, OUT = 0x100, 0x400, 0x600


def parse(text):
    data = bytearray(0x800)
    data[TEXT:TEXT + len(text) + 1] = text + b'\0'
    data[NAME:NAME + 11] = b'#' * 11
    regs, mem = blob.call('fat_name_parse', data=data, si=TEXT, di=NAME, bx=0x1234,
                          cx=0x5678)
    assert regs['di'] == NAME and regs['bx'] == 0x1234 and regs['cx'] == 0x5678
    return regs, mem[NAME:NAME + 11]


@pytest.mark.parametrize('text,name,used', [
    (b'readme.txt', b'README  TXT', 10),
    (b'README.TXT', b'README  TXT', 10),
    (b'many', b'MANY       ', 4),
    (b'a.b', b'A       B  ', 3),
    (b'numbers.', b'NUMBERS    ', 8),
    (b'12345678.abc', b'12345678ABC', 12),
    (b'~$!(x).{}', b"~$!(X)  {} ", 9),
    (b'.', b'.          ', 1),
    (b'..', b'..         ', 2),
    (b'docs\\hello.txt', b'DOCS       ', 4),
    (b'docs/hello.txt', b'DOCS       ', 4),
    (b'hello.txt more', b'HELLO   TXT', 9),
    (b'..\\docs', b'..         ', 2),
])
def test_parse_good(text, name, used):
    regs, got = parse(text)
    assert regs['cf'] == 0
    assert got == name
    assert regs['si'] == TEXT + used


@pytest.mark.parametrize('text', [
    b'', b'\\', b' ', b'toolongname', b'name.text', b'a.b.c', b'bad*', b'what?',
    b'a+b', b'semi;', b'.x', b'...', b'x:', b'"q"', b'tab\tx', b'\x80',
])
def test_parse_bad(text):
    regs, _ = parse(text)
    assert regs['cf'] == 1


def text_of(name):
    data = bytearray(0x800)
    data[NAME:NAME + 11] = name
    regs, mem = blob.call('fat_name_text', data=data, si=NAME, di=OUT, ax=0x5A5A)
    assert regs['si'] == NAME and regs['ax'] == 0x5A5A
    return mem[OUT:regs['di']]


@pytest.mark.parametrize('name,text', [
    (b'README  TXT', b'README.TXT'), (b'NUMBERS TXT', b'NUMBERS.TXT'),
    (b'MANY       ', b'MANY'), (b'.          ', b'.'), (b'..         ', b'..'),
    (b'ABCDEFGHXYZ', b'ABCDEFGH.XYZ'), (b'A       B  ', b'A.B'),
])
def test_name_text(name, text):
    assert text_of(name) == text


def stamp(routine, value):
    regs, mem = blob.call(routine, data=bytes(0x800), ax=value, di=OUT)
    assert regs['ax'] == value
    return mem[OUT:regs['di']].decode()


def test_dates():
    rng = random.Random(286)
    values = [0, 0xFFFF, (9 << 9) | (1 << 5) | 1] + [rng.randrange(0x10000) for _ in range(200)]
    for v in values:
        assert stamp('fmt_fat_date', v) == '%d-%02d-%02d' % (1980 + (v >> 9), (v >> 5) & 15,
                                                            v & 31)
    assert stamp('fmt_fat_date', (9 << 9) | (1 << 5) | 1) == '1989-01-01'


def test_times():
    rng = random.Random(287)
    for v in [0, (23 << 11) | (59 << 5) | 29] + [rng.randrange(0x10000) for _ in range(200)]:
        hours, minutes = v >> 11, (v >> 5) & 63
        if hours > 99 or minutes > 99:
            continue
        assert stamp('fmt_fat_time', v) == '%02d:%02d' % (hours, minutes)
