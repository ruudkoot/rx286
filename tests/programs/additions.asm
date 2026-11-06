; ============================================================================
; rx286 - tests/programs/additions.asm
; The kernel's additions of roadmap os-server.md P2: the seal, a thread
; suspended and its frame moved, the pools and the retype in pieces.
;
; A TEST_CAPS program (untyped memory, its own space and thread: slots
; 10-13), one part a build:
;   TEST_ADD_SEAL     KCALL_SEAL: a fresh segment sealed and called; every
;                     refusal; sealed code run as a new space's thread; at
;                     last a write through the sealed selector, a #GP
;   TEST_ADD_SUSPEND  a worker suspended, its frame read and written with a
;                     signal's frame, resumed in a handler that returns by
;                     IRET (os-server.md E6); IF and NT as the kernel keeps
;                     them; a worker suspended inside KCALL_LOG, whose call
;                     still returns its count and gives up the log's turn
;                     (E11); one suspended in its call's wait, which stops
;                     with its reply; one suspended in its revokes' windows,
;                     whose revokes end whole; one awaiting its fault's
;                     reply, which stops at once with its registers as at
;                     the fault, and goes on in a handler that never
;                     returns; every refusal
;   TEST_ADD_POOLS    threads made until the arena, not a pool, refuses
;                     (pools of 64); 40 spaces more, holding copies that a
;                     revoke deletes, then deleted; a 64 KB segment retyped,
;                     its zeroing in pieces (TEST_STRETCH measures them: no
;                     delete looks through every slot, os-server.md D9)
; Its lines come through uprint; the workers' through KCALL_LOG.
; ============================================================================

cpu 286
bits 16
%include "build.inc"
%include "program.inc"
%include "kcalls.inc"

MY_CODE             equ 0x07
MY_DATA             equ 0x0F
UT_MEMORY           equ 0x57            ; TEST_CAPS: slot 10
UT_ARENA            equ 0x5F            ; 11
MY_SPACE            equ 0x67            ; 12
MY_THREAD           equ 0x6F            ; 13
S_SEG               equ 0x87            ; 16: a segment to seal
S_SEG2              equ 0x8F            ; 17
S_COPY              equ 0x97            ; 18
S_EP                equ 0x9F            ; 19
W_SPACE             equ 0xA7            ; 20: the worker's space
W_THREAD            equ 0xAF            ; 21: and thread
W_STACK_MINE        equ 0xB7            ; 22: a copy of the worker's stack
W_DATA_MINE         equ 0xBF            ; 23: and of its data
NTF_SLEEP           equ 0xC7            ; 24: its own timer's
SCRATCH             equ 0xCF            ; 25
X_SPACE             equ 0xD7            ; 26: the sealed program's space
X_THREAD            equ 0xDF            ; 27
NTF_STOP            equ 0xE7            ; 28: signalled when the worker has stopped
BIG                 equ 0xEF            ; 29: the 64 KB segment
THREAD_FIRST        equ 0x127           ; 36 on: the pools' threads
S_EPF               equ 0xF7            ; 30: the worker's fault endpoint
S_REPLY             equ 0xFF            ; 31: a reply saved
X_HOLD              equ 0x107           ; 32: a space of 64 slots, the revoker's
HOLDER              equ 0x10F           ; 33: the pools' space that holds 40
SMALL               equ 0x117           ; 34: each of them, before it moves there
UT_POOLS            equ 0x11F           ; 35: the pools' part of the arena
POOLS_BYTES         equ 14336             ; (the program has about 15 KB of the arena)
THREADS             equ 24
SPACES              equ 40

; A worker's slots
WK_CODE             equ 0x07
WK_DATA             equ 0x0F
WK_STACK            equ 0x17
WK_NTF              equ 0x1F
WK_EP               equ 0x27            ; a copy of S_EP (roles 3 and 4)
WK_X                equ 0x2F            ; X_HOLD (role 4)
W_SIZE              equ 512
W_COUNT             equ 0               ; in its data: its count
W_SIGNALS           equ 2               ;    the signals it took
W_WRONG             equ 4               ;    KCALL_LOG results that were wrong
W_ROLE              equ 6               ;    1 count, 2 log, 3 call, 4 revoke, 5 fault
W_REPLY             equ 8               ;    the caller's last reply
W_LINE              equ 0x40            ;    its log line
W_LINE_SIZE         equ 9
SIGFRAME            equ 26              ; ES DS DI SI BP SP BX DX CX AX IP CS FLAGS
DELIVERIES          equ 20
REVOKE_COPIES       equ 40
ROLE_COUNT          equ 1
ROLE_LOG            equ 2
ROLE_CALL           equ 3
ROLE_REVOKE         equ 4
ROLE_FAULT          equ 5

