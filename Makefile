# ============================================================================
# rx286 - Makefile
# Builds the boot sector, the loader, the kernel and the modules (the root,
# the OS server, the program, the counter), the boot image of them all, and
# puts them on a
# 1.2 MB FAT12 floppy image; runs Bochs; runs the tests.
#
#   make                 release and debug images
#   make release|debug|test-build
#   make run             Bochs with a window, on the debug image
#   make run-release     the same on the release image (COM2 the modem)
#   make debugger        Bochs stopped at the kernel's entry, with symbols
#   make test            every suite (tests/)
#   make test-286        the suites on DOSBox-X's 286 and MAME's IBM PC/AT
#   make check           test and test-286, plus check-286, the image checks,
#                        the reproducibility check, lint and the documents' checks
#   make check-ia16      the C built with gcc-ia16, and its tests (not in check)
#   make doctor          the tools and their versions
#   make sizes           each segment against its room
#   make clean
#
# One flavour at a time is built into build/<flavour>/ (FLAVOUR=release,
# debug or test). Test images get their own directory B=... and defines from
# tools/run-test. docs/building.md explains all of it.
# ============================================================================

.SUFFIXES:
.DELETE_ON_ERROR:
SHELL := /bin/bash

FLAVOUR ?= debug
B ?= build/$(FLAVOUR)
PROGRAM ?= shell
TEST_DEFINES ?=

NASM ?= nasm
PYTHON ?= python3
BOCHS ?= bochs

flavour_define_release := -dRELEASE
flavour_define_debug := -dDEBUG
flavour_define_test := -dTEST
FLAVOUR_DEFINE := $(flavour_define_$(FLAVOUR))
ifeq ($(FLAVOUR_DEFINE),)
$(error FLAVOUR must be release, debug or test, not '$(FLAVOUR)')
endif

NASMFLAGS := -f bin -w+all -w+error -Isrc/include/ $(FLAVOUR_DEFINE) $(TEST_DEFINES)

# The program the kernel carries (test builds may choose another).
program_main_shell := src/userland/shell.asm
program_main_idle := tests/programs/idle.asm
program_main_syscalls := tests/programs/syscalls.asm
program_main_attack := tests/programs/attack.asm
program_main_fuzz := tests/programs/fuzz.asm
program_main_storage := tests/programs/storage.asm
program_main_devices := tests/programs/devices.asm
program_main_fputhreads := tests/programs/fputhreads.asm
program_main_caps := tests/programs/caps.asm
program_main_ipc := tests/programs/ipc.asm
program_main_rings := tests/programs/rings.asm
program_main_keys := tests/programs/keys.asm
program_main_revoke := tests/programs/revoke.asm
program_main_additions := tests/programs/additions.asm
program_main_services := tests/programs/services.c
PROGRAM_MAIN := $(program_main_$(PROGRAM))
# The program's module: assembled, or a C program linked (c.mk)
PROGRAM_BIN := $(if $(filter %.c,$(PROGRAM_MAIN)),$(B)/user.rx,$(B)/user.bin)
# The counter runs beside the shell; beside a test program only if the test
# asks for it (TEST_COUNTER_*), so that the test programs' transcripts and
# timings stay their own. Its priority is below the program's (3), or as a
# test says.
WITH_COUNTER := $(or $(filter shell,$(PROGRAM)),$(findstring TEST_COUNTER,$(TEST_DEFINES)))
# The clock runs beside the shell too (roadmap l4.md L11, D19), above it, so
# that it ticks while the shell computes (it sleeps but for a moment a
# second); in a test build only if the test asks (TEST_DEMO), since it would
# put the time in every transcript's timing.
WITH_CLOCK := $(if $(filter test,$(FLAVOUR)),$(findstring TEST_DEMO,$(TEST_DEFINES)),$(filter \
    shell,$(PROGRAM)))
