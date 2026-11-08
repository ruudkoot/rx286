; ============================================================================
; rx286 - src/lib/crt/memory-far.asm
; memcpy, memmove, memset and memcmp for C's compact model (roadmap
; memory.md M5): memory.asm's routines, every pointer far.
;
; A pointer is an offset and a selector, the offset in the lower word, as
; the stack holds it. SS need not be DS (Watcom's -zu: a server thread's
; stack is a segment of its own), so nothing here reads through DS but what
; a pointer names; DS is pegged to DGROUP (-zdp) and given back. ES is free
; across a call (cabi.inc). A routine that returns a pointer returns it in
; DX:AX. memmove copies from the end only when both areas are in the same
; segment, by the same selector: two selectors of one segment are taken for
; two segments, which nothing in rx286 makes for C.
; ============================================================================

cpu 286
bits 16
%include "build.inc"
%include "cabi.inc"

global memcpy, memmove, memset, memcmp

code_section

; ----------------------------------------------------------------------------
; memcpy - void far *memcpy(void far *to, const void far *from, size_t n)
;   In:       the stack: to, from, n
;   Out:      DX:AX = to
;   Destroys: BX, CX, ES
; ----------------------------------------------------------------------------
memcpy:
        push bp
        mov bp, sp
        push si
        push di
        push ds
        les di, ARG(0)
        lds si, ARG(2)
        mov cx, ARG(4)
        cld
        shr cx, 1
        rep movsw
        adc cx, cx                      ; the odd byte, if any
        rep movsb
        pop ds
        mov ax, ARG(0)
        mov dx, ARG(1)
        pop di
        pop si
        pop bp
        ret

; ----------------------------------------------------------------------------
; memmove - void far *memmove(void far *to, const void far *from, size_t n):
; as memcpy, but the areas may overlap (in one segment, by one selector)
;   In:       the stack: to, from, n
;   Out:      DX:AX = to
;   Destroys: BX, CX, ES
; ----------------------------------------------------------------------------
memmove:
        push bp
        mov bp, sp
        push si
        push di
        push ds
        les di, ARG(0)
        lds si, ARG(2)
        mov cx, ARG(4)
        mov ax, es
        mov bx, ds
        cmp ax, bx
        jne .forward                    ; two segments: no overlap
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
        pop ds
        mov ax, ARG(0)
        mov dx, ARG(1)
        pop di
        pop si
        pop bp
        ret

; ----------------------------------------------------------------------------
; memset - void far *memset(void far *to, int c, size_t n)
;   In:       the stack: to, c, n
;   Out:      DX:AX = to
;   Destroys: BX, CX, ES
; ----------------------------------------------------------------------------
memset:
        push bp
        mov bp, sp
        push di
        les di, ARG(0)
        mov al, ARG(2)
        mov ah, al
        mov cx, ARG(3)
        cld
        shr cx, 1
        rep stosw
        adc cx, cx
        rep stosb
        mov ax, ARG(0)
        mov dx, ARG(1)
        pop di
        pop bp
        ret

; ----------------------------------------------------------------------------
; memcmp - int memcmp(const void far *a, const void far *b, size_t n)
;   In:       the stack: a, b, n
;   Out:      AX < 0, 0 or > 0, as the first byte that differs is smaller in a,
;             nowhere, or larger in a
;   Destroys: BX, CX, DX, ES
; ----------------------------------------------------------------------------
memcmp:
        push bp
        mov bp, sp
        push si
        push di
        push ds
        lds si, ARG(0)
        les di, ARG(2)
        mov cx, ARG(4)
        xor ax, ax
        cld
        repe cmpsb
        je .done
        mov al, [si - 1]
        mov bl, [es:di - 1]
        xor bh, bh
        sub ax, bx
.done:
        pop ds
        pop di
        pop si
        pop bp
        ret