begin_udata
step                dw 0
frame               times TFR_SIZE db 0
signal_frame        times 13 dw 0
threads             dw 0
role                dw 0
inside              dw 0
end_udata

; report "what" - "additions: what: " and AX in decimal
%macro report 1
        push ds
        pop es
        push ax
        PRINT "additions: ", %1, ": "
        pop ax
        call print_dec
        call print_newline
%endmacro

; setnz_ax - AX = 1 if ZF is clear, else 0 (the 286 has no SETcc)
%macro setnz_ax 0
        mov ax, 0
        jz %%zero
        inc ax
%%zero:
%endmacro
; setb_ax - AX = 1 if CF is set, else 0
%macro setb_ax 0
        mov ax, 0
        jnc %%clear
        inc ax
%%clear:
%endmacro
; kcall_thread op - KCALL_THREAD on DX with AL = op
%macro kcall_thread 1
        mov al, %1
        kcall KCALL_THREAD
%endmacro

FLAGS_NT_BIT        equ 0x4000
FLAGS_IF_BIT        equ 0x0200

; status "what" - report the last kernel call's status (AL), from 0
%macro status 1
        xor ah, ah
        report %1
%endmacro

; ----------------------------------------------------------------------------
; entry - the part this build runs; a restart after the fault on purpose
; ends it
;   In:       the kernel's start
;   Out:      does not return
;   Destroys: everything
; ----------------------------------------------------------------------------
entry:
        cld
        mov ax, [step]
        inc word [step]
        test ax, ax
        jnz done
        mov dx, UT_ARENA
        mov al, CAP_NOTIFY
        mov si, NTF_SLEEP
        kcall KCALL_RETYPE
%ifdef TEST_ADD_SEAL
        jmp seal_part
%elifdef TEST_ADD_SUSPEND
        jmp suspend_part
%else
        jmp pools_part
%endif

; ----------------------------------------------------------------------------
; done - the end: "done", then the keys, read for ever
;   In:       nothing
;   Out:      does not return
;   Destroys: everything
; ----------------------------------------------------------------------------
done:
        PRINT "additions: done", CHAR_LF
.wait:
        mov al, KEY_WAIT
        sys SYS_READ_KEY
        jmp .wait

; ----------------------------------------------------------------------------
; failed - a call the test needs failed: its status, and the end
;   In:       AL = the status
;   Out:      does not return
;   Destroys: everything
; ----------------------------------------------------------------------------
failed:
        status "a setup call failed, status"
        jmp done

%macro must 0
        jc failed
%endmacro

; ============================================================================ the seal
; ----------------------------------------------------------------------------
; seal_part - KCALL_SEAL, its refusals, sealed code as a thread's; then a
; write through the sealed selector
;   In:       nothing
;   Out:      does not return
;   Destroys: everything
; ----------------------------------------------------------------------------
seal_part:
        mov si, S_SEG
        call data64
        mov ax, S_SEG
        mov es, ax
        mov word [es:0], 0x34B8         ; mov ax, 1234h
        mov word [es:2], 0xCB12         ; retf
        mov dx, S_SEG
        kcall KCALL_SEAL
        status "seal a fresh segment (0)"
        db 0x9A                         ; call far S_SEG:0
        dw 0, S_SEG
        report "the sealed code ran, AX (4660)"
        lar ax, [cs:sealed]
        mov al, ah
        xor ah, ah
        report "its access byte (251: readable code of DPL 3)"
        mov dx, S_SEG
        kcall KCALL_SEAL
        status "seal it again (2)"
        mov si, S_SEG2
        call data64
        mov dx, MY_SPACE
        mov si, S_SEG2
        mov di, S_COPY
        mov al, COPY_COPY
        kcall KCALL_COPY
        must
        mov dx, S_SEG2
        kcall KCALL_SEAL
        status "seal a segment a copy of which lives (6)"
        mov dx, S_COPY
        kcall KCALL_SEAL
        status "seal the copy (6)"
        mov dx, UT_MEMORY
        mov al, CAP_SEGMENT
        mov si, SCRATCH
        mov cx, 64
        mov bl, 0xD2                    ; data of DPL 2
        kcall KCALL_RETYPE
        must
        mov dx, SCRATCH
        kcall KCALL_SEAL
        status "seal a segment of DPL 2 (2)"
        mov dx, SCRATCH
        kcall KCALL_DELETE
        mov dx, UT_ARENA
        mov al, CAP_ENDPOINT
        mov si, S_EP
        kcall KCALL_RETYPE
        must
        mov dx, S_EP
        kcall KCALL_SEAL
        status "seal an endpoint (1)"
        call sealed_program
        mov cx, 5
        call sleep
        mov ax, S_SEG                   ; a write through it: #GP
        mov es, ax
        mov byte [es:0], 0x90
        PRINT "additions: the write went through", CHAR_LF
        jmp done