COUNTER_PRIORITY := $(if $(findstring TEST_COUNTER_SAME,$(TEST_DEFINES)),3,$(if \
    $(findstring TEST_COUNTER_ABOVE,$(TEST_DEFINES)),4,1))
# The program's ring: 3, or 1 or 2 for the tests of those rings, which ask
# for IOPL as a driver would (tests/rings).
PROGRAM_RING := $(if $(findstring TEST_RING1,$(TEST_DEFINES)),1:3:fg:iopl,$(if \
    $(findstring TEST_RING2,$(TEST_DEFINES)),2:3:fg:iopl,3:3:fg))
# The modules of the boot image (tools/mkimage): NAME=BINARY:RING:PRIORITY[:FLAG...].
# Servers run above their clients (roadmap l4.md D9): the drivers, the root,
# the OS server, the programs. The drivers run above the root (os-server.md
# P4), whose copy of a fork's data must not keep a serial line's bytes
# waiting.
MODULES := root=$(B)/root.rx:2:6 os=$(B)/os.rx:2:5 \
    printer=$(B)/printer.bin:1:7:driver:service=1 mouse=$(B)/mouse.bin:1:7:driver:irq=4:service=2 \
    console=$(B)/console.bin:1:7:driver:service=3 kbd=$(B)/keyboard.bin:1:7:driver:irq=1:service=4 \
    fd=$(B)/diskette.bin:1:7:driver:irq=6:service=5 hd=$(B)/fixeddisk.bin:1:7:driver:irq=14:service=6 \
    serial=$(B)/serial.bin:1:7:driver:irq=3:service=7 sound=$(B)/sound.bin:1:7:driver:service=8 \
    rtc=$(B)/rtc.bin:1:7:driver:service=9 \
    program=$(PROGRAM_BIN):$(PROGRAM_RING) \
    $(if $(WITH_CLOCK),clock=$(B)/clock.rx:3:4) \
    $(if $(WITH_COUNTER),counter=$(B)/counter.rx:3:$(COUNTER_PRIORITY))
ifeq ($(PROGRAM_MAIN),)
$(error PROGRAM must be shell, idle, syscalls, attack, fuzz, storage, devices, fputhreads, caps, ipc, rings, keys, revoke, additions or services, not '$(PROGRAM)')
endif

# Reproducible images (roadmap E5): a zeroed file, mformat without -C, a fixed
# serial and media byte, and every time stamp from SOURCE_DATE_EPOCH.
export SOURCE_DATE_EPOCH := 599616000
export MTOOLS_SKIP_CHECK := 1
FLOPPY_SECTORS := 2400
FLOPPY_SERIAL := 52583836

IMAGE := $(B)/rx286.img
BINARIES := $(B)/boot-sector.bin $(B)/boot-loader.bin $(B)/root.rx $(B)/os.rx \
    $(B)/printer.bin $(B)/mouse.bin $(B)/console.bin $(B)/keyboard.bin $(B)/diskette.bin \
    $(B)/fixeddisk.bin $(B)/serial.bin $(B)/sound.bin $(B)/rtc.bin $(PROGRAM_BIN) \
    $(B)/clock.rx $(B)/counter.rx $(B)/kernel.bin $(B)/image.bin

.PHONY: all release debug test-build image symbols run run-release debugger test test-286 check \
        check-286 check-image check-repro lint check-docs unit doctor sizes clean disks \
        check-ia16

all:
	$(MAKE) FLAVOUR=release image symbols
	$(MAKE) FLAVOUR=debug image symbols

release debug:
	$(MAKE) FLAVOUR=$@ image symbols

test-build:
	$(MAKE) FLAVOUR=test image symbols

image: $(IMAGE)
symbols: $(B)/rx286.sym

# assemble OUTPUT SOURCE [EXTRA NASM FLAGS]: a binary, with its listing and
# map beside it.
define assemble
	@mkdir -p $(dir $(1))
	$(NASM) $(NASMFLAGS) $(3) -dMAPFILE=$(1:.bin=.map) -l $(1:.bin=.lst) -o $(1) $(2)
