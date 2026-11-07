; ============================================================================
; rx286 - src/os/start.asm
; The start of each of the OS server's threads (roadmap os-server.md P5), in
; place of crt0: C's small model wants SS = DS, and the server has a thread
; for each program.
;
; The root starts each thread with SP = n * OS_STACK in the server's stack
; segment, n the program's module number (or OS_CONTROL_N, the control
; thread), which is how it knows its program; a restart starts it there
; again. Nothing is pushed there: here the thread takes the n-th part of
; the stacks at the bottom of the data segment, OS_PART bytes from
; (n - 2) OS_PART on, and calls os_thread(n) (os.c). Each part's lowest word is a guard, which os.c
; checks after every message, and on a thread's first start its part is
; filled with it, so that a test build can tell how deep the thread has
; gone (os_stack_used). The lowest part's guard is the null pointer's too
; (crt0.asm). The root zeroed the data; a restart keeps the fill.
; ============================================================================

cpu 286
bits 16
%include "build.inc"
%include "cabi.inc"

OS_STACK_SHIFT      equ 2               ; the root's: SP = n * OS_STACK (4) at a start
OS_FIRST_N          equ 2               ; module 1 is the server: programs from 2
OS_LAST_N           equ 32              ; the processes' (PROC_N0 + PROCS - 1; P6), then
                                        ;    the tty thread (TTY_N; P11): SP = 4n, at most
                                        ;    the server's stack, 128
OS_PART_SHIFT       equ 10
OS_PART             equ 1 << OS_PART_SHIFT  ; each thread's part of the stacks
OS_STACKS           equ (OS_LAST_N - OS_FIRST_N + 1) * OS_PART
OS_GUARD            equ 0x5A5A          ; the guard, and the fill

global _start, os_stack_ok, os_stack_used
extern os_thread

%ifdef ELF
[section .stackbot nobits alloc write align=16]
%else
[segment _STACKBOT public class=DATA use16 align=16]
[group DGROUP _STACKBOT]
%endif
        resb OS_STACKS

code_section

; ----------------------------------------------------------------------------
; _start - a thread's entry: its part of the stacks, filled the first time,
; then C
;   In:       SP = n * OS_STACK; DS = ES = the server's data
;   Out:      does not return
;   Destroys: everything
; ----------------------------------------------------------------------------
_start:
        cld
        mov dx, sp
        shr dx, OS_STACK_SHIFT          ; DX = n
        mov bx, dx
        sub bx, OS_FIRST_N - 1
        shl bx, OS_PART_SHIFT           ; BX = its part's top
        lea di, [bx - OS_PART]          ; DI = its bottom
        cmp word [di], OS_GUARD
        je .filled                      ; started before: the fill tells its depth
        mov ax, OS_GUARD
        mov cx, OS_PART / 2
        rep stosw
.filled:
        mov ax, ds
        mov ss, ax                      ; interrupts wait for the next instruction
        mov sp, bx
        push dx
        call os_thread                  ; does not return
.stop:
        jmp .stop

; ----------------------------------------------------------------------------
; os_stack_ok - int os_stack_ok(unsigned n): is thread n's guard still there?
;   In:       the stack: n
;   Out:      AX = 1 if so, else 0
;   Destroys: BX
; ----------------------------------------------------------------------------
os_stack_ok:
        push bp
        mov bp, sp
        call part_bottom                ; BX = its bottom
        xor ax, ax
        cmp word [bx], OS_GUARD
        jne .done
        inc ax
.done:
        pop bp
        ret

; ----------------------------------------------------------------------------
; os_stack_used - unsigned os_stack_used(unsigned n): the bytes of its part
; thread n has used at most (the fill no longer there above the lowest)
;   In:       the stack: n
;   Out:      AX = the bytes
;   Destroys: BX, CX
; ----------------------------------------------------------------------------
os_stack_used:
        push bp
        mov bp, sp
        call part_bottom
        mov cx, OS_PART / 2
.word:
        cmp word [bx], OS_GUARD
        jne .found
        add bx, 2
        loop .word
.found:
        mov ax, cx
        shl ax, 1
        pop bp
        ret

; ----------------------------------------------------------------------------
; part_bottom - thread n's part's lowest word
;   In:       BP = a frame whose first argument is n
;   Out:      BX = its offset
;   Destroys: nothing else
; ----------------------------------------------------------------------------
part_bottom:
        mov bx, ARG(0)
        sub bx, OS_FIRST_N
        shl bx, OS_PART_SHIFT
        ret
