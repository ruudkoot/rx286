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
import subprocess
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def include_constants(name):
    """The `NAME equ value` constants of src/include/<name>, evaluated where
    they are plain numbers or simple expressions of earlier constants."""
    values = {}
    path = os.path.join(ROOT, 'src', 'include', name)
    for line in open(path, encoding='utf-8'):
        line = line.split(';', 1)[0].strip()
        m = re.match(r'^([A-Z_][A-Z0-9_]*)\s+equ\s+(.+)$', line)
        if not m:
            continue
        expr = m.group(2)
        expr = re.sub(r'\b([0-9][0-9A-Fa-f]*)h\b', r'0x\1', expr)
        try:
            values[m.group(1)] = eval(expr, {'__builtins__': {}}, dict(values))
        except Exception:
            pass
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


def symbol_offsets(path):
    """name -> offset in its segment, for every symbol of a map file."""
    return {name: virt for _, _, virt, name in read_map(path)}


# Where each binary's file offset 0 lies in memory.
def binary_bases():
    return {
        'boot-sector': (LAYOUT['BOOT_SECTOR_PHYS'], 'bs.'),
        'boot-loader': (LAYOUT['LOADER_PHYS'], 'ld.'),
        'kernel': (LAYOUT['KERNEL_PHYS'], ''),
        'user': (LAYOUT['KERNEL_PHYS'] + LAYOUT['UTEXT_OFF'], 'u.'),
    }


def bochs_symbols(build_dir):
    """Lines of a Bochs symbol file: every symbol at its linear address."""
    lines = []
    for binary, (base, prefix) in binary_bases().items():
        path = os.path.join(build_dir, binary + '.map')
        if not os.path.exists(path):
            continue
        for _, real, _, name in read_map(path):
            lines.append((base + real, prefix + name))
    lines.sort()
    return ['%08x %s' % (addr, name) for addr, name in lines]


# ---------------------------------------------------------------- Bochs

BOCHSRC_TEMPLATE = os.path.join(ROOT, 'bochs', 'rx286.bochsrc.in')
DISKS = os.path.join(ROOT, 'build', 'disks')


def write_bochsrc(path, image, serial, log, display, debugger_log=None, magic=False,
                  disks=DISKS):
    """Write a bochsrc for one run from bochs/rx286.bochsrc.in. Bochs locks
    the hard-disk images, so runs at the same time need their own `disks`."""
    text = open(BOCHSRC_TEMPLATE, encoding='utf-8').read()
    subs = {
        '@IMAGE@': image,
        '@FDB@': os.path.join(disks, 'fdb.img'),
        '@HD0@': os.path.join(disks, 'hd0.img'),
        '@HD1@': os.path.join(disks, 'hd1.img'),
        '@SERIAL@': serial,
        '@LOG@': log,
        '@DISPLAY@': display,
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


def private_disks(directory):
    """Copies of drive B and the hard disks for one run (the hard disks are
    sparse, so the copies cost nothing)."""
    import shutil
    shutil.rmtree(directory, ignore_errors=True)   # with any lock a killed Bochs left
    os.makedirs(directory)
    shutil.copyfile(os.path.join(DISKS, 'fdb.img'), os.path.join(directory, 'fdb.img'))
    for name in ('hd0.img', 'hd1.img'):
        size = os.path.getsize(os.path.join(DISKS, name))
        with open(os.path.join(directory, name), 'wb') as f:
            f.truncate(size)
    return directory
DISPLAY_WINDOW = 'wx'


# ---------------------------------------------------------------- key scripts
#
# A test types keys through the kernel's test hook (src/kernel/test.asm),
# which reads a byte stream assembled into the test image:
#   01 s   type scancode s once the program waits for a key, its ring empty
#   02 s   type scancode s at the next tick, whatever the program does
#   03 n   wait n ticks
#   00     the end: once the program waits for a key, the test ends

OP_END, OP_WHEN_WAITING, OP_NOW, OP_WAIT = 0, 1, 2, 3

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
         'esc': 0x01, 'enter': 0x1C, 'bs': 0x0E, 'f1': 0x3B, 'caps': 0x3A,
         'scroll-lock': 0x46, 'del': 0x53}


