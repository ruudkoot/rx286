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
;   TEST_ADD_RESUME   kernel calls that give way at every window (TEST_GIVE_WAY)
;                     and resume (os-server.md P3): a line of the log, a
;                     64 KB retype over memory that was written, a revoke, a
;                     delete that empties a space
;   TEST_ADD_POOLS    128 threads and 64 spaces more, objects of the memory for
;                     segments (os-server.md P3), the spaces holding copies
;                     that a revoke deletes, then all revoked; a 64 KB
;                     segment retyped, its zeroing in pieces (TEST_STRETCH
;                     measures them: no delete looks through every slot, D9)
;   TEST_ADD_SIBLINGS a list of 3,072 siblings: an endpoint copied into
;                     every slot of twelve spaces of 256, six of them
;                     deleted (each delete unlinks one copy), then the
;                     endpoint (the other 1,536 adopted at once);
;                     TEST_STRETCH measures: no stretch grows with the list
;                     (os-server.md P15)
;   TEST_ADD_RINGS    the children's rings (os-server.md P15): copies of a
;                     segment deleted and moved in every place of a ring -
;                     first, among others, alone, with children - then
;                     revoked: each revoke takes exactly what derives from
;                     it; a segment that is not the first of its untyped's
;                     ring sealed (its parent found back along the ring)
;   TEST_ADD_RESIZE   KCALL_RESIZE (os-server.md P15): a segment made longer
;                     in place over memory a revoke left written, its copy
;                     with it, its bytes kept and the new ones zeroed in
;                     pieces; shorter, its end retyped next; every refusal;
;                     at last a read past a shorter end through ES, loaded
;                     before the call: #GP
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
S_EPF               equ 0xF7            ; 30: the worker's fault endpoint
S_REPLY             equ 0xFF            ; 31: a reply saved
X_HOLD              equ 0x107           ; 32: a space of 64 slots, the revoker's
HOLDER              equ 0x10F           ; 33: the pools' space that holds 64 spaces
SMALL               equ 0x117           ; 34: each of them, before it moves there
UT_POOLS            equ 0x11F           ; 35: the pools' memory, from UT_MEMORY
T_HOLDER            equ 0x12F           ; 37: the space that holds 128 threads
POOLS_BYTES         equ 0xF000            ; 60 KB: 128 threads, 66 spaces, an endpoint
THREADS             equ 128
SPACES              equ 64
UT_SEG              equ 0x127           ; 36: TEST_ADD_RESUME's memory for a segment
COPY_FIRST          equ 0x14F           ; 41 on: copies of S_EP
COPIES              equ 10
GIVE_WAY            equ 1000

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
line                times 64 db 0
role                dw 0
inside              dw 0
rz_base             dw 0, 0             ; resize_part's segment's base
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
%elifdef TEST_ADD_RESUME
        jmp resume_part
%elifdef TEST_RV_FRAME
        jmp rv_frame_part
%elifdef TEST_RV_RETYPE
        jmp rv_retype_part
%elifdef TEST_RV_DEAD
        jmp rv_dead_part
%elifdef TEST_RV_SPACES
        jmp rv_spaces_part
%elifdef TEST_RV_MISC
        jmp rv_misc_part
%elifdef TEST_RV_FLUSH
        jmp rv_flush_part
%elifdef TEST_RV_LEAK
        jmp rv_leak_part
%elifdef TEST_ADD_SIBLINGS
        jmp siblings_part
%elifdef TEST_ADD_RESIZE
        jmp resize_part
%elifdef TEST_ADD_RINGS
        jmp rings_part
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
        call read_key
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
.write_f: mov byte [es:0], 0x90
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

; ============================================================================ resumed calls
; ----------------------------------------------------------------------------
; resume_part - every interrupt window of the kernel's gives way
; (TEST_GIVE_WAY), and each call resumes where it was: a line of the log
; whole, a 64 KB segment zeroed over memory that held a pattern, a revoke of
; ten copies, a delete that empties a space of them
;   In:       nothing
;   Out:      does not return
;   Destroys: everything
; ----------------------------------------------------------------------------
resume_part:
        mov dx, UT_ARENA
        mov al, CAP_ENDPOINT
        mov si, S_EP
        kcall KCALL_RETYPE
        must
        ; the log: a window after each byte
        push ds
        pop es
        mov di, line
        mov si, resume_line
        mov cx, resume_line_end - resume_line
        cs rep movsb
        call give_way
        mov si, line
        mov cx, resume_line_end - resume_line
        kcall KCALL_LOG
        push ax
        call no_give_way
        call gave_way
        pop ax
        report "its bytes (40)"
        ; a 64 KB segment, written, its memory given back, retyped again
        mov dx, UT_MEMORY
        mov al, CAP_UNTYPED
        mov si, UT_SEG
        mov cx, 0x1000
        kcall KCALL_RETYPE
        must
        call big_segment
        must
        mov ax, BIG
        mov es, ax
        mov word [es:0], 0x5A5A
        mov word [es:0x8000], 0x5A5A
        mov word [es:0xFFFC], 0x5A5A
        push ds
        pop es
        mov dx, UT_SEG
        kcall KCALL_REVOKE
        must
        call give_way
        call big_segment
        push ax
        call no_give_way
        call gave_way
        pop ax
        status "a 64 KB retype, giving way (0)"
        mov ax, BIG
        mov es, ax
        mov ax, [es:0]
        or ax, [es:0x8000]
        or ax, [es:0xFFFC]
        push ds
        pop es
        report "the pattern left in it (0)"
        ; a revoke of ten copies
        call ten_copies
        call give_way
        mov dx, S_EP
        kcall KCALL_REVOKE
        push ax
        call no_give_way
        call gave_way
        pop ax
        status "a revoke of ten copies, giving way (0)"
        call ten_copies                 ; their slots empty again?
        status "the copies' slots empty after it (0)"
        mov dx, S_EP
        kcall KCALL_REVOKE
        must
        ; a delete that empties a space holding copies
        mov dx, UT_ARENA
        mov al, CAP_SPACE
        mov si, HOLDER
        mov cx, 16
        kcall KCALL_RETYPE
        must
        mov di, 0x07
        mov cx, 8
