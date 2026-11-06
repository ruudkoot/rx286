; ============================================================================
; rx286 - tests/programs/revoke.asm
; Delete and revoke (roadmap l4.md L12; tests/revoke), with what TEST_CAPS
; builds give the program: the rest of the memory for segments and of the
; arena as untyped, its own space and its own thread.
;
; A copy of a segment loaded in DS, its parent revoked: DS is null after
; the call. Memory: untyped of its own, a segment made from it, the untyped
; revoked, a segment made again: at the same base. An endpoint with a
; worker's call queued on it: revoked (the worker's copy goes) and deleted,
; the last capability to it: the worker's call fails with KE_CAP, and the
; worker says so on the log. A worker's space and thread made from untyped
; of their own, the untyped revoked: both gone. And E3's ABA case: the
; program's DS and a worker's name the same slot of two spaces; across a
; call to the worker, which reads its own, the program still reads its own.
; Then (l4.md L13) a worker that deletes its own stack: its way back fails
; each time, and the kernel stops it rather than retry for ever; and copies
; the kernel refuses, of untyped and of a saved reply (KE_ARG).
; Workers run above the program, so each has done its part when the
; program goes on; they write to the kernel's log (KCALL_LOG): their spaces
; hold no endpoint to the OS server.
; ============================================================================

cpu 286
bits 16
%include "build.inc"
%include "program.inc"
%include "kcalls.inc"

MY_CODE             equ 0x07            ; its slots (slot n: n * 8 + 4 + 3)
UT_MEMORY           equ 0x57            ; given (TEST_CAPS): slot 10
UT_ARENA            equ 0x5F            ; slot 11
MY_SPACE            equ 0x67            ; slot 12
SEG_A               equ 0x7F            ; 15: a segment, retyped
SEG_B               equ 0x87            ; 16: a copy of it
UT_OWN              equ 0x8F            ; 17: untyped of its own, from the memory's
SEG_OWN             equ 0x97            ; 18: a segment of that
EP                  equ 0x9F            ; 19: an endpoint
SAME                equ 0xA7            ; 20: the slot both spaces fill (the ABA case)
UT_WORKER           equ 0xAF            ; 21: untyped of the arena's, for a worker
W1_SPACE            equ 0xB7            ; 22, 23: the queued caller
W1_THREAD           equ 0xBF
W2_SPACE            equ 0xC7            ; 24, 25: the ABA case's server
W2_THREAD           equ 0xCF
W3_SPACE            equ 0xD7            ; 26, 27: the worker revoked with its space
W3_THREAD           equ 0xDF
EP2                 equ 0xE7            ; 28: the ABA case's endpoint
SCRATCH             equ 0xEF            ; 29: segments on their way to a space
W4_SPACE            equ 0xF7            ; 30, 31: the worker without its stack
W4_THREAD           equ 0xFF
W5_SPACE            equ 0x107           ; 32, 33: the caller whose reply is saved
W5_THREAD           equ 0x10F
EP3                 equ 0x117           ; 34: its endpoint
REPLY               equ 0x11F           ; 35: the reply owed it

W_CODE              equ 0x07            ; a worker's slots
W_DATA              equ 0x0F
W_STACK             equ 0x17
W_EP                equ 0x1F            ; the endpoint it calls or receives on
W_WAIT              equ 0x27            ; a notification nobody signals
W_SIZE              equ 256
W_LINE              equ 0x40            ; where a worker builds a line

ROLE_CALLER         equ 1
ROLE_SERVER         equ 2
ROLE_WAITER         equ 3
ROLE_STRANDED       equ 4               ; deletes its own stack
ROLE_ASKER          equ 5               ; calls, and waits once answered
MARK_PROGRAM        equ 'A'             ; the ABA case: what each space's SAME holds
MARK_WORKER         equ 'B'
WORKER_PRIORITY     equ 4               ; above the program

begin_udata
base_then           dw 0
end_udata

