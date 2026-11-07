; ============================================================================
; rx286 - src/bin/fpu287.asm
; fpu's work on the 287 (roadmap os-server.md P12; src/bin/fpu.c): the
; square root of 2 or pi, times 10^17, stored as 18 BCD digits (FBSTP).
; The C convention of cabi.inc.
; ============================================================================

cpu 286
bits 16
%include "build.inc"
%include "cabi.inc"

global fpu_digits

FPU_SQRT2           equ 0               ; fpu_digits's which

code_section

; ----------------------------------------------------------------------------
; fpu_digits - void fpu_digits(unsigned char *bcd, int which): the square
; root of 2 (which 0) or pi (else) times 10^17, rounded, as FBSTP's ten
; bytes: nine of two digits each, the least significant first, then a sign
;   In:       the stack: bcd, which
;   Out:      bcd's ten bytes
;   Destroys: BX
; ----------------------------------------------------------------------------
fpu_digits:
        push bp
        mov bp, sp
        push word 0x0163                ; 10^17, 0163_4578_5D8A_0000h: 18 digits in
        push word 0x4578                ;    FBSTP's store
        push word 0x5D8A
        push word 0x0000
        push word 2
        fninit
        fild qword [bp - 8]             ; ST0 = 10^17
        cmp word ARG(1), FPU_SQRT2
        jne .pi
        fild word [bp - 10]
        fsqrt
        jmp .scale
.pi:
        fldpi
.scale:
        fmulp st1, st0
        mov bx, ARG(0)
        fbstp [bx]                      ; rounded to the nearest integer
        fwait                           ; stored
        mov sp, bp
        pop bp
        ret
