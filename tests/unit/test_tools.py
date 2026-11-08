# rx286 - tests/unit/test_tools.py: the tools' own checks (roadmap os-server.md P15, the
# review of tools/): each test here passed a wrong input, or missed a slip, before its fix.
import importlib.machinery
import importlib.util
import os
import struct
import subprocess
import sys
import types

import pytest

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
TOOLS = os.path.join(ROOT, 'tools')
sys.path.insert(0, TOOLS)
import rxlib  # noqa: E402  (tools/ first on the path)


def load(name):
    """A tool of tools/ as a module."""
    loader = importlib.machinery.SourceFileLoader(name.replace('-', '_'),
                                                  os.path.join(TOOLS, name))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


RUN_TEST = load('run-test')
CHECK_286 = load('check-286')
CHECK_IMAGE = load('check-image')
CHECK_DOCS = load('check-docs')
LINT = load('lint')
MKEXE = load('mkexe')


def a_test(tmp_path, text, name='probe.test'):
    path = tmp_path / name
    path.write_text(text)
    return RUN_TEST.Test(str(path))


# ---------------------------------------------------------------- run-test

def test_contains_compares_whole_lines(tmp_path):
    t = a_test(tmp_path, 'match: contains\n---\ndrives: done\n')
    assert RUN_TEST.compare(t, ['drives: done? no, 3 failed', 'TEST END'], []) is not None
    assert RUN_TEST.compare(t, ['drives: done', 'TEST END'], []) is None


def test_any_text_in_an_expected_line(tmp_path):
    t = a_test(tmp_path, 'match: contains\n---\nstatus, clock: {...}\n')
    assert RUN_TEST.compare(t, ['status, clock: 00:00:46', 'TEST END'], []) is None
    assert RUN_TEST.compare(t, ['the status, clock: 00:00:46', 'TEST END'], []) is not None
    full = a_test(tmp_path, '---\nup {...}s\n', 'full.test')
    assert RUN_TEST.compare(full, ['up 3s', 'TEST END'], []) is None
    assert RUN_TEST.compare(full, ['up 3', 'TEST END'], []) is not None


def test_printers_byte_for_byte(tmp_path):
    t = a_test(tmp_path, 'emulators: bochs\nlpt1: one\\r\nlpt1: two\\r\n---\n')
    out = tmp_path / 'lpt1.out'
    for wrong in (b'one\ntwo\n', b'one\r\ntwo\r', b'one\r\ntwo\r\n\x0c', b'o\rne\r\ntwo\r\n'):
        out.write_bytes(wrong)
        assert RUN_TEST.check_printers(t, [str(out), '/dev/null']) is not None, wrong
    out.write_bytes(b'one\r\ntwo\r\n')
    assert RUN_TEST.check_printers(t, [str(out), '/dev/null']) is None


def test_a_file_holds_its_bytes(tmp_path):
    disks = tmp_path / 'disks'
    disks.mkdir()
    image = disks / 'fdb.img'
    image.write_bytes(bytes(720 * 512))
    env = dict(os.environ, MTOOLS_SKIP_CHECK='1')
    subprocess.run(['mformat', '-i', str(image), '-f', '360', '::'], check=True, env=env)
    text = tmp_path / 'x.txt'
    text.write_bytes(b'rx286 wrote this\r\n')
    subprocess.run(['mcopy', '-i', str(image), str(text), '::X.TXT'], check=True, env=env)
    t = types.SimpleNamespace(fscks=[], run_dir=str(tmp_path),
                              files=[('B', '/X.TXT', 'rx286 wrote this\n')])
    assert RUN_TEST.check_volumes(t) is not None
    t.files = [('B', '/X.TXT', 'rx286 wrote this\r\n')]
    assert RUN_TEST.check_volumes(t) is None


