; ============================================================================
; rx286 - src/lib/os/oscall.asm
; Today's system calls for C (roadmap os-server.md P1): the stub of
; src/userland/stub.asm, which C reaches through a struct of registers,
; until lib/os's POSIX calls replace them (P6-P14).
; ============================================================================

cpu 286
bits 16
%include "build.inc"
%include "cabi.inc"
%include "layout.inc"
%include "disks.inc"
%include "syscalls.inc"

; struct os_regs (rx/oscall.h)
OR_AX               equ 0
OR_BX               equ 2
OR_CX               equ 4
OR_DX               equ 6
OR_SI               equ 8
OR_DI               equ 10

global os_call_regs

code_section

; ----------------------------------------------------------------------------
; os_call_regs - int os_call_regs(struct os_regs *r): a system call with r's
; registers (AH the function), which come back changed; ES = DS for the
; buffers it fills
;   In:       the stack: r
;   Out:      AX = 0, or 1 if the call set CF (r's AX the error)
;   Destroys: BX, CX, DX
; ----------------------------------------------------------------------------
os_call_regs:
        push bp
        mov bp, sp
        push si
        push di
        push es
        mov bx, ARG(0)
        mov ax, [bx + OR_AX]
        mov cx, [bx + OR_CX]
        mov dx, [bx + OR_DX]
        mov si, [bx + OR_SI]
        mov di, [bx + OR_DI]
        mov bx, [bx + OR_BX]
        push ds
        pop es
        call os_call
        push bx                         ; (no flags change from here to the jnc)
        mov bx, ARG(0)
        mov [bx + OR_AX], ax
        pop word [bx + OR_BX]
        mov [bx + OR_CX], cx
        mov [bx + OR_DX], dx
        mov [bx + OR_SI], si
        mov [bx + OR_DI], di
        mov ax, 0
        jnc .done
        inc ax
.done:
        pop es
        pop di
        pop si
        pop bp
        ret

%include "stub.asm"
