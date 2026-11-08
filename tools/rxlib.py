# ============================================================================
# rx286 - tools/rxlib.py
# Shared code of the tools: NASM map files, Bochs symbol files, the bochsrc
# template, key scripts, and running Bochs.
#
# The tools import it as `import rxlib`: Python puts the script's directory,
# tools/, first on the module path.
# ============================================================================

import os
import re
import struct
import subprocess
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# Every tool that imports this runs in UTC, and so does everything it starts:
# mtools turns SOURCE_DATE_EPOCH into a FAT time stamp in local time, and
# Bochs its time0 into the CMOS clock likewise, so the host's time zone would
# be in the disks' bytes and the guest's date (roadmap os-server.md P15).
os.environ['TZ'] = 'UTC'
time.tzset()


# ---------------------------------------------------------------- expressions
# NASM's and C's integer expressions, each by its own rules (roadmap
# os-server.md P15): NASM's numbers are 64 bits, its / and % unsigned (// and
# %% signed), its >> logical, and its comparisons bind more loosely than &, ^
# and |; C's int is 16 bits here (Open Watcom's and gcc-ia16's small model),
# its long 32, and a signed overflow or a shift past the width is undefined.
# tools/inc2h checks with them that a header means what its include file
# does; include_constants reads the include files by NASM's.

class ExpressionError(ValueError):
    pass


NASM_BINARY = {'||': 1, '^^': 2, '&&': 3, '=': 4, '==': 4, '!=': 4, '<>': 4, '<': 4, '<=': 4,
               '>': 4, '>=': 4, '|': 5, '^': 6, '&': 7, '<<': 8, '>>': 8, '<<<': 8, '>>>': 8,
               '+': 9, '-': 9, '*': 10, '/': 10, '//': 10, '%': 10, '%%': 10}
C_BINARY = {'||': 1, '&&': 2, '|': 3, '^': 4, '&': 5, '==': 6, '!=': 6, '<': 7, '<=': 7,
            '>': 7, '>=': 7, '<<': 8, '>>': 8, '+': 9, '-': 9, '*': 10, '/': 10, '%': 10}
OPERATORS = sorted(set(NASM_BINARY) | set(C_BINARY) | {'~', '!', '(', ')'}, key=len,
                   reverse=True)
NASM_NUMBER = re.compile(r'0[xX][0-9A-Fa-f]+|[0-9][0-9A-Fa-f]*[hH]|[01]+[bB]|[0-9]+(?![\w.$])')
C_NUMBER = re.compile(r'(0[xX][0-9A-Fa-f]+|0[0-7]*|[1-9][0-9]*)([uU]?[lL]?|[lL][uU])(?![\w.$])')
NAME = re.compile(r'[A-Za-z_][A-Za-z0-9_]*')


def tokens(expr, c):
    """An expression's tokens: ('num', text), ('name', text), ('op', text).
    Anything else (strings, $, a number of another base) is refused."""
    out, i = [], 0
    while i < len(expr):
        if expr[i].isspace():
            i += 1
            continue
        m = (C_NUMBER if c else NASM_NUMBER).match(expr, i)
        if m and m.end() > i:
            out.append(('num', m.group(0)))
            i = m.end()
            continue
        m = NAME.match(expr, i)
        if m:
            out.append(('name', m.group(0)))
            i = m.end()
            continue
        op = next((o for o in OPERATORS if expr.startswith(o, i)), None)
        if op is None or not c and op not in NASM_BINARY and op not in '~!()' or \
                c and op not in C_BINARY and op not in '~!()':
            raise ExpressionError('not understood at %r' % expr[i:])
        out.append(('op', op))
        i += len(op)
    return out


def parse(toks, binary):
    """A list of tokens to a tree: ('num', text), ('name', text), (op, a)
    for a unary operator, (op, a, b) for a binary one."""
    pos = [0]

    def peek():
        return toks[pos[0]] if pos[0] < len(toks) else (None, None)

    def take():
        pos[0] += 1
        return toks[pos[0] - 1]

    def unary():
        kind, text = peek()
        if kind == 'op' and text in ('-', '+', '~', '!'):
            take()
            return ('u' + text, unary())
        if kind == 'op' and text == '(':
            take()
            tree = climb(1)
            if take() != ('op', ')'):
                raise ExpressionError('a ( without its )')
            return tree
        if kind in ('num', 'name'):
            return take()
        raise ExpressionError('an operand missing')

    def climb(least):
        tree = unary()
        while True:
            kind, text = peek()
            if kind != 'op' or text not in binary or binary[text] < least:
                return tree
            take()
            tree = (text, tree, climb(binary[text] + 1))
    tree = climb(1)
    if pos[0] != len(toks):
        raise ExpressionError('more after the expression: %r' % (toks[pos[0]],))
    return tree


def nasm_number(text):
    if text[:2] in ('0x', '0X'):
        return int(text[2:], 16)
    if text[-1] in 'hH':
        return int(text[:-1], 16)
    if text[-1] in 'bB':
        return int(text[:-1], 2)
    return int(text, 10)                    # NASM: a leading 0 is no octal


def nasm_value(expr, names):
    """An expression's value as NASM computes it (a signed 64-bit int);
    `names` maps the names it may use to their values."""
    def wrap(v):
        return (v + (1 << 63)) % (1 << 64) - (1 << 63)

    def u(v):
        return v % (1 << 64)

    def trunc_div(a, b):
        q = abs(a) // abs(b)
        return q if (a < 0) == (b < 0) else -q

    def ev(t):
        if t[0] == 'num':
            return wrap(nasm_number(t[1]))
        if t[0] == 'name':
            if t[1] not in names:
                raise ExpressionError('no value for %s' % t[1])
            return names[t[1]]
        if len(t) == 2:
            a = ev(t[1])
            return {'u-': lambda: wrap(-a), 'u+': lambda: a, 'u~': lambda: wrap(~a),
                    'u!': lambda: int(a == 0)}[t[0]]()
        op, a, b = t[0], ev(t[1]), ev(t[2])
        if op in ('/', '//', '%', '%%') and b == 0:
            raise ExpressionError('division by zero')
        if op in ('<<', '<<<', '>>', '>>>') and not 0 <= b < 64:
            return 0 if op != '>>>' or a >= 0 else -1
        return wrap({'+': lambda: a + b, '-': lambda: a - b, '*': lambda: a * b,
                     '/': lambda: u(a) // u(b), '//': lambda: trunc_div(a, b),
                     '%': lambda: u(a) % u(b), '%%': lambda: a - trunc_div(a, b) * b,
                     '<<': lambda: a << b, '<<<': lambda: a << b,
                     '>>': lambda: u(a) >> b, '>>>': lambda: a >> b,
                     '&': lambda: a & b, '|': lambda: a | b, '^': lambda: a ^ b,
                     '=': lambda: int(a == b), '==': lambda: int(a == b),
                     '!=': lambda: int(a != b), '<>': lambda: int(a != b),
                     '<': lambda: int(a < b), '<=': lambda: int(a <= b),
                     '>': lambda: int(a > b), '>=': lambda: int(a >= b),
                     '&&': lambda: int(bool(a) and bool(b)),
                     '||': lambda: int(bool(a) or bool(b)),
                     '^^': lambda: int(bool(a) != bool(b))}[op]())
    return ev(parse(tokens(expr, False), NASM_BINARY))