def test_a_debugger_test_needs_its_breakpoint_and_its_end(tmp_path):
    with pytest.raises(ValueError):
        a_test(tmp_path, 'emulators: bochs\ndebugger: info gdt 0 13\n---\nGDT{...}\n')
    t = a_test(tmp_path, 'emulators: bochs\nbreak: pm_start.ready\ndebugger: sreg\n---\n'
                         'tr:{...}\n', 'dbg.test')
    met = ['(0) Breakpoint 1, 0x000000000001045f in ?? ()', 'sreg', 'tr:0x0020', 'quit']
    assert RUN_TEST.compare(t, [], met) is None
    assert RUN_TEST.compare(t, [], met[1:]) is not None          # never met
    assert RUN_TEST.compare(t, [], met[:3]) is not None          # never at its end


def test_prefix_or_contains_expects_something(tmp_path):
    with pytest.raises(ValueError):
        a_test(tmp_path, 'match: prefix\nimage: missing\n---\n')
    a_test(tmp_path, '---\n', 'empty-full.test')                 # TEST END alone: fine


def test_a_space_at_a_key_lines_end(tmp_path):
    t = a_test(tmp_path, 'keys: echo\\s\nkeys: hi\\n\n---\n')
    assert rxlib.compile_keys(t.keys) == rxlib.compile_keys('echo hi\n')
    printed = a_test(tmp_path, 'emulators: bochs\nlpt1: \\s  indented\n---\n', 'p.test')
    assert printed.printed['lpt1'] == ['   indented']


@pytest.mark.parametrize('header', [
    'install: BC /BIN/X z-x.rx', 'timeout: nan', 'timeout: 0', 'timeout: 9999', 'match: Full',
    'modem: hayes', '# emulators: bochs\nmodem: hayes', 'emulators: mame bochs\nmodem: hayes',
    'image: sideways'])
def test_header_values_are_checked(tmp_path, header):
    with pytest.raises(ValueError):
        a_test(tmp_path, header + '\n---\nx\n')


@pytest.mark.parametrize('header', [
    'fsck: B', 'file: C /X.TXT x', 'install: D /X z-x.rx', 'media: B ejected',
    'emulators: mame\nmedia: B protected', 'emulators: mame\nlpt1: x',
    'emulators: mame\nmedia: LPT2 absent'])
def test_what_an_emulator_has_not_is_refused(tmp_path, header):
    with pytest.raises(ValueError):
        a_test(tmp_path, header + '\n---\nx\n')


def test_what_an_emulator_has_is_taken(tmp_path):
    a_test(tmp_path, 'emulators: bochs mame\nfsck: B\nmedia: B ejected\n---\nx\n')
    a_test(tmp_path, 'emulators: bochs dosbox-x\nmodem: hayes\nlpt1: x\n---\nx\n', 'b.test')


def test_forbidden_lines_fail_a_test(tmp_path):
    t = a_test(tmp_path, 'match: contains\nforbid: rx286: {...} fault #{...}\n---\nx\n')
    assert RUN_TEST.compare(t, ['x', 'TEST END'], []) is None
    assert RUN_TEST.compare(t, ['x', 'rx286: os fault #UD at 0006:9AFA', 'TEST END'], []) \
        is not None


def test_a_second_boot_fails_a_test(tmp_path):
    t = a_test(tmp_path, 'match: contains\n---\nfuzz: done\n')
    boot = ['rx286, test build', 'fuzz: starting']
    assert RUN_TEST.compare(t, boot + ['fuzz: done', 'TEST END'], []) is None
    assert RUN_TEST.compare(t, boot + boot + ['fuzz: done', 'TEST END'], []) is not None
    twice = a_test(tmp_path, '---\nrx286, test build\nrx286, test build\n', 'r.test')
    assert RUN_TEST.compare(twice, ['rx286, test build'] * 2 + ['TEST END'], []) is None


def test_runs_apart(tmp_path):
    t = a_test(tmp_path, '---\nx\n')
    dirs = set()
    for emulator in RUN_TEST.EMULATORS:
        RUN_TEST.EMULATOR = emulator
        dirs.add(t.run_dir)
    RUN_TEST.EMULATOR = 'bochs'
    assert len(dirs) == 3
    assert t.build_dir.endswith(os.path.join(os.path.basename(str(tmp_path)), 'probe'))