sealed              dw S_SEG

; ----------------------------------------------------------------------------
; data64 - 64 bytes of data of DPL 3 into a slot
;   In:       SI = the slot
;   Out:      nothing (the end on a failure)
;   Destroys: AX, BX, CX, DX
; ----------------------------------------------------------------------------
data64:
        mov dx, UT_MEMORY
        mov al, CAP_SEGMENT
        mov cx, 64
        mov bl, 0xF2
        kcall KCALL_RETYPE
        must
        ret

; ----------------------------------------------------------------------------
; sealed_program - child's bytes into a segment, sealed, made a new space's
; code, a thread started there
;   In:       nothing
;   Out:      nothing (the end on a failure)
;   Destroys: AX, BX, CX, DX, SI, DI, ES
; ----------------------------------------------------------------------------
sealed_program:
        mov dx, UT_MEMORY
        mov al, CAP_SEGMENT
        mov si, SCRATCH
        mov cx, child_end - child
        mov bl, 0xF2
        kcall KCALL_RETYPE
        must
        push ds
        mov ax, SCRATCH
        mov es, ax
        push cs
        pop ds
        mov si, child
        xor di, di
        mov cx, child_end - child
        rep movsb
        pop ds
        push ds
        pop es
        mov dx, SCRATCH
        kcall KCALL_SEAL
        must
        mov bx, X_SPACE
        mov dx, X_THREAD
        mov si, SCRATCH
        call worker_space
        mov dx, X_THREAD
        mov si, X_SPACE
        xor bx, bx                      ; its entry: the segment's start
        mov cx, W_SIZE
        mov al, THREAD_CONFIGURE
        kcall KCALL_THREAD
        must
        mov dx, X_THREAD
        mov cl, 2
        call start_thread
        ret

; ----------------------------------------------------------------------------
; child - position-independent code, copied into a sealed segment: one
; line, read through DS = CS (readable code), then a wait for ever
;   In:       its start
;   Out:      does not return
;   Destroys: everything
; ----------------------------------------------------------------------------
child:
        push cs
        pop ds
        mov si, child_line - child
        mov cx, child_line_end - child_line
        kcall KCALL_LOG
.wait:
        mov dx, WK_NTF
        kcall KCALL_RECV
        jmp .wait
child_line          db "child: running from a sealed segment", CHAR_LF
child_line_end      equ $
child_end           equ $

; ============================================================================ suspend
; ----------------------------------------------------------------------------
; suspend_part - a worker suspended, its frame moved, a signal delivered;
; the flags the kernel keeps; a worker inside KCALL_LOG; the refusals
;   In:       nothing
;   Out:      does not return
;   Destroys: everything
; ----------------------------------------------------------------------------
suspend_part:
        mov dx, UT_ARENA
        mov al, CAP_NOTIFY
        mov si, NTF_STOP
        kcall KCALL_RETYPE
        must
        mov dx, UT_ARENA
        mov al, CAP_ENDPOINT
        mov si, S_EP
        kcall KCALL_RETYPE
        must
        mov ax, ROLE_COUNT
        call make_worker
        mov cx, 5
        call sleep
        call worker_count
        test ax, ax
        setnz_ax
        report "the worker counted (1)"
        call deliver
        mov cx, 5
        call sleep
        mov ax, W_SIGNALS
        call worker_word
        report "signals it took (1)"
        call worker_count
        push ax
        mov cx, 5
        call sleep
        call worker_count
        pop bx
        sub ax, bx
        setnz_ax
        report "it counts on after its handler (1)"
        ; the flags: written without IF and with NT, read back with IF, without NT
        call suspend_worker
        mov bl, FRAME_READ
        call worker_frame
        must
        mov word [frame + TFR_FLAGS], FLAGS_NT_BIT | 0x0001     ; NT and CF, no IF
        mov bl, FRAME_WRITE
        call worker_frame
        must
        mov bl, FRAME_READ
        call worker_frame
        must
        mov ax, [frame + TFR_FLAGS]
        and ax, FLAGS_NT_BIT | FLAGS_IF_BIT | 0x0001
        report "FLAGS after a write of NT and CF (513: IF and CF, no NT)"
        call resume_worker
        ; the refusals
        mov dx, MY_THREAD
        mov al, THREAD_SUSPEND
        xor si, si
        kcall KCALL_THREAD
        status "suspend itself (2)"
        mov dx, W_THREAD
        mov bl, FRAME_READ
        call frame_call
        status "a frame of a thread not suspended (6)"
        mov dx, W_THREAD
        mov al, THREAD_SUSPEND
        xor si, si
        kcall KCALL_THREAD
        must
        mov dx, W_THREAD
        mov al, THREAD_SUSPEND
        xor si, si
        kcall KCALL_THREAD
        status "suspend it twice (6)"
        mov cx, 2
        call sleep                      ; it stops at its way back
        mov dx, W_THREAD
        mov bl, FRAME_READ
        mov si, MY_DATA
        mov di, 0xFFF0                  ; past its data segment
        mov al, THREAD_FRAME
        kcall KCALL_THREAD
        status "a frame into bytes past the segment (1)"
        call resume_worker
        ; a worker inside KCALL_LOG, suspended and resumed again and again
        mov ax, ROLE_LOG
        call make_worker
        mov cx, DELIVERIES
