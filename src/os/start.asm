; ============================================================================
; rx286 - src/os/start.asm
; The start of each of the OS server's threads (roadmap os-server.md P5), in
; place of crt0: C's small model wants SS = DS, and the server has a thread
; for each program.
;
; The root starts each thread with SP = n * OS_STACK in the server's stack
; segment (os.inc): n a program's module number, OS_CONTROL_N, a process
; entry's thread from OS_PROC_N0, or OS_TTY_N; which is how it knows its
; work; a restart starts it there again. Nothing is pushed there but a
; call's return: here the thread takes its part of the stacks at the bottom
; of the data segment, OS_PART bytes each (part_of: a program's by the
; programs before it in the module table, the others' after
; OS_SESSIONS of them, os-server.md P15), and calls os_thread(n) (os.c).
; Each part's lowest word is a guard, which os.c checks after every
; message, and on a thread's first start its part is filled with it, so
; that a test build can tell how deep the thread has gone
; (os_stack_used). The lowest part's guard is the null pointer's too
; (crt0.asm). The root zeroed the data; a restart keeps the fill.
; ============================================================================

cpu 286
bits 16
%include "build.inc"
%include "cabi.inc"
%include "layout.inc"
%include "os.inc"

OS_STACK_SHIFT      equ 2               ; SP = n * OS_STACK (4) at a start
%if 1 << OS_STACK_SHIFT != OS_STACK
  %error "start.asm: OS_STACK_SHIFT must match os.inc's OS_STACK"
%endif
OS_FIRST_N          equ 2               ; module 1 is the server: programs from 2
OS_MODULES_SEL      equ 3 * 8 + 4 + 2   ; the server's slot 3: the module table (server.h)
OS_PART_SHIFT       equ 10
OS_PART             equ 1 << OS_PART_SHIFT  ; each thread's part of the stacks
OS_PARTS            equ OS_SESSIONS + OS_TTY_N - OS_CONTROL_N + 1
OS_STACKS           equ OS_PARTS * OS_PART
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
        call part_of                    ; BX = its part
        jc .stop                        ; past the parts: the root starts none such
        inc bx
        shl bx, OS_PART_SHIFT           ; BX = its part's top
        push ds
        pop es
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
; part_of - thread n's part of the stacks: a program's (n a module number
; below OS_CONTROL_N) one of the first OS_SESSIONS, by the programs before
; it in the module table - neither drivers nor an archive; the others'
; after those. It pushes nothing: _start has a call's room alone
;   In:       BX = n
;   Out:      CF clear and BX = its part (from 0); CF set if it has none
;   Destroys: AX, CX, SI, ES
; ----------------------------------------------------------------------------
part_of:
        cmp bx, OS_TTY_N
        ja .none
        cmp bx, OS_CONTROL_N
        jb .program
        sub bx, OS_CONTROL_N - OS_SESSIONS
        clc
        ret
.program:
        mov cx, bx
        sub cx, OS_FIRST_N              ; CX = the modules from 2 before it
        jb .none
        mov ax, OS_MODULES_SEL
        mov es, ax
        mov si, MODULE_HEADER_SIZE + OS_FIRST_N * MODULE_ENTRY_SIZE
        xor bx, bx
        jcxz .counted
.module:
        test byte [es:si + M_FLAGS], MF_DRIVER | MF_ARCHIVE
        jnz .next
        inc bx
.next:
        add si, MODULE_ENTRY_SIZE
        loop .module
.counted:
        cmp bx, OS_SESSIONS
        jae .none
        clc
        ret
.none:
        stc
        ret

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
; part_bottom - thread n's part's lowest word (a thread that has a part)
;   In:       BP = a frame whose first argument is n
;   Out:      BX = its offset
;   Destroys: nothing else
; ----------------------------------------------------------------------------
part_bottom:
        push ax
        push cx
        push si
        push es
        mov bx, ARG(0)
        call part_of
        shl bx, OS_PART_SHIFT
        pop es
        pop si
        pop cx
        pop ax
        ret