; report "what" - "revoke: what: " and AX in decimal
%macro report 1
        push ds
        pop es
        PRINT "revoke: ", %1, ": "
        call print_dec
        call print_newline
%endmacro

; must - stop the test if the last kernel call failed
%macro must 0
        jc setup_failed
%endmacro

; ----------------------------------------------------------------------------
; entry - the checks, once; then "done", and a wait for the end
;   In:       the kernel's start (program.inc)
;   Out:      does not return
;   Destroys: everything
; ----------------------------------------------------------------------------
entry:
        cld
        call check_ds
        call check_memory
        call check_endpoint
        call check_space
        call check_aba
        call check_stranded
        call check_copies
        PRINT "revoke: done", CHAR_LF
.wait:
        mov al, KEY_WAIT
        sys SYS_READ_KEY
        jmp .wait

; ----------------------------------------------------------------------------
; check_ds - a copy of a segment in DS, its parent revoked: DS null on return
;   In:       DS = ES = its data
;   Out:      a line
;   Destroys: everything but DS, ES
; ----------------------------------------------------------------------------
check_ds:
        mov dx, UT_MEMORY
        mov al, CAP_SEGMENT
        mov si, SEG_A
        mov cx, 16
        mov bl, 0xF2
        kcall KCALL_RETYPE
        must
        mov dx, MY_SPACE
        mov si, SEG_A
        mov di, SEG_B
        mov al, COPY_COPY
        kcall KCALL_COPY
        must
        push ds
        mov ax, SEG_B
        mov ds, ax                      ; the copy, in DS
        mov dx, SEG_A
        kcall KCALL_REVOKE              ; the copy goes: DS null on the way back
        mov ax, ds
        pop ds
        report "a copy in DS, its parent revoked: DS (0)"
        ret

; ----------------------------------------------------------------------------
; check_memory - untyped of its own; a segment made from it; the untyped
; revoked; a segment made again, at the same base
;   In:       DS = ES = its data
;   Out:      a line
;   Destroys: everything but DS, ES
; ----------------------------------------------------------------------------
check_memory:
        mov dx, UT_MEMORY
        mov al, CAP_UNTYPED
        mov si, UT_OWN
        mov cx, 64                      ; a kilobyte
        kcall KCALL_RETYPE
        must
        call own_segment
        mov [base_then], ax
        mov dx, UT_OWN
        kcall KCALL_REVOKE
        must
        mov dx, SEG_OWN                 ; gone with it
        kcall KCALL_SEGMENT
        mov ax, 0
        jc .gone
        inc ax
.gone:
        report "the untyped revoked, its segment still there (0)"
        call own_segment
        cmp ax, [base_then]
        mov ax, 1
        je .same
        xor ax, ax
.same:
        report "memory given back, made again at the same base (1)"
        ret

; ----------------------------------------------------------------------------
; own_segment - a segment of UT_OWN in SEG_OWN, and its base
;   In:       nothing
;   Out:      AX = its base's low word (stops the test on a failure)
;   Destroys: BX, CX, DX, SI
; ----------------------------------------------------------------------------
own_segment:
        mov dx, UT_OWN
        mov al, CAP_SEGMENT
        mov si, SEG_OWN
        mov cx, 256
        mov bl, 0xF2
        kcall KCALL_RETYPE
        must
        mov dx, SEG_OWN
        kcall KCALL_SEGMENT             ; DL:AX = its base
        must
        ret