def test_an_error_is_its_tests_alone(tmp_path, monkeypatch):
    t = a_test(tmp_path, '---\nx\n')

    def broken(test):
        raise KeyError('no symbol nowhere in user.map')
    monkeypatch.setattr(RUN_TEST, 'run_one', broken)
    test, error, _ = RUN_TEST.run(t)
    assert test is t and 'no symbol nowhere' in error


# ---------------------------------------------------------------- check-286

@pytest.mark.parametrize('code', [
    [0x0F, 0x01, 0x3F], [0x0F, 0x01, 0xF9], [0x0F, 0x01, 0xC8], [0x0F, 0x00, 0xF0],
    [0x0F, 0x01, 0xC1], [0xDA, 0xC1], [0xDB, 0xF1], [0xDF, 0xE9], [0xDF, 0x0F], [0xDB, 0x0F],
    [0xDD, 0x0F], [0xDF, 0xC1], [0xDB, 0xD1], [0xDF, 0xF1], [0x8E, 0xF0], [0x8C, 0xF8],
    [0x8E, 0xC8], [0x9B, 0xDB, 0xE8]])
def test_check_286_refuses_later_instructions(code):
    assert CHECK_286.check_instruction(code) is not None, code


@pytest.mark.parametrize('code', [
    [0x0F, 0x01, 0x07], [0x0F, 0x01, 0x27], [0x0F, 0x01, 0xE0], [0x0F, 0x01, 0xF0],
    [0x0F, 0x00, 0xC8], [0x0F, 0x00, 0xE8], [0xDB, 0xE4], [0x9B, 0xDB, 0xE3], [0xDF, 0xE0],
    [0xDD, 0x37], [0xDF, 0x2F], [0xD9, 0xC9], [0xDE, 0xD9], [0xDD, 0xC1], [0x8C, 0xC8]])
def test_check_286_passes_the_286s_own(code):
    assert CHECK_286.check_instruction(code) is None, code


def test_check_286_reads_hidden_and_aligned_lines(tmp_path):
    src = tmp_path / 'gaps.asm'
    src.write_text('cpu 386\nbits 16\n        nop\n        align 4, mov eax, eax\n'
                   '[list -]\n        mov ecx, 3\n[list +]\n        align 4, db 0x66\n')
    lst = tmp_path / 'gaps.lst'
    subprocess.run(['nasm', '-f', 'bin', '-o', os.devnull, '-l', str(lst), str(src)], check=True)
    assert sorted(line for _, line, _, _, _ in CHECK_286.check_listing(str(lst))) == [4, 5]


def test_check_286_needs_a_listing():
    assert CHECK_286.main([]) == 1


# ---------------------------------------------------------------- inc2h, include_constants

@pytest.mark.parametrize('line', [
    'X equ 010', 'X equ "MT"', 'X equ 1 << 16 >> 8', 'X equ 300 * 200 / 100', 'X equ -7 / 2',
    'X equ ~0x8000', 'X equ 7 // 2', 'X equ 7 %% 2', '%define G \'MT\''])
def test_inc2h_refuses_what_c_reads_otherwise(tmp_path, line):
    inc = tmp_path / 'probe.inc'
    inc.write_text('A equ 4\n' + line + '\n')
    done = subprocess.run([sys.executable, os.path.join(TOOLS, 'inc2h'), str(inc),
                           str(tmp_path / 'probe.h')], capture_output=True, text=True)
    assert done.returncode != 0, line


def test_inc2h_refuses_a_condition_c_reads_otherwise(tmp_path):
    inc = tmp_path / 'probe.inc'
    inc.write_text('A equ 4\n%if A & 4 == 4\nB equ 1\n%endif\n')
    done = subprocess.run([sys.executable, os.path.join(TOOLS, 'inc2h'), str(inc),
                           str(tmp_path / 'probe.h')], capture_output=True, text=True)
    assert done.returncode != 0


