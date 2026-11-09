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
INC_NAMES := build kcalls os layout disks drivers ports selectors descriptors posix archive \
    vectors exe
INC_HEADERS := $(addprefix $(INC_H)/,$(addsuffix .h,$(INC_NAMES)))
# (and the servers' own: a change of one rebuilds every object, os-server.md P11)
C_HEADERS := $(wildcard src/include/c/*.h src/include/rx/*.h src/os/*.h src/root/*.h) \
    $(INC_HEADERS)

$(INC_H)/%.h: src/include/%.inc tools/inc2h tools/rxlib.py
	@mkdir -p $(dir $@)
	$(PYTHON) tools/inc2h $< $@

# The flavour and the test's NASM defines, as the C compiler takes them;
# INIT_SHELL where init runs the shell (PROGRAM=shell or sh)
C_DEFINES := $(patsubst -d%,-D%,$(FLAVOUR_DEFINE) $(TEST_DEFINES)) \
    $(if $(filter shell sh,$(PROGRAM)),-DINIT_SHELL)
NASM_C_FLAGS := -w+all -w+error -Isrc/include/ -Isrc/userland/ -Isrc/lib/ $(FLAVOUR_DEFINE) \
    $(TEST_DEFINES)

# Open Watcom in every build: the far libraries, and the programs built in
# the compact model, are Watcom's alone, gcc-ia16 having no such model
# (roadmap memory.md D11 B)
WCC := $(WATCOM)/binl64/wcc
WLINK := $(WATCOM)/binl64/wlink
WLIB := $(WATCOM)/binl64/wlib
WDIS := $(WATCOM)/binl64/wdis
WCC_FLAGS := -q -2 -ms -zl -zls -zld -s -ecc -os -zastd=c99 -wx -we -x -fr= \
    -i=src/include/c -i=src/include -i=$(INC_H) $(subst -D,-d,$(C_DEFINES))

# wlink_exe NAME OBJECTS [MKEXE_FLAGS]: an rx286 executable of wlink's, code
# at 1000:0, data at 2000:0. A DOS executable, for its relocations, which
# mkexe makes selectors (memory.md M5): MKEXE_FLAGS gives a module's ring
# if it is not 3.
define wlink_exe
	@mkdir -p $(C_B)
	printf '%s\n' 'option quiet, nodefaultlibs, start=__start' 'option map=$(C_B)/$(1).wmap' \
	    'disable 1014' 'format dos' 'name $(C_B)/$(1).exe' \
	    $(foreach o,$(filter %.obj,$(2)),'file $(o)') \
	    $(foreach l,$(filter %.lib,$(2)),'library $(l)') \
	    'order clname CODE segaddr=0x1000 offset=0 clname DATA segaddr=0x2000 offset=0 segment _STACKBOT segment CONST segment CONST2 segment _DATA clname BSS noemit' \
	    > $(C_B)/$(1).lnk
	$(WLINK) @$(C_B)/$(1).lnk
	$(PYTHON) tools/mkexe $(3) --wlink $(C_B)/$(1).exe $(C_B)/$(1).wmap $(B)/$(1).rx
endef

# (each made in a directory of its own, then moved into place: two wlibs at
# once in one directory, under make -j, spoil each other's work file)
make_wlib = rm -f $(1) && rm -rf $(1).dir && mkdir $(1).dir && \
    $(WLIB) -q -n -b $(1).dir/$(notdir $(1)) $(addprefix +,$(2)) && \
    mv $(1).dir/$(notdir $(1)) $(1) && rm -rf $(1).dir

ifeq ($(CC_KIND),watcom)
OBJ := obj

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

$(C_B)/tests/%.$(OBJ): tests/%.asm $(COMMON_SRC) src/include/cabi.inc
	@mkdir -p $(dir $@)
	$(NASM) -f obj --gprefix _ $(NASM_C_FLAGS) -l $(@:.$(OBJ)=.lst) -o $@ $<

# c_link NAME OBJECTS [MKEXE_FLAGS]: an rx286 executable (wlink_exe)
c_link = $(call wlink_exe,$(1),$(2),$(3))
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

$(C_B)/tests/%.$(OBJ): tests/%.asm $(COMMON_SRC) src/include/cabi.inc
	@mkdir -p $(dir $@)
	$(NASM) -f elf32 -dELF $(NASM_C_FLAGS) -l $(@:.$(OBJ)=.lst) -o $@ $<

define c_link
	@mkdir -p $(C_B)
	$(IA16_LD) -T tools/ia16.ld --no-check-sections -o $(C_B)/$(1).elf $(filter %.$(OBJ),$(2)) \
	    --start-group $(filter %.lib,$(2)) --end-group
	$(PYTHON) tools/mkexe $(3) --elf $(C_B)/$(1).elf $(B)/$(1).rx
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
OS_OBJS := $(C_B)/lib/os/module.$(OBJ)
POSIX_OBJS := $(addprefix $(C_B)/lib/posix/,posix.$(OBJ) fork.$(OBJ) stdio.$(OBJ) malloc.$(OBJ) \
    files.$(OBJ) dirent.$(OBJ) path.$(OBJ) errors.$(OBJ) signal.$(OBJ) sigtramp.$(OBJ) \
    time.$(OBJ) ps.$(OBJ) devices.$(OBJ) daemon.$(OBJ) pthread.$(OBJ) thread.$(OBJ))
C_LIBS := $(addprefix $(C_B)/,crt.lib c.lib rx286.lib os.lib)
C_LIB_OBJS := $(START_OBJS) $(C_LIBS)
# A process's (roadmap os-server.md P6): posix in place of today's os
PROCESS_LIBS := $(START_OBJS) $(addprefix $(C_B)/,crt.lib c.lib rx286.lib posix.lib)

ifeq ($(CC_KIND),watcom)
make_lib = $(make_wlib)
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

# The far libraries (roadmap memory.md M5): the C libraries again, in
# Watcom's compact model: every data pointer far, SS not taken for DS (-zu),
# DS pegged to DGROUP (-zdp) so that the code needs no segment relocations;
# their assembly with FAR_DATA (memory-far.asm, kcall.asm's far branches).
# In every build, gcc-ia16's too (D11 B). setjmp is not among them: no
# program in the compact model uses it. The start (crt0, start.c) is a
# module program's: a process's arguments are offsets (spawn), not far.
FAR_B := $(C_B)/far
WCC_FAR_FLAGS := $(subst -ms,-mc -zu -zdp,$(WCC_FLAGS))
FAR_START_OBJS := $(addprefix $(FAR_B)/lib/crt/,crt0.obj start.obj)
FAR_LIBS := $(addprefix $(FAR_B)/,crt.lib c.lib rx286.lib os.lib)

$(FAR_B)/%.obj: src/%.c $(C_HEADERS) c.mk
	@mkdir -p $(dir $@)
	$(WCC) $(WCC_FAR_FLAGS) -fo=$@ $<
	$(WDIS) -l=$(@:.obj=.dis) $@

$(FAR_B)/tests/%.obj: tests/%.c $(C_HEADERS) c.mk
	@mkdir -p $(dir $@)
	$(WCC) $(WCC_FAR_FLAGS) -fo=$@ $<
	$(WDIS) -l=$(@:.obj=.dis) $@

$(FAR_B)/lib/crt/helpers.obj: src/lib/crt/helpers.asm $(COMMON_SRC) src/include/cabi.inc
	@mkdir -p $(dir $@)
	$(NASM) -f obj -dFAR_DATA $(NASM_C_FLAGS) -l $(@:.obj=.lst) -o $@ $<

$(FAR_B)/%.obj: src/%.asm $(COMMON_SRC) src/include/cabi.inc
	@mkdir -p $(dir $@)
	$(NASM) -f obj --gprefix _ -dFAR_DATA $(NASM_C_FLAGS) -l $(@:.obj=.lst) -o $@ $<

$(FAR_B)/crt.lib: $(addprefix $(FAR_B)/lib/crt/,memory-far.obj helpers.obj)
	$(call make_wlib,$@,$^)
$(FAR_B)/c.lib: $(addprefix $(FAR_B)/lib/c/,string.obj printf.obj stdlib.obj)
	$(call make_wlib,$@,$^)
$(FAR_B)/rx286.lib: $(FAR_B)/lib/rx286/kcall.obj
	$(call make_wlib,$@,$^)
$(FAR_B)/os.lib: $(FAR_B)/lib/os/module.obj
	$(call make_wlib,$@,$^)
image: $(FAR_START_OBJS) $(FAR_LIBS)

# The C modules of the boot image: the root task, the first module
# (roadmap l4.md L5; in C since os-server.md P4), the clock and the counter
ROOT_OBJS := $(addprefix $(C_B)/root/,root.$(OBJ) services.$(OBJ) buddy.$(OBJ))
$(B)/root.rx: $(C_LIB_OBJS) $(ROOT_OBJS) tools/mkexe tools/rxlib.py
	$(call c_link,root,$(C_LIB_OBJS) $(ROOT_OBJS),--ring 2)

$(C_B)/root/%.$(OBJ): $(wildcard src/root/*.h)

# The OS server (roadmap l4.md L6; in C since os-server.md P5): in C's
# compact model on the far libraries, Watcom's in every build (memory.md
# M6, D10 B, D11 B), with a server's start (lib/crt/server.asm): each
# thread on a stack segment of its own. Its DGROUP holds its tables alone:
# the build stops past SERVER_DGROUP_MAX (40 KB: 35 KB at 48 entries, M7),
# which the linker would say only at 64 KB
SERVER_START := $(FAR_B)/lib/crt/server.obj
SERVER_OBJS := $(addprefix $(FAR_B)/os/,os.obj proc.obj cache.obj vol.obj vfs.obj signal.obj \
    tty.obj dev.obj)
SERVER_DGROUP_MAX := 40960
$(B)/os.rx: $(SERVER_START) $(SERVER_OBJS) $(FAR_LIBS) tools/mkexe tools/rxlib.py
	$(call wlink_exe,os,$(SERVER_START) $(SERVER_OBJS) $(FAR_LIBS), \
	    --ring 2 --dgroup-max $(SERVER_DGROUP_MAX))

$(FAR_B)/os/%.obj: $(wildcard src/os/*.h)

# /z, the archive of programs (roadmap os-server.md P6; tools/mkarchive):
# init, and the processes' test programs (tests/posix)
# The tests' programs (tests/posix) only in the builds of those tests
# (TEST_POSIX_*), so that /z and the image stay small (64 KB at most)
Z_TESTS := proc=$(C_B)/tests/posix/proc.$(OBJ) child=$(C_B)/tests/posix/child.$(OBJ) \
    files=$(C_B)/tests/posix/files.$(OBJ) execs=$(C_B)/tests/posix/exec.$(OBJ) \
    pipes=$(C_B)/tests/posix/pipe.$(OBJ) keys=$(C_B)/tests/posix/keys.$(OBJ) \
    signals=$(C_B)/tests/posix/signal.$(OBJ)+$(C_B)/tests/posix/sigasm.$(OBJ) \
    sigfpu=$(C_B)/tests/posix/sigfpu.$(OBJ)+$(C_B)/tests/posix/sigasm.$(OBJ) \
    tty=$(C_B)/tests/posix/tty.$(OBJ) jobs=$(C_B)/tests/posix/jobs.$(OBJ) \
    console=$(C_B)/tests/posix/console.$(OBJ) poll=$(C_B)/tests/posix/poll.$(OBJ) \
    thread=$(C_B)/tests/posix/thread.$(OBJ) drives=$(C_B)/tests/posix/drives.$(OBJ) \
    devices=$(C_B)/tests/posix/devices.$(OBJ) fsrand=$(C_B)/tests/posix/fsrand.$(OBJ) \
    pxrand=$(C_B)/tests/posix/pxrand.$(OBJ) edges=$(C_B)/tests/posix/edges.$(OBJ) \
    late=$(C_B)/tests/posix/late.$(OBJ) many=$(C_B)/tests/posix/many.$(OBJ) \
    held=$(C_B)/tests/posix/held.$(OBJ) overflow=$(C_B)/tests/posix/overflow.$(OBJ) \
    orphans=$(C_B)/tests/posix/orphans.$(OBJ) names=$(C_B)/tests/posix/names.$(OBJ) \
    rdtime=$(C_B)/tests/posix/rdtime.$(OBJ)
# The programs whose executables say they use the 287 (mkexe --287; P10)
Z_287 := sigfpu fpu crash
WITH_Z_TESTS := $(findstring TEST_POSIX,$(TEST_DEFINES))
# Each TEST_POSIX_* build's: its own program and those it runs from /z (or,
# for exec, installs on C), so that the image keeps under 128 KB (P12)
Z_FOR_PROC := proc child
Z_FOR_FILES := files
Z_FOR_EXEC := execs child
Z_FOR_PIPE := pipes child
Z_FOR_KEYS := keys
Z_FOR_SIGNAL := signals
Z_FOR_SIGFPU := sigfpu
Z_FOR_TTY := tty
Z_FOR_JOBS := jobs
Z_FOR_CONSOLE := console
Z_FOR_POLL := poll
Z_FOR_THREAD := thread
Z_FOR_DRIVES := drives
Z_FOR_DEVICES := devices
Z_FOR_FSRAND := fsrand
Z_FOR_NAMES := names
Z_FOR_RDTIME := rdtime
Z_FOR_PXRAND := pxrand
Z_FOR_EDGES := edges
Z_FOR_LATE := late
Z_FOR_MANY := many
Z_FOR_HELD := held
Z_FOR_OVERFLOW := overflow
Z_FOR_ORPHANS := orphans
Z_WANTED := $(foreach t,$(patsubst -dTEST_POSIX_%,%,$(filter -dTEST_POSIX_%,$(TEST_DEFINES))), \
    $(Z_FOR_$(t)))
Z_TESTS_USED := $(foreach p,$(Z_TESTS),$(if $(filter $(firstword $(subst =, ,$(p))),$(Z_WANTED)),$(p)))
# The shell and its first commands (P9), where init runs the shell, and
# the daemons it starts (P12)
Z_SHELL := sh=$(C_B)/bin/sh/sh.$(OBJ) $(foreach c,echo cat ls clock counter, \
    $(c)=$(C_B)/bin/$(c).$(OBJ))
Z_PROGRAMS := init=$(C_B)/userland/init.$(OBJ) $(if $(WITH_Z_TESTS),$(Z_TESTS_USED)) \
    $(if $(filter shell sh,$(PROGRAM)),$(Z_SHELL))
# Programs for the disks, not /z (roadmap os-server.md P8): run-test's
# install: lines put them on a run's drive C, `make run` all of them in
# /c/bin (tools/install-programs). The shell's commands but its first
# three are there, as D11 has it (P12): the image holds 128 KB
BIN_COMMANDS := $(foreach c,cp mv rm mkdir rmdir wc lp more clear uptime date sleep env head \
    kill ps spin keys mem beep play joy mouse term nice, \
    $(c)=$(C_B)/bin/$(c).$(OBJ)) crash=$(C_B)/bin/crash.$(OBJ)+$(C_B)/bin/crashes.$(OBJ) \
    fpu=$(C_B)/bin/fpu.$(OBJ)+$(C_B)/bin/fpu287.$(OBJ)
DISK_PROGRAMS := $(if $(WITH_Z_TESTS),codes=$(C_B)/tests/posix/codes.$(OBJ)) \
    $(if $(filter shell sh,$(PROGRAM)),$(BIN_COMMANDS))
DISK_FILES := $(foreach p,$(DISK_PROGRAMS),$(B)/z-$(firstword $(subst =, ,$(p))).rx)
image: $(DISK_FILES)
Z_NAMES := $(foreach p,$(Z_PROGRAMS),$(firstword $(subst =, ,$(p))))
Z_FILES := $(addprefix $(B)/z-,$(addsuffix .rx,$(Z_NAMES)))
# A program of /z or the disks: NAME=OBJECT, or NAME=OBJECT+OBJECT...
define z_program
$(B)/z-$(1).rx: $(PROCESS_LIBS) $(subst +, ,$(2)) tools/mkexe tools/rxlib.py
	$$(call c_link,z-$(1),$(PROCESS_LIBS) $(subst +, ,$(2)),$(if $(filter $(1),$(Z_287)),--287))
endef
$(foreach p,$(Z_PROGRAMS) $(DISK_PROGRAMS),$(eval $(call z_program,$(firstword \
    $(subst =, ,$(p))),$(lastword $(subst =, ,$(p))))))
$(B)/z.arc: $(Z_FILES) tools/mkarchive tools/rxlib.py
	$(PYTHON) tools/mkarchive $@ $(foreach n,$(Z_NAMES),$(n)=$(B)/z-$(n).rx)

# A test program in C (tests/programs/*.c), the program module of its
# build; those of FAR_PROGRAMS in the compact model, on the far libraries
# (memory.md M5), a server of them on a server's start (M6)
FAR_PROGRAMS := tables twin
FAR_SERVERS := twin
FAR_PROGRAM_START := $(if $(filter $(PROGRAM),$(FAR_SERVERS)),$(SERVER_START),$(FAR_START_OBJS))
ifeq ($(filter $(PROGRAM),$(FAR_PROGRAMS)),)
$(B)/user.rx: $(C_LIB_OBJS) $(C_B)/tests/programs/$(PROGRAM).$(OBJ) tools/mkexe tools/rxlib.py
	$(call c_link,user,$(C_LIB_OBJS) $(C_B)/tests/programs/$(PROGRAM).$(OBJ), \
	    --ring $(firstword $(subst :, ,$(PROGRAM_RING))))
else
$(B)/user.rx: $(FAR_PROGRAM_START) $(FAR_LIBS) $(FAR_B)/tests/programs/$(PROGRAM).obj tools/mkexe \
    tools/rxlib.py
	$(call wlink_exe,user,$(FAR_PROGRAM_START) $(FAR_LIBS) $(FAR_B)/tests/programs/$(PROGRAM).obj, \
	    --ring $(firstword $(subst :, ,$(PROGRAM_RING))))
endif

$(B)/counter.rx: $(C_LIB_OBJS) $(C_B)/userland/counter.$(OBJ) \
    $(C_B)/userland/counter-fpu.$(OBJ) tools/mkexe tools/rxlib.py
	$(call c_link,counter,$(C_LIB_OBJS) $(C_B)/userland/counter.$(OBJ) \
	    $(C_B)/userland/counter-fpu.$(OBJ))
