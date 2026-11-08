; ============================================================================
; rx286 - src/lib/crt/setjmp.asm
; setjmp and longjmp (roadmap os-server.md P1).
;
; A jmp_buf (src/include/c/setjmp.h) holds what C keeps across a call: SI,
; DI, BP, SP and the return address. DS, ES and SS are the program's one
; data segment in the small model, so they are not saved.
; ============================================================================

cpu 286
bits 16
%include "build.inc"
%include "cabi.inc"

JB_SI               equ 0
JB_DI               equ 2
JB_BP               equ 4
JB_SP               equ 6               ; SP after the return: the caller's
JB_IP               equ 8

global setjmp, longjmp

code_section

; ----------------------------------------------------------------------------
; setjmp - int setjmp(jmp_buf env): the caller's registers into env
;   In:       the stack: env
;   Out:      AX = 0
;   Destroys: BX
; ----------------------------------------------------------------------------
setjmp:
        mov bx, sp
        mov bx, [bx + 2]                ; env
        mov [bx + JB_SI], si
        mov [bx + JB_DI], di
        mov [bx + JB_BP], bp
        pop ax                          ; the return address
        mov [bx + JB_SP], sp
        mov [bx + JB_IP], ax
        push ax
        xor ax, ax
        ret

; ----------------------------------------------------------------------------
; longjmp - void longjmp(jmp_buf env, int value): back to env's setjmp,
; which returns value (1 if value is 0)
;   In:       the stack: env, value
;   Out:      does not return
;   Destroys: everything
; ----------------------------------------------------------------------------
longjmp:
        mov bx, sp
        mov ax, [bx + 4]                ; value
        mov bx, [bx + 2]                ; env
        test ax, ax
        jnz .value
        inc ax
.value:
        mov si, [bx + JB_SI]
        mov di, [bx + JB_DI]
        mov bp, [bx + JB_BP]
        mov sp, [bx + JB_SP]
        jmp word [bx + JB_IP]