.again:
        push cx
        mov cx, 1
        call sleep
        call suspend_worker
        call resume_worker
        pop cx
        loop .again
        mov cx, 5
        call sleep
        mov ax, W_WRONG
        call worker_word
        report "KCALL_LOG results the suspends spoilt (0)"
        call suspend_worker             ; the log's turn is free while it stops
        call ticks
        push ax
        PRINT "additions: the log is free", CHAR_LF
        call ticks
        pop bx
        sub ax, bx
        cmp ax, 5
        setb_ax
        report "the line took under 5 ticks (1)"
        call resume_worker
        call call_wait
        call revoke_windows
        call fault_wait
        jmp done

; ----------------------------------------------------------------------------
; call_wait - a worker suspended while its call waits for our reply: it
; stops only once the reply has come, which is then in its frame
;   In:       nothing
;   Out:      lines
;   Destroys: everything but DS
; ----------------------------------------------------------------------------
call_wait:
        mov ax, ROLE_CALL
        call make_worker
        mov cx, 2
        call sleep                      ; its call waits on S_EP
        mov dx, W_THREAD
        mov al, THREAD_SUSPEND
        mov si, NTF_STOP
        kcall KCALL_THREAD
        must
        mov cx, 2
        call sleep
        mov dx, NTF_STOP
        kcall KCALL_POLL
        cmp al, KE_EMPTY
        setnz_ax
        report "suspended in its call: stopped before the reply (0)"
        mov dx, S_EP
        xor bp, bp
        kcall KCALL_RECV                ; its call
        must
        mov si, S_REPLY
        kcall KCALL_SAVE_REPLY
        must
        mov dx, S_REPLY
        mov bx, 0x4242
        kcall KCALL_SEND
        must
        mov dx, NTF_STOP
        kcall KCALL_RECV                ; stopped, with the reply
        mov bl, FRAME_READ
        call worker_frame
        must
        mov ax, [frame + TFR_BX]
        report "its reply in its frame (16962)"
        mov ax, [frame + TFR_FLAGS]
        and ax, 1
        or ax, [frame + TFR_AX]
        report "and its status (0)"
        jmp resume_worker

; ----------------------------------------------------------------------------
; revoke_windows - a worker that copies an endpoint into 40 slots and
; revokes it, again and again, suspended and resumed: a suspend that comes
; in a revoke's window stops it once the revoke has ended, every copy gone
;   In:       nothing
;   Out:      lines
;   Destroys: everything but DS
; ----------------------------------------------------------------------------
revoke_windows:
        mov dx, UT_ARENA
        mov al, CAP_SPACE
        mov si, X_HOLD
        mov cx, 64
        kcall KCALL_RETYPE
        must
        mov ax, ROLE_REVOKE
        call make_worker
        mov word [inside], 0
        mov cx, DELIVERIES
.again:
        push cx
        mov cx, 1
        call sleep
        call suspend_worker
        mov bl, FRAME_READ
        call worker_frame
        must
        cmp word [frame + TFR_IP], revoker.revoked
        jne .resume
        inc word [inside]
.resume:
        call resume_worker
        pop cx
        loop .again
        mov cx, 5
        call sleep
        mov ax, W_WRONG
        call worker_word
        report "revokes and copies the suspends spoilt (0)"
        cmp word [inside], 0
        setnz_ax
        report "suspends that came in a revoke (1)"
        call worker_count
        test ax, ax
        setnz_ax
        report "the worker revoked (1)"
        ret