def c_value(expr, names, int_bits=16, long_bits=32):
    """An expression's value and type as C computes it: (value, bits,
    signed). `names` maps a name to its (value, bits, signed), as a #define
    of a parenthesised expression has its type. int_bits=long_bits=64 is the
    preprocessor's #if. Undefined behaviour (a signed overflow, a shift past
    the width) is refused."""
    INT, UINT, LONG, ULONG = (int_bits, True), (int_bits, False), (long_bits, True), \
        (long_bits, False)

    def fits(v, kind):
        bits, signed = kind
        return -(1 << bits - 1) <= v < (1 << bits - 1) if signed else 0 <= v < (1 << bits)

    def literal(text):
        m = C_NUMBER.fullmatch(text)
        digits, suffix = m.group(1), m.group(2).lower()
        v = int(digits, 16) if digits[:2].lower() == '0x' else \
            int(digits, 8) if digits.startswith('0') else int(digits)
        decimal = not digits.startswith('0') or digits == '0'
        if 'u' in suffix:
            kinds = [ULONG] if 'l' in suffix else [UINT, ULONG]
        elif 'l' in suffix:
            kinds = [LONG, ULONG]
        else:                                   # C89's: a decimal is never unsigned int
            kinds = [INT, LONG, ULONG] if decimal else [INT, UINT, LONG, ULONG]
        for kind in kinds:
            if fits(v, kind):
                return v, kind
        raise ExpressionError('%s fits no C type' % text)

    def common(ka, kb):
        # The usual arithmetic conversions: the wider type, which holds every
        # value of the narrower here (long 32 bits, int 16); of one width,
        # unsigned if either is
        if ka[0] != kb[0]:
            return ka if ka[0] > kb[0] else kb
        return ka if ka == kb else (ka[0], False)

    def convert(v, kind):
        bits, signed = kind
        if signed:
            if not fits(v, kind):
                raise ExpressionError('%d does not fit a signed %d-bit int' % (v, bits))
            return v
        return v % (1 << bits)

    def result(v, kind):
        if kind[1] and not fits(v, kind):
            raise ExpressionError('a signed %d-bit overflow (%d)' % (kind[0], v))
        return convert(v, kind), kind

    def ev(t):
        if t[0] == 'num':
            return literal(t[1])
        if t[0] == 'name':
            if t[1] not in names:
                raise ExpressionError('no value for %s' % t[1])
            v, bits, signed = names[t[1]]
            return v, (bits, signed)
        if len(t) == 2:
            a, ka = ev(t[1])
            if t[0] == 'u!':
                return int(a == 0), INT
            if t[0] == 'u+':
                return a, ka
            if t[0] == 'u-':
                return result(-a, ka)
            return result(~a if ka[1] else ~a % (1 << ka[0]), ka)
        op = t[0]
        (a, ka), (b, kb) = ev(t[1]), ev(t[2])
        if op in ('&&', '||'):
            return int(bool(a) and bool(b) if op == '&&' else bool(a) or bool(b)), INT
        if op in ('<<', '>>'):
            if not 0 <= b < ka[0]:
                raise ExpressionError('a shift by %d of a %d-bit value' % (b, ka[0]))
            if op == '<<':
                if ka[1] and (a < 0 or not fits(a << b, ka)):
                    raise ExpressionError('a signed shift out of range: %d << %d' % (a, b))
                return convert(a << b, ka), ka
            return a >> b, ka
        kind = common(ka, kb)
        a, b = convert(a, kind), convert(b, kind)
        if op in ('==', '!=', '<', '<=', '>', '>='):
            return int({'==': a == b, '!=': a != b, '<': a < b, '<=': a <= b, '>': a > b,
                        '>=': a >= b}[op]), INT
        if op in ('/', '%'):
            if b == 0:
                raise ExpressionError('division by zero')
            q = abs(a) // abs(b) * (1 if (a < 0) == (b < 0) else -1)
            return result(q if op == '/' else a - q * b, kind)
        return result({'+': a + b, '-': a - b, '*': a * b, '&': a & b, '|': a | b,
                       '^': a ^ b}[op], kind)
    v, (bits, signed) = ev(parse(tokens(expr, True), C_BINARY))
    return v, bits, signed


def same_value(nasm, c):
    """Whether C's (value, bits, signed) holds NASM's value: the same, or
    the same bits of a value that fits them (-1 as an unsigned 0FFFFh)."""
    v, bits, signed = c
    if nasm == v:
        return True
    return -(1 << bits - 1) <= nasm < (1 << bits) and (nasm - v) % (1 << bits) == 0


def include_constants(name, names=None):
    """The `NAME equ value` constants of src/include/<name>, as NASM
    evaluates them (nasm_value), and those of the files it includes. A
    constant that cannot be evaluated stops it: a tool must not read a
    number wrong, nor miss one, in silence."""
    values = dict(names or {})
    path = os.path.join(ROOT, 'src', 'include', name)
    for n, line in enumerate(open(path, encoding='utf-8'), 1):
        line = line.split(';', 1)[0].strip()
        inc = re.match(r'^%include\s+"([^"]+)"', line)
        if inc:
            values.update(include_constants(inc.group(1), values))
            continue
        m = re.match(r'^([A-Za-z_][A-Za-z0-9_]*)\s+equ\s+(.+)$', line)
        if not m:
            continue
        expr = re.sub(r"'([^']{1,8})'", lambda q: str(int.from_bytes(
            q.group(1).encode('latin-1'), 'little')), m.group(2))
        try:
            values[m.group(1)] = nasm_value(expr, values)
        except ExpressionError as e:
            raise ExpressionError('%s:%d: %s: %s' % (path, n, m.group(1), e))
    return values


