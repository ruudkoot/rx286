; ============================================================================
; rx286 - src/lib/crt/server.asm
; The start of a server's threads, and its lock (roadmap memory.md M6, *The
; model for multi-threaded servers*): in place of crt0, for a server in C's
; compact model, each of whose threads runs on a stack segment of its own,
; so that an overflow faults at the segment's limit before it writes
; anything that is not its own (D10 B).
;
; The root starts thread n at the server's entry with SP = n * OS_STACK in
; the server's stack segment (slot 2), which is only the starts' room. Here
; the thread finds its stack's selector in the server's table,
; server_stacks[n] (server_threads of them; 0 or past them: none, and it
; stops), and runs on it: SS that selector, SP the segment's top (LSL). The
; stack's lowest word is a guard: on a first start the whole segment is
; filled with it, so that server_stack_used can tell how deep the thread
; has gone; the top word then holds n, for server_self. Then C:
; server_thread(n), the server's, which does not return.
;
; A fault of a server's thread goes to the root, which reports it and
; replies at the second entry, SERVE_FAULT_AT bytes past the first (os.inc):
; the thread starts there afresh on its stack, filled again if it ran past
; the guard, and calls the server's policy, server_fault(n), first; if that
; returns, server_thread(n), as at a start.
;
; The lock: a word that XCHG takes, and the holder's number beside it,
; written by the same routine with no push between the two, so that no
; fault (a push past the stack's limit) can leave the lock taken with no
; holder: server_lock_holder tells a fault's policy whether the thread that
; faulted held it.
; ============================================================================

cpu 286
bits 16
%include "build.inc"
%include "cabi.inc"
%include "os.inc"

%ifndef FAR_DATA
  %error "server.asm: a server's threads are in C's compact model (FAR_DATA)"
%endif

STACK_SHIFT         equ 2               ; SP = n * OS_STACK (4) at a start
%if 1 << STACK_SHIFT != OS_STACK
  %error "server.asm: STACK_SHIFT must match os.inc's OS_STACK"
%endif
SERVER_GUARD        equ 0x5A5A          ; the guard, and the fill
LOCK_HOLDER         equ 2               ; struct server_lock: the word, then its holder

global _start, server_self, server_stack_ok, server_stack_used
global server_lock_try, server_lock_give, server_lock_holder
extern server_thread, server_fault, server_stacks, server_threads

data_section                            ; (DGROUP, for the table's offsets)

code_section

; ----------------------------------------------------------------------------
; _start - a thread's entry, and SERVE_FAULT_AT past it its entry after a
; fault: its stack, filled the first time, then C
;   In:       SP = n * OS_STACK in the starts' room; DS = ES = the data
;   Out:      does not return
;   Destroys: everything
; ----------------------------------------------------------------------------
_start:
        jmp short .start
.fault:                                 ; the root's reply to a fault comes here
        mov bx, 1
        jmp short .go
.start:
        xor bx, bx                      ; BX = 1 after a fault
.go:
        cld
        mov dx, sp
        shr dx, STACK_SHIFT             ; DX = n
        call stack_of                   ; AX = its stack, SI = its top (pushes nothing)
        jc .stop                        ; none such: the root starts none
        mov es, ax
        cmp word [es:0], SERVER_GUARD
        je .filled                      ; started before, within its stack
        xor di, di
        mov ax, SERVER_GUARD
        mov cx, si
        dec cx
        shr cx, 1
        inc cx                          ; CX = its words (8000h for 64 KB)
        rep stosw
.filled:
        mov ax, es
        mov ss, ax                      ; interrupts wait for the next instruction
        mov sp, si
        push dx                         ; n, at its top (server_self)
        test bx, bx
        jz .serve
        push dx
        call server_fault               ; the server's policy, on a fresh stack
        add sp, 2
        mov dx, [ss:si - 2]             ; n again (SI kept)
.serve:
        push dx
        call server_thread              ; does not return
.stop:
        jmp .stop

%if _start.fault - _start != SERVE_FAULT_AT
  %error "server.asm: the entry after a fault must be SERVE_FAULT_AT past the start"
%endif

; ----------------------------------------------------------------------------
; stack_of - thread n's stack: its selector from server_stacks, its top
; from its limit. It pushes nothing: a start has a call's room alone
;   In:       DX = n; DS = the data
;   Out:      CF clear, AX = the selector, SI = the top (0: 64 KB); CF set if
;             n has none (past the table, 0, or not a segment the server
;             may read)
;   Destroys: CX
; ----------------------------------------------------------------------------
stack_of:
        cmp dx, [DGROUP_OFFSET(server_threads)]
        jae .none
        mov si, dx
        shl si, 1
        mov ax, [si + DGROUP_OFFSET(server_stacks)]
        test ax, ax
        jz .none
        lsl si, ax
        jnz .none
        inc si                          ; the top: the limit's next byte
        clc
        ret
.none:
        stc
        ret

; ----------------------------------------------------------------------------
; server_self - unsigned server_self(void): the calling thread's number, at
; its stack's top
;   In:       SS = its stack
;   Out:      AX = n
;   Destroys: BX
; ----------------------------------------------------------------------------
server_self:
        mov ax, ss
        lsl bx, ax
        mov ax, [ss:bx - 1]             ; the top word: the limit's last two bytes
        ret

; ----------------------------------------------------------------------------
; server_stack_ok - int server_stack_ok(unsigned n): is thread n's guard
; still there?
;   In:       the stack: n
;   Out:      AX = 1 if so (or n has no stack), else 0
;   Destroys: BX, CX, DX, ES
; ----------------------------------------------------------------------------
server_stack_ok:
        push bp
        mov bp, sp
        push si
        mov dx, ARG(0)
        mov ax, 1
        call stack_of
        jc .done
        mov es, ax
        xor ax, ax
        cmp word [es:0], SERVER_GUARD
        jne .done
        inc ax
.done:
        pop si
        pop bp
        ret

; ----------------------------------------------------------------------------
; server_stack_used - unsigned server_stack_used(unsigned n): the bytes of
; its stack thread n has used at most (the fill no longer there above the
; lowest word)
;   In:       the stack: n
;   Out:      AX = the bytes (0 if it has no stack)
;   Destroys: BX, CX, DX, ES
; ----------------------------------------------------------------------------
server_stack_used:
        push bp
        mov bp, sp
        push si
        push di
        mov dx, ARG(0)
        xor ax, ax
        call stack_of
        jc .done
        mov es, ax
        xor di, di
        mov cx, si
        dec cx
        shr cx, 1
        inc cx                          ; CX = its words
        mov bx, cx
        mov ax, SERVER_GUARD
        repe scasw
        je .all                         ; (the fill throughout: none used)
        inc cx                          ; the first word that is not the fill
.all:
        mov ax, cx
        shl ax, 1
.done:
        pop di
        pop si
        pop bp
        ret

; ----------------------------------------------------------------------------
; server_lock_try - int server_lock_try(struct server_lock *lock, unsigned
; holder): the lock taken, and its holder written, if it was free
;   In:       the stack: lock (far), holder
;   Out:      AX = 1 if taken, 0 if another holds it
;   Destroys: BX, ES
; ----------------------------------------------------------------------------
server_lock_try:
        push bp
        mov bp, sp
        les bx, ARG(0)
        mov ax, 1
        xchg ax, [es:bx]                ; (XCHG locks the bus by itself: os-server.md W4)
        test ax, ax
        mov ax, 0
        jnz .done
        mov ax, ARG(2)                  ; no push between the XCHG and this
        mov [es:bx + LOCK_HOLDER], ax
        mov ax, 1
.done:
        pop bp
        ret

; ----------------------------------------------------------------------------
; server_lock_give - void server_lock_give(struct server_lock *lock): the
; lock given up, its holder first
;   In:       the stack: lock (far)
;   Out:      nothing
;   Destroys: BX, ES
; ----------------------------------------------------------------------------
server_lock_give:
        push bp
        mov bp, sp
        les bx, ARG(0)
        mov word [es:bx + LOCK_HOLDER], 0
        mov word [es:bx], 0
        pop bp
        ret

; ----------------------------------------------------------------------------
; server_lock_holder - unsigned server_lock_holder(const struct server_lock
; *lock): the thread that holds the lock, or 0 if none
;   In:       the stack: lock (far)
;   Out:      AX = its number, or 0
;   Destroys: BX, ES
; ----------------------------------------------------------------------------
server_lock_holder:
        push bp
        mov bp, sp
        les bx, ARG(0)
        xor ax, ax
        cmp word [es:bx], 0
        je .done
        mov ax, [es:bx + LOCK_HOLDER]
.done:
        pop bp
        ret