; ----------------------------------------------------------------------------
; fault_wait - a worker that faults, its fault's call received; suspended
; meanwhile, it stops at once, its registers as at the fault; resumed in a
; handler that never returns; the fault's reply then finds nobody
;   In:       nothing
;   Out:      lines
;   Destroys: everything but DS
; ----------------------------------------------------------------------------
fault_wait:
        mov dx, UT_ARENA
        mov al, CAP_ENDPOINT
        mov si, S_EPF
        kcall KCALL_RETYPE
        must
        mov ax, ROLE_FAULT
        call make_worker
        mov dx, S_EPF
        xor bp, bp
        kcall KCALL_RECV                ; its fault, as a call
        must
        push si
        xor ah, ah
        report "its fault's call: the vector (13)"
        pop ax
        cmp ax, faulter.fault
        setnz_ax
        report "and the IP, the HLT's (0)"
        mov dx, W_THREAD
        mov al, THREAD_SUSPEND
        mov si, NTF_STOP
        kcall KCALL_THREAD
        must
        mov dx, NTF_STOP
        kcall KCALL_RECV                ; it stops at once
        mov bl, FRAME_READ
        call worker_frame
        must
        mov si, frame + TFR_DI          ; DI SI BP SP BX DX CX AX: the fault's
        mov ax, 0x6666
        mov cx, 7
        xor dx, dx
.register:
        cmp si, frame + TFR_SP_POPA
        jne .compare
        add si, 2                       ; (SP: not set)
.compare:
        cmp ax, [si]
        je .same
        inc dx
.same:
        add si, 2
        sub ax, 0x1111
        loop .register
        mov ax, dx
        report "its registers not as at the fault (0)"
        mov ax, [frame + TFR_IP]
        cmp ax, faulter.fault
        setnz_ax
        report "its IP not the HLT's (0)"
        mov word [frame + TFR_IP], fault_handler
        mov bl, FRAME_WRITE
        call worker_frame
        must
        call resume_worker
        mov cx, 3
        call sleep
        mov ax, W_SIGNALS
        call worker_word
        report "its handler ran (1)"
        call worker_count
        push ax
        mov cx, 3
        call sleep
        call worker_count
        pop bx
        sub ax, bx
        setnz_ax
        report "and never returned: it counts (1)"
        mov si, S_REPLY
        kcall KCALL_SAVE_REPLY
        must
        mov dx, S_REPLY
        xor bx, bx
        kcall KCALL_SEND
        status "the fault's reply, after the suspend (6)"
        ret


; ----------------------------------------------------------------------------
; make_worker - a worker of a role in a space of its own, at priority 2:
; counting (1) or logging (2)
;   In:       AX = the role
;   Out:      nothing (the end on a failure)
;   Destroys: AX, BX, CX, DX, SI, DI, ES
; ----------------------------------------------------------------------------
make_worker:
        mov [role], ax
        push ax
        mov dx, W_SPACE                 ; a former worker's, gone first
        kcall KCALL_DELETE
        mov dx, W_THREAD
        kcall KCALL_DELETE
        mov dx, W_STACK_MINE
        kcall KCALL_DELETE
        mov dx, W_DATA_MINE
        kcall KCALL_DELETE
        mov bx, W_SPACE
        mov dx, W_THREAD
        mov si, MY_CODE
        call worker_space
        mov cx, W_DATA_MINE
        mov es, cx
        pop ax
        mov [es:W_ROLE], ax
        push ds
        pop es
        mov dx, W_SPACE                 ; the endpoint, and X_HOLD's space
        mov si, S_EP
        mov di, WK_EP
        mov al, COPY_COPY
        kcall KCALL_COPY
        must
        cmp word [role], ROLE_REVOKE
        jne .configure
        mov dx, W_SPACE
        mov si, X_HOLD
        mov di, WK_X
        mov al, COPY_COPY
        kcall KCALL_COPY
        must
.configure:
        mov dx, W_THREAD
        mov si, W_SPACE
        mov bx, worker
        mov cx, W_SIZE
        mov al, THREAD_CONFIGURE
        kcall KCALL_THREAD
        must
        cmp word [role], ROLE_FAULT
        jne .start
        mov dx, W_THREAD                ; its faults: calls on S_EPF
        mov si, S_EPF
        mov al, THREAD_FAULT
        kcall KCALL_THREAD
        must
.start:
        mov dx, W_THREAD
        mov cl, 2
        call start_thread
        ret

; ----------------------------------------------------------------------------
; worker_space - a space of 16 slots and a thread: code (a copy of a slot of
; ours), data and stack (copies kept in W_DATA_MINE, W_STACK_MINE), a
; notification to wait on
;   In:       BX = the space's slot; DX = the thread's slot; SI = the code
;   Out:      nothing (the end on a failure)
;   Destroys: AX, CX, DI
; ----------------------------------------------------------------------------
worker_space:
        push si
        push dx
        push bx
        mov dx, UT_ARENA
        mov al, CAP_SPACE
        mov si, bx
        mov cx, 16
        kcall KCALL_RETYPE
        must
        pop bx
        pop si                          ; the thread's slot
        push bx
        mov al, CAP_THREAD
        kcall KCALL_RETYPE
        must
        pop bx
        pop si                          ; the code
        mov dx, bx
        mov di, WK_CODE
        mov al, COPY_COPY
        cmp si, SCRATCH                 ; a sealed segment is moved, not copied
        jne .copy
        mov al, COPY_MOVE