; ----------------------------------------------------------------------------
; check_endpoint - a worker's call queued on an endpoint; the endpoint
; revoked (the worker's copy goes) and deleted (the last capability): the
; worker's call fails with KE_CAP, which it says on the log
;   In:       DS = ES = its data
;   Out:      the worker's line
;   Destroys: everything but DS, ES
; ----------------------------------------------------------------------------
check_endpoint:
        mov dx, UT_ARENA
        mov al, CAP_ENDPOINT
        mov si, EP
        kcall KCALL_RETYPE
        must
        mov al, ROLE_CALLER
        mov bx, W1_SPACE
        mov dx, W1_THREAD
        mov si, UT_ARENA
        mov di, EP
        call make_worker                ; it calls, and waits in the queue
        mov dx, EP
        kcall KCALL_REVOKE              ; its copy: gone; the call still queued
        must
        mov dx, EP
        kcall KCALL_DELETE              ; the last capability: the endpoint dies
        must
        ret

; ----------------------------------------------------------------------------
; check_space - a worker made from untyped of its own; the untyped revoked:
; its space and thread gone
;   In:       DS = ES = its data
;   Out:      a line
;   Destroys: everything but DS, ES
; ----------------------------------------------------------------------------
check_space:
        mov dx, UT_ARENA
        mov al, CAP_UNTYPED
        mov si, UT_WORKER
        mov cx, 2048 >> 4               ; a space of 16 slots (528 bytes), a thread
        kcall KCALL_RETYPE
        must
        mov al, ROLE_WAITER
        mov bx, W3_SPACE
        mov dx, W3_THREAD
        mov si, UT_WORKER
        xor di, di
        call make_worker                ; it waits for good
        mov dx, UT_WORKER
        kcall KCALL_REVOKE
        must
        mov dx, W3_THREAD
        mov al, THREAD_INFO
        kcall KCALL_THREAD              ; its slot: empty
        mov ax, 0
        jnc .there
        inc ax
.there:
        report "a worker's untyped revoked: its thread gone (1)"
        ret

; ----------------------------------------------------------------------------
; check_aba - E3's ABA case: the program's DS and the worker's name slot
; SAME of two spaces, which hold two segments; across a call to the worker,
; which reads its own, the program reads its own
;   In:       DS = ES = its data
;   Out:      a line
;   Destroys: everything but DS, ES
; ----------------------------------------------------------------------------
check_aba:
        mov dx, UT_MEMORY
        mov al, CAP_SEGMENT
        mov si, SAME
        mov cx, 16
        mov bl, 0xF2
        kcall KCALL_RETYPE
        must
        mov ax, SAME
        mov es, ax
        mov byte [es:0], MARK_PROGRAM
        push ds
        pop es
        mov dx, UT_ARENA
        mov al, CAP_ENDPOINT
        mov si, EP2
        kcall KCALL_RETYPE
        must
        mov al, ROLE_SERVER
        mov bx, W2_SPACE
        mov dx, W2_THREAD
        mov si, UT_ARENA
        mov di, EP2
        call make_worker                ; it waits for a call
        push ds
        mov ax, SAME
        mov ds, ax                      ; slot SAME, in DS, across the call
        mov dx, EP2
        xor bp, bp
        mov al, 1
        kcall KCALL_CALL                ; BX = what the worker read in its own
        mov al, [0]
        pop ds
        push ax
        mov ax, bx
        report "the worker read, in its own slot (66)"
        pop ax
        xor ah, ah
        report "and the program, in its own, after the call (65)"
        ret

; ----------------------------------------------------------------------------
; check_stranded - a worker that deletes its own stack slot: each way back
; fails, and after a few the kernel stops it (STATE_STOPPED, 8)
;   In:       DS = ES = its data
;   Out:      a line
;   Destroys: everything but DS, ES
; ----------------------------------------------------------------------------
check_stranded:
        mov al, ROLE_STRANDED
        mov bx, W4_SPACE
        mov dx, W4_THREAD
        mov si, UT_ARENA
        xor di, di
        call make_worker                ; it runs, and stops
        mov dx, W4_THREAD
        mov al, THREAD_INFO
        kcall KCALL_THREAD              ; BL = its state
        must
        mov al, bl
        xor ah, ah
        report "a worker without its stack: stopped (8)"
        ret

; ----------------------------------------------------------------------------
; check_copies - the copies the kernel refuses (KE_ARG, 2): of untyped,
; whose memory two retypes would carve; and of a saved reply, answered once
;   In:       DS = ES = its data
;   Out:      two lines
;   Destroys: everything but DS, ES
; ----------------------------------------------------------------------------
check_copies:
        mov dx, MY_SPACE
        mov si, UT_MEMORY
        mov di, SCRATCH
        mov al, COPY_COPY
        kcall KCALL_COPY
        xor ah, ah
        report "untyped copied: status (2)"
        mov dx, UT_ARENA
        mov al, CAP_ENDPOINT
        mov si, EP3
        kcall KCALL_RETYPE
        must
        mov al, ROLE_ASKER
        mov bx, W5_SPACE
        mov dx, W5_THREAD
        mov si, UT_ARENA
        mov di, EP3
        call make_worker                ; its call, queued
        mov dx, EP3
        xor bp, bp
        kcall KCALL_RECV
        must
        mov si, REPLY
        kcall KCALL_SAVE_REPLY
        must
        mov dx, MY_SPACE
        mov si, REPLY
        mov di, SCRATCH
        mov al, COPY_COPY
        kcall KCALL_COPY
        push ax
        mov dx, REPLY                   ; answered: the worker goes on
        xor bp, bp
        xor al, al
        kcall KCALL_SEND
        pop ax
        xor ah, ah
        report "a saved reply copied: status (2)"
        ret

; ----------------------------------------------------------------------------
; make_worker - a worker: a space and a thread from untyped, the program's
; code, data (its first word the role), a stack, a notification nobody
; signals, and in W_EP a copy of an endpoint; a server's own segment in slot
; SAME, marked; started above the program, so it has done its part (called,
; or waited) when the program goes on
;   In:       AL = the role; BX = the space's slot; DX = the thread's slot; SI
;             = the untyped (of the arena) to make them of; DI = the
;             endpoint (0: none)
;   Out:      nothing (stops the test on a failure)
;   Destroys: AX, BX, CX, DX, SI, DI
; ----------------------------------------------------------------------------
make_worker:
        mov [w_role], al
        mov [w_space], bx
        mov [w_thread], dx
        mov [w_untyped], si
        mov [w_ep], di
        mov cx, 16
        cmp al, ROLE_SERVER
        jne .slots
        mov cx, 32                      ; room for slot SAME
.slots:
        mov dx, si
        mov al, CAP_SPACE
        mov si, bx
        kcall KCALL_RETYPE
        must
        mov dx, [w_untyped]
        mov al, CAP_THREAD
        mov si, [w_thread]
        kcall KCALL_RETYPE
        must
        mov dx, [w_space]               ; the program's code
        mov si, MY_CODE
        mov di, W_CODE
        mov al, COPY_COPY
        kcall KCALL_COPY
        must
        call scratch_segment            ; its data: the role first
        mov ax, SCRATCH
        mov es, ax
        mov al, [w_role]
        xor ah, ah
        mov [es:0], ax
        push ds
        pop es
        mov di, W_DATA
        call move_in
        call scratch_segment            ; its stack
        mov di, W_STACK
        call move_in
        mov si, [w_ep]
        test si, si
        jz .notify
        mov dx, [w_space]
        mov di, W_EP
        mov al, COPY_COPY
        kcall KCALL_COPY
        must
.notify:
        mov dx, UT_ARENA                ; a notification nobody signals
        mov al, CAP_NOTIFY
        mov si, SCRATCH
        kcall KCALL_RETYPE
        must
        mov di, W_WAIT
        call move_in
        cmp byte [w_role], ROLE_SERVER
        jne .start
        call scratch_segment            ; a server's own slot SAME
        mov ax, SCRATCH
        mov es, ax
        mov byte [es:0], MARK_WORKER
        push ds
        pop es
        mov di, SAME
        call move_in
.start:
        mov dx, [w_thread]
        mov si, [w_space]
        mov bx, worker
        mov al, THREAD_CONFIGURE
        mov cx, W_SIZE
        kcall KCALL_THREAD
        must
        mov al, THREAD_START
        mov cl, WORKER_PRIORITY
        xor ch, ch
        kcall KCALL_THREAD
        must
        ret

begin_udata
w_role              db 0                ; make_worker's: the worker's
w_space             dw 0
w_thread            dw 0
w_untyped           dw 0
w_ep                dw 0
end_udata

; ----------------------------------------------------------------------------
; move_in - SCRATCH moved into a slot of the worker's space
;   In:       DI = the slot; w_space
;   Out:      nothing (stops the test on a failure)
;   Destroys: AX, DX, SI
; ----------------------------------------------------------------------------
move_in:
        mov dx, [w_space]
        mov si, SCRATCH
        mov al, COPY_MOVE
        kcall KCALL_COPY
        must
        ret

; ----------------------------------------------------------------------------
; scratch_segment - W_SIZE bytes of data, DPL 3, into SCRATCH
;   In:       nothing
;   Out:      nothing (stops the test on a failure)
;   Destroys: AX, CX, DX, SI
; ----------------------------------------------------------------------------
scratch_segment:
        push bx
        mov dx, UT_MEMORY
        mov al, CAP_SEGMENT
        mov si, SCRATCH
        mov cx, W_SIZE
        mov bl, 0xF2
        kcall KCALL_RETYPE
        pop bx
        must
        ret

; ----------------------------------------------------------------------------
; worker - a worker's code, by its role (its data's first word)
;   In:       its start: DS = ES = its data
;   Out:      does not return
;   Destroys: everything
; ----------------------------------------------------------------------------
worker:
        cmp word [0], ROLE_CALLER
        je .caller
        cmp word [0], ROLE_SERVER
        je .server
        cmp word [0], ROLE_STRANDED
        je .stranded
        cmp word [0], ROLE_ASKER
        je .asker