LAYOUT = include_constants('layout.inc')


# ---------------------------------------------------------------- NASM maps

def read_map(path):
    """Symbols of a NASM map file: a list of (section, real, virtual, name).
    `real` is the file offset, `virtual` the offset in the segment."""
    symbols = []
    section = None
    in_symbols = False
    for line in open(path, encoding='utf-8', errors='replace'):
        if line.startswith('-- Symbols'):
            in_symbols = True
            continue
        if not in_symbols:
            continue
        m = re.match(r'^---- Section (\S+)', line)
        if m:
            section = m.group(1)
            continue
        m = re.match(r'^\s+([0-9A-F]+)\s+([0-9A-F]+)\s+(\S+)\s*$', line)
        if m and section:
            symbols.append((section, int(m.group(1), 16), int(m.group(2), 16), m.group(3)))
    return symbols


def map_sections(path):
    """name -> (file offset, length) for every section of a NASM map file."""
    sections = {}
    for line in open(path, encoding='utf-8', errors='replace'):
        m = re.match(r'^\s*([0-9A-F]+)\s+([0-9A-F]+)\s+([0-9A-F]+)\s+([0-9A-F]{8})\s+'
                     r'(progbits|nobits)\s+(\S+)', line)
        if m:
            sections[m.group(6)] = (int(m.group(2), 16), int(m.group(4), 16))
    return sections


# ---------------------------------------------------------------- the boot image

def image_modules(image):
    """The modules of a boot image (bytes): a list of dicts of the module
    table's fields (layout.inc), the first the root's."""
    L = LAYOUT
    table = L['MODULE_TABLE_OFF']
    count = int.from_bytes(image[table + L['MH_COUNT']:table + L['MH_COUNT'] + 2], 'little')
    modules = []
    for n in range(count):
        e = table + L['MODULE_HEADER_SIZE'] + n * L['MODULE_ENTRY_SIZE']

        def word(field):
            return int.from_bytes(image[e + field:e + field + 2], 'little')
        modules.append({
            'name': image[e:e + L['M_NAME_SIZE']].split(b'\0', 1)[0].decode('ascii'),
            'code': word(L['M_CODE']) * 16, 'code_size': word(L['M_CODE_SIZE']),
            'data': word(L['M_DATA']) * 16, 'data_size': word(L['M_DATA_SIZE']),
            'data_room': word(L['M_DATA_ROOM']), 'stack': word(L['M_STACK']),
            'entry': word(L['M_ENTRY']), 'ring': image[e + L['M_RING']],
            'priority': image[e + L['M_PRIORITY']], 'flags': image[e + L['M_FLAGS']],
            'data_at': word(L['M_DATA_AT']), 'irq': image[e + L['M_IRQ']],
            'service': image[e + L['M_SERVICE']],
        })
    return modules


def fletcher(data):
    """The boot tests' sum of an image (entry.asm): over its words, the sum
    of the running sums, 16 bits."""
    plain = total = 0
    for i in range(0, len(data) - 1, 2):
        plain = (plain + data[i] + 256 * data[i + 1]) & 0xFFFF
        total = (total + plain) & 0xFFFF
    return total


def symbol_offsets(path):
    """name -> offset in its segment, for every symbol of a map file."""
    return {name: virt for _, _, virt, name in read_map(path)}


# The modules' binaries, by their names in the module table, and the
# prefixes of their symbols.
MODULE_BINARIES = {'root': ('root', 'r.'), 'os': ('os', 'o.'), 'program': ('user', 'u.'),
                   'counter': ('counter', 'c.'), 'printer': ('printer', 'p.'),
                   'mouse': ('mouse', 'm.'), 'console': ('console', 'v.'),
                   'kbd': ('keyboard', 'k.'), 'fd': ('diskette', 'f.'),
                   'hd': ('fixeddisk', 'h.'), 'serial': ('serial', 's.'),
                   'sound': ('sound', 'a.'), 'rtc': ('rtc', 't.'),
                   'clock': ('clock', 'l.')}


def binary_bases(build_dir):
    """Where each binary's file offset 0 lies in memory: for a module, where
    its code is in the image (its data is copied elsewhere at start)."""
    bases = {
        'boot-sector': (LAYOUT['BOOT_SECTOR_PHYS'], 'bs.'),
        'boot-loader': (LAYOUT['LOADER_PHYS'], 'ld.'),
        'kernel': (LAYOUT['KERNEL_PHYS'], ''),
    }
    path = os.path.join(build_dir, 'image.bin')
    if os.path.exists(path):
        for module in image_modules(open(path, 'rb').read()):
            if module['name'] in MODULE_BINARIES:
                binary, prefix = MODULE_BINARIES[module['name']]
                bases[binary] = (LAYOUT['KERNEL_PHYS'] + module['code'], prefix)
    return bases


# A module's data sections: copied to a segment of its own at its start,
# so its symbols have no linear address a symbol file could give
MODULE_DATA_SECTIONS = ('udata', 'rxdata')


def bochs_symbols(build_dir):
    """Lines of a Bochs symbol file: every symbol at its linear address;
    a module's data symbols, which have none, are left out."""
    lines = []
    for binary, (base, prefix) in binary_bases(build_dir).items():
        path = os.path.join(build_dir, binary + '.map')
        if not os.path.exists(path):
            continue
        module = binary not in ('boot-sector', 'boot-loader', 'kernel')
        for section, real, _, name in read_map(path):
            if not (module and section in MODULE_DATA_SECTIONS):
                lines.append((base + real, prefix + name))
    lines.sort()
    return ['%08x %s' % (addr, name) for addr, name in lines]


# ---------------------------------------------------------------- Bochs

BOCHSRC_TEMPLATE = os.path.join(ROOT, 'bochs', 'rx286.bochsrc.in')
DISKS = os.path.join(ROOT, 'build', 'disks')     # as tools/mkdisks made them, for copies
RUN_DISKS = os.path.join(ROOT, 'build', 'run-disks')    # make run's, which it writes to