endef

# Each binary depends on every file it could include: NASM 2.16.01's -MD
# leaves %include'd files out of its dependency lists.
COMMON_SRC := $(wildcard src/include/*.inc) $(wildcard src/lib/*.asm) Makefile
BOOT_SRC := $(wildcard src/boot-sector/*.asm) $(COMMON_SRC)
LOADER_SRC := $(wildcard src/boot-loader/*.asm) $(COMMON_SRC)
KERNEL_SRC := $(wildcard src/kernel/*.asm src/kernel/*.inc) $(COMMON_SRC) $(TEST_KEYS_FILE)
PROGRAM_SRC := $(PROGRAM_MAIN) $(wildcard src/userland/*.asm src/userland/*.inc tests/programs/*.asm) \
    $(COMMON_SRC)

$(B)/boot-sector.bin: src/boot-sector/boot-sector.asm $(BOOT_SRC)
	$(call assemble,$@,$<)

$(B)/boot-loader.bin: src/boot-loader/boot-loader.asm $(LOADER_SRC)
	$(call assemble,$@,$<,-Isrc/boot-loader/ -Isrc/lib/)

$(B)/user.bin: $(PROGRAM_SRC)
	$(call assemble,$@,$<,-Isrc/userland/ -Isrc/lib/)

# The C programs and libraries (roadmap os-server.md P1): the clock, beside
# the shell (l4.md L11), and the counter (l4.md L2), among them.
include c.mk

# The drivers outside the kernel (roadmap l4.md L7).
$(B)/%.bin: src/drivers/%.asm src/drivers/dwait.asm $(wildcard src/userland/*.inc) $(COMMON_SRC)
	$(call assemble,$@,$<,-Isrc/userland/ -Isrc/lib/ -Isrc/drivers/)

$(B)/kernel.bin: src/kernel/kernel.asm $(KERNEL_SRC)
	$(call assemble,$@,$<,-Isrc/kernel/ -Isrc/lib/)

# The boot image: the kernel, the module table and the modules. On the
# floppy it is KERNEL.BIN, upper case as FAT12 keeps names.
$(B)/image.bin: $(B)/kernel.bin $(B)/root.rx $(B)/os.rx $(B)/printer.bin $(B)/mouse.bin \
    $(B)/console.bin $(B)/keyboard.bin $(B)/diskette.bin $(B)/fixeddisk.bin $(B)/serial.bin \
    $(B)/sound.bin $(B)/rtc.bin $(PROGRAM_BIN) $(B)/clock.rx $(B)/counter.rx tools/mkimage \
    tools/rxlib.py
	$(PYTHON) tools/mkimage $@ $(B)/kernel.bin $(MODULES)

$(IMAGE): $(BINARIES)
	rm -f $@.tmp
	dd if=/dev/zero of=$@.tmp bs=512 count=$(FLOPPY_SECTORS) status=none
	mformat -i $@.tmp -f 1200 -R 4 -m 0xF9 -N $(FLOPPY_SERIAL) -v RX286 \
	    -B $(B)/boot-sector.bin ::
	dd if=$(B)/boot-loader.bin of=$@.tmp bs=512 seek=1 conv=notrunc status=none
	mcopy -i $@.tmp $(B)/image.bin ::KERNEL.BIN
	mv $@.tmp $@

$(B)/rx286.sym: $(BINARIES) tools/map2sym
	$(PYTHON) tools/map2sym $(B) > $@


# ---------------------------------------------------------------- the other drives
# Drive B, a 360 KB diskette, and the fixed disks C and D (AT drive types 2
# and 1), each with one FAT12 partition: the sample files of disks/, built
# by tools/mkdisks (disks/README.md). `make run` lets the shell write to
# them; `make clean` or a change of disks/ makes them afresh.
DISKS := build/disks
DISK_SOURCES := $(shell find disks -type f) tools/mkdisks
disks: $(DISKS)/fdb.img

$(DISKS)/fdb.img $(DISKS)/hd0.img $(DISKS)/hd1.img &: $(DISK_SOURCES)
	rm -rf $(DISKS).tmp
	$(PYTHON) tools/mkdisks $(DISKS).tmp
	@mkdir -p $(DISKS)
	rm -f $(DISKS)/*.lock
	mv $(DISKS).tmp/fdb.img $(DISKS).tmp/hd0.img $(DISKS).tmp/hd1.img $(DISKS)/
	rmdir $(DISKS).tmp

# ---------------------------------------------------------------- running
run: disks
	$(MAKE) FLAVOUR=debug image symbols
	$(PYTHON) tools/bochs-run --mode run --build build/debug

debugger: disks
	$(MAKE) FLAVOUR=debug image symbols
	$(PYTHON) tools/bochs-run --mode debugger --build build/debug

# The release image, whose COM2 is the modem's line (term), not the log.
run-release: disks
	$(MAKE) FLAVOUR=release image symbols
	$(PYTHON) tools/bochs-run --mode run --build build/release --release

# ---------------------------------------------------------------- checks
test: disks
	$(PYTHON) tools/run-test

# The suites on two 286 cores (roadmap M9): DOSBox-X's, and MAME's IBM PC/AT,
# which needs the IBM 5170 ROM set in ~/mame/roms (docs/emulators.md).
test-286: disks
	$(PYTHON) tools/run-test --emulator dosbox-x
	@if (cd /tmp && mame -rompath $(HOME)/mame/roms -verifyroms ibm5170 2>/dev/null | grep -q '1 were OK'); then \
	    $(PYTHON) tools/run-test --emulator mame; \
	else \
	    echo "test-286: no IBM 5170 ROMs in ~/mame/roms: MAME's suites skipped"; \
	fi

unit:
	$(PYTHON) -m pytest -q -W ignore::DeprecationWarning tests/unit

# Every listing there is: the flavours', and the test images' once the tests
# have run (make check runs them first).
check-286: all test-build
	$(PYTHON) tools/check-286 --self-test
	$(PYTHON) tools/check-286 $$(find build -name '*.lst' -o -name '*.dis' | sort)

check-image: all
	$(PYTHON) tools/check-image build/release
	$(PYTHON) tools/check-image build/debug

check-repro:
	rm -rf build/repro-a build/repro-b
	$(MAKE) FLAVOUR=release B=build/repro-a image
	$(MAKE) FLAVOUR=release B=build/repro-b image
	cmp build/repro-a/rx286.img build/repro-b/rx286.img
	@echo "check-repro: two release images are identical"

lint:
	$(PYTHON) tools/lint

check-docs:
	$(PYTHON) tools/check-docs

check: unit test test-286 check-286 check-image check-repro lint check-docs
	@echo "make check: all checks passed"

# The C built with gcc-ia16 too (roadmap os-server.md D1, D22): the tests
# whose images carry C programs, on Bochs; not part of make check, since it
# needs gcc-ia16 in $(IA16) (docs/building.md).
IA16_TESTS := tests/demo/demo.test tests/root/fault.test $(wildcard tests/threads/*.test) \
    $(wildcard tests/services/*.test) tests/root/own-fault.test \
    tests/kernel/stretch-kill.test
check-ia16: disks
	$(PYTHON) tools/run-test --cc ia16 $(IA16_TESTS)
	$(MAKE) FLAVOUR=release B=build/release-ia16 CC_KIND=ia16 image
	$(PYTHON) tools/check-286 $$(find build/tests-ia16 build/release-ia16 -name '*.dis' | sort)
	@echo "make check-ia16: the C built with gcc-ia16 passed"

doctor:
	@tools/doctor

sizes: release
	$(PYTHON) tools/sizes build/release

clean:
	rm -rf build