def compile_keys(script):
    """A key script to the kernel's byte stream (see above).

    Plain characters are typed as the US keyboard types them; escapes are
    \\n (Enter), \\b (Backspace), \\t (Tab), \\e (Esc). Braces name others:
    {up}, {down}, {left}, {right}, {esc}, {f1}, {caps}, {scroll-lock}, {del},
    {ctrl-X} and {alt-X} for a key X,
    {ctrl-break}, {ctrl-alt-del} (typed at once, even if the program does
    not wait), and {wait N} (N ticks)."""
    out = []

    def press(code, op=OP_WHEN_WAITING):
        # A release gives no ASCII, so it is typed at once: the program may
        # not wait again (a key that starts a loop).
        out.extend([op, code, OP_NOW, code | 0x80])

    i = 0
    while i < len(script):
        ch = script[i]
        if ch == '\\' and i + 1 < len(script):
            esc = {'n': '\n', 'b': '\b', 't': '\t', 'e': '\x1b', '\\': '\\', '{': '{'}
            ch = esc.get(script[i + 1])
            if ch is None:
                raise ValueError('key script: unknown escape \\%s' % script[i + 1])
            i += 2
        elif ch == '{':
            end = script.index('}', i)
            name = script[i + 1:end]
            i = end + 1
            if name in NAMED:
                press(NAMED[name])
            elif name.startswith('wait '):
                n = int(name[5:])
                while n > 0:
                    out.extend([OP_WAIT, min(n, 255)])
                    n -= 255
            elif name == 'ctrl-break':
                out.extend([OP_NOW, SC_CTRL, OP_NOW, SC_SCROLL_LOCK,
                            OP_NOW, SC_SCROLL_LOCK | 0x80, OP_NOW, SC_CTRL | 0x80])
            elif name == 'ctrl-alt-del':
                out.extend([OP_NOW, SC_CTRL, OP_NOW, SC_ALT, OP_NOW, SC_DELETE,
                            OP_NOW, SC_DELETE | 0x80, OP_NOW, SC_ALT | 0x80,
                            OP_NOW, SC_CTRL | 0x80])
            elif (name.startswith('ctrl-') and len(name) == 6 or
                  name.startswith('alt-') and len(name) == 5) and name[-1] in KEYS:
                modifier = SC_CTRL if name.startswith('ctrl-') else SC_ALT
                out.extend([OP_WHEN_WAITING, modifier])
                press(KEYS[name[-1]][0])
                out.extend([OP_NOW, modifier | 0x80])
            else:
                raise ValueError('key script: unknown key {%s}' % name)
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


def keys_include(script):
    """The NASM include of a key script: the label test_keys and its bytes."""
    data = compile_keys(script)
    lines = ['; generated by tools/rxlib.py from a test\'s key script', 'test_keys:']
    for k in range(0, len(data), 16):
        lines.append('    db ' + ', '.join('0x%02X' % b for b in data[k:k + 16]))
    return '\n'.join(lines) + '\n'


# ---------------------------------------------------------------- transcripts

def normalise_transcript(raw):
    """COM1's bytes as the lines a person would read: CR and FF dropped,
    backspaces applied, trailing spaces trimmed."""
    text = raw.decode('latin-1')
    lines = []
    for line in text.replace('\r', '').replace('\f', '').split('\n'):
        chars = []
        for c in line:
            if c == '\b':
                if chars:
                    chars.pop()
            else:
                chars.append(c)
        lines.append(''.join(chars).rstrip())
    while lines and lines[-1] == '':
        lines.pop()
    return lines


def run_bochs(bochsrc, rc_commands, timeout, until=None, serial=None, cwd=None):
    """Run Bochs on a bochsrc with a debugger script. Stops when Bochs exits,
    when `until(lines)` is true of the serial transcript, or at `timeout`
    seconds. Returns (status, seconds), status 'exit', 'until' or 'timeout'."""
    rc = bochsrc + '.rc'
    with open(rc, 'w', encoding='utf-8') as f:
        f.write('\n'.join(rc_commands) + '\n')
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
