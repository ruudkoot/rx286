; ============================================================================
; rx286 - src/userland/px.asm
; The NASM binding to the OS server's calls (roadmap os-server.md P14, D21):
; for the programs the root builds in assembly, the kernel's test programs.
;
; The px macro (program.inc) calls os_px with the call's number (posix.inc's
; PX_*) in AL and its arguments in BX, CX, SI and DI, as lib/posix's rx_px
; passes them: a call on the program's endpoint to the server (OS_EP),
; labelled with the number. A buffer is an offset in the program's data
; segment, which the server holds; no selector is passed. The result comes
; back in BX, or -1 and the errno in CX. The server answers such a program
; a few calls only: write, a key read, exit, nanosleep (docs/syscalls.md).
; ============================================================================

%ifndef RX286_PX_ASM
%define RX286_PX_ASM

%include "kcalls.inc"
%include "os.inc"
%include "posix.inc"

begin_udata
px_key              dw 0                ; read_key's key
end_udata

; ----------------------------------------------------------------------------
; os_px - a call on the OS server
;   In:       AL = the call (PX_*); BX, CX, SI, DI its arguments
;   Out:      BX = the result, or -1 and CX = the errno (ENOSYS: no server
;             answered); SI, DI as the call returns them
;   Destroys: AX
; ----------------------------------------------------------------------------
os_px:
        push dx
        push bp
        mov dx, OS_EP
        xor bp, bp
        kcall KCALL_CALL
        jnc .done
        mov bx, -1                      ; no OS server to answer
        mov cx, ENOSYS
.done:
        pop bp
        pop dx
        ret

; ----------------------------------------------------------------------------
; read_key - the next key, waited for: the keyboard driver's, through the
; server (PX_READ of descriptor 0, two bytes a key)
;   In:       nothing
;   Out:      AL = its ASCII (0: none), AH = its scancode
;   Destroys: nothing else
; ----------------------------------------------------------------------------
read_key:
        push bx
        push cx
        push si
        push di
.again:
        xor bx, bx
        mov di, px_key
        mov cx, 2
        px PX_READ
        cmp bx, 2
        jne .again                      ; (none: a call refused, as in fuzz)
        mov ax, [px_key]
        pop di
        pop si
        pop cx
        pop bx
        ret

%endif
