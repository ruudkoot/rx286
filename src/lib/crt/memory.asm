; ============================================================================
; rx286 - src/lib/crt/memory.asm
; memcpy, memmove, memset and memcmp, by string instructions (roadmap
; os-server.md P1).
;
; Near pointers in the small model: everything in DS, which C keeps equal
; to ES and SS. gcc-ia16 calls memcpy for a struct's copy (E1), so these are
; the crt's, not only libc's. The C convention of cabi.inc: arguments on
; the stack, SI, DI, BP, DS and ES kept.
; ============================================================================

cpu 286
bits 16
%include "build.inc"
%include "cabi.inc"

global memcpy, memmove, memset, memcmp

code_section

; ----------------------------------------------------------------------------
; memcpy - void *memcpy(void *to, const void *from, size_t n)
;   In:       the stack: to, from, n
;   Out:      AX = to
;   Destroys: BX, CX, DX
; ----------------------------------------------------------------------------
memcpy:
        push bp
        mov bp, sp
        push si
        push di
        mov di, ARG(0)
        mov si, ARG(1)
        mov cx, ARG(2)
        cld
        shr cx, 1
        rep movsw
        adc cx, cx                      ; the odd byte, if any
        rep movsb
        mov ax, ARG(0)
        pop di
        pop si
        pop bp
        ret

; ----------------------------------------------------------------------------
; memmove - void *memmove(void *to, const void *from, size_t n): as memcpy,
; but the areas may overlap
;   In:       the stack: to, from, n
;   Out:      AX = to
;   Destroys: BX, CX, DX
; ----------------------------------------------------------------------------
memmove:
        push bp
        mov bp, sp
        push si
        push di
        mov di, ARG(0)
        mov si, ARG(1)
        mov cx, ARG(2)
        cmp di, si
        jbe .forward
        add si, cx                      ; from the end, backwards
        dec si
        add di, cx
        dec di
        std
        rep movsb
        cld
        jmp .done
.forward:
        cld
        rep movsb
.done:
        mov ax, ARG(0)
        pop di
        pop si
        pop bp
        ret

; ----------------------------------------------------------------------------
; memset - void *memset(void *to, int c, size_t n)
;   In:       the stack: to, c, n
;   Out:      AX = to
;   Destroys: BX, CX, DX
; ----------------------------------------------------------------------------
memset:
        push bp
        mov bp, sp
        push di
        mov di, ARG(0)
        mov al, ARG(1)
        mov ah, al
        mov cx, ARG(2)
        cld
        shr cx, 1
        rep stosw
        adc cx, cx
        rep stosb
        mov ax, ARG(0)
        pop di
        pop bp
        ret

; ----------------------------------------------------------------------------
; memcmp - int memcmp(const void *a, const void *b, size_t n)
;   In:       the stack: a, b, n
;   Out:      AX < 0, 0 or > 0, as the first byte that differs is smaller in a,
;             nowhere, or larger in a
;   Destroys: BX, CX, DX
; ----------------------------------------------------------------------------
memcmp:
        push bp
        mov bp, sp
        push si
        push di
        mov si, ARG(0)
        mov di, ARG(1)
        mov cx, ARG(2)
        xor ax, ax
        cld
        repe cmpsb
        je .done
        mov al, [si - 1]
        mov bl, [di - 1]
        xor bh, bh
        sub ax, bx
.done:
        pop di
        pop si
        pop bp
        ret
