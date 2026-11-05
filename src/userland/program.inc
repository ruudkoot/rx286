; ============================================================================
; rx286 - src/userland/program.inc
; What every program includes: its two sections, the system calls, and the
; macros to put data in its data segment and to print.
;
; The sys macro calls the stub to the OS server (stub.asm, which uprint.asm
; includes; roadmap l4.md L6). The root, the OS server and the drivers are
; not the OS server's clients: they define KERNEL_LOG, and their one system
; call, SYS_WRITE, is a line on the kernel's log (KCALL_LOG; l4.md L10).
;
; A program is assembled on its own (roadmap D5): code at UCODE:0000 (its
; entry), data in UDATA, both at the offsets layout.inc gives. The kernel
; starts it with DS = ES = UDATA, SS:SP = USTACK:USTACK_SIZE, registers zero.
; ============================================================================

%ifndef RX286_PROGRAM_INC
%define RX286_PROGRAM_INC

%include "layout.inc"
%include "syscalls.inc"
%include "kcalls.inc"

%ifdef KERNEL_LOG
; sys SYS_WRITE - outside the OS server's programs: DS:SI, CX bytes to the
; kernel's log; no other system call is theirs
%macro sys 1
  %ifnidn %1, SYS_WRITE
    %error "sys: only SYS_WRITE, the kernel's log, outside the OS server's programs"
  %endif
    kcall KCALL_LOG
%endmacro
%else
; sys function - a system call, through the OS server (stub.asm)
%macro sys 1
    mov ah, (%1)
    call os_call
%endmacro
%endif

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

; PRINT "text" - write a string through SYS_WRITE
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