# What a test may change of the drives and printers (tools/run-test's
# `media:`): the first four in the emulator (LPT2's adapter gone: Bochs
# only), the others in the run's copies of the images (damage_disks).
MEDIA = ('B ejected', 'B protected', 'D absent', 'LPT2 absent', 'B damaged', 'D blank',
         'B deep', 'B loop', 'B zerodir', 'B longnames')
# 'B deep': directories whose paths reach DOS's 64 characters (PATH_MAX).
DEEP_PATH = '/'.join(c * 8 for c in 'ABCDEF')      # 54 characters as \AAAAAAAA...
DEEP_FITS = 'ABCDEFG.X'          # \ and 9 more: exactly 64
DEEP_TOO_LONG = 'ABCDEFGH.XY'    # 66


def write_bochsrc(path, image, serial, log, display, disks, debugger_log=None, magic=False,
                  printers=('/dev/null', '/dev/null'), media=(),
                  log_port='com2', modem=None):
    """Write a bochsrc for one run from bochs/rx286.bochsrc.in. Bochs locks
    the hard-disk images, so runs at the same time need their own `disks`,
    and writes to them: never DISKS, which the runs copy.
    `serial` is the file the log goes to, from `log_port`: 'com2' (debug and
    test builds), 'com3' (a test build whose COM2 is the modem, MODEM_COM2),
    or None (a release build, whose COM2 is the modem); `modem` the host:port
    the modem on COM2 connects to, if any. `printers` are the files LPT1 and LPT2 print into; `media`
    a list of MEDIA."""
    for m in media:
        if m not in MEDIA:
            raise ValueError('unknown media change %r' % m)
    text = open(BOCHSRC_TEMPLATE, encoding='utf-8').read()
    subs = {
        '@IMAGE@': image,
        '@FDB@': os.path.join(disks, 'fdb.img'),
        '@FDB_STATUS@': 'ejected' if 'B ejected' in media else 'inserted',
        '@FDB_PROTECTED@': '1' if 'B protected' in media else '0',
        '@HD0@': os.path.join(disks, 'hd0.img'),
        '@HD1@': os.path.join(disks, 'hd1.img'),
        '@HD1_TYPE@': 'none' if 'D absent' in media else 'disk',
        '@LPT1@': printers[0],
        '@LPT2@': printers[1],
        '@LPT2_ENABLED@': '0' if 'LPT2 absent' in media else '1',
        '@COM2@': ('mode=file, dev=' + serial if log_port == 'com2' else
                   'mode=socket-client, dev=' + modem if modem else 'mode=null'),
        '@COM3@': 'mode=file, dev=' + serial if log_port == 'com3' else 'mode=null',
        '@CLOCK_SYNC@': 'realtime' if modem else 'none',
        '@LOG@': log,
        '@DISPLAY@': display,
        '@CONFIG_INTERFACE@': 'wx' if display == 'wx' else 'textconfig',
        '@DEBUGGER_LOG@': debugger_log or '/dev/null',
        '@MAGIC@': '1' if magic else '0',
    }
    for key, value in subs.items():
        text = text.replace(key, value)
    leftover = re.findall(r'@[A-Z_]+@', text)
    if leftover:
        raise RuntimeError('bochsrc template: unknown placeholders %s' % leftover)
    with open(path, 'w', encoding='utf-8') as f:
        f.write(text)


DISPLAY_HEADLESS = 'rfb, options="timeout=0"'


DISK_IMAGES = ('fdb.img', 'hd0.img', 'hd1.img')     # drives B, C, D (tools/mkdisks)
FAT12_BAD_LINK = 0xFF0          # a reserved value: no cluster of any volume
LONG_NAMES = ('A long name.txt', 'Another long one.txt')   # 'B longnames' (P15)


def damage_disks(directory, media):
    """The changes of MEDIA made to a run's copies of the images: 'D blank'
    zeroes fixed disk D (no partition at all); 'B damaged' points the FAT
    entry of B:\\MANY's first cluster outside the volume, in both FATs, and
    'B loop' to itself, its 32 entries all used (os-server.md P15);
    'B zerodir' zeroes the first cluster of MANY's entry; 'B longnames'
    adds two files with long names (VFAT's entries before their 8.3 ones);
    'B deep' adds DEEP_PATH, and in it DEEP_FITS and DEEP_TOO_LONG. Two
    changes of MANY at once ('B zerodir', 'B damaged', 'B loop') are
    refused, and so is a change of MANY when B has none: a test must never
    run on a drive it believes damaged and is not."""
    of_many = [m for m in media if m in ('B zerodir', 'B damaged', 'B loop')]
    if len(of_many) > 1:
        raise ValueError('media: %s change the same directory, MANY' % ' and '.join(of_many))
    if 'B deep' in media:
        path = os.path.join(directory, 'fdb.img')
        env = dict(os.environ, MTOOLS_SKIP_CHECK='1', SOURCE_DATE_EPOCH='599616000')
        parts = DEEP_PATH.split('/')
        for n in range(len(parts)):
            subprocess.run(['mmd', '-i', path, '::/' + '/'.join(parts[:n + 1])],
                           env=env, check=True, capture_output=True)
        for name in (DEEP_FITS, DEEP_TOO_LONG):
            subprocess.run(['mmd', '-i', path, '::/%s/%s' % (DEEP_PATH, name)],
                           env=env, check=True, capture_output=True)
    if 'D blank' in media:
        path = os.path.join(directory, 'hd1.img')
        size = os.path.getsize(path)
        with open(path, 'r+b') as f:
            f.truncate(0)
            f.truncate(size)
    if 'B zerodir' in media:
        path = os.path.join(directory, 'fdb.img')
        with open(path, 'r+b') as f:
            boot = f.read(512)
            reserved = int.from_bytes(boot[0x0E:0x10], 'little')
            fats, per_fat = boot[0x10], int.from_bytes(boot[0x16:0x18], 'little')
            roots = int.from_bytes(boot[0x11:0x13], 'little')
            at = (reserved + fats * per_fat) * 512
            f.seek(at)
            root = f.read(roots * 32)
            found = [k for k in range(roots) if root[k * 32:k * 32 + 11] == b'MANY       ']
            if len(found) != 1:
                raise ValueError("media: B zerodir: B's root holds %d MANY" % len(found))
            f.seek(at + found[0] * 32 + 0x1A)
            f.write(b'\0\0')
    if 'B longnames' in media:
        path = os.path.join(directory, 'fdb.img')
        env = dict(os.environ, MTOOLS_SKIP_CHECK='1', SOURCE_DATE_EPOCH='599616000')
        source = os.path.join(directory, 'longname.txt')
        with open(source, 'w') as f:
            f.write('A file with a long name.\n')
        for name in LONG_NAMES:
            subprocess.run(['mcopy', '-i', path, source, '::' + name], env=env, check=True,
                           capture_output=True, stdin=subprocess.DEVNULL)
        os.remove(source)
    if 'B damaged' in media or 'B loop' in media:
        path = os.path.join(directory, 'fdb.img')
        env = dict(os.environ, MTOOLS_SKIP_CHECK='1')
        chain = subprocess.run(['mshowfat', '-i', path, '::MANY'], capture_output=True,
                               text=True, env=env).stdout
        first = re.search(r'<(\d+)', chain)
        if not first:
            raise ValueError("media: B damaged or B loop: B has no MANY with a cluster")
        cluster = int(first.group(1))
        with open(path, 'r+b') as f:
            boot = f.read(512)
            reserved = int.from_bytes(boot[0x0E:0x10], 'little')
            fats, per_fat = boot[0x10], int.from_bytes(boot[0x16:0x18], 'little')
            for n in range(fats):
                at = (reserved + n * per_fat) * 512 + cluster * 3 // 2
                f.seek(at)
                pair = int.from_bytes(f.read(2), 'little')
                link = cluster if 'B loop' in media else FAT12_BAD_LINK
                if cluster & 1:
                    pair = (pair & 0x000F) | (link << 4)
                else:
                    pair = (pair & 0xF000) | link
                f.seek(at)
                f.write(pair.to_bytes(2, 'little'))


