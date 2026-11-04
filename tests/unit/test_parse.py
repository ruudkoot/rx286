# rx286 - tests/unit/test_parse.py: the shell's command-line parsing.
import pytest

from x86 import Blob

blob = Blob('parse')
TEXT, WORD = 0x100, 0x400


def call(routine, text, word=b''):
    data = bytearray(0x800)
    data[TEXT:TEXT + len(text) + 1] = text + b'\0'
    data[WORD:WORD + len(word) + 1] = word + b'\0'
    regs, _ = blob.call(routine, data=data, si=TEXT, di=WORD, ax=0x5A5A, cx=0x1234)
    return regs


@pytest.mark.parametrize('text,word,matches,rest', [
    (b'echo hello', b'echo', True, b'hello'),
    (b'   echo   hello  ', b'echo', True, b'hello  '),
    (b'echo', b'echo', True, b''),
    (b'echoes', b'echo', False, None),
    (b'ech', b'echo', False, None),
    (b'help', b'echo', False, None),
    (b'', b'echo', False, None),
    (b'crash gp', b'crash', True, b'gp'),
    (b'Echo', b'echo', True, b''),
    (b'DIR C:\\', b'dir', True, b'C:\\'),
    (b'eCHO x', b'echo', True, b'x'),
    (b'ech0', b'echo', False, None),
    (b'[cho', b'{cho', False, None),
])
def test_parse_match(text, word, matches, rest):
    regs = call('parse_match', text, word)
    assert regs['cf'] == (0 if matches else 1)
    if matches:
        assert regs['si'] == TEXT + len(text) - len(rest)
    else:
        assert regs['si'] == TEXT
    assert regs['di'] == WORD and regs['ax'] == 0x5A5A


@pytest.mark.parametrize('text,length', [(b'gp', 2), (b'gp x', 2), (b'', 0), (b' x', 0),
                                         (b'kernel', 6)])
def test_parse_word_length(text, length):
    regs = call('parse_word_length', text)
    assert regs['cx'] == length
    assert regs['ax'] == 0x5A5A and regs['si'] == TEXT


def test_skip_spaces():
    assert call('parse_skip_spaces', b'    x')['si'] == TEXT + 4
