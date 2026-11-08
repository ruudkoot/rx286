; ============================================================================
; rx286 - src/lib/posix/sigtramp.asm
; The trampoline (roadmap os-server.md P10, D7 A): where the OS server
; starts a process's thread to run a signal's handler. The server stopped
; the thread, wrote the signal's frame (SF_*, posix.inc) below its SP and
; pointed SP at it, with DS and ES the process's data and DF clear. The
; trampoline saves the 287 if the frame asks (SF_287), calls the handler
; with the signal, 0 and the frame (where SA_SIGINFO's siginfo_t and
; context would be: a handler of one argument takes the first alone),
; restores the 287, gives the server the mask back
; (PX_SIGRETURN), which may run another handler first, and returns to
; where the thread was: the frame's ES and DS, POPA, then IRET, which at
; ring 3 takes back IP, CS and FLAGS but not IOPL.
; ============================================================================

cpu 286
bits 16
%include "build.inc"
%include "cabi.inc"
%include "kcalls.inc"
%include "os.inc"
%include "posix.inc"

global rx_sigtramp

code_section

; ----------------------------------------------------------------------------
; rx_sigtramp - a handler's run, from the server's frame
;   In:       SS:SP = the frame (SF_*); DS = ES = the process's data
;   Out:      does not return: the frame's IRET
;   Destroys: nothing: every register as the frame had it
; ----------------------------------------------------------------------------
rx_sigtramp:
        mov bp, sp                      ; BP = the frame, which the handler keeps
        cmp word [bp + SF_287], 0
        je .call
        sub sp, SF_287_SIZE
        mov bx, sp
        fsave [bx]                      ; (DS's base is SS's)
        fwait
.call:
        push bp                         ; the frame
        push word 0                     ; (no siginfo_t)
        push word [bp + SF_SIG]
        call word [bp + SF_HANDLER]
        add sp, 6
        cmp word [bp + SF_287], 0
        je .back
        mov bx, sp
        frstor [bx]
        add sp, SF_287_SIZE
.back:
        mov cx, [bp + SF_MASK]
        mov si, [bp + SF_MASK + 2]
        mov dx, OS_EP
        mov ax, (KCALL_CALL << 8) | PX_SIGRETURN
        push bp
        xor bp, bp
        int KCALL_VECTOR
        pop bp
        lea sp, [bp + SF_ES]
        pop es
        pop ds
        popa
        iret
