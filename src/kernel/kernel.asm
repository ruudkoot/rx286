; ============================================================================
; rx286 - src/kernel/kernel.asm
; The kernel's image, KERNEL.BIN: every segment at its fixed offset, and the
; program included at its own.
;
; layout.inc gives each segment's offset and room; NASM stops the build if
; one outgrows its room, since the sections would overlap. The sections are
; declared first, in file order, so that modules can add to kdata
; (begin_kdata) from anywhere. The GDT, IDT and TSSs open kdata. The program
; (src/userland, or a test program) is assembled on its own and included as
; a binary: it can name nothing of the kernel's (roadmap D5).
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
%include "kernel.inc"

section entry start=ENTRY_OFF vstart=0
section ktext start=KTEXT_OFF vstart=0
section kdata start=KDATA_OFF vstart=0
section user start=UTEXT_OFF vstart=0

section entry
%include "entry.asm"
entry_end:
%if ENTRY_ROOM < 256
  %error "kernel.asm: the entry's room is too small"
%endif

section kdata
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
%include "keyboard.asm"
%include "keymap.asm"
%include "rtc.asm"
%include "fpu.asm"
%include "console.asm"
%include "serial.asm"
%include "print.asm"
%include "syscall.asm"
%include "program.asm"
%include "test.asm"
%include "format.asm"
ktext_end:

section kdata
kdata_end:

; The program: USER_FILE_SIZE bytes, its data padded with zeros to the room.
; "TIMES value is negative" here means the program's data outgrew UDATA_ROOM.
section user
user_start:
        incbin USER_BIN
        times USER_FILE_SIZE - ($ - user_start) db 0
