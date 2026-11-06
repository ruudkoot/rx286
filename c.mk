# ============================================================================
# rx286 - c.mk
# The C part of the build (roadmap os-server.md P1), which the Makefile
# includes: the headers made from the NASM include files, C and NASM objects
# for one compiler, the libraries, and the programs linked into rx286
# executables (tools/mkexe).
#
#   CC_KIND=watcom (the default)   Open Watcom v2 in $(WATCOM)
#   CC_KIND=ia16                   gcc-ia16 in $(IA16) (make check-ia16)
#
# Everything goes under $(B)/c/. A C file compiles with the build's flavour
# (-DTEST, -DDEBUG, -DRELEASE) and the test's defines; its disassembly
# (.dis) goes beside its object for tools/check-286, as a NASM object's
# listing (.lst) does. docs/c.md explains the toolchain and its rules.
# ============================================================================

CC_KIND ?= watcom
WATCOM ?= $(HOME)/opt/open-watcom
IA16 ?= $(HOME)/opt/gcc-ia16
C_B := $(B)/c
INC_H := $(B)/inc

# The C headers made from the NASM include files (tools/inc2h)
INC_NAMES := build syscalls kcalls os layout disks drivers ports selectors descriptors posix archive \
    vectors exe
INC_HEADERS := $(addprefix $(INC_H)/,$(addsuffix .h,$(INC_NAMES)))
C_HEADERS := $(wildcard src/include/c/*.h src/include/rx/*.h) $(INC_HEADERS)

$(INC_H)/%.h: src/include/%.inc tools/inc2h
	@mkdir -p $(dir $@)
	$(PYTHON) tools/inc2h $< $@

# The flavour and the test's NASM defines, as the C compiler takes them;
# INIT_SHELL where init runs the shell (PROGRAM=sh)
C_DEFINES := $(patsubst -d%,-D%,$(FLAVOUR_DEFINE) $(TEST_DEFINES)) \
    $(if $(filter sh,$(PROGRAM)),-DINIT_SHELL)
NASM_C_FLAGS := -w+all -w+error -Isrc/include/ -Isrc/userland/ -Isrc/lib/ $(FLAVOUR_DEFINE) \
    $(TEST_DEFINES)

ifeq ($(CC_KIND),watcom)
OBJ := obj
WCC := $(WATCOM)/binl64/wcc
WLINK := $(WATCOM)/binl64/wlink
WLIB := $(WATCOM)/binl64/wlib
WDIS := $(WATCOM)/binl64/wdis
WCC_FLAGS := -q -2 -ms -zl -zls -zld -s -ecc -os -zastd=c99 -wx -we -x -fr= \
    -i=src/include/c -i=src/include -i=$(INC_H) $(subst -D,-d,$(C_DEFINES))

$(C_B)/%.$(OBJ): src/%.c $(C_HEADERS) c.mk
	@mkdir -p $(dir $@)
	$(WCC) $(WCC_FLAGS) -fo=$@ $<
	$(WDIS) -l=$(@:.$(OBJ)=.dis) $@

$(C_B)/tests/%.$(OBJ): tests/%.c $(C_HEADERS) c.mk
	@mkdir -p $(dir $@)
	$(WCC) $(WCC_FLAGS) -fo=$@ $<
	$(WDIS) -l=$(@:.$(OBJ)=.dis) $@

$(C_B)/lib/crt/helpers.$(OBJ): src/lib/crt/helpers.asm $(COMMON_SRC) src/include/cabi.inc
	@mkdir -p $(dir $@)
	$(NASM) -f obj $(NASM_C_FLAGS) -l $(@:.$(OBJ)=.lst) -o $@ $<

$(C_B)/%.$(OBJ): src/%.asm $(COMMON_SRC) src/include/cabi.inc $(wildcard src/userland/*.asm)
	@mkdir -p $(dir $@)
	$(NASM) -f obj --gprefix _ $(NASM_C_FLAGS) -l $(@:.$(OBJ)=.lst) -o $@ $<

# c_link NAME OBJECTS: an rx286 executable, code at 1000:0, data at 2000:0
define c_link
	@mkdir -p $(C_B)
	printf '%s\n' 'option quiet, nodefaultlibs, start=__start' 'option map=$(C_B)/$(1).wmap' \
	    'disable 1014' 'format raw bin' 'name $(C_B)/$(1).raw' \
	    $(foreach o,$(filter %.$(OBJ),$(2)),'file $(o)') \
	    $(foreach l,$(filter %.lib,$(2)),'library $(l)') \
	    'order clname CODE segaddr=0x1000 offset=0 clname DATA segaddr=0x2000 offset=0 segment _STACKBOT segment CONST segment CONST2 segment _DATA clname BSS noemit' \
	    > $(C_B)/$(1).lnk
	$(WLINK) @$(C_B)/$(1).lnk
	$(PYTHON) tools/mkexe --wlink $(C_B)/$(1).raw $(C_B)/$(1).wmap $(B)/$(1).rx
endef
else ifeq ($(CC_KIND),ia16)
OBJ := o
IA16_GCC := $(IA16)/bin/ia16-elf-gcc
IA16_LD := $(IA16)/bin/ia16-elf-ld
IA16_OBJDUMP := $(IA16)/bin/ia16-elf-objdump
IA16_FLAGS := -march=i80286 -mcmodel=small -mprotected-mode -ffreestanding -fno-builtin \
    -fcall-used-es -Os -std=gnu99 -Wall -Wextra -Werror -Isrc/include/c -Isrc/include \
    -I$(INC_H) $(C_DEFINES)

$(C_B)/%.$(OBJ): src/%.c $(C_HEADERS) c.mk
	@mkdir -p $(dir $@)
	$(IA16_GCC) $(IA16_FLAGS) -c -o $@ $<
	$(IA16_OBJDUMP) -d -M i8086 $@ > $(@:.$(OBJ)=.dis)

$(C_B)/tests/%.$(OBJ): tests/%.c $(C_HEADERS) c.mk
	@mkdir -p $(dir $@)
	$(IA16_GCC) $(IA16_FLAGS) -c -o $@ $<
	$(IA16_OBJDUMP) -d -M i8086 $@ > $(@:.$(OBJ)=.dis)

$(C_B)/%.$(OBJ): src/%.asm $(COMMON_SRC) src/include/cabi.inc $(wildcard src/userland/*.asm)
	@mkdir -p $(dir $@)
	$(NASM) -f elf32 -dELF $(NASM_C_FLAGS) -l $(@:.$(OBJ)=.lst) -o $@ $<

define c_link
	@mkdir -p $(C_B)
	$(IA16_LD) -T tools/ia16.ld --no-check-sections -o $(C_B)/$(1).elf $(filter %.$(OBJ),$(2)) \
	    --start-group $(filter %.lib,$(2)) --end-group
	$(PYTHON) tools/mkexe --elf $(C_B)/$(1).elf $(B)/$(1).rx
endef
else
$(error CC_KIND must be watcom or ia16, not '$(CC_KIND)')
endif

# The start of every program, linked whole, and the libraries, from which
# the linker takes what a program uses: crt (the compilers' helpers, the
# mem* routines, setjmp), c (ISO C), rx286 (the kernel's calls), os (the
# system calls)
START_OBJS := $(addprefix $(C_B)/lib/crt/,crt0.$(OBJ) start.$(OBJ))
CRT_OBJS := $(addprefix $(C_B)/lib/crt/,memory.$(OBJ) setjmp.$(OBJ) helpers.$(OBJ))
LIBC_OBJS := $(addprefix $(C_B)/lib/c/,string.$(OBJ) printf.$(OBJ) stdlib.$(OBJ))
RX286_OBJS := $(C_B)/lib/rx286/kcall.$(OBJ)
OS_OBJS := $(addprefix $(C_B)/lib/os/,oscall.$(OBJ) today.$(OBJ))
POSIX_OBJS := $(addprefix $(C_B)/lib/posix/,posix.$(OBJ) fork.$(OBJ) stdio.$(OBJ) malloc.$(OBJ) \
    files.$(OBJ) dirent.$(OBJ) path.$(OBJ) errors.$(OBJ))
C_LIBS := $(addprefix $(C_B)/,crt.lib c.lib rx286.lib os.lib)
C_LIB_OBJS := $(START_OBJS) $(C_LIBS)
# A process's (roadmap os-server.md P6): posix in place of today's os
PROCESS_LIBS := $(START_OBJS) $(addprefix $(C_B)/,crt.lib c.lib rx286.lib posix.lib)

ifeq ($(CC_KIND),watcom)
make_lib = rm -f $(1) && $(WLIB) -q -n -b $(1) $(addprefix +,$(2))
else
make_lib = rm -f $(1) && $(IA16)/bin/ia16-elf-ar rcs $(1) $(2)
endif
$(C_B)/crt.lib: $(CRT_OBJS)
	$(call make_lib,$@,$^)
$(C_B)/c.lib: $(LIBC_OBJS)
	$(call make_lib,$@,$^)
$(C_B)/rx286.lib: $(RX286_OBJS)
	$(call make_lib,$@,$^)
$(C_B)/os.lib: $(OS_OBJS)
	$(call make_lib,$@,$^)
$(C_B)/posix.lib: $(POSIX_OBJS)
	$(call make_lib,$@,$^)

# The C modules of the boot image: the root task, the first module
# (roadmap l4.md L5; in C since os-server.md P4), the clock and the counter
ROOT_OBJS := $(addprefix $(C_B)/root/,root.$(OBJ) services.$(OBJ) buddy.$(OBJ))
$(B)/root.rx: $(C_LIB_OBJS) $(ROOT_OBJS) tools/mkexe
	$(call c_link,root,$(C_LIB_OBJS) $(ROOT_OBJS))

$(C_B)/root/%.$(OBJ): $(wildcard src/root/*.h)

# The OS server (roadmap l4.md L6; in C since os-server.md P5): its own start
# (start.asm), a thread a program, each on its part of the stacks
SERVER_OBJS := $(addprefix $(C_B)/os/,start.$(OBJ) os.$(OBJ) proc.$(OBJ) files.$(OBJ) fat.$(OBJ) \
    cache.$(OBJ) vol.$(OBJ) vfs.$(OBJ))
$(B)/os.rx: $(SERVER_OBJS) $(C_LIBS) tools/mkexe
	$(call c_link,os,$(SERVER_OBJS) $(C_LIBS))

$(C_B)/os/%.$(OBJ): $(wildcard src/os/*.h)

# /z, the archive of programs (roadmap os-server.md P6; tools/mkarchive):
# init, and the processes' test programs (tests/posix)
# The tests' programs (tests/posix) only in the builds of those tests
# (TEST_POSIX_*), so that /z and the image stay small (64 KB at most)
Z_TESTS := proc=$(C_B)/tests/posix/proc.$(OBJ) child=$(C_B)/tests/posix/child.$(OBJ) \
    files=$(C_B)/tests/posix/files.$(OBJ) execs=$(C_B)/tests/posix/exec.$(OBJ) \
    pipes=$(C_B)/tests/posix/pipe.$(OBJ) keys=$(C_B)/tests/posix/keys.$(OBJ)
WITH_Z_TESTS := $(findstring TEST_POSIX,$(TEST_DEFINES))
# The shell and its commands (P9), where init runs the shell
Z_SHELL := sh=$(C_B)/bin/sh/sh.$(OBJ) $(foreach c,echo cat ls cp mv rm mkdir rmdir wc lp more, \
    $(c)=$(C_B)/bin/$(c).$(OBJ))
Z_PROGRAMS := init=$(C_B)/userland/init.$(OBJ) $(if $(WITH_Z_TESTS),$(Z_TESTS)) \
    $(if $(filter sh,$(PROGRAM)),$(Z_SHELL))
# Programs for the disks, not /z (roadmap os-server.md P8): run-test's
# install: lines put them on a run's drive C
DISK_PROGRAMS := $(if $(WITH_Z_TESTS),codes=$(C_B)/tests/posix/codes.$(OBJ))
DISK_FILES := $(foreach p,$(DISK_PROGRAMS),$(B)/z-$(firstword $(subst =, ,$(p))).rx)
image: $(DISK_FILES)
Z_NAMES := $(foreach p,$(Z_PROGRAMS),$(firstword $(subst =, ,$(p))))
Z_FILES := $(addprefix $(B)/z-,$(addsuffix .rx,$(Z_NAMES)))
define z_program
$(B)/z-$(1).rx: $(PROCESS_LIBS) $(2) tools/mkexe
	$$(call c_link,z-$(1),$(PROCESS_LIBS) $(2))
endef
$(foreach p,$(Z_PROGRAMS) $(DISK_PROGRAMS),$(eval $(call z_program,$(firstword \
    $(subst =, ,$(p))),$(lastword $(subst =, ,$(p))))))
$(B)/z.arc: $(Z_FILES) tools/mkarchive tools/rxlib.py
	$(PYTHON) tools/mkarchive $@ $(foreach n,$(Z_NAMES),$(n)=$(B)/z-$(n).rx)

# A test program in C (tests/programs/*.c), the program module of its build
$(B)/user.rx: $(C_LIB_OBJS) $(C_B)/tests/programs/$(PROGRAM).$(OBJ) tools/mkexe
	$(call c_link,user,$(C_LIB_OBJS) $(C_B)/tests/programs/$(PROGRAM).$(OBJ))

$(B)/clock.rx: $(C_LIB_OBJS) $(C_B)/userland/clock.$(OBJ) tools/mkexe
	$(call c_link,clock,$(C_LIB_OBJS) $(C_B)/userland/clock.$(OBJ))

$(B)/counter.rx: $(C_LIB_OBJS) $(C_B)/userland/counter.$(OBJ) \
    $(C_B)/userland/counter-fpu.$(OBJ) tools/mkexe
	$(call c_link,counter,$(C_LIB_OBJS) $(C_B)/userland/counter.$(OBJ) \
	    $(C_B)/userland/counter-fpu.$(OBJ))