def install_file(image, fixed, path, source):
    """A file put on a drive's image at a path, its directories made: a
    fixed disk's in its first FAT12 partition (mtools at its offset). An
    error's text, or None. Never a question on the terminal: mtools asks
    one of a name already there, which a captured stderr would hide."""
    if fixed:
        data = open(image, 'rb').read(512)
        starts = [struct.unpack_from('<I', data, 0x1BE + 16 * k + 8)[0] for k in range(4)
                  if data[0x1BE + 16 * k + 4] == 1]
        if not starts:
            return 'no FAT12 partition on %s' % image
        image += '@@%d' % (starts[0] * 512)
    env = dict(os.environ, MTOOLS_SKIP_CHECK='1', SOURCE_DATE_EPOCH='599616000')
    parts = path.strip('/').split('/')
    for k in range(1, len(parts)):              # (-D s: there already, skipped)
        subprocess.run(['mmd', '-D', 's', '-i', image, '::/' + '/'.join(parts[:k])],
                       stdin=subprocess.DEVNULL, capture_output=True, env=env)
    done = subprocess.run(['mcopy', '-o', '-i', image, source, '::' + path],
                          stdin=subprocess.DEVNULL, capture_output=True, text=True, env=env)
    return done.stderr.strip() or 'mcopy failed' if done.returncode else None


def private_disks(directory):
    """Copies of drives B, C and D for one run, which may write to them. The
    images are sparse (tools/mkdisks), and so are the copies."""
    import shutil
    shutil.rmtree(directory, ignore_errors=True)   # with any lock a killed Bochs left
    os.makedirs(directory)
    for name in DISK_IMAGES:
        subprocess.run(['cp', '--sparse=always', os.path.join(DISKS, name),
                        os.path.join(directory, name)], check=True)
    return directory


BOCHS_PLUGINS = '/usr/lib/x86_64-linux-gnu/bochs/plugins'


def window_display():
    """The display for a Bochs window (make run, make debugger): X11
    (package bochs-x) or SDL2 (bochs-sdl) if installed, else wx (bochs-wx),
    which needs wx as the configuration interface too."""
    for name, plugin in (('x', 'libbx_x_gui.so'), ('sdl2', 'libbx_sdl2_gui.so')):
        if os.path.exists(os.path.join(BOCHS_PLUGINS, plugin)):
            return name
    return 'wx'


# ---------------------------------------------------------------- key scripts
#
# A test types keys through the kernel's test hook (src/kernel/test.asm),
# which reads a byte stream assembled into the test image:
#   01 s   type scancode s once the program waits for a key, its ring empty
#   02 s   type scancode s at the next tick, whatever the program does
#   03 n   wait n ticks
#   04 a b c   a mouse packet, to the mouse driver at the next tick
#   00     the end: once the program waits for a key, the test ends

OP_END, OP_WHEN_WAITING, OP_NOW, OP_WAIT, OP_MOUSE = 0, 1, 2, 3, 4

# Scancode set 1 of the US keyboard: character -> (scancode, shift).
_ROWS = [
    (0x02, '1234567890-=', '!@#$%^&*()_+'),
    (0x10, 'qwertyuiop[]', 'QWERTYUIOP{}'),
    (0x1E, "asdfghjkl;'`", 'ASDFGHJKL:"~'),
    (0x2B, '\\zxcvbnm,./', '|ZXCVBNM<>?'),
]
KEYS = {' ': (0x39, False), '\n': (0x1C, False), '\b': (0x0E, False),
        '\t': (0x0F, False), '\x1b': (0x01, False)}
for start, plain, shifted in _ROWS:
    for i, (p, s) in enumerate(zip(plain, shifted)):
        KEYS[p] = (start + i, False)
        KEYS[s] = (start + i, True)

SC_LSHIFT, SC_CTRL, SC_ALT = 0x2A, 0x1D, 0x38
SC_SCROLL_LOCK, SC_DELETE = 0x46, 0x53
NAMED = {'up': 0x48, 'down': 0x50, 'left': 0x4B, 'right': 0x4D,
         'esc': 0x01, 'enter': 0x1C, 'bs': 0x0E, 'caps': 0x3A,
         'scroll-lock': 0x46, 'del': 0x53, 'sysrq': 0x54, 'home': 0x47, 'end': 0x4F,
         'pgup': 0x49, 'pgdn': 0x51, 'ins': 0x52}
NAMED.update({'f%d' % n: 0x3A + n for n in range(1, 11)})   # F1 3Bh to F10 44h
# The named keys an enhanced keyboard has a grey twin of (E0h before it)
GREY = ('ins', 'del', 'home', 'end', 'pgup', 'pgdn', 'up', 'down', 'left', 'right', 'enter')


