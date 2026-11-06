; ============================================================================
; rx286 - src/lib/crt/helpers.asm
; The 32-bit arithmetic both compilers call, so that no compiler's library
; is linked (roadmap os-server.md E2, W5).
;
; Watcom's code generator calls __U4M and __I4M (multiply), __U4D and __I4D
; (divide, with the remainder) with its own registers: DX:AX and CX:BX in,
; DX:AX and CX:BX out (bld/cg/intel/i86/h/_rtinfo.h). gcc-ia16 calls
; libgcc's __udivsi3, __umodsi3, __divsi3 and __modsi3 with two 32-bit
; arguments on the stack, cdecl, the result in DX:AX. One shift-and-subtract
; divide serves all of them. These names are the compilers' own, so this
; file is assembled without --gprefix.
; ============================================================================

cpu 286
bits 16
%include "build.inc"
%include "cabi.inc"

code_section

; (tests/unit assembles both sets at once, with HELPERS_BOTH)
%if !%isdef(ELF) || %isdef(HELPERS_BOTH)
global __U4M, __I4M, __U4D, __I4D

; ----------------------------------------------------------------------------
; __I4M - Watcom's signed 32-bit multiply: its low 32 bits are __U4M's
;   In:       DX:AX, CX:BX = the factors
;   Out:      DX:AX = the product's low 32 bits
;   Destroys: CX
; ----------------------------------------------------------------------------
__I4M:
        jmp __U4M

; ----------------------------------------------------------------------------
; __U4M - Watcom's unsigned 32-bit multiply
;   In:       DX:AX, CX:BX = the factors
;   Out:      DX:AX = the product's low 32 bits
;   Destroys: CX
; ----------------------------------------------------------------------------
__U4M:
        push si
        mov si, ax                      ; SI = a's low word
        xchg ax, dx                     ; AX = a's high word
        mul bx                          ; a high * b low
        xchg ax, cx                     ; CX = that; AX = b's high word
        mul si                          ; b high * a low
        add cx, ax
        mov ax, si
        mul bx                          ; a low * b low, in full
        add dx, cx
        pop si
        ret

; ----------------------------------------------------------------------------
; __U4D - Watcom's unsigned 32-bit divide
;   In:       DX:AX = the dividend; CX:BX = the divisor
;   Out:      DX:AX = the quotient; CX:BX = the remainder
;   Destroys: nothing else
; ----------------------------------------------------------------------------
__U4D:
        call udiv32
        ret

; ----------------------------------------------------------------------------
; __I4D - Watcom's signed 32-bit divide: the quotient truncated, the
; remainder with the dividend's sign, as C's / and %
;   In:       DX:AX = the dividend; CX:BX = the divisor
;   Out:      DX:AX = the quotient; CX:BX = the remainder
;   Destroys: nothing else
; ----------------------------------------------------------------------------
__I4D:
        call sdiv32
        ret
%endif

%if %isdef(ELF) || %isdef(HELPERS_BOTH)
global __udivsi3, __umodsi3, __divsi3, __modsi3

; ----------------------------------------------------------------------------
; __udivsi3 - gcc's unsigned 32-bit quotient
;   In:       the stack: the dividend, then the divisor (32 bits each)
;   Out:      DX:AX = the quotient
;   Destroys: BX, CX
; ----------------------------------------------------------------------------
__udivsi3:
        call gcc_args
        call udiv32
        ret

; ----------------------------------------------------------------------------
; __umodsi3 - gcc's unsigned 32-bit remainder
;   In:       the stack: the dividend, then the divisor (32 bits each)
;   Out:      DX:AX = the remainder
;   Destroys: BX, CX
; ----------------------------------------------------------------------------
__umodsi3:
        call gcc_args
        call udiv32
        mov ax, bx
        mov dx, cx
        ret

; ----------------------------------------------------------------------------
; __divsi3 - gcc's signed 32-bit quotient
;   In:       the stack: the dividend, then the divisor (32 bits each)
;   Out:      DX:AX = the quotient, truncated toward zero
;   Destroys: BX, CX
; ----------------------------------------------------------------------------
__divsi3:
        call gcc_args
        call sdiv32
        ret

; ----------------------------------------------------------------------------
; __modsi3 - gcc's signed 32-bit remainder
;   In:       the stack: the dividend, then the divisor (32 bits each)
;   Out:      DX:AX = the remainder, of the dividend's sign
;   Destroys: BX, CX
; ----------------------------------------------------------------------------
__modsi3:
        call gcc_args
        call sdiv32
        mov ax, bx
        mov dx, cx
        ret

; ----------------------------------------------------------------------------
; gcc_args - the two 32-bit arguments of a libgcc divide into registers
;   In:       the stack: gcc_args's return, the helper's return, then the
;             dividend and the divisor
;   Out:      DX:AX = the dividend; CX:BX = the divisor
;   Destroys: nothing else
; ----------------------------------------------------------------------------
gcc_args:
        push bp
        mov bp, sp
        mov ax, [bp + 6]
        mov dx, [bp + 8]
        mov bx, [bp + 10]
        mov cx, [bp + 12]
        pop bp
        ret
%endif

; ----------------------------------------------------------------------------
; udiv32 - unsigned 32-bit divide, a bit at a time
;   In:       DX:AX = the dividend; CX:BX = the divisor (0: the quotient is
;             all ones, as no exception is raised)
;   Out:      DX:AX = the quotient; CX:BX = the remainder
;   Destroys: nothing else
; ----------------------------------------------------------------------------
udiv32:
        push si
        push di
        push bp
        mov si, bx                      ; CX:SI = the divisor
        xor di, di
        xor bp, bp                      ; BP:DI = the remainder
        mov bx, 32
.bit:
        shl ax, 1
        rcl dx, 1                       ; the dividend's next bit into the remainder
        rcl di, 1
        rcl bp, 1
        cmp bp, cx
        jb .next
        ja .subtract
        cmp di, si
        jb .next
.subtract:
        sub di, si
        sbb bp, cx
        inc ax                          ; that bit of the quotient
.next:
        dec bx
        jnz .bit
        mov bx, di
        mov cx, bp
        pop bp
        pop di
        pop si
        ret

; ----------------------------------------------------------------------------
; sdiv32 - signed 32-bit divide: the quotient truncated toward zero, the
; remainder with the dividend's sign
;   In:       DX:AX = the dividend; CX:BX = the divisor
;   Out:      DX:AX = the quotient; CX:BX = the remainder
;   Destroys: nothing else
; ----------------------------------------------------------------------------
sdiv32:
        push si
        xor si, si                      ; bit 0: the quotient's sign; bit 1: the remainder's
        test dx, dx
        jns .divisor
        neg dx
        neg ax
        sbb dx, 0
        or si, 3
.divisor:
        test cx, cx
        jns .divide
        neg cx
        neg bx
        sbb cx, 0
        xor si, 1
.divide:
        call udiv32
        test si, 1
        jz .remainder
        neg dx
        neg ax
        sbb dx, 0
.remainder:
        test si, 2
        jz .done
        neg cx
        neg bx
        sbb cx, 0
.done:
        pop si
        ret