.copy:
        kcall KCALL_COPY
        must
        mov si, W_DATA_MINE
        mov di, WK_DATA
        call worker_segment
        mov si, W_STACK_MINE
        mov di, WK_STACK
        call worker_segment
        push bx
        mov dx, UT_ARENA
        mov al, CAP_NOTIFY
        mov si, SCRATCH
        kcall KCALL_RETYPE
        must
        pop dx
        push dx
        mov si, SCRATCH
        mov di, WK_NTF
        mov al, COPY_MOVE
        kcall KCALL_COPY
        must
        pop bx
        ret

; ----------------------------------------------------------------------------
; worker_segment - W_SIZE bytes of data into one of our slots (deleted
; first), and a copy into the worker's space
;   In:       BX = the space's slot; SI = our slot; DI = the worker's slot
;   Out:      nothing (the end on a failure)
;   Destroys: AX, CX, DX
; ----------------------------------------------------------------------------
worker_segment:
        push bx
        push di
        push si
        mov dx, si
        kcall KCALL_DELETE
        pop si
        push si
        mov dx, UT_MEMORY
        mov al, CAP_SEGMENT
        mov cx, W_SIZE
        mov bl, 0xF2
        kcall KCALL_RETYPE
        must
        pop si
        pop di
        pop dx
        push dx
        mov al, COPY_COPY
        kcall KCALL_COPY
        must
        pop bx
        ret

; ----------------------------------------------------------------------------
; start_thread - a thread started at a priority
;   In:       DX = the thread; CL = the priority
;   Out:      nothing (the end on a failure)
;   Destroys: AX, CX
; ----------------------------------------------------------------------------
start_thread:
        xor ch, ch
        mov al, THREAD_START
        kcall KCALL_THREAD
        must
        ret

; ----------------------------------------------------------------------------
; worker_count - the worker's count, from our copy of its data
;   In:       nothing
;   Out:      AX = the count's low word
;   Destroys: nothing
; ----------------------------------------------------------------------------
worker_count:
        mov ax, W_COUNT
        ; falls through

; ----------------------------------------------------------------------------
; worker_word - a word of the worker's data
;   In:       AX = its offset
;   Out:      AX = the word
;   Destroys: nothing
; ----------------------------------------------------------------------------
worker_word:
        push es
        push bx
        mov bx, ax
        mov ax, W_DATA_MINE
        mov es, ax
        mov ax, [es:bx]
        pop bx
        pop es
        ret

; ----------------------------------------------------------------------------
; suspend_worker - the worker suspended, waited for until it has stopped
;   In:       nothing
;   Out:      nothing (the end on a failure)
;   Destroys: AX, BX, DX, SI
; ----------------------------------------------------------------------------
suspend_worker:
        mov dx, W_THREAD
        mov al, THREAD_SUSPEND
        mov si, NTF_STOP
        kcall KCALL_THREAD
        must
        mov dx, NTF_STOP
        kcall KCALL_RECV                ; it has stopped
        ret

; ----------------------------------------------------------------------------
; resume_worker - the suspended worker resumed, at priority 2
;   In:       nothing
;   Out:      nothing (the end on a failure)
;   Destroys: AX, CX, DX
; ----------------------------------------------------------------------------
resume_worker:
        mov dx, W_THREAD
        mov cl, 2
        jmp start_thread

; ----------------------------------------------------------------------------
; frame_call - THREAD_FRAME of the worker, our `frame` the bytes
;   In:       DX = the thread; BL = FRAME_READ or FRAME_WRITE
;   Out:      CF and AL the status
;   Destroys: AH, SI, DI
; ----------------------------------------------------------------------------
frame_call:
        mov si, MY_DATA
        mov di, frame
        mov al, THREAD_FRAME
        kcall KCALL_THREAD
        ret

; ----------------------------------------------------------------------------
; worker_frame - THREAD_FRAME of the worker
;   In:       BL = FRAME_READ or FRAME_WRITE
;   Out:      CF and AL the status
;   Destroys: AH, DX, SI, DI
; ----------------------------------------------------------------------------
worker_frame:
        mov dx, W_THREAD
        jmp frame_call

