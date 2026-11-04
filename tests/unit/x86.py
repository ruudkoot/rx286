# ============================================================================
# rx286 - tests/unit/x86.py
# Runs pure routines of rx286 on the host: NASM assembles a small blob around
# a module, and Unicorn executes its routines in 16-bit mode (roadmap D18).
#
# Unicorn is not a 286 and has no protection, so only routines that take
# registers and memory and touch no hardware are tested this way. The blob
# runs in real-mode segments: code at 1000:0000, data at 2000:0000, the stack
# at 3000:FFFE.
# ============================================================================

import os
import subprocess
import sys
import tempfile

from unicorn import Uc, UC_ARCH_X86, UC_MODE_16
from unicorn import x86_const as X

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(ROOT, 'tools'))
import rxlib  # noqa: E402

CODE_SEG, DATA_SEG, STACK_SEG = 0x1000, 0x2000, 0x3000
RETURN_IP = 0xFFF0          # a routine returns here, which ends the run
REGS = {'ax': X.UC_X86_REG_AX, 'bx': X.UC_X86_REG_BX, 'cx': X.UC_X86_REG_CX,
        'dx': X.UC_X86_REG_DX, 'si': X.UC_X86_REG_SI, 'di': X.UC_X86_REG_DI,
        'bp': X.UC_X86_REG_BP, 'flags': X.UC_X86_REG_FLAGS}


class Blob:
    """A blob assembled from tests/unit/<name>.asm, ready to call."""

    def __init__(self, name, defines=('RELEASE',)):
        src = os.path.join(ROOT, 'tests', 'unit', name + '.asm')
        self.tmp = tempfile.TemporaryDirectory()
        out = os.path.join(self.tmp.name, name + '.bin')
        mapfile = os.path.join(self.tmp.name, name + '.map')
        cmd = ['nasm', '-f', 'bin', '-w+all', '-w+error',
               '-I' + os.path.join(ROOT, 'src', 'include') + '/',
               '-I' + os.path.join(ROOT, 'src', 'kernel') + '/',
               '-I' + os.path.join(ROOT, 'src', 'userland') + '/',
               '-I' + os.path.join(ROOT, 'src', 'boot-loader') + '/',
               '-dMAPFILE=' + mapfile, '-o', out, src]
        cmd += ['-d' + d for d in defines]
        subprocess.run(cmd, check=True)
        self.code = open(out, 'rb').read()
        assert len(self.code) < RETURN_IP, 'blob too large'
        self.symbols = rxlib.symbol_offsets(mapfile)

    def call(self, routine, data=b'', limit=1_000_000, **regs):
        """Call `routine` with registers `regs` and `data` at 2000:0000.
        Returns (registers after, the data segment's 64 KB)."""
        mu = Uc(UC_ARCH_X86, UC_MODE_16)
        mu.mem_map(0x10000, 0x30000)
        mu.mem_write(CODE_SEG * 16, self.code)
        mu.mem_write(CODE_SEG * 16 + RETURN_IP, b'\x90')
        if data:
            mu.mem_write(DATA_SEG * 16, bytes(data))
        mu.reg_write(X.UC_X86_REG_CS, CODE_SEG)
        mu.reg_write(X.UC_X86_REG_DS, DATA_SEG)
        mu.reg_write(X.UC_X86_REG_ES, DATA_SEG)
        mu.reg_write(X.UC_X86_REG_SS, STACK_SEG)
        mu.reg_write(X.UC_X86_REG_SP, 0xFFFE - 2)
        mu.mem_write(STACK_SEG * 16 + 0xFFFE - 2, RETURN_IP.to_bytes(2, 'little'))
        for name, value in regs.items():
            mu.reg_write(REGS[name], value & 0xFFFF)
        start = CODE_SEG * 16 + self.symbols[routine]
        mu.emu_start(start, CODE_SEG * 16 + RETURN_IP, count=limit)
        if mu.reg_read(X.UC_X86_REG_IP) != RETURN_IP:
            raise RuntimeError('%s did not return within %d instructions' % (routine, limit))
        out = {name: mu.reg_read(reg) for name, reg in REGS.items()}
        out['cf'] = out['flags'] & 1
        out['zf'] = (out['flags'] >> 6) & 1
        return out, bytes(mu.mem_read(DATA_SEG * 16, 0x10000))
