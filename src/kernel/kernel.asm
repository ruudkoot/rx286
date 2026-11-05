; ============================================================================
; rx286 - src/kernel/kernel.asm
; The kernel: the first part of the boot image, KERNEL.BIN, every segment
; at its fixed offset.
;
; layout.inc gives each segment's offset and room; NASM stops the build if
; one outgrows its room, since the sections would overlap. The sections are
; declared first, in file order, so that modules can add to kdata
; (begin_kdata) from anywhere. The GDT, IDT and TSSs open kdata, whose
; offsets are those of SEL_KDATA (KDATA_VSTART on). tools/mkimage puts the
; module table and the modules after it - the root, the program, the
; counter - each assembled on its own: they can name nothing of the
; kernel's (roadmap D5; l4.md L5).
; ============================================================================

cpu 286
bits 16
%include "build.inc"
%include "ports.inc"
%include "layout.inc"
%include "selectors.inc"
%include "vectors.inc"
%include "descriptors.inc"
%include "syscalls.inc"
%include "kcalls.inc"
%include "disks.inc"
%include "kernel.inc"

section entry start=ENTRY_OFF vstart=0
section ktext start=KTEXT_OFF vstart=0
section kdata start=KDATA_OFF vstart=KDATA_VSTART

section entry
%include "entry.asm"
entry_end:
%if ENTRY_ROOM < 256
  %error "kernel.asm: the entry's room is too small"
%endif

section kdata
kdata_start:
%include "gdt.asm"
%include "idt.asm"
%include "tss.asm"

section ktext
%include "interrupt.asm"
%include "start.asm"
%include "fault.asm"
%include "panic.asm"
%include "pic.asm"
%include "timer.asm"
%include "rtc.asm"
%include "fpu.asm"
%include "speaker.asm"
%include "gameport.asm"
%include "modem.asm"
%include "console.asm"
%include "serial.asm"
%include "print.asm"
%include "syscall.asm"
%include "program.asm"
%include "thread.asm"
%include "cap.asm"
%include "ipc.asm"
%include "caps.asm"
%include "test.asm"
%include "format.asm"
ktext_end:

section kdata
kdata_end:
