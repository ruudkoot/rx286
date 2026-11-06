; ============================================================================
; rx286 - src/lib/posix/fork.asm
; fork's way to the OS server and back (roadmap os-server.md P6): the
; registers C keeps go on the stack, which the root copies with the data
; segment; the child starts at .child with the parent's SP, pops them, and
; returns 0. The 287's state is not kept yet: a child starts with a clean
; one.
; ============================================================================

cpu 286
bits 16
%include "build.inc"
%include "cabi.inc"
%include "kcalls.inc"
%include "os.inc"
%include "posix.inc"

global rx_px_fork_raw

code_section

; ----------------------------------------------------------------------------
; rx_px_fork_raw - rx_u32 rx_px_fork_raw(void): PX_FORK
;   In:       nothing
;   Out:      AX = the child's pid (0 in the child), or -1 and DX = the error
;   Destroys: BX, CX
; ----------------------------------------------------------------------------
rx_px_fork_raw:
        push bp
        push si
        push di
        mov bx, .child                  ; the child's IP
        mov cx, sp                      ; and its SP: these three, then the return
        mov dx, OS_EP
        xor bp, bp
        mov ax, (KCALL_CALL << 8) | PX_FORK
        int KCALL_VECTOR
        mov ax, bx                      ; the pid, or -1
        mov dx, cx                      ; the error
        jnc .parent
        mov ax, -1
        mov dx, ENOSYS
.parent:
        pop di
        pop si
        pop bp
        ret
.child:
        pop di
        pop si
        pop bp
        xor ax, ax
        xor dx, dx
        ret