.hold:
        push cx
        push di
        mov dx, HOLDER
        mov si, S_EP
        mov al, COPY_COPY
        kcall KCALL_COPY
        pop di
        pop cx
        must
        add di, 8
        loop .hold
        call give_way
        mov dx, HOLDER
        kcall KCALL_DELETE
        push ax
        call no_give_way
        call gave_way
        pop ax
        status "a delete that empties a space, giving way (0)"
        mov dx, HOLDER
        mov al, THREAD_INFO
        kcall KCALL_THREAD              ; (any call on it: its slot is empty)
        status "its slot empty (1)"
        jmp done

resume_line         db "additions: a line written a byte a turn", CHAR_LF
resume_line_end     equ $

; ----------------------------------------------------------------------------
; give_way - every interrupt window of the kernel's gives way from now on
;   In:       nothing
;   Out:      nothing (the end on a failure)
;   Destroys: AX, CX
; ----------------------------------------------------------------------------
give_way:
        mov cx, GIVE_WAY
        jmp give_way_set

; ----------------------------------------------------------------------------
; no_give_way - the windows give way only to a more urgent thread again
;   In:       nothing
;   Out:      nothing (the end on a failure)
;   Destroys: AX, CX
; ----------------------------------------------------------------------------
no_give_way:
        xor cx, cx
        ; falls through

; ----------------------------------------------------------------------------
; give_way_set - TEST_GIVE_WAY: the next CX windows give way
;   In:       CX = the windows
;   Out:      CX = the windows that were still to
;   Destroys: AX
; ----------------------------------------------------------------------------
give_way_set:
        mov al, TEST_GIVE_WAY
        kcall KCALL_TEST
        must
        ret