def test_inc2h_refuses_a_16_bit_wrap(tmp_path):
    inc = tmp_path / 'probe.inc'
    inc.write_text('A equ 0FFFFh\nB equ A + 1\n')          # NASM 65536, C's unsigned 0
    done = subprocess.run([sys.executable, os.path.join(TOOLS, 'inc2h'), str(inc),
                           str(tmp_path / 'probe.h')], capture_output=True, text=True)
    assert done.returncode != 0 and 'NASM makes B 65536, C 0' in done.stderr


def test_inc2h_keeps_what_both_read_alike(tmp_path):
    inc = tmp_path / 'probe.inc'
    inc.write_text("A equ 0FFFFh\nB equ A - 1\nC equ 'MT'\nD equ (A & 0x0F) << 4\n"
                   "%if B > A && (A & 4) == 4\nE equ 1\n%endif\n")
    subprocess.run([sys.executable, os.path.join(TOOLS, 'inc2h'), str(inc),
                    str(tmp_path / 'probe.h')], check=True)
    assert '#define C (0x544D)' in (tmp_path / 'probe.h').read_text()


def test_include_constants_by_nasms_rules():
    assert rxlib.LAYOUT['MODULE_MAX'] == 15 and isinstance(rxlib.LAYOUT['MODULE_MAX'], int)
    assert rxlib.include_constants('ports.inc')['PIT_DIVISOR'] == 23864
    assert rxlib.nasm_value('-7 / 2', {}) == 0x7FFFFFFFFFFFFFFC     # unsigned
    assert rxlib.nasm_value('-7 // 2', {}) == -3


# ---------------------------------------------------------------- mkimage, check-image

@pytest.mark.parametrize('specs', [
    ['root=r.rx:9:200'], ['root=r.rx:2:6:drvier'], ['root=r.rx:1:7:driver:irq=99'],
    ['root=r.rx:1:7:driver:irq=-1'], ['root=r.rx:1:7:servcie=3'], ['root=r.rx:1:7:service=77'],
    ['os=o.rx:2:5', 'root=r.rx:2:6'], ['root=r.rx:2:6', 'root=r.rx:2:6'],
    ['root=r.rx:2:6:driver=1']])
def test_mkimage_refuses_a_bad_spec(tmp_path, specs):
    kernel = tmp_path / 'kernel.bin'
    kernel.write_bytes(b'\x90' * 16)
    done = subprocess.run([sys.executable, os.path.join(TOOLS, 'mkimage'),
                           str(tmp_path / 'image.bin'), str(kernel)] + specs,
                          capture_output=True, text=True)
    assert done.returncode != 0 and 'mkimage:' in done.stderr, specs


