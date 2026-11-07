; ============================================================================
; rx286 - src/userland/program.inc
; What every program in assembly includes: its two sections, the OS
; server's calls, and the macros to put data in its data segment and to
; print.
;
; The px macro calls the OS server (px.asm, which uprint.asm includes;
; roadmap os-server.md P14, docs/syscalls.md). The root, the OS server and
; the drivers, which include this for its sections, are not the OS
; server's clients: their lines go to the kernel's log (KCALL_LOG).
;
; A program is assembled on its own (roadmap D5): code at UCODE:0000 (its
; entry), data in UDATA, both at the offsets layout.inc gives. The kernel
; starts it with DS = ES = UDATA, SS:SP = USTACK:USTACK_SIZE, registers zero.
; ============================================================================

%ifndef RX286_PROGRAM_INC
%define RX286_PROGRAM_INC

%include "layout.inc"
%include "kcalls.inc"
%include "posix.inc"

; px call - a call on the OS server (posix.inc's PX_*): BX, CX, SI, DI its
; arguments -> BX the result, or -1 and CX the errno (px.asm's os_px)
%macro px 1
    mov al, (%1)
    call os_px
%endmacro

section utext start=USER_TEXT_START vstart=0
section udata start=USER_DATA_START vstart=0
section utext

CHAR_LF             equ 10
CHAR_CR             equ 13
CHAR_BS             equ 8
CHAR_ESC            equ 27
CHAR_FF             equ 12

; begin_udata / end_udata - put what lies between in the data segment
%macro begin_udata 0
    [section udata]
%endmacro
%macro end_udata 0
    __?SECT?__
%endmacro

; PRINT "text" - write a string to the standard output
%macro PRINT 1+
    begin_udata
%%text: db %1, 0
    end_udata
    push si
    mov si, %%text
    call print_str
    pop si
%endmacro

%endif