; ----------------------------------------------------------------------------
; gave_way - "gave way (1)" if a window gave way since give_way
;   In:       CX = the windows that were still to (no_give_way's)
;   Out:      a line
;   Destroys: AX
; ----------------------------------------------------------------------------
gave_way:
        cmp cx, GIVE_WAY
        setnz_ax
        report "the call gave way (1)"
        ret

; ----------------------------------------------------------------------------
; big_segment - a 64 KB segment in BIG, from UT_SEG
;   In:       nothing
;   Out:      CF and AL: the retype's status
;   Destroys: AX, BX, CX, DX, SI
; ----------------------------------------------------------------------------
big_segment:
        mov dx, UT_SEG
        mov al, CAP_SEGMENT
        mov si, BIG
        mov cx, 0xFFFF
        mov bl, 0xF2
        kcall KCALL_RETYPE
        ret

; ----------------------------------------------------------------------------
; ten_copies - S_EP copied into slots 41-50 of the program's own space
;   In:       nothing
;   Out:      CF and AL: the first copy's status that was not KE_OK
;   Destroys: AX, CX, DX, SI, DI
; ----------------------------------------------------------------------------
ten_copies:
        mov di, COPY_FIRST
        mov cx, COPIES
.copy:
        push cx
        push di
        mov dx, MY_SPACE
        mov si, S_EP
        mov al, COPY_COPY
        kcall KCALL_COPY
        pop di
        pop cx
        jc .done
        add di, 8
        loop .copy
.done:
        ret

; ============================================================================ the pools
; ----------------------------------------------------------------------------
; pools_part - 128 threads and 64 spaces made of the memory for segments
; (os-server.md P3), all revoked at once; then a 64 KB segment, zeroed in
; pieces
;   In:       nothing
;   Out:      does not return
;   Destroys: everything
; ----------------------------------------------------------------------------
pools_part:
        mov dx, UT_MEMORY               ; any untyped makes objects (P3); not
        mov al, CAP_UNTYPED             ; UT_MEMORY itself: everything the root
        mov si, UT_POOLS                ; made is below it
        mov cx, POOLS_BYTES >> 4
        kcall KCALL_RETYPE
        must
        mov dx, UT_POOLS
        mov al, CAP_SPACE
        mov si, T_HOLDER
        mov cx, THREADS
        kcall KCALL_RETYPE
        must
        mov word [threads], 0
        mov di, 0x07                    ; T_HOLDER's slot 0 on
.thread:
        cmp word [threads], THREADS
        jae .counted
        push di
        mov dx, UT_POOLS
        mov al, CAP_THREAD
        mov si, SMALL
        kcall KCALL_RETYPE
        pop di
        jc .refused
        push di
        mov dx, T_HOLDER
        mov si, SMALL
        mov al, COPY_MOVE
        kcall KCALL_COPY
        pop di
        must
        inc word [threads]
        add di, 8
        jmp .thread
.refused:
        push ax
        mov ax, [threads]
        report "threads made, before a refusal"
        pop ax
        status "then the retype said"
        jmp .spaces
.counted:
        mov ax, [threads]
        report "threads made (128)"
.spaces:
        call many_spaces
        mov dx, UT_POOLS                ; its memory back: every one of them gone
        kcall KCALL_REVOKE
        status "all of them revoked (0)"
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

SIB_SPACES          equ 12          ; TEST_ADD_SIBLINGS' spaces of 256 slots

; ----------------------------------------------------------------------------
; siblings_part - TEST_ADD_SIBLINGS: an endpoint's 3,072 copies, in twelve
; spaces of 256 slots; six of the spaces deleted, each slot's delete one
; copy out of the long list; then the endpoint, its other 1,536 copies
; adopted at once (os-server.md P15)
;   In:       the program's start
;   Out:      does not return (done)
;   Destroys: everything
; ----------------------------------------------------------------------------
siblings_part:
        mov dx, UT_MEMORY
        mov al, CAP_UNTYPED
        mov si, UT_POOLS
        mov cx, (SIB_SPACES * (16 + 32 * 256) + 64) >> 4
        kcall KCALL_RETYPE
        must
        mov dx, UT_POOLS
        mov al, CAP_ENDPOINT
        mov si, S_EP
        kcall KCALL_RETYPE
        must
        call sibling_copies
        report "copies made (3072)"
        mov si, sib_slots
        mov cx, SIB_SPACES / 2
.delete:
        push cx
        push si
        mov dx, [si]
        kcall KCALL_DELETE              ; each slot's delete unlinks a copy
        pop si
        pop cx
        add si, 2
        loop .delete
        mov ax, 0
        report "half the spaces deleted with them (0)"
        mov dx, S_EP
        kcall KCALL_DELETE              ; its other 1,536 copies adopted at once
        status "the endpoint deleted (0)"
        jmp done

; ----------------------------------------------------------------------------
; sibling_copies - SIB_SPACES spaces of 256 slots, each slot a copy of S_EP
;   In:       nothing
;   Out:      AX = the copies made
;   Destroys: everything but DS
; ----------------------------------------------------------------------------
sibling_copies:
        mov word [made], 0
        mov si, sib_slots
        mov cx, SIB_SPACES
.space:
        push cx
        push si
        mov dx, UT_POOLS
        mov al, CAP_SPACE
        mov si, [si]
        mov cx, 256
        kcall KCALL_RETYPE
        must
        pop si
        push si
        mov bx, [si]
        mov di, 0x07                    ; its slot 0 on
        mov cx, 256
.copy:
        push cx
        push di
        push bx
        mov dx, bx
        mov si, S_EP
        mov al, COPY_COPY
        kcall KCALL_COPY
        must
        inc word [made]
        pop bx
        pop di
        pop cx
        add di, 8
        loop .copy
        pop si
        pop cx
        add si, 2
        loop .space
        mov ax, [made]
        ret

; ----------------------------------------------------------------------------
; many_spaces - 64 spaces more, each with a copy of an endpoint, moved into
; a space that holds them all; the endpoint revoked
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
        report "spaces made (64)"
        mov dx, S_EP
        kcall KCALL_REVOKE
        status "their copies of an endpoint revoked (0)"
        ret

; ============================================================================ the resize
RZ_UNTYPED_PARAS    equ 0x200           ; 8 KB of untyped
RZ_FIRST            equ 1000            ; the segment's bytes at first
RZ_GROWN            equ 8000            ;    made longer: zeroed in four pieces
RZ_SHORT            equ 100             ;    and shorter
ACC_DATA3           equ 0xF2            ; present, DPL 3, data, writable

; ----------------------------------------------------------------------------
; resize_part - KCALL_RESIZE: longer in place, its copy too, the new bytes
; zeroed; every refusal; shorter, its end given back; then a read past a
; shorter end through ES, which was loaded before the call: #GP
;   In:       nothing
;   Out:      does not return
;   Destroys: everything
; ----------------------------------------------------------------------------
resize_part:
        mov dx, UT_MEMORY
        mov al, CAP_UNTYPED
        mov si, UT_SEG
        mov cx, RZ_UNTYPED_PARAS
        kcall KCALL_RETYPE
        must
        call rz_dirty
        call rz_first
        mov dx, S_SEG
        mov cx, RZ_GROWN
        kcall KCALL_RESIZE
        status "make it 8,000 bytes (0)"
        mov ax, S_COPY
        lsl ax, ax
        report "its copy's limit (7999)"
        mov dx, S_SEG
        kcall KCALL_SEGMENT
        xor bx, bx
        cmp ax, [rz_base]
        jne .moved
        cmp dx, [rz_base + 2]
        jne .moved
        inc bx
.moved:
        mov ax, bx
        report "its base kept (1)"
        mov ax, S_COPY
        mov es, ax
        mov ax, [es:RZ_FIRST - 2]
        report "the word at its old end, through the copy (4660)"
        mov ax, S_COPY
        mov es, ax
        xor ax, ax
        mov si, RZ_FIRST
.new:
        or ax, [es:si]
        add si, 2
        cmp si, RZ_GROWN
        jb .new
        report "its new bytes, ORed (0)"
        mov dx, S_COPY
        mov cx, 2000
        kcall KCALL_RESIZE
        status "resize the copy (6)"
        mov dx, S_SEG
        mov cx, RZ_UNTYPED_PARAS * 16 + 16
        kcall KCALL_RESIZE
        status "past its untyped (3)"
        mov dx, S_SEG
        xor cx, cx
        kcall KCALL_RESIZE
        status "to 0 bytes (2)"
        mov dx, MY_DATA
        mov cx, 2000
        kcall KCALL_RESIZE
        status "its own data, of the root's untyped (6)"
        mov dx, UT_SEG
        mov cx, 2000
        kcall KCALL_RESIZE
        status "an untyped (1)"
        mov si, S_SEG2
        call data64
        mov dx, S_SEG2
        kcall KCALL_SEAL
        must
        mov dx, S_SEG2
        mov cx, 128
        kcall KCALL_RESIZE
        status "sealed code (2)"
        mov dx, S_SEG
        mov cx, RZ_SHORT
        kcall KCALL_RESIZE
        status "make it 100 bytes (0)"
        mov ax, S_COPY
        lsl ax, ax
        report "its copy's limit (99)"
        mov dx, UT_SEG
        mov al, CAP_SEGMENT
        mov si, SCRATCH
        mov cx, 64
        mov bl, ACC_DATA3
        kcall KCALL_RETYPE
        must
        mov dx, SCRATCH
        kcall KCALL_SEGMENT
        sub ax, [rz_base]
        report "the next retype's base, from its (112: its end given back)"
        mov dx, S_SEG
        mov cx, RZ_FIRST
        kcall KCALL_RESIZE
        status "longer, with that carved after it (6)"
        mov dx, UT_SEG                  ; again, for the read through ES
        kcall KCALL_REVOKE
        must
        call rz_first
        PRINT "additions: a read past a shorter end, through ES loaded before", CHAR_LF
        mov ax, S_COPY
        mov es, ax
        mov dx, S_SEG
        mov cx, RZ_SHORT
        kcall KCALL_RESIZE
.read_f: mov al, [es:RZ_SHORT + 10]
        PRINT "additions: the read went through", CHAR_LF
        jmp done

; ----------------------------------------------------------------------------
; rz_dirty - UT_SEG's memory written all over: a segment over all of it,
; filled with FFh, then revoked
;   In:       nothing
;   Out:      nothing (the end on a failure)
;   Destroys: AX, BX, CX, DX, SI, DI, ES
; ----------------------------------------------------------------------------
rz_dirty:
        mov dx, UT_SEG
        mov al, CAP_SEGMENT
        mov si, S_SEG
        mov cx, RZ_UNTYPED_PARAS * 16
        mov bl, ACC_DATA3
        kcall KCALL_RETYPE
        must
        mov ax, S_SEG
        mov es, ax
        xor di, di
        mov cx, RZ_UNTYPED_PARAS * 8
        mov ax, 0xFFFF
        rep stosw
        push ds
        pop es
        mov dx, UT_SEG
        kcall KCALL_REVOKE
        must
        ret

; ----------------------------------------------------------------------------
; rz_first - S_SEG: RZ_FIRST bytes from UT_SEG, 4660 in its last word, its
; base in rz_base; a copy of it in S_COPY
;   In:       nothing
;   Out:      nothing (the end on a failure)
;   Destroys: AX, BX, CX, DX, SI, DI, ES
; ----------------------------------------------------------------------------
rz_first:
        mov dx, UT_SEG
        mov al, CAP_SEGMENT
        mov si, S_SEG
        mov cx, RZ_FIRST
        mov bl, ACC_DATA3
        kcall KCALL_RETYPE
        must
        mov ax, S_SEG
        mov es, ax
        mov word [es:RZ_FIRST - 2], 0x1234
        push ds
        pop es
        mov dx, MY_SPACE
        mov si, S_SEG
        mov di, S_COPY
        mov al, COPY_COPY
        kcall KCALL_COPY
        must
        mov dx, S_SEG
        kcall KCALL_SEGMENT
        mov [rz_base], ax
        mov [rz_base + 2], dx
        ret

; ============================================================================ the rings
RG_SLOT             equ 0x14F           ; 41 on: the ring's segments, RG(0) to RG(9)
%define RG(n) (RG_SLOT + (n) * 8)

; rg_copy from, to - a copy of a slot's segment into another of ours
%macro rg_copy 2
        mov dx, MY_SPACE
        mov si, %1
        mov di, %2
        mov al, COPY_COPY
        kcall KCALL_COPY
        must
%endmacro
; rg_move from, to - a slot's segment moved to another of ours
%macro rg_move 2
        mov dx, MY_SPACE
        mov si, %1
        mov di, %2
        mov al, COPY_MOVE
        kcall KCALL_COPY
        must
%endmacro
; rg_delete slot, rg_revoke slot
%macro rg_delete 1
        mov dx, %1
        kcall KCALL_DELETE
        must
%endmacro
%macro rg_revoke 1
        mov dx, %1
        kcall KCALL_REVOKE
        must
%endmacro

; ----------------------------------------------------------------------------
; rings_part - the rings of children: deletes and moves in every place of a
; ring, then revokes that must take what derives from each and no more; a
; segment that is not the first of its ring sealed
;   In:       nothing
;   Out:      does not return
;   Destroys: everything
; ----------------------------------------------------------------------------
rings_part:
        mov si, RG(0)                   ; D, and three copies: RG3 RG2 RG1
        call data64
        rg_copy RG(0), RG(1)
        rg_copy RG(0), RG(2)
        rg_copy RG(0), RG(3)
        rg_copy RG(2), RG(4)            ; two of RG2: RG5 RG4
        rg_copy RG(2), RG(5)
        rg_delete RG(2)                 ; among others, with children: RG3 RG5 RG4 RG1
        rg_copy RG(5), RG(6)            ; one of RG5
        rg_move RG(3), RG(7)            ; the first, childless: RG7 RG5 RG4 RG1
        rg_move RG(5), RG(8)            ; among others, with a child: RG7 RG8 RG4 RG1
        rg_revoke RG(8)                 ; its child alone
        mov ax, 1 << 6
        call rg_live
        report "a moved copy's child, revoked (0)"
        mov ax, (1 << 0) | (1 << 1) | (1 << 4) | (1 << 7) | (1 << 8)
        call rg_live
        report "the others kept (5)"
        rg_revoke RG(0)
        mov ax, 0x3FE
        call rg_live
        report "the segment revoked: its copies, each moved or spliced (0)"
        mov ax, 1
        call rg_live
        report "and it kept (1)"
        rg_copy RG(0), RG(1)            ; a ring of two: RG2 RG1
        rg_copy RG(0), RG(2)
        rg_delete RG(2)                 ; its first: RG1 alone, the first
        rg_move RG(1), RG(9)            ; alone: moved
        rg_copy RG(9), RG(3)            ; a child of it
        rg_revoke RG(0)
        mov ax, 0x3FE
        call rg_live
        report "after a first deleted and one alone moved, revoked (0)"
        mov dx, UT_MEMORY               ; two segments of the same untyped: RG5
        mov al, CAP_SEGMENT             ;    is not the first of its ring
        mov si, RG(5)
        mov cx, 64
        mov bl, 0xF2
        kcall KCALL_RETYPE
        must
        mov si, RG(6)
        call data64
        mov dx, RG(5)
        kcall KCALL_SEAL
        status "seal a segment not the first of its untyped's ring (0)"
        jmp done

; ----------------------------------------------------------------------------
; rg_live - how many of the ring's slots hold a segment, among some
;   In:       AX = a bit for each slot, RG(0) the lowest
;   Out:      AX = how many of them hold one (LSL takes the selector)
;   Destroys: BX, CX, DX
; ----------------------------------------------------------------------------
rg_live:
        mov bx, ax
        xor ax, ax
        mov dx, RG(0)
        mov cx, 10
.slot:
        shr bx, 1
        jnc .next
        push ax
        lsl ax, dx
        pop ax
        jnz .next
        inc ax
.next:
        add dx, 8
        loop .slot
        ret

; ============================================================================ review tests
%ifndef KPANIC
KPANIC              equ 0x03C6          ; panic's offset in the kernel's code (kernel.map)
%endif
%ifndef KMSG
KMSG                equ 0x8352          ; a message of kdata's (kernel.map)
%endif
RV_T                equ 0x1A7           ; 52
NTF_GO              equ 0x1AF           ; 53
NTF_B               equ 0x1B7           ; 54
RV_SPACE            equ 0x1BF           ; 55
RV_UT               equ 0x1C7           ; 56
UT3                 equ 0x1CF           ; 57
RV_HOLD             equ 0x1D7           ; 58
RV_SEG              equ 0x1DF           ; 59
RV_TMP              equ 0x1E7           ; 60
RV_EPS              equ 200

begin_udata
in_retype           dw 0
acted               dw 0
b_revoke            dw 0
b_space             dw 0
b_ut                dw 0
trials              dw 0
made                dw 0
b_wakes             dw 0
b_inside            dw 0
pre_call            dw 0
sib_slots           dw HOLDER, SMALL, UT_SEG, T_HOLDER, 0x1A7, 0x1AF, 0x1B7, 0x1BF, 0x1C7
                    dw 0x1CF, 0x1F7, 0x1FF
end_udata

; ----------------------------------------------------------------------------
; rv_frame_part - finding 2 of os-server.md P15's kernel review: THREAD_FRAME's write
; of a ring-3 thread's CS 0008h, then its start: the CS's RPL is the
; thread's ring, and the way back refuses it (a fault), never ring 0
;   In:       the program's start
;   Out:      does not return (done)
;   Destroys: everything
; ----------------------------------------------------------------------------
rv_frame_part:
        mov dx, UT_ARENA
        mov al, CAP_ENDPOINT
        mov si, S_EP
        kcall KCALL_RETYPE
        must
        mov dx, UT_ARENA
        mov al, CAP_NOTIFY
        mov si, NTF_STOP
        kcall KCALL_RETYPE
        must
        mov ax, ROLE_COUNT
        call make_worker
        mov cx, 3
        call sleep
        call suspend_worker
        mov bl, FRAME_READ
        call worker_frame
        must
        mov ax, [frame + TFR_CS]
        report "the worker's CS before"
        mov word [frame + TFR_CS], 0x0008      ; SEL_KCODE, RPL 0
        mov word [frame + TFR_IP], KPANIC
        mov word [frame + TFR_SI], KMSG
        mov word [frame + TFR_BP], 0
        mov word [frame + TFR_DS], 0x0010      ; SEL_KDATA
        mov word [frame + TFR_ES], 0x0010
        mov bl, FRAME_WRITE
        call worker_frame
        status "FRAME_WRITE of CS 0008h"
        call resume_worker
        mov cx, 5
        call sleep
        PRINT "additions: still here: the kernel refused it", CHAR_LF
        jmp done

RV_D                equ 0x1EF           ; 61: thread D, which retypes over and over
; ----------------------------------------------------------------------------
; rv_retype_part - finding 1: a segment's retype resumed after a revoke gave its
; untyped's memory back meanwhile ends KE_STATE, writing nothing more
;   In:       the program's start
;   Out:      does not return (done)
;   Destroys: everything
; ----------------------------------------------------------------------------
rv_retype_part:
        mov dx, UT_MEMORY
        mov al, CAP_UNTYPED
        mov si, UT_SEG
        mov cx, 0x1000
        kcall KCALL_RETYPE
        must
        mov dx, UT_ARENA
        mov al, CAP_NOTIFY
        mov si, NTF_GO
        kcall KCALL_RETYPE
        must
        mov dx, UT_ARENA
        mov al, CAP_NOTIFY
        mov si, NTF_B
        kcall KCALL_RETYPE
        must
        mov dx, UT_ARENA
        mov al, CAP_THREAD
        mov si, RV_T
        kcall KCALL_RETYPE
        must
        mov dx, UT_ARENA
        mov al, CAP_THREAD
        mov si, RV_D
        kcall KCALL_RETYPE
        must
        mov dx, RV_T                    ; B: priority 2, a tick at a time
        mov si, MY_SPACE
        mov bx, rv_b
        mov cx, 0x400
        mov al, THREAD_CONFIGURE
        kcall KCALL_THREAD
        must
        mov dx, RV_D                    ; D: priority 1, retypes for ever
        mov si, MY_SPACE
        mov bx, rv_d
        mov cx, 0x200
        mov al, THREAD_CONFIGURE
        kcall KCALL_THREAD
        must
        mov dx, RV_T
        mov cl, 2
        call start_thread
        mov dx, RV_D
        mov cl, 1
        call start_thread
        mov dx, NTF_GO                  ; D says when it is done
        kcall KCALL_RECV
        mov ax, [trials]
        report "D's retypes"
        mov ax, [b_wakes]
        report "B's ticks"
        mov ax, [b_inside]
        report "B found D inside its retype"
        cmp word [acted], 1
        jne .end
        mov ax, [b_revoke]
        status "B: revoke of the untyped D retypes from"
        mov ax, [b_space]
        status "B: a space of 256 slots retyped from it"
        mov ax, [b_ut]
        status "B: the rest of it retyped as untyped"
        mov ax, [made]
        status "D: its 64 KB segment's retype, resumed (KE_STATE expected: 6)"
        cmp byte [made], KE_OK
        jne .end
        mov ax, BIG
        mov es, ax
        mov ax, [es:0]
        push ds
        pop es
        report "D's segment's word 0, the space's SP_SLOTS (256: a segment over a kernel object)"
        mov ax, BIG
        mov es, ax
        mov ax, [es:2]
        push ds
        pop es
        report "and word 2, its LDT's GDT selector"
.end:
        jmp done

; ----------------------------------------------------------------------------
; rv_d - thread D (finding 1): a 64 KB segment retyped from UT_SEG,
; deleted and its memory given back, over and over, until B has acted
; inside a retype (B may find in_retype set just after the call returned:
; then again, as disk-scheduler.md M2's timing showed on gcc-ia16's build)
;   In:       a thread's start
;   Out:      does not return
;   Destroys: everything
; ----------------------------------------------------------------------------
rv_d:
.loop:
        inc word [trials]
        cmp word [trials], 3000
        ja .over
        mov dx, UT_SEG
        mov al, CAP_SEGMENT
        mov si, BIG
        mov cx, 0xFFFF
        mov bl, 0xF2
        mov word [in_retype], 1
        kcall KCALL_RETYPE
        mov word [in_retype], 0
        mov [made], ax
        cmp word [acted], 1
        jne .again
        cmp byte [made], KE_OK
        jne .over                       ; the race: the retype refused at its resumption
        mov dx, BIG                     ; made: and still there after B's revoke (the bug),
        kcall KCALL_SEGMENT             ;    or deleted by it, B having come after the
        jnc .over                       ;    call returned, before in_retype went to 0:
        dec word [b_inside]             ;    not the race, which is tried again, B's
        mov word [acted], 0             ;    space and untyped revoked with UT_SEG's
        mov dx, UT_SEG                  ;    children, and B back to its ticks
        kcall KCALL_REVOKE
        mov dx, NTF_B
        kcall KCALL_SIGNAL
        jmp .loop
.again:
        mov dx, BIG
        kcall KCALL_DELETE
        mov dx, UT_SEG
        kcall KCALL_REVOKE
        jmp .loop
.over:
        mov dx, NTF_GO
        kcall KCALL_SIGNAL
.stay:
        mov dx, NTF_GO
        kcall KCALL_POLL
        jmp .stay

; ----------------------------------------------------------------------------
; rv_b - thread B (finding 1): a tick at a time; inside D's retype, its
; revoke and retypes of the same untyped
;   In:       a thread's start
;   Out:      does not return
;   Destroys: everything
; ----------------------------------------------------------------------------
rv_b:
.loop:
        mov dx, NTF_B
        mov cx, 1
        kcall KCALL_TIMER
        mov dx, NTF_B
        kcall KCALL_RECV
        inc word [b_wakes]
        cmp word [in_retype], 1
        jne .loop
        inc word [b_inside]
        mov dx, UT_SEG
        kcall KCALL_REVOKE
        mov [b_revoke], ax
        mov dx, UT_SEG
        mov al, CAP_SPACE
        mov si, RV_SPACE
        mov cx, 256
        kcall KCALL_RETYPE
        mov [b_space], ax
        mov dx, UT_SEG
        mov al, CAP_UNTYPED
        mov si, RV_UT
        mov cx, 0x1000 - 513
        kcall KCALL_RETYPE
        mov [b_ut], ax
        mov word [acted], 1
.stay:
        mov dx, NTF_B
        kcall KCALL_RECV
        cmp word [acted], 0             ; D found it was not the race: again
        je .loop
        jmp .stay

; ----------------------------------------------------------------------------
; rv_dead_part - finding 7: a thread that lost its last capability while it ran
; ends at its call's next window, never off the CPU while its control
; block's memory is given out again
;   In:       the program's start
;   Out:      does not return (done)
;   Destroys: everything
; ----------------------------------------------------------------------------
rv_dead_part:
        mov dx, UT_MEMORY
        mov al, CAP_UNTYPED
        mov si, UT3
        mov cx, (RV_EPS + 16)
        kcall KCALL_RETYPE
        must
        mov dx, UT_ARENA
        mov al, CAP_SPACE
        mov si, RV_HOLD
        mov cx, 256
        kcall KCALL_RETYPE
        must
        mov di, 0x07
        mov cx, RV_EPS
.ep:
        push cx
        push di
        mov dx, UT3
        mov al, CAP_ENDPOINT
        mov si, RV_TMP
        kcall KCALL_RETYPE
        must
        pop di
        push di
        mov dx, RV_HOLD
        mov si, RV_TMP
        mov al, COPY_MOVE
        kcall KCALL_COPY
        must
        pop di
        pop cx
        add di, 8
        loop .ep
        mov dx, UT3                     ; R's thread: U3's newest child
        mov al, CAP_THREAD
        mov si, RV_T
        kcall KCALL_RETYPE
        must
        mov dx, RV_T
        mov si, MY_SPACE
        mov bx, rv_r
        mov cx, 0x300
        mov al, THREAD_CONFIGURE
        kcall KCALL_THREAD
        must
        mov dx, RV_T
        mov cl, 2
        call start_thread
        mov cx, 1                       ; R revokes U3 meanwhile
        call sleep
        mov ax, [made]
        report "R got back from its revoke (0: it is dead, off the CPU)"
        mov dx, RV_T
        mov al, THREAD_INFO
        kcall KCALL_THREAD
        status "our capability to R (1: gone)"
        mov dx, UT3                     ; its memory back, R still queued
        kcall KCALL_REVOKE
        status "A's revoke of U3"
        mov dx, UT3
        mov al, CAP_SEGMENT
        mov si, RV_SEG
        mov cx, (RV_EPS + 16) * 16
        mov bl, 0xF2
        kcall KCALL_RETYPE
        status "A's segment over all of U3"
        mov ax, RV_SEG
        mov es, ax
        mov di, RV_EPS * 16             ; R's control block
        mov word [es:di + 0], 0         ; T_CONT: none
        mov word [es:di + 8], 0         ; T_LDT
        mov word [es:di + 184 + TFR_CS], 0x0008
        mov word [es:di + 184 + TFR_IP], KPANIC
        mov word [es:di + 184 + TFR_SI], KMSG
        mov word [es:di + 184 + TFR_BP], 0
        mov word [es:di + 184 + TFR_DS], 0x0010
        mov word [es:di + 184 + TFR_ES], 0x0010
        mov word [es:di + 184 + TFR_FLAGS], 0x0002
        push ds
        pop es
        PRINT "additions: R's control block written through a segment", CHAR_LF
        mov cx, 5
        call sleep
        PRINT "additions: still here", CHAR_LF
        jmp done

; ----------------------------------------------------------------------------
; rv_r - thread R (finding 7): its revoke, which deletes its own last
; capability
;   In:       a thread's start
;   Out:      does not return
;   Destroys: everything
; ----------------------------------------------------------------------------
rv_r:
        mov dx, UT3
        kcall KCALL_REVOKE
        mov word [made], 1
.spin:
        jmp .spin

; ----------------------------------------------------------------------------
; rv_spaces_part - finding 3: spaces are refused (KE_POOL) past SPACE_MAX, and
; the kernel's data past the list of spaces stays whole
;   In:       the program's start
;   Out:      does not return (done)
;   Destroys: everything
; ----------------------------------------------------------------------------
rv_spaces_part:
        mov dx, UT_ARENA
        mov al, CAP_SPACE
        mov si, RV_HOLD
        mov cx, 256
        kcall KCALL_RETYPE
        must
        mov word [made], 0
        mov di, 0x07
        mov cx, 250
.space:
        push cx
        push di
        mov dx, UT_ARENA
        mov al, CAP_SPACE
        mov si, RV_TMP
        mov cx, 8
        kcall KCALL_RETYPE
        jc .refused
        pop di
        push di
        mov dx, RV_HOLD
        mov si, RV_TMP
        mov al, COPY_MOVE
        kcall KCALL_COPY
        must
        inc word [made]
        pop di
        pop cx
        add di, 8
        loop .space
        jmp .counted
.refused:
        pop di
        pop cx
        status "a retype refused"
.counted:
        mov ax, [made]
        report "spaces made by the program (KE_POOL due at 128 in all)"
        mov dx, RV_HOLD
        kcall KCALL_DELETE
        status "all of them deleted"
        mov dx, UT_ARENA
        mov al, CAP_ENDPOINT
        mov si, RV_TMP
        kcall KCALL_RETYPE
        status "an endpoint retyped after"
        jmp done


; ----------------------------------------------------------------------------
; rv_flush_part - finding 9: a dead space still to be emptied is emptied before
; a revoke gives its untyped's memory back
;   In:       the program's start
;   Out:      does not return (done)
;   Destroys: everything
; ----------------------------------------------------------------------------
rv_flush_part:
        mov dx, UT_ARENA
        mov al, CAP_ENDPOINT
        mov si, S_EP
        kcall KCALL_RETYPE
        must
        mov dx, UT_MEMORY               ; U: just the space S
        mov al, CAP_UNTYPED
        mov si, UT3
        mov cx, 513
        kcall KCALL_RETYPE
        must
        mov dx, UT3
        mov al, CAP_SPACE
        mov si, RV_SPACE
        mov cx, 256
        kcall KCALL_RETYPE
        must
        mov di, 0x07                    ; every slot of S: a copy of S_EP
        mov cx, 256
.copy:
        push cx
        push di
        mov dx, RV_SPACE
        mov si, S_EP
        mov al, COPY_COPY
        kcall KCALL_COPY
        must
        pop di
        pop cx
        add di, 8
        loop .copy
        mov dx, UT_ARENA
        mov al, CAP_THREAD
        mov si, RV_T
        kcall KCALL_RETYPE
        must
        mov dx, RV_T                    ; X: deletes S, at priority 2
        mov si, MY_SPACE
        mov bx, rv_x
        mov cx, 0x300
        mov al, THREAD_CONFIGURE
        kcall KCALL_THREAD
        must
        mov cx, 1
        call sleep                      ; a tick's edge
        mov dx, RV_T
        mov cl, 2
        call start_thread
        mov cx, 2
        call sleep                      ; X flushes S meanwhile
        mov ax, [made]
        mov [b_wakes], ax
        mov dx, RV_SPACE
        mov al, THREAD_INFO
        kcall KCALL_THREAD
        mov [b_inside], ax
        mov dx, RV_T
        kcall_thread THREAD_INFO
        mov [pre_call], bx
        mov dx, UT3                     ; U has no child left: its memory back
        kcall KCALL_REVOKE
        mov [b_revoke], ax
        mov dx, UT3
        mov al, CAP_SEGMENT
        mov si, RV_SEG
        mov cx, 8208
        mov bl, 0xF2
        kcall KCALL_RETYPE
        mov [b_space], ax
        jc .no_seg
        mov ax, RV_SEG
        mov es, ax
        mov word [es:0], 8              ; SP_SLOTS
        mov word [es:8], 0              ; SP_FLUSH
        mov byte [es:16 + 64], CAP_NOTIFY       ; slot 0's shadow: a notification...
        mov word [es:16 + 64 + 2], 0x0008       ; ...whose object is SEL_KCODE
        push ds
        pop es
.no_seg:
        mov ax, [b_wakes]
        report "X back from its delete (0: still flushing)"
        mov ax, [b_inside]
        status "S's capability (1: deleted by X)"
        mov ax, [pre_call]
        status "X's state (1: ready, given way)"
        mov ax, [b_revoke]
        status "A's revoke of U"
        mov ax, [b_space]
        status "A's segment over S's memory"
        PRINT "additions: S's header and slot 0 written through the segment", CHAR_LF
        mov cx, 5
        call sleep
        mov ax, [made]
        report "X back from its delete"
        jmp done

; ----------------------------------------------------------------------------
; rv_x - thread X (finding 9): its delete of a space's last capability
;   In:       a thread's start
;   Out:      does not return
;   Destroys: everything
; ----------------------------------------------------------------------------
rv_x:
        mov dx, RV_SPACE
        kcall KCALL_DELETE
        mov word [made], 1
.stay:
        jmp .stay


; ----------------------------------------------------------------------------
; rv_leak_part - finding 4: a dead thread whose space dies is not left in the
; list of threads with no capability to it
;   In:       the program's start
;   Out:      does not return (done)
;   Destroys: everything
; ----------------------------------------------------------------------------
rv_leak_part:
        mov dx, UT_MEMORY
        mov al, CAP_UNTYPED
        mov si, UT3
        mov cx, (RV_EPS + 16)
        kcall KCALL_RETYPE
        must
        mov dx, UT_ARENA
        mov al, CAP_SPACE
        mov si, RV_HOLD
        mov cx, 256
        kcall KCALL_RETYPE
        must
        mov di, 0x07
        mov cx, RV_EPS
.ep:
        push cx
        push di
        mov dx, UT3
        mov al, CAP_ENDPOINT
        mov si, RV_TMP
        kcall KCALL_RETYPE
        must
        pop di
        push di
        mov dx, RV_HOLD
        mov si, RV_TMP
        mov al, COPY_MOVE
        kcall KCALL_COPY
        must
        pop di
        pop cx
        add di, 8
        loop .ep
        mov dx, UT3                     ; R's thread: U3's newest child
        mov al, CAP_THREAD
        mov si, RV_T
        kcall KCALL_RETYPE
        must
        mov dx, UT_ARENA                ; R's space: our code, its data and stack, U3
        mov al, CAP_SPACE
        mov si, W_SPACE
        mov cx, 16
        kcall KCALL_RETYPE
        must
        mov dx, W_SPACE
        mov si, MY_CODE
        mov di, WK_CODE
        mov al, COPY_COPY
        kcall KCALL_COPY
        must
        mov bx, W_SPACE
        mov si, W_DATA_MINE
        mov di, WK_DATA
        call worker_segment
        mov bx, W_SPACE
        mov si, W_STACK_MINE
        mov di, WK_STACK
        call worker_segment
        mov dx, W_SPACE
        mov si, UT3
        mov di, WK_X
        mov al, COPY_MOVE
        kcall KCALL_COPY
        must
        mov dx, RV_T
        mov si, W_SPACE
        mov bx, rv_r2
        mov cx, W_SIZE
        mov al, THREAD_CONFIGURE
        kcall KCALL_THREAD
        must
        mov cx, 1
        call sleep                      ; a tick's edge
        mov dx, RV_T
        mov cl, 2
        call start_thread
        mov cx, 1
        call sleep                      ; R revokes U3 meanwhile, dead at once
        mov dx, RV_T
        mov al, THREAD_INFO
        kcall KCALL_THREAD
        mov [b_inside], ax
        mov dx, W_SPACE                 ; its space gone while it is off the CPU
        kcall KCALL_DELETE
        mov [b_revoke], ax
        mov cx, 5
        call sleep
        mov ax, [b_inside]
        status "our capability to R (1: gone, R dead)"
        mov ax, [b_revoke]
        status "R's space deleted"
        PRINT "additions: the threads now:", CHAR_LF
        mov al, TEST_DUMP
        kcall KCALL_TEST
        jmp done

; ----------------------------------------------------------------------------
; rv_r2 - thread R (finding 4): its revoke, as rv_r's
;   In:       a thread's start
;   Out:      does not return
;   Destroys: everything
; ----------------------------------------------------------------------------
rv_r2:
        mov dx, WK_X
        kcall KCALL_REVOKE
.spin:
        jmp .spin

; ----------------------------------------------------------------------------
; rv_misc_part - finding 8: a thread whose space died keeps nothing of that
; life: THREAD_FRAME of it running is KE_STATE, an old suspend's mark
; and notification are gone
;   In:       the program's start
;   Out:      does not return (done)
;   Destroys: everything
; ----------------------------------------------------------------------------
rv_misc_part:
        mov dx, UT_ARENA
        mov al, CAP_ENDPOINT
        mov si, S_EP
        kcall KCALL_RETYPE
        must
        mov dx, UT_ARENA
        mov al, CAP_NOTIFY
        mov si, NTF_STOP
        kcall KCALL_RETYPE
        must
        ; (a) suspended, its space deleted, configured and started again
        mov ax, ROLE_COUNT
        call make_worker
        mov cx, 2
        call sleep
        call suspend_worker
        mov dx, W_SPACE
        kcall KCALL_DELETE
        must
        mov dx, W_THREAD
        kcall_thread THREAD_INFO
        mov al, bl
        status "(a) the suspended worker, its space gone: state (0)"
        call rv_new_space
        mov dx, W_THREAD
        mov cl, 2
        call start_thread
        mov cx, 3
        call sleep
        call worker_count
        report "(a) it counts again in its new space (non-zero)"
        mov bl, FRAME_READ
        call worker_frame
        status "(a) THREAD_FRAME of it, running (KE_STATE expected: 6)"
        ; (b) marked to suspend while it waits, its space deleted, started again
        mov ax, ROLE_CALL
        call make_worker
        mov cx, 2
        call sleep
        mov dx, W_THREAD
        kcall_thread THREAD_INFO
        mov al, bl
        status "(b) the calling worker's state (4: sending)"
        mov dx, W_THREAD
        mov al, THREAD_SUSPEND
        mov si, NTF_STOP
        kcall KCALL_THREAD
        status "(b) marked to suspend"
        mov dx, W_SPACE
        kcall KCALL_DELETE
        must
        call rv_new_space
        mov dx, W_THREAD
        mov cl, 2
        call start_thread
        mov cx, 3
        call sleep
        call worker_count
        report "(b) its count in its new space (non-zero expected)"
        mov dx, W_THREAD
        kcall_thread THREAD_INFO
        mov al, bl
        status "(b) its state (2 or 1 expected; 8: stopped by the old mark)"
        mov dx, NTF_STOP
        kcall KCALL_POLL
        status "(b) the old notification signalled (8: KE_EMPTY expected)"
        jmp done

; ----------------------------------------------------------------------------
; rv_new_space - a new space for the worker's thread (W_THREAD kept): code,
; data (zeroed: role 0 counts), stack, configured
;   In:       nothing
;   Out:      nothing (a failure ends the test: must)
;   Destroys: AX, BX, CX, DX, SI, DI
; ----------------------------------------------------------------------------
rv_new_space:
        mov dx, RV_TMP
        kcall KCALL_DELETE
        mov bx, W_SPACE
        mov dx, RV_TMP
        mov si, MY_CODE
        call worker_space
        mov dx, W_THREAD
        mov si, W_SPACE
        mov bx, worker
        mov cx, W_SIZE
        mov al, THREAD_CONFIGURE
        kcall KCALL_THREAD
        must
        ret

%include "uprint.asm"
%include "format.asm"
