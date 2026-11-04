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


# What a test may change of the drives (tools/run-test's `media:`): the
# first three in the emulator, the others in the run's copies of the images
# (damage_disks).
MEDIA = ('B ejected', 'B protected', 'D absent', 'B damaged', 'D blank', 'B deep')
# 'B deep': directories whose paths reach DOS's 64 characters (PATH_MAX).
DEEP_PATH = '/'.join(c * 8 for c in 'ABCDEF')      # 54 characters as \AAAAAAAA...
DEEP_FITS = 'ABCDEFG.X'          # \ and 9 more: exactly 64
DEEP_TOO_LONG = 'ABCDEFGH.XY'    # 66


def write_bochsrc(path, image, serial, log, display, debugger_log=None, magic=False,
                  disks=DISKS, printers=('/dev/null', '/dev/null'), media=()):
    """Write a bochsrc for one run from bochs/rx286.bochsrc.in. Bochs locks
    the hard-disk images, so runs at the same time need their own `disks`.
    `printers` are the files LPT1 and LPT2 print into; `media` a list of
    MEDIA."""
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
        '@SERIAL@': serial,
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


def damage_disks(directory, media):
    """The changes of MEDIA made to a run's copies of the images: 'D blank'
    zeroes fixed disk D (no partition at all); 'B damaged' points the FAT
    entry of B:\\MANY's first cluster outside the volume, in both FATs;
    'B deep' adds DEEP_PATH, and in it DEEP_FITS and DEEP_TOO_LONG."""
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
    if 'B damaged' in media:
        path = os.path.join(directory, 'fdb.img')
        env = dict(os.environ, MTOOLS_SKIP_CHECK='1')
        chain = subprocess.run(['mshowfat', '-i', path, '::MANY'], capture_output=True,
                               text=True, env=env, check=True).stdout
        cluster = int(re.search(r'<(\d+)', chain).group(1))
        with open(path, 'r+b') as f:
            boot = f.read(512)
            reserved = int.from_bytes(boot[0x0E:0x10], 'little')
            fats, per_fat = boot[0x10], int.from_bytes(boot[0x16:0x18], 'little')
            for n in range(fats):
                at = (reserved + n * per_fat) * 512 + cluster * 3 // 2
                f.seek(at)
                pair = int.from_bytes(f.read(2), 'little')
                if cluster & 1:
                    pair = (pair & 0x000F) | (FAT12_BAD_LINK << 4)
                else:
                    pair = (pair & 0xF000) | FAT12_BAD_LINK
                f.seek(at)
                f.write(pair.to_bytes(2, 'little'))


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

FORM_FEED = '[form feed]'


def normalise_transcript(raw):
    """COM1's bytes as the lines a person would read: CR dropped, a form
    feed (or a run of them) as a line of its own, FORM_FEED, backspaces
    applied, trailing spaces trimmed."""
    text = raw.decode('latin-1')
    # Test builds write trace lines straight to COM1, even in the middle of
    # a line of the console's: cut them out, so the console's line joins up.
    text = re.sub(r'\[trace\][^\n]*\n', '', text)
    text = re.sub(r'\f+', '\n' + FORM_FEED + '\n', text.replace('\r', ''))
    lines = []
    for line in text.split('\n'):
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


DOSBOX_TEMPLATE = os.path.join(ROOT, 'dosbox-x', 'rx286.conf.in')


def run_dosbox(directory, image, serial, timeout, until,
               printers=('/dev/null', '/dev/null')):
    """Run DOSBox-X (a 286, roadmap M9) on an image without a window, until
    `until(lines)` holds of the serial transcript or `timeout` seconds; LPT1
    and LPT2 print into `printers`. DOSBox-X has no shutdown port and ignores
    SIGTERM: it is killed."""
    text = open(DOSBOX_TEMPLATE, encoding='utf-8').read()
    text = text.replace('@IMAGE@', image).replace('@SERIAL@', serial)
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
    total = sum(c[0x10:0x2E])
    c[0x2E], c[0x2F] = total >> 8, total & 0xFF
    c[0x32] = 0x19              # the century
    c[0x33] = 0x80              # 128 KB expansion: 512 + 128 = 640 KB
    return bytes(c)


MAME_STOP_SECONDS = 10       # for MAME to save its diskettes and stop, after SIGTERM


def run_mame(directory, image, serial, timeout, until, disks=None, media=()):
    """Run MAME's IBM PC/AT (a real 80286 core, IBM's BIOS; roadmap M9) on an
    image without a window, until `until(lines)` holds of the serial
    transcript or `timeout` seconds. `disks` is the run's own directory of
    drives B, C and D (private_disks), less what `media` takes out ('B
    ejected', 'D absent'; MAME cannot write-protect a diskette from its
    command line). The AT has no printer port here: its
    four slots hold the EGA, the diskette controller, the serial card and
    the IDE card, which the diskettes need too (docs/emulators.md). MAME
    writes a diskette back to its file only when it stops, so it is asked
    to stop (SIGTERM) before it is killed."""
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
    log = open(os.path.join(directory, 'mame.log'), 'w')
    started = time.monotonic()
    proc = subprocess.Popen(
        ['mame', 'ibm5170', '-rompath', MAME_ROMS, '-ramsize', '640K',
         '-isa2:fdc:fdc:0', '525hd', '-isa2:fdc:fdc:1', '525dd',
         '-isa3:comat:serport0', 'null_modem', '-bitb', serial,
         '-flop1', image,                # isa4 stays the IDE card: the AT's task file at 1F0h
         '-video', 'none', '-sound', 'none', '-nothrottle', '-skip_gameinfo',
         '-nvram_directory', nvram, '-cfg_directory', os.path.join(directory, 'mame-cfg'),
         '-autoboot_script', MAME_SCRIPT, '-autoboot_delay', '0',
         '-seconds_to_run', str(int(timeout * 10))] + args,
        stdin=subprocess.DEVNULL, stdout=log, stderr=log, cwd=directory)
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
        proc.terminate()
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
