; ============================================================================
; rx286 - src/lib/rx286/kcall.asm
; The kernel's calls for C (roadmap os-server.md, *The libraries*): the
; binding src/include/rx/rx286.h declares.
;
; rx_kcall makes any call of INT 31h with a struct of registers in and out
; (docs/kernel-calls.md); the others are the calls C makes often, without
; the struct. The C convention of cabi.inc.
; ============================================================================

cpu 286
bits 16
%include "build.inc"
%include "cabi.inc"
%include "kcalls.inc"

; struct rx_kregs (rx286.h)
KR_AX               equ 0
KR_BX               equ 2
KR_CX               equ 4
KR_DX               equ 6
KR_SI               equ 8
KR_DI               equ 10
KR_BP               equ 12

global rx_kcall, rx_ticks, rx_log, rx_log_far, rx_ud2, rx_verr, rx_xchg

code_section

; ----------------------------------------------------------------------------
; rx_kcall - int rx_kcall(struct rx_kregs *r): INT 31h with r's registers,
; which come back changed
;   In:       the stack: r
;   Out:      AX = the status (KE_*): 0, or the error with CF; r's registers
;   Destroys: BX, CX, DX
; ----------------------------------------------------------------------------
rx_kcall:
        push bp
        mov bp, sp
        push si
        push di
        push word ARG(0)
        mov bx, ARG(0)
        mov ax, [bx + KR_AX]
        mov cx, [bx + KR_CX]
        mov dx, [bx + KR_DX]
        mov si, [bx + KR_SI]
        mov di, [bx + KR_DI]
        mov bp, [bx + KR_BP]
        mov bx, [bx + KR_BX]
        int KCALL_VECTOR
        push bx
        mov bx, sp
        mov bx, [bx + 2]                ; r again (no flags change from here)
        mov [bx + KR_AX], ax
        pop word [bx + KR_BX]
        mov [bx + KR_CX], cx
        mov [bx + KR_DX], dx
        mov [bx + KR_SI], si
        mov [bx + KR_DI], di
        mov [bx + KR_BP], bp
        mov ax, 0
        jnc .done
        mov al, [bx + KR_AX]            ; the status, KE_*
.done:
        pop bx
        pop di
        pop si
        pop bp
        ret

; ----------------------------------------------------------------------------
; rx_verr - int rx_verr(unsigned selector): may the caller read through it?
; (VERR, at the caller's privilege)
;   In:       the stack: the selector
;   Out:      AX = 1 if so, else 0
;   Destroys: nothing else
; ----------------------------------------------------------------------------
rx_verr:
        push bp
        mov bp, sp
        mov ax, ARG(0)
        verr ax
        mov ax, 0
        jnz .done
        inc ax
.done:
        pop bp
        ret

; ----------------------------------------------------------------------------
; rx_ticks - unsigned long rx_ticks(void): the ticks since the start
; (KCALL_TICKS, TICKS_HZ a second)
;   In:       nothing
;   Out:      DX:AX = the ticks
;   Destroys: nothing else
; ----------------------------------------------------------------------------
rx_ticks:
        mov ah, KCALL_TICKS
        int KCALL_VECTOR
        ret

; ----------------------------------------------------------------------------
; rx_log - int rx_log(const void *bytes, unsigned n): to the kernel's log
; (KCALL_LOG)
;   In:       the stack: bytes, n
;   Out:      AX = the bytes written, or -1
;   Destroys: BX, CX, DX
; ----------------------------------------------------------------------------
rx_log:
        push bp
        mov bp, sp
        push si
        mov si, ARG(0)
        mov cx, ARG(1)
        mov ah, KCALL_LOG
        int KCALL_VECTOR
        jnc .done
        mov ax, -1
.done:
        pop si
        pop bp
        ret

; ----------------------------------------------------------------------------
; rx_log_far - int rx_log_far(unsigned segment, unsigned offset, unsigned n):
; bytes of another segment to the kernel's log (KCALL_LOG): a server's,
; from its client's transfer segment
;   In:       the stack: segment, offset, n
;   Out:      AX = the bytes written (fewer if the thread is to restart), or
;             -1
;   Destroys: BX, CX, DX
; ----------------------------------------------------------------------------
rx_log_far:
        push bp
        mov bp, sp
        push si
        push ds
        mov si, ARG(1)
        mov cx, ARG(2)
        mov ds, ARG(0)
        mov ah, KCALL_LOG
        int KCALL_VECTOR
        jnc .done
        mov ax, -1
.done:
        pop ds
        pop si
        pop bp
        ret

; ----------------------------------------------------------------------------
; rx_xchg - int rx_xchg(int *word, int value): the word swapped with a value
; in one instruction, for a lock (os-server.md D17): XCHG locks the bus by
; itself, which a LOCK prefix at ring 3 may not (W4)
;   In:       the stack: word, value
;   Out:      AX = the word's old value
;   Destroys: BX
; ----------------------------------------------------------------------------
rx_xchg:
        push bp
        mov bp, sp
        mov bx, ARG(0)
        mov ax, ARG(1)
        xchg ax, [bx]
        pop bp
        ret

; ----------------------------------------------------------------------------
; rx_ud2 - void rx_ud2(void): an invalid opcode on purpose, for the tests of
; faults (its address is the fault's)
;   In:       nothing
;   Out:      does not return: #UD
;   Destroys: nothing
; ----------------------------------------------------------------------------
rx_ud2:
        db 0x0F, 0x0B                   ; UD2: #UD on a 286 too