def compile_keys(script):
    """A key script to the kernel's byte stream (see above).

    Plain characters are typed as the US keyboard types them; escapes are
    \\n (Enter), \\b (Backspace), \\t (Tab), \\e (Esc), \\s (a space: one at a
    keys: line's ends, which run-test would take off). Braces name others:
    {up}, {down}, {left}, {right}, {home}, {end}, {pgup}, {pgdn}, {ins},
    {del}, {esc}, {f1} to {f10}, {caps}, {scroll-lock}, {sysrq} (the
    kernel's thread dump, in debug and test builds; {dump} the same at
    once, waiting or not), {ctrl-X} and {alt-X} for a key X or a named one
    ({alt-f2}), {ctrl-break}, {ctrl-alt-del} (typed at once, even if the
    program does not wait), {now K}: the key {K} typed at once, as ^C for a
    program that never reads ({now ctrl-c}), {wait N} (N ticks),
    {mouse DX DY B}: a Microsoft mouse's packet, DX right and DY down (-128
    to 127), B the buttons down (L, R, LR or -), and {mouse-bytes A B C}:
    three bytes from the mouse as they are, in hexadecimal; a packet, as a
    key, while a reader waits (os-server.md P12); {grey K}, a named key K
    as an enhanced keyboard's grey key or the keypad's Enter sends it, after
    E0h ({grey home}, {grey enter}: os-server.md P15), for the keys of GREY
    alone. {ctrl-X} and {alt-X} take an unshifted X, {wait N} an N of 1 or
    more: anything else is refused, never typed as something else."""
    out = []
    when = [OP_WHEN_WAITING]            # {now K}'s: OP_NOW for its key alone

    def press(code):
        # A release gives no ASCII, so it is typed at once: the program may
        # not wait again (a key that starts a loop).
        out.extend([when[0], code, OP_NOW, code | 0x80])

    def press_grey(code):
        # E0h before the key's make and before its release, as an enhanced
        # keyboard sends a grey key: the prefix and the key at once
        out.extend([when[0], 0xE0, OP_NOW, code, OP_NOW, 0xE0, OP_NOW, code | 0x80])

    i = 0
    while i < len(script):
        ch = script[i]
        if ch == '\\' and i + 1 < len(script):
            esc = {'n': '\n', 'b': '\b', 't': '\t', 'e': '\x1b', 's': ' ', '\\': '\\',
                   '{': '{'}
            ch = esc.get(script[i + 1])
            if ch is None:
                raise ValueError('key script: unknown escape \\%s' % script[i + 1])
            i += 2
        elif ch == '{':
            end = script.index('}', i)
            name = script[i + 1:end]
            i = end + 1
            when[0] = OP_WHEN_WAITING
            if name.startswith('now '):
                when[0] = OP_NOW
                name = name[4:]
            if name in NAMED:
                press(NAMED[name])
            elif name.startswith('grey ') and name[5:] in GREY:
                press_grey(NAMED[name[5:]])
            elif name.startswith('mouse-bytes '):
                raw = [int(b, 16) for b in name.split()[1:]]
                if len(raw) != 3 or not all(0 <= b < 0x80 for b in raw):
                    raise ValueError('key script: bad mouse bytes {%s}' % name)
                out.append(OP_MOUSE)
                out.extend(raw)
            elif name.startswith('mouse '):
                out.append(OP_MOUSE)
                out.extend(mouse_packet(name))
            elif name.startswith('wait '):
                n = int(name[5:])
                if n < 1:
                    raise ValueError('key script: {%s}: a wait of 1 tick or more' % name)
                while n > 0:
                    out.extend([OP_WAIT, min(n, 255)])
                    n -= 255
            elif name == 'dump':
                out.extend([OP_NOW, NAMED['sysrq'], OP_NOW, NAMED['sysrq'] | 0x80])
            elif name == 'ctrl-break':
                out.extend([OP_NOW, SC_CTRL, OP_NOW, SC_SCROLL_LOCK,
                            OP_NOW, SC_SCROLL_LOCK | 0x80, OP_NOW, SC_CTRL | 0x80])
            elif name == 'ctrl-alt-del':
                out.extend([OP_NOW, SC_CTRL, OP_NOW, SC_ALT, OP_NOW, SC_DELETE,
                            OP_NOW, SC_DELETE | 0x80, OP_NOW, SC_ALT | 0x80,
                            OP_NOW, SC_CTRL | 0x80])
            elif (name.startswith('ctrl-') and len(name) == 6 or
                  name.startswith('alt-') and len(name) == 5) and name[-1] in KEYS:
                if KEYS[name[-1]][1]:       # its shift would be lost: Ctrl+a for {ctrl-A}
                    raise ValueError('key script: {%s}: a shifted key under Ctrl or Alt'
                                     % name)
                modifier = SC_CTRL if name.startswith('ctrl-') else SC_ALT
                out.extend([when[0], modifier])
                press(KEYS[name[-1]][0])
                out.extend([OP_NOW, modifier | 0x80])
            elif name.startswith(('ctrl-', 'alt-')) and name.split('-', 1)[1] in NAMED:
                modifier = SC_CTRL if name.startswith('ctrl-') else SC_ALT
                out.extend([when[0], modifier])
                press(NAMED[name.split('-', 1)[1]])
                out.extend([OP_NOW, modifier | 0x80])
            else:
                raise ValueError('key script: unknown key {%s}' % name)
            when[0] = OP_WHEN_WAITING
            continue
        else:
            i += 1
        if ch not in KEYS:
            raise ValueError('key script: no key types %r' % ch)
        code, shift = KEYS[ch]
        if shift:
            out.extend([OP_WHEN_WAITING, SC_LSHIFT])
        press(code)
        if shift:
            out.extend([OP_NOW, SC_LSHIFT | 0x80])
    out.append(OP_END)
    return out


def mouse_packet(spec):
    """A key script's {mouse DX DY B} as the three bytes a Microsoft mouse
    sends: 1 L R Y7 Y6 X7 X6, 0 X5-X0, 0 Y5-Y0."""
    _, dx, dy, buttons = spec.split()
    dx, dy = int(dx), int(dy)
    if not (-128 <= dx <= 127 and -128 <= dy <= 127) or buttons not in ('-', 'L', 'R', 'LR'):
        raise ValueError('key script: bad mouse packet {%s}' % spec)
    x, y = dx & 0xFF, dy & 0xFF
    first = 0x40 | (0x20 if 'L' in buttons else 0) | (0x10 if 'R' in buttons else 0)
    first |= ((y >> 6) << 2) | (x >> 6)
    return [first, x & 0x3F, y & 0x3F]


