# rx286 - tests/unit/test_selftest.py: the harness runs a routine and sees memory.
from x86 import Blob


def test_add_store():
    blob = Blob('selftest')
    regs, mem = blob.call('add_store', ax=0x1234, bx=0x1111, di=0x10)
    assert regs['ax'] == 0x2345
    assert mem[0x10:0x12] == b'\x45\x23'