def a_module_table(entries):
    """A boot image of rxlib.LAYOUT's form: entries of (name, code, code size,
    data, data size, data room, data at, flags, irq, service)."""
    L = rxlib.LAYOUT
    image = bytearray(L['MODULES_OFF'] + 0x400)
    table = L['MODULE_TABLE_OFF']
    image[table:table + 2] = b'MT'
    struct.pack_into('<HH', image, table + L['MH_COUNT'], len(entries), len(image) // 16)
    for n, (name, code, code_size, data, data_size, room, at, flags, irq, service) in \
            enumerate(entries):
        e = table + L['MODULE_HEADER_SIZE'] + n * L['MODULE_ENTRY_SIZE']
        image[e:e + len(name)] = name.encode()
        for field, value in (('M_CODE', code // 16), ('M_CODE_SIZE', code_size),
                             ('M_DATA', data // 16), ('M_DATA_SIZE', data_size),
                             ('M_DATA_ROOM', room), ('M_DATA_AT', at)):
            struct.pack_into('<H', image, e + L[field], value)
        image[e + L['M_RING']], image[e + L['M_PRIORITY']] = 2, 6
        image[e + L['M_FLAGS']], image[e + L['M_IRQ']] = flags, irq
        image[e + L['M_SERVICE']] = service
    struct.pack_into('<H', image, len(image) - 2, L['KERNEL_END_MARK'])
    return bytes(image)


def test_check_image_reads_the_whole_table():
    m = rxlib.LAYOUT['MODULES_OFF']
    good = [('root', m, 0x40, m + 0x40, 0x20, 0x100, 0, 0, 0, 0),
            ('os', m + 0x60, 0x40, m + 0xA0, 0x20, 0x100, 0, 0, 0, 0)]
    assert CHECK_IMAGE.check_modules(a_module_table(good)) == []
    for wrong in ([good[0], ('os',) + good[1][1:6] + (0xFF00,) + good[1][7:]],
                  [good[0], ('os', m) + good[1][2:]],
                  [good[0], ('os',) + good[1][1:7] + (0xFF, 200, 0)],
                  [good[0], ('os',) + good[1][1:9] + (77,)]):
        assert CHECK_IMAGE.check_modules(a_module_table(wrong)) != [], wrong
    assert CHECK_IMAGE.check_modules(a_module_table([])) != []


# ---------------------------------------------------------------- the time zone, the disks

def test_the_tools_run_in_utc():
    assert os.environ['TZ'] == 'UTC'


def test_a_run_names_its_disks():
    with pytest.raises(TypeError):
        rxlib.write_bochsrc('x', image='i', serial='s', log='l', display='d')
    assert rxlib.RUN_DISKS != rxlib.DISKS


def test_key_scripts_refuse_what_they_cannot_type():
    for script in ('{ctrl-A}', '{alt-!}', '{grey f1}', '{wait 0}', '{wait -5}'):
        with pytest.raises(ValueError):
            rxlib.compile_keys(script)
    rxlib.compile_keys('{ctrl-a}{grey home}{wait 1}')


def test_damage_disks_refuses_what_it_cannot_do(tmp_path):
    image = tmp_path / 'fdb.img'
    image.write_bytes(bytes(720 * 512))
    subprocess.run(['mformat', '-i', str(image), '-f', '360', '::'], check=True,
                   env=dict(os.environ, MTOOLS_SKIP_CHECK='1'))
    for media in (['B zerodir'], ['B damaged'], ['B zerodir', 'B loop']):
        with pytest.raises(ValueError):
            rxlib.damage_disks(str(tmp_path), media)


# ---------------------------------------------------------------- mkexe, mkarchive, mkdisks

def test_mkexe_reads_a_publics_segment(tmp_path):
    src = tmp_path / 'probe.asm'
    src.write_text('cpu 286\nsegment _TEXT class=CODE\nglobal code_name\ncode_name: ret\n'
                   'segment _DATA class=DATA\nglobal data_name\ndata_name: dw 0\n')
    obj = tmp_path / 'probe.obj'
    subprocess.run(['nasm', '-f', 'obj', '-o', str(obj), str(src)], check=True)
    assert MKEXE.omf_publics(str(obj)) == {'code_name': 'CODE', 'data_name': 'DATA'}


def an_mz(tmp_path, module, relocations):
    """A DOS executable as wlink writes one for c_link: the load module from
    1000:0, each relocation as a segment and an offset from there."""
    table, count = 0x1C, len(relocations)
    header = -(-(table + 4 * count) // 16)
    size = header * 16 + len(module)
    head = bytearray(header * 16)
    struct.pack_into('<2sHHHH', head, 0, b'MZ', size % 512, -(-size // 512), count, header)
    struct.pack_into('<H', head, 0x18, table)
    for n, at in enumerate(relocations):
        linear = 0x10000 + at
        struct.pack_into('<HH', head, table + 4 * n, linear & 0xF, linear >> 4)
    path = tmp_path / 'probe.exe'
    path.write_bytes(bytes(head) + module)
    return str(path)


def test_mkexe_makes_relocations_selectors(tmp_path):
    module = bytearray(0x10010)
    struct.pack_into('<HH', module, 0x10002, 0x1234, 0x2000)       # a far pointer to data
    struct.pack_into('<H', module, 0x0004, 0x1000)                  # code's segment, in code
    image, relocations = MKEXE.mz_image(an_mz(tmp_path, bytes(module), [0x10004, 0x0004]))
    assert image == bytes(module) and relocations == [0x10004, 0x0004]
    for ring, data, code in ((3, 0x0F, 0x07), (2, 0x0E, 0x06)):
        out = MKEXE.relocate(image, relocations, ring, 'probe.exe')
        assert struct.unpack_from('<HHH', out, 0x10002)[1] == data
        assert struct.unpack_from('<H', out, 0x0004)[0] == code
        assert out[0x10002:0x10004] == b'\x34\x12'


def test_mkexe_refuses_another_paragraph(tmp_path):
    module = bytearray(0x10010)
    struct.pack_into('<H', module, 0x10004, 0x3000)
    image, relocations = MKEXE.mz_image(an_mz(tmp_path, bytes(module), [0x10004]))
    with pytest.raises(SystemExit):
        MKEXE.relocate(image, relocations, 3, 'probe.exe')
    with pytest.raises(SystemExit):
        MKEXE.relocate(image, [0x1000F], 3, 'probe.exe')


def test_mkexe_reads_wlinks_addresses():
    assert MKEXE.map_address('1000:0013') == 0x13
    assert MKEXE.map_address('2001:0002') == 0x12
    assert MKEXE.map_address('0000:0400') == 0x400


def an_rx(tmp_path, name, code=b'\xC3'):
    E = rxlib.include_constants('exe.inc')
    header = bytearray(E['RX_HEADER_SIZE'])
    header[0:2] = b'RX'
    struct.pack_into('<H', header, E['RXH_VERSION'], E['RX_VERSION'])
    struct.pack_into('<H', header, E['RXH_CODE'], len(code))
    path = tmp_path / name
    path.write_bytes(bytes(header) + code)
    return str(path)


def test_mkarchive_refuses_a_name_twice_and_too_much(tmp_path):
    one = an_rx(tmp_path, 'one.rx')
    run = [sys.executable, os.path.join(TOOLS, 'mkarchive'), str(tmp_path / 'z.arc')]
    assert subprocess.run(run + ['a=' + one, 'a=' + one], capture_output=True).returncode != 0
    A = rxlib.include_constants('archive.inc')
    head = -(-(A['AR_HEADER_SIZE'] + A['AR_ENTRY_SIZE']) // 16) * 16
    big = an_rx(tmp_path, 'big.rx', bytes(0xFFFF - head - 32))     # an archive of 65,535
    assert subprocess.run(run + ['a=' + big], capture_output=True).returncode != 0
    assert subprocess.run(run + ['a=' + one, 'b=' + one]).returncode == 0


def test_mkdisks_takes_dos_names_alone():
    MKDISKS = load('mkdisks')
    for name in ('README.TXT', 'GAMES', 'A_B~1.C'):
        assert MKDISKS.DOS_NAME.match(name), name
    for name in ('lower.txt', 'LONGNAMEX.TXT', 'A.TEXT', 'two.dots.TXT'):
        assert not MKDISKS.DOS_NAME.match(name), name


# ---------------------------------------------------------------- lint, check-docs

def lint_probe(tmp_path, name, body, comment='/*'):
    path = tmp_path / name
    rel = os.path.relpath(str(path), ROOT)
    if name.endswith('.c'):
        head = '/* ====\n * rx286 - %s\n * ==== */\n' % rel
    else:
        head = '; ====\n; rx286 - %s\n; ====\n' % rel
    path.write_text(head + body)
    return [p.split(': ', 2)[1] for p in LINT.lint(str(path))]


@pytest.mark.parametrize('body', [
    '\nstatic int two_lines(int a,\n                     int b)\n{\n    return a + b;\n}\n',
    '\nint same_line(void) {\n    return 0;\n}\n',
    '\nint x; /* a declaration\'s comment */\nint after(void)\n{\n    return x;\n}\n',
    '\n/* something else - not its name */\nint named(void)\n{\n    return 0;\n}\n'])
def test_lint_finds_a_function_without_its_comment(tmp_path, body):
    assert 'function' in lint_probe(tmp_path, 'probe.c', body)


@pytest.mark.parametrize('word', ['int _far *p;', 'int __based(x) *p;', 'int __loadds f;',
                                  '#pragma pack(1)', 'int __builtin_expect;',
                                  '_Pragma("x")', 'int far *p;'])
def test_lint_finds_a_compilers_word(tmp_path, word):
    assert 'compiler' in lint_probe(tmp_path, 'probe.c', '\n' + word + '\n')


@pytest.mark.parametrize('call', ['f(OS_DATA, (rx_u16)(unsigned)line, n);',
                                  'f(SLOT(1),\n  (unsigned)&local);',
                                  'f(OS_DATA, (unsigned long)buf);'])
def test_lint_finds_a_data_selector_and_a_cast_offset(tmp_path, call):
    assert 'selector' in lint_probe(tmp_path, 'probe.c', '\n' + call + '\n')


def entry_probe(tmp_path, monkeypatch, body, where='src/os'):
    """lint's rules for a file of a tree at tmp_path, in `where`"""
    monkeypatch.setattr(LINT, 'ROOT', str(tmp_path))
    os.makedirs(tmp_path / where, exist_ok=True)
    path = tmp_path / where / 'probe.c'
    path.write_text('/* ====\n * rx286 - %s/probe.c\n * ==== */\n%s' % (where, body))
    return [p.split(': ', 2)[1] for p in LINT.lint(str(path))]


@pytest.mark.parametrize('body', ['\nx |= (rx_u16)(1u << i);\n', '\nif (m & (1u << k))\n',
                                  '\nm &= ~(1 << entry);\n', '\nm |= 1u << (i % 16);\n',
                                  '\nm |= 1u << (t & 15);\n', '\nm |= 1u << n;\n'])
def test_lint_finds_an_entrys_bit_in_a_narrow_mask(tmp_path, monkeypatch, body):
    assert 'entry-bit' in entry_probe(tmp_path, monkeypatch, body)


def test_lint_takes_an_entrys_bit_in_a_byte(tmp_path, monkeypatch):
    body = '\nb[i >> 3] |= (rx_u8)(1u << (i & 7));\nb[k / 8] |= 1u << (k % 8);\nw |= 1u << unit;\n'
    assert 'entry-bit' not in entry_probe(tmp_path, monkeypatch, body)
    assert 'entry-bit' not in entry_probe(tmp_path, monkeypatch, '\nm |= 1u << i;\n',
                                          'src/bin')


def test_lint_takes_a_pointers_own_selector(tmp_path):
    body = '\nf(RX_SEG(line), RX_OFF(line), n);\nf(OS_DATA, offset);\n/* OS_DATA, (rx_u16)x */\n'
    assert 'selector' not in lint_probe(tmp_path, 'probe.c', body)


@pytest.mark.parametrize('body', [
    '    %include "build.inc"\n',
    'cpu 286\ncpu 386\n',
    'section .data\nx: db 0\n[section .text]\nno_header:\n        ret\n',
    'cpu 286\n%include "build.inc"\n; port_probe - x\n;   In: x\n;   Out: x\n;   Destroys: x\n'
    'port_probe:\n        mov dx, 0x3F8\n        mov al, 1\n        out dx, al\n        ret\n'])
def test_lint_reads_assembly_more_closely(tmp_path, body):
    assert lint_probe(tmp_path, 'probe.asm', body), body


def test_check_docs_reads_a_tables_values():
    rows = '| `A` | 0100h | x |\n| `B` | 5 | y |\n'
    assert CHECK_DOCS.table_values('d.md', rows, {'A': 0x100, 'B': 6}) == \
        ['d.md:2: B is 6 (6h), not 5']