def keys_include(script):
    """The NASM include of a key script: the label test_keys and its bytes."""
    data = compile_keys(script)
    lines = ['; generated by tools/rxlib.py from a test\'s key script', 'test_keys:']
    for k in range(0, len(data), 16):
        lines.append('    db ' + ', '.join('0x%02X' % b for b in data[k:k + 16]))
    return '\n'.join(lines) + '\n'


# ---------------------------------------------------------------- transcripts

FORM_FEED = '[form feed]'


STATUS_START, STATUS_END = '\x01', '\x02'


def normalise_transcript(raw):
    """The log's bytes (COM2's, or COM3's with a modem on COM2) as the lines
    a person would read: CR dropped, a form
    feed (or a run of them) as a line of its own, FORM_FEED, backspaces
    applied, trailing spaces trimmed. A background program's status, which
    a TEST_DEMO build puts between STATUS_START and STATUS_END wherever the
    log is (roadmap l4.md L11), comes out as a line of its own, "status,
    NAME: TEXT", after the line it fell in."""
    text = raw.decode('latin-1')
    # Test builds write trace lines straight to the log, even in the middle of
    # a line of the console's: cut them out, so the console's line joins up.
    text = re.sub(r'\[trace\][^\n]*\n', '', text)
    text = re.sub(r'\f+', '\n' + FORM_FEED + '\n', text.replace('\r', ''))
    lines = []
    for line in text.split('\n'):
        statuses = re.findall(STATUS_START + '([^' + STATUS_END + ']*)' + STATUS_END, line)
        line = re.sub(STATUS_START + '[^' + STATUS_END + ']*' + STATUS_END, '', line)
        chars = []
        for c in line:
            if c == '\b':
                if chars:
                    chars.pop()
            else:
                chars.append(c)
        lines.append(''.join(chars).rstrip())
        lines.extend('status, ' + s.rstrip() for s in statuses)
    while lines and lines[-1] == '':
        lines.pop()
    return lines


DOSBOX_TEMPLATE = os.path.join(ROOT, 'dosbox-x', 'rx286.conf.in')


def run_dosbox(directory, image, serial, timeout, until,
               printers=('/dev/null', '/dev/null'), log_port='com2', modem=None):
    """Run DOSBox-X (a 286, roadmap M9) on an image without a window, until
    `until(lines)` holds of the transcript, the log in `serial` (from
    `log_port`, as write_bochsrc's), or `timeout` seconds; LPT1 and LPT2
    print into `printers`; a modem on COM2 connects to `modem` (host:port).
    DOSBox-X has no shutdown port and ignores SIGTERM: it is killed."""
    text = open(DOSBOX_TEMPLATE, encoding='utf-8').read()
    log = 'file file:' + serial
    host, _, port = (modem or '').partition(':')
    text = text.replace('@IMAGE@', image)
    text = text.replace('@COM2@', log if log_port == 'com2' else
                        'nullmodem server:%s port:%s transparent:1' % (host, port) if modem
                        else 'dummy')
    text = text.replace('@COM3@', log if log_port == 'com3' else 'disabled')
    text = text.replace('@LPT1@', printers[0]).replace('@LPT2@', printers[1])
    conf = os.path.join(directory, 'dosbox-x.conf')
    with open(conf, 'w', encoding='utf-8') as f:
        f.write(text)
    env = dict(os.environ, SDL_VIDEODRIVER='dummy', SDL_AUDIODRIVER='dummy',
               HOME=directory)              # its own settings stay in the test's directory
    log = open(os.path.join(directory, 'dosbox-x.log'), 'w')
    started = time.monotonic()
    proc = subprocess.Popen(['dosbox-x', '-conf', conf, '-nogui', '-nomenu', '-fastlaunch'],
                            stdin=subprocess.DEVNULL, stdout=log, stderr=log, env=env,
                            cwd=directory)
    status = 'exit'
    while proc.poll() is None:
        if time.monotonic() - started > timeout:
            status = 'timeout'
            break
        if os.path.exists(serial) and until(normalise_transcript(open(serial, 'rb').read())):
            status = 'until'
            break
        time.sleep(0.05)
    if proc.poll() is None:
        proc.kill()
        proc.wait()
    log.close()
    return status, time.monotonic() - started


MAME_SCRIPT = os.path.join(ROOT, 'mame', 'rx286.lua')
MAME_ROMS = os.path.expanduser('~/mame/roms')     # the IBM 5170 ROM set (docs/emulators.md)


def at_cmos():
    """The 64 bytes of CMOS of rx286's AT, as IBM's SETUP would leave them, so
    the real BIOS's power-on test passes in MAME: drive A 1.2 MB, B 360 KB, no
    fixed disk, two diskette drives, a 287, an EGA, 640 KB, the checksum of
    10h-2Dh (IBM, Technical Reference, 1-45 to 1-50)."""
    c = bytearray(64)
    c[0x00:0x0A] = bytes([0, 0, 0, 0, 0, 0, 0x01, 0x01, 0x01, 0x89])   # MAME sets the time
    c[0x0A] = 0x26              # 32 kHz base, 1,024 Hz rate
    c[0x0B] = 0x02              # 24-hour, BCD
    c[0x0D] = 0x80              # valid RAM and time: the battery is good
    c[0x10] = 0x21              # diskettes: A high capacity (2), B double sided (1)
    c[0x12] = 0x00              # no fixed disk
    c[0x14] = 0x43              # two diskette drives, primary display with its own BIOS (EGA), 287
    c[0x15], c[0x16] = 0x80, 0x02   # 640 KB base memory
    c[0x17], c[0x18] = MAME_EXTENDED_KB & 0xFF, MAME_EXTENDED_KB >> 8   # and above 1 MB
    total = sum(c[0x10:0x2E])
    c[0x2E], c[0x2F] = total >> 8, total & 0xFF
    c[0x32] = 0x19              # the century
    c[0x33] = 0x80              # 128 KB expansion: 512 + 128 = 640 KB
    return bytes(c)


MAME_STOP_SECONDS = 10       # for MAME to exit when mame/rx286.lua is asked, before a kill
MAME_RAM = '1664K'           # 640 KB, and 1 MB above 1 MB (roadmap os-server.md P3)
MAME_EXTENDED_KB = 1024      # which the CMOS says, or the POST stops at error 164


