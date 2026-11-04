; ============================================================================
; rx286 - src/userland/program.inc
; What every program includes: its two sections, the system calls, and the
; macros to put data in its data segment and to print.
;
; A program is assembled on its own (roadmap D5): code at UCODE:0000 (its
; entry), data in UDATA, both at the offsets layout.inc gives. The kernel
; starts it with DS = ES = UDATA, SS:SP = USTACK:USTACK_SIZE, registers zero.
; ============================================================================

%ifndef RX286_PROGRAM_INC
%define RX286_PROGRAM_INC

%include "layout.inc"
%include "syscalls.inc"

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
