; ============================================================================
; rx286 - src/lib/crt/crt0.asm
; The start of every C program (roadmap os-server.md P1, *The libraries*).
;
; The kernel starts a program with DS = ES = its data segment and SS:SP its
; stack (slot 2). C's small model wants SS = DS: the stack is the bottom of
; the data segment, STACK_TOP bytes, so that an overflow wraps past the
; segment's limit and faults (E7). A guard word at offset 0 catches a write
; through a null pointer, which lands there (D20 of the review). crt0 calls
; rx_crt_main (start.c), compiled by the program's own compiler, which
; calls main: Watcom names main for its own convention (E3). Nothing here
; zeroes the data: the root built it zeroed, and a restarted program keeps
; its data, as every rx286 program does. The stack's top three words are
; main's argc, argv and envp: a process's, which the OS server put there
; (os-server.md P6), or zeros, for a program the root builds. With FAR_DATA
; (C's compact model, memory.md M5) argv and envp are far, five words: a
; program the root builds, whose are zeros, since a process's are offsets.
; ============================================================================

cpu 286
bits 16
%include "build.inc"
%include "cabi.inc"

%ifndef STACK_TOP
STACK_TOP           equ 0x0400          ; the stack's bytes: data begins there
%endif
%ifdef FAR_DATA
CRT_ARGS            equ 10              ; argc, argv, envp far at its top: rx_crt_main's
%else
CRT_ARGS            equ 6               ; argc, argv, envp at its top: rx_crt_main's
%endif
RX_GUARD            equ 0x5A5A          ; the null pointer's guard word
RX_GUARD_AT         equ 0               ; where: the data segment's first word

global _start, rx_guard_ok
extern rx_crt_main

%ifdef ELF
[section .stackbot nobits alloc write align=16]
%else
[segment _STACKBOT public class=DATA use16 align=16]
[group DGROUP _STACKBOT]
%endif
        resb STACK_TOP

code_section

; ----------------------------------------------------------------------------
; _start - a C program's entry: its stack in its data segment, then C
;   In:       the kernel's start: DS = ES = the data segment
;   Out:      does not return
;   Destroys: everything
; ----------------------------------------------------------------------------
_start:
        mov ax, ds
        mov ss, ax                      ; interrupts wait for the next instruction
        mov sp, STACK_TOP - CRT_ARGS    ; rx_crt_main's arguments
        mov word [RX_GUARD_AT], RX_GUARD
        cld
        call rx_crt_main
.stop:
        jmp .stop                       ; rx_crt_main does not return

; ----------------------------------------------------------------------------
; rx_guard_ok - int rx_guard_ok(void): is the null pointer's guard word
; still there?
;   In:       DS = the data segment
;   Out:      AX = 1 if so, else 0
;   Destroys: nothing
; ----------------------------------------------------------------------------
rx_guard_ok:
        xor ax, ax
        cmp word [RX_GUARD_AT], RX_GUARD
        jne .done
        inc ax
.done:
        ret