def run_mame(directory, image, serial, timeout, until, disks=None, media=()):
    """Run MAME's IBM PC/AT (a real 80286 core, IBM's BIOS; roadmap M9) on an
    image without a window, until `until(lines)` holds of the serial
    transcript or `timeout` seconds. `disks` is the run's own directory of
    drives B, C and D (private_disks), less what `media` takes out ('B
    ejected', 'D absent'; MAME cannot write-protect a diskette from its
    command line). The AT has no printer port here: its
    four slots hold the EGA, the diskette controller, the serial card and
    the IDE card, which the diskettes need too (docs/emulators.md). MAME
    run so takes no signal to stop (SIGTERM and SIGINT alike are ignored):
    to stop, the runner makes a file that mame/rx286.lua watches for, and
    the machine exits as at its own end, its diskettes written back;
    MAME_STOP_SECONDS later it is killed. (tools/run-test fails a test whose
    diskette it checks if MAME left its image as it was.) SDL's dummy
    drivers keep MAME
    from opening any window: `-video none` alone still opens one under
    WSLg."""
    nvram = os.path.join(directory, 'mame-nvram')
    os.makedirs(os.path.join(nvram, 'ibm5170'), exist_ok=True)
    with open(os.path.join(nvram, 'ibm5170', 'mb_rtc'), 'wb') as f:
        f.write(at_cmos())
    open(serial, 'wb').close()      # the null modem's file must exist
    args = []
    if disks:
        # MAME knows a raw fixed disk by its name: .hd.
        for name, drive in (('hd0.img', 'c.hd'), ('hd1.img', 'd.hd')):
            link = os.path.join(disks, drive)
            if not os.path.exists(link):
                os.symlink(name, link)
        if 'B ejected' not in media:
            args += ['-flop2', os.path.join(disks, 'fdb.img')]
        args += ['-hard1', os.path.join(disks, 'c.hd')]
        if 'D absent' not in media:
            args += ['-isa4:ide:ide:1', 'hdd', '-hard2', os.path.join(disks, 'd.hd')]
    stop = os.path.join(directory, 'mame-stop')
    if os.path.exists(stop):
        os.remove(stop)
    log = open(os.path.join(directory, 'mame.log'), 'w')
    started = time.monotonic()
    proc = subprocess.Popen(
        ['mame', 'ibm5170', '-rompath', MAME_ROMS, '-ramsize', MAME_RAM,
         '-isa2:fdc:fdc:0', '525hd', '-isa2:fdc:fdc:1', '525dd',
         '-isa3:comat:serport0', 'microsoft_mouse',     # COM1: the mouse
         '-isa3:comat:serport1', 'null_modem', '-bitb', serial,   # COM2: the log
         '-flop1', image,                # isa4 stays the IDE card: the AT's task file at 1F0h
         '-video', 'none', '-sound', 'none', '-nothrottle', '-skip_gameinfo',
         '-nvram_directory', nvram, '-cfg_directory', os.path.join(directory, 'mame-cfg'),
         '-autoboot_script', MAME_SCRIPT, '-autoboot_delay', '0',
         '-seconds_to_run', str(int(timeout * 10))] + args,
        stdin=subprocess.DEVNULL, stdout=log, stderr=log, cwd=directory,
        env=dict(os.environ, SDL_VIDEODRIVER='dummy', SDL_AUDIODRIVER='dummy',
                 RX286_MAME_STOP=stop))
    status = 'exit'
    while proc.poll() is None:
        if time.monotonic() - started > timeout:
            status = 'timeout'
            break
        if until(normalise_transcript(open(serial, 'rb').read())):
            status = 'until'
            break
        time.sleep(0.05)
    if proc.poll() is None:
        open(stop, 'w').close()         # mame/rx286.lua: the machine exits
        try:
            proc.wait(MAME_STOP_SECONDS)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait()
    log.close()
    return status, time.monotonic() - started


# Bochs' rfb display takes the first free port from 5900 up, but two Bochs
# started at once can both bind one port: the second's listen fails, and so
# does every later bind of the same socket, and Bochs stops with this message
# before the machine starts. Such a run is started again, a moment later, once
# the locks the stopped Bochs left on its disk images are gone.
RFB_BIND_FAILED = b'RFB could not bind any port'
RFB_ATTEMPTS = 5


def run_bochs(bochsrc, rc_commands, timeout, until=None, serial=None, log=None,
              disks=None, cwd=None):
    """Run Bochs on a bochsrc with a debugger script. Stops when Bochs exits,
    when `until(lines)` is true of the serial transcript, or at `timeout`
    seconds. Returns (status, seconds), status 'exit', 'until' or 'timeout'.
    `log` is Bochs' log: a run whose rfb display found no port is repeated.
    `disks` is the run's own directory of disk images (private_disks)."""
    rc = bochsrc + '.rc'
    with open(rc, 'w', encoding='utf-8') as f:
        f.write('\n'.join(rc_commands) + '\n')
    for attempt in range(RFB_ATTEMPTS):
        if log and os.path.exists(log):
            os.remove(log)
        status, seconds = run_bochs_once(bochsrc, rc, timeout, until, serial, cwd)
        if status != 'exit' or not log or not os.path.exists(log) or \
                RFB_BIND_FAILED not in open(log, 'rb').read():
            break
        if serial and os.path.exists(serial):
            os.remove(serial)
        for name in os.listdir(disks) if disks else ():
            if name.endswith('.lock'):
                os.remove(os.path.join(disks, name))
        time.sleep(0.1 + 0.2 * attempt)
    return status, seconds


def run_bochs_once(bochsrc, rc, timeout, until, serial, cwd):
    """One run of Bochs, as run_bochs describes."""
    started = time.monotonic()
    proc = subprocess.Popen(['bochs', '-q', '-f', bochsrc, '-rc', rc],
                            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                            stderr=subprocess.DEVNULL, cwd=cwd)
    status = 'exit'
    while proc.poll() is None:
        if time.monotonic() - started > timeout:
            status = 'timeout'
            break
        if until and serial and os.path.exists(serial):
            if until(normalise_transcript(open(serial, 'rb').read())):
                status = 'until'
                break
        time.sleep(0.05)
    if proc.poll() is None:
        proc.kill()
        proc.wait()
    return status, time.monotonic() - started