.wait:
        mov dx, W_WAIT                  ; for good: nobody signals it
        kcall KCALL_RECV
        jmp .wait
.caller:
        mov dx, W_EP
        xor bp, bp
        mov al, 1
        kcall KCALL_CALL                ; queued: nobody receives
        xor ah, ah
        push ax
        mov si, msg_failed
        mov di, W_LINE
        call copy_text
        pop ax
        add al, '0'
        stosb
        mov al, CHAR_LF
        stosb
        mov cx, di
        mov si, W_LINE
        sub cx, si
        kcall KCALL_LOG
        jmp .wait
.stranded:
        mov dx, W_STACK                 ; its own stack: no way back to ring 3
        kcall KCALL_DELETE
.stranded_back:
        jmp .wait                       ; never: the kernel stops it
.asker:
        mov dx, W_EP
        xor bp, bp
        mov al, 1
        kcall KCALL_CALL
        jmp .wait
.server:
        mov dx, W_EP
        xor bp, bp
        kcall KCALL_RECV
        push ds
        mov ax, SAME                    ; its own slot SAME
        mov ds, ax
        mov bl, [0]
        pop ds
        xor bh, bh
        mov dx, W_EP
        xor bp, bp
        kcall KCALL_REPLY_RECV
        jmp .wait

; ----------------------------------------------------------------------------
; copy_text - a zero-terminated text of the code to ES:DI
;   In:       CS:SI = the text; ES:DI = where
;   Out:      DI past it
;   Destroys: AX, SI
; ----------------------------------------------------------------------------
copy_text:
        mov al, [cs:si]
        test al, al
        jz .done
        stosb
        inc si
        jmp copy_text
.done:
        ret

msg_failed          db "revoke: the worker's queued call, its endpoint deleted: status (1): ", 0

; ----------------------------------------------------------------------------
; setup_failed - a call the test needs failed: say so, and stop
;   In:       AL = the status
;   Out:      does not return
;   Destroys: everything
; ----------------------------------------------------------------------------
setup_failed:
        xor ah, ah
        report "a setup call failed, status"
.stop:
        jmp .stop

%include "uprint.asm"
%include "format.asm"