; ----------------------------------------------------------------------------
; deliver - a signal: the worker suspended, a frame of its registers pushed
; on its stack, its IP the handler's, resumed
;   In:       nothing
;   Out:      nothing (the end on a failure)
;   Destroys: AX, BX, CX, DX, SI, DI, ES
; ----------------------------------------------------------------------------
deliver:
        call suspend_worker
        mov bl, FRAME_READ
        call worker_frame
        must
        mov si, frame                   ; the frame the handler pops: ES, DS,
        mov di, signal_frame            ; PUSHA's eight words, IP, CS, FLAGS
        push ds
        pop es
        mov cx, 10
        rep movsw
        mov ax, [frame + TFR_IP]
        stosw
        mov ax, [frame + TFR_CS]
        stosw
        mov ax, [frame + TFR_FLAGS]
        stosw
        mov di, [frame + TFR_SP]
        sub di, SIGFRAME
        mov [frame + TFR_SP], di
        mov word [frame + TFR_IP], handler
        mov ax, W_STACK_MINE
        mov es, ax
        mov si, signal_frame
        mov cx, SIGFRAME / 2
        rep movsw
        push ds
        pop es
        mov bl, FRAME_WRITE
        call worker_frame
        must
        jmp resume_worker

; ----------------------------------------------------------------------------
; ticks - the ticks since the start's low word
;   In:       nothing
;   Out:      AX = the ticks
;   Destroys: DX
; ----------------------------------------------------------------------------
ticks:
        kcall KCALL_TICKS
        ret

; ----------------------------------------------------------------------------
; sleep - CX ticks, on the kernel's timer
;   In:       CX = the ticks
;   Out:      nothing
;   Destroys: AX, BX, DX
; ----------------------------------------------------------------------------
sleep:
        mov dx, NTF_SLEEP
        kcall KCALL_TIMER
        must
        mov dx, NTF_SLEEP
        kcall KCALL_RECV
        ret

; ============================================================================ the worker
; ----------------------------------------------------------------------------
; worker - a thread of this program's code in a space of its own: counts for
; ever (role 1), or writes a line with KCALL_LOG for ever and counts the
; results that are not its line's length (role 2)
;   In:       its start: DS = ES = its data
;   Out:      does not return
;   Destroys: everything
; ----------------------------------------------------------------------------
worker:
        mov ax, [W_ROLE]
        cmp ax, ROLE_LOG
        je logger
        cmp ax, ROLE_CALL
        je caller
        cmp ax, ROLE_REVOKE
        je revoker
        cmp ax, ROLE_FAULT
        je faulter
.count:
        inc word [W_COUNT]
        jmp .count

; ----------------------------------------------------------------------------
; logger - the logging worker's loop
;   In:       DS = ES = its data
;   Out:      does not return
;   Destroys: everything
; ----------------------------------------------------------------------------
logger:
        mov di, W_LINE
        push cs
        pop ds
        mov si, log_line
        mov cx, W_LINE_SIZE
        rep movsb
        push es
        pop ds
.line:
        mov si, W_LINE
        mov cx, W_LINE_SIZE
        kcall KCALL_LOG
        cmp ax, W_LINE_SIZE
        je .line
        inc word [W_WRONG]
        jmp .line

log_line            db "worker: ", CHAR_LF

; ----------------------------------------------------------------------------
; caller - the calling worker's loop: a call on S_EP, its reply kept
;   In:       DS = ES = its data
;   Out:      does not return
;   Destroys: everything
; ----------------------------------------------------------------------------
caller:
        mov dx, WK_EP
        xor bp, bp
        mov al, 1
        kcall KCALL_CALL
        mov [W_REPLY], bx
        jmp caller

; ----------------------------------------------------------------------------
; revoker - the revoking worker's loop: S_EP copied into X_HOLD's first 40
; slots, then revoked (a window after each copy it deletes); a copy or a
; revoke that fails, wrong
;   In:       DS = ES = its data
;   Out:      does not return
;   Destroys: everything
; ----------------------------------------------------------------------------
revoker:
        mov di, 0x07
        mov cx, REVOKE_COPIES
.copy:
        push cx
        push di
        mov dx, WK_X
        mov si, WK_EP
        mov al, COPY_COPY
        kcall KCALL_COPY
        pop di
        pop cx
        jc .wrong
        add di, 8
        loop .copy
        mov dx, WK_EP
        kcall KCALL_REVOKE
.revoked:
        jc .wrong
        inc word [W_COUNT]
        jmp revoker
.wrong:
        inc word [W_WRONG]
        mov dx, WK_EP
        kcall KCALL_REVOKE
        jmp revoker

; ----------------------------------------------------------------------------
; faulter - the faulting worker: known registers, then a HLT, a #GP at ring 3
;   In:       DS = ES = its data
;   Out:      does not return
;   Destroys: everything
; ----------------------------------------------------------------------------
faulter:
        xor ax, ax
        mov cx, 0x1111
        mov dx, 0x2222
        mov bx, 0x3333
        mov bp, 0x4444
        mov si, 0x5555
        mov di, 0x6666
.fault:
        hlt
        jmp .fault

; ----------------------------------------------------------------------------
; fault_handler - the faulting worker's handler, which never returns: it
; counts the signal and goes to the count's loop
;   In:       DS = its data
;   Out:      does not return
;   Destroys: everything
; ----------------------------------------------------------------------------
fault_handler:
        inc word [W_SIGNALS]
        jmp worker.count

; ----------------------------------------------------------------------------
; handler - the worker's signal handler: counts, and returns through the
; frame its signaller pushed, by IRET at ring 3
;   In:       SS:SP the frame; DS = its data
;   Out:      the registers and the place of the frame
;   Destroys: nothing
; ----------------------------------------------------------------------------
handler:
        inc word [W_SIGNALS]
        pop es
        pop ds
        popa
        iret

; ============================================================================ the pools
; ----------------------------------------------------------------------------
; pools_part - 24 threads made, more than the old pools left room for (pools
; of 64), or until a retype is refused: KE_MEM, the arena full, not KE_POOL;
; revoked, and 40 spaces made in their room; then a 64 KB segment, zeroed in
; pieces
;   In:       nothing
;   Out:      does not return
;   Destroys: everything
; ----------------------------------------------------------------------------
pools_part:
        mov dx, UT_ARENA                ; (not UT_ARENA itself: everything the
        mov al, CAP_UNTYPED             ; root made is below it)
        mov si, UT_POOLS
        mov cx, POOLS_BYTES >> 4
        kcall KCALL_RETYPE
        must
        mov word [threads], 0
        mov si, THREAD_FIRST
.thread:
        cmp si, THREAD_FIRST + THREADS * 8
        jae .counted
        push si
        mov dx, UT_POOLS
        mov al, CAP_THREAD
        kcall KCALL_RETYPE
        pop si
        jc .refused
        inc word [threads]
        add si, 8
        jmp .thread
.refused:
        push ax
        mov ax, [threads]
        report "threads made, more than the old pool's 24 less those in use"
        pop ax
        status "then the retype said (3: KE_MEM, the arena full)"
        jmp .spaces
.counted:
        mov ax, [threads]
        report "threads made, all 24 (the old pool held 24 in all)"
.spaces:
        mov dx, UT_POOLS                ; its memory back: every thread gone
        kcall KCALL_REVOKE
        status "the threads revoked (0)"
        call many_spaces
.big:
        mov dx, UT_MEMORY
        mov al, CAP_SEGMENT
        mov si, BIG
        mov cx, 0xFFFF
        mov bl, 0xF2
        kcall KCALL_RETYPE
        status "a 64 KB segment retyped (0)"
        mov ax, BIG
        mov es, ax
        mov ax, [es:0xFFFC]             ; (its limit is FFFEh)
        or ax, [es:0x8000]
        push ds
        pop es
        report "zeroed (0)"
        jmp done

; ----------------------------------------------------------------------------
; many_spaces - 40 spaces more, each with a copy of an endpoint, moved into
; a space that holds them all; the endpoint revoked, then that space deleted
; (and with it all 40)
;   In:       nothing
;   Out:      lines
;   Destroys: everything but DS
; ----------------------------------------------------------------------------
many_spaces:
        mov dx, UT_POOLS
        mov al, CAP_SPACE
        mov si, HOLDER
        mov cx, 64
        kcall KCALL_RETYPE
        must
        mov dx, UT_POOLS
        mov al, CAP_ENDPOINT
        mov si, S_EP
        kcall KCALL_RETYPE
        must
        mov di, 0x07                    ; HOLDER's slot 0 on
        mov cx, SPACES
.space:
        push cx
        push di
        mov dx, UT_POOLS
        mov al, CAP_SPACE
        mov si, SMALL
        mov cx, 8
        kcall KCALL_RETYPE
        must
        mov dx, SMALL
        mov si, S_EP
        mov di, 0x07
        mov al, COPY_COPY
        kcall KCALL_COPY
        must
        pop di
        push di
        mov dx, HOLDER
        mov si, SMALL
        mov al, COPY_MOVE
        kcall KCALL_COPY
        must
        pop di
        pop cx
        add di, 8
        loop .space
        mov ax, SPACES
        report "spaces made (40)"
        mov dx, S_EP
        kcall KCALL_REVOKE
        status "their copies of an endpoint revoked (0)"
        mov dx, HOLDER
        kcall KCALL_DELETE
        status "the space that holds them deleted (0)"
        ret

%include "uprint.asm"
%include "format.asm"
