; ============================================================================
; rx286 - tests/programs/ipc.asm
; IPC between threads (roadmap l4.md L4): endpoints, badges, replies,
; capabilities in messages, notifications, the kernel's timer.
;
; In a TEST_CAPS build this program holds untyped memory and its own space.
; From them it makes a server (priority 4) and clients (priority 1), each a
; thread in a space of its own whose code is a copy of this program's
; (worker, below, chooses its part by the first word of its data); then it
; calls the server, passes it segments, sleeps on the kernel's timer while
; the clients call, signals notifications, calls a server below it and the
; one above it while a thread between them is busy, is refused every way it
; can think of, and last calls an endpoint nobody receives on, which only
; Ctrl+Break ends. Its own lines come through uprint; the workers build
; each of theirs in their own data and write it to the kernel's log with
; one KCALL_LOG, and read the ticks with KCALL_TICKS: their spaces hold no
; endpoint to the OS server.
;
; TEST_IPC_TIMING (tests/timing) makes 10,000 calls instead, and says how
; many instructions a round trip took on Bochs.
; ============================================================================

cpu 286
bits 16
%include "build.inc"
%include "program.inc"
%include "kcalls.inc"

; Its slots, as selectors (slot n: n * 8 + 4 + 3); slots 8 and 9 are its
; endpoint to the OS server and its transfer segment
MY_CODE             equ 0x07
MY_DATA             equ 0x0F
LOW_SPACE           equ 0x1F            ; 3, 4: a server below this program
LOW_THREAD          equ 0x27
BUSY_SPACE          equ 0x2F            ; 5, 6: a thread between the two servers
BUSY_THREAD         equ 0x37
EP_LOW              equ 0x3F            ; 7: the server below's endpoint
UT_MEMORY           equ 0x57            ; given (TEST_CAPS): slot 10
UT_ARENA            equ 0x5F            ; slot 11
MY_SPACE            equ 0x67            ; slot 12
EP                  equ 0x77            ; slot 14: the server's endpoint
NTF_SLEEP           equ 0x7F            ; 15: its own timer's
NTF_SIG             equ 0x87            ; 16: to signal three times
NTF_SIG1            equ 0x8F            ; 17-19: copies badged 1, 2, 4
NTF_SIG2            equ 0x97
NTF_SIG4            equ 0x9F
NTF_CTRL            equ 0xA7            ; 20: wakes the server in the queue's test
NTF_BOUND           equ 0xAF            ; 21: bound to the server
EP_NOGRANT          equ 0xB7            ; 22: a send-only copy; later client D's thread
SERVER_SPACE        equ 0xBF            ; 23, 24
SERVER_THREAD       equ 0xC7
A_SPACE             equ 0xCF            ; 25, 26
A_THREAD            equ 0xD7
B_SPACE             equ 0xDF            ; 27, 28
B_THREAD            equ 0xE7
C_SPACE             equ 0xEF            ; 29, 30
C_THREAD            equ 0xF7
SCRATCH             equ 0xFF            ; 31: segments on their way to a new space
BUFFER              equ 0x107           ; 32: a segment passed to the server
D_SPACE             equ 0x10F           ; 33
D_THREAD            equ EP_NOGRANT

; A worker's space: the same slots in every one
W_CODE              equ 0x07
W_DATA              equ 0x0F
W_STACK             equ 0x17
W_EP                equ 0x1F            ; the server's endpoint (a client's: badged)
W_CTRL              equ 0x27            ; the server: NTF_CTRL
W_RSLOT             equ 0x2F            ; the server: where a passed segment lands
W_SAVED             equ 0x37            ; the server: a saved reply
W_SIZE              equ 256             ; a worker's data, and its stack
W_LINE              equ 0x40            ; where a worker builds a line, in its data

ROLE_SERVER         equ 1
ROLE_A              equ 2               ; the saved reply's client
ROLE_QUEUE          equ 3               ; a client of the queue's test
ROLE_BUSY           equ 4               ; the thread between the two servers

BUSY_TICKS          equ 5               ; how long it keeps the CPU (E10 measured 5)
%ifdef TEST_IPC_TIMING
CALLS               equ 10000
%else
CALLS               equ 1000
%endif
BUDGET_TICKS        equ 100             ; for 1000 round trips (Bochs takes 11, MAME 50)
BOCHS_IPS           equ 4000000         ; instructions a second (rxlib.write_bochsrc)
TIMING_BUDGET       equ 1000            ; instructions a round trip, on Bochs

begin_udata
started             db 0
wrong               dw 0
t0                  dw 0
end_udata

; report "what" - "ipc: what: " and AX in decimal
%macro report 1
        push ds
        pop es
        PRINT "ipc: ", %1, ": "
        call print_dec
        call print_newline
%endmacro


; must - stop the test if the last kernel call failed
%macro must 0
        jc setup_failed
%endmacro

; ----------------------------------------------------------------------------
; entry - the test, once; after Ctrl+Break, "done"
;   In:       the kernel's start
;   Out:      does not return
;   Destroys: everything
; ----------------------------------------------------------------------------
entry:
        cmp byte [started], 0
        jne done
        mov byte [started], 1
        ; ---- its objects
        mov al, CAP_ENDPOINT
        mov si, EP
        call retype_object
        mov al, CAP_NOTIFY
        mov si, NTF_SLEEP
        call retype_object
        mov al, CAP_NOTIFY
        mov si, NTF_SIG
        call retype_object
        mov al, CAP_NOTIFY
        mov si, NTF_CTRL
        call retype_object
        mov al, CAP_NOTIFY
        mov si, NTF_BOUND
        call retype_object
        mov si, NTF_SIG
        mov di, NTF_SIG1
        mov bx, 1
        call mint_mine
        mov di, NTF_SIG2
        mov bx, 2
        call mint_mine
        mov di, NTF_SIG4
        mov bx, 4
        call mint_mine
        mov dx, MY_SPACE                ; a send-only copy of the endpoint: no grant
        mov si, EP
        mov di, EP_NOGRANT
        mov al, COPY_MINT
        mov bx, 0x99
        mov cl, RIGHT_SEND
        kcall KCALL_COPY
        must
        ; ---- the server: the endpoint, its control notification, bound
        mov al, ROLE_SERVER
        mov bx, SERVER_SPACE
        mov dx, SERVER_THREAD
        call make_thread
        mov dx, SERVER_SPACE
        mov si, EP
        mov di, W_EP
        mov al, COPY_COPY
        kcall KCALL_COPY
        must
        mov si, NTF_CTRL
        mov di, W_CTRL
        kcall KCALL_COPY
        must
        mov dx, SERVER_THREAD
        mov al, THREAD_BIND
        mov si, NTF_BOUND
        kcall KCALL_THREAD
        must
        mov dx, SERVER_THREAD
        mov cl, 4
        call start_thread
        PRINT "ipc: the server runs", CHAR_LF
        ; ---- a thousand calls
        sys SYS_TICKS
        mov [t0], ax
        xor si, si
.call:
        mov bx, si
        mov al, 1
        mov dx, EP
        push si
        xor bp, bp
        kcall KCALL_CALL
        pop si
        inc si
        cmp bx, si
        je .right
        inc word [wrong]
.right:
        cmp si, CALLS
        jb .call
        sys SYS_TICKS
        sub ax, [t0]
%ifdef TEST_IPC_TIMING
        jmp timing
%endif
        push ax
        mov ax, [wrong]
        report "1000 calls answered; wrong answers"
        pop ax
        cmp ax, BUDGET_TICKS
        jbe .budget
        report "1000 calls took ticks, over the budget"
        jmp .caps
.budget:
        PRINT "ipc: 1000 calls within the budget", CHAR_LF
.caps:
        ; ---- a segment passed, used, deleted, passed again; kept; refused
        mov dx, UT_MEMORY
        mov al, CAP_SEGMENT
        mov si, BUFFER
        mov cx, 16
        mov bl, 0xF2
        kcall KCALL_RETYPE
        must
        mov al, 2
        mov bp, BUFFER
        call call_server
        mov ax, BUFFER
        mov es, ax
        mov ax, [es:0]
        mov word [es:0], 0
        report "the server wrote into the buffer (19279)"
        mov al, 2
        mov bp, BUFFER
        call call_server
        mov ax, BUFFER
        mov es, ax
        mov ax, [es:0]
        report "and again, after it deleted its copy (19279)"
        mov al, 3
        mov bp, BUFFER
        call call_server
        mov ax, bx
        report "kept, in the server's slot (47)"
        mov al, 3
        mov bp, BUFFER
        call call_server
        mov ax, bx
        report "passed to a full slot: arrived as (0)"
        mov al, 2
        mov dx, EP_NOGRANT
        mov bp, BUFFER
        kcall KCALL_CALL
        report "through an endpoint without the grant right (2)"
        mov al, 2
        mov dx, EP
        mov bp, SCRATCH
        kcall KCALL_CALL
        report "passing an empty slot (1)"
        mov dx, EP_NOGRANT              ; its slot is wanted for client D
        kcall KCALL_DELETE
        must
        ; ---- the timer; a reply saved, and answered after another
        mov al, ROLE_A
        mov bx, A_SPACE
        mov dx, A_THREAD
        mov di, 0x000A
        call make_client
        sys SYS_TICKS
        mov [t0], ax
        mov cx, 3
        call sleep
        sys SYS_TICKS
        sub ax, [t0]
        cmp ax, 3
        mov ax, 1
        jae .slept
        xor ax, ax
.slept:
        report "slept on the timer for 3 ticks or more (1)"
        mov al, 5
        xor bp, bp
        call call_server
        mov ax, bx
        report "answered before the call it saved (55)"
        mov cx, 2
        call sleep                      ; client A says what it got
        ; ---- three callers queued while the server does not receive
        mov al, 6
        xor bp, bp
        call call_server                ; the server now waits on NTF_CTRL
        mov al, ROLE_QUEUE
        mov bx, B_SPACE
        mov dx, B_THREAD
        mov di, 0x000B
        call make_client
        mov al, ROLE_QUEUE
        mov bx, C_SPACE
        mov dx, C_THREAD
        mov di, 0x000C
        call make_client
        mov al, ROLE_QUEUE
        mov bx, D_SPACE
        mov dx, D_THREAD
        mov di, 0x000D
        call make_client
        mov cx, 3
        call sleep                      ; they call, and queue
        PRINT "ipc: the server, woken", CHAR_LF
        mov dx, NTF_CTRL
        kcall KCALL_SIGNAL
        must
        mov cx, 3
        call sleep                      ; they say what they got
        ; ---- notifications
        mov dx, NTF_SIG1
        kcall KCALL_SIGNAL
        mov dx, NTF_SIG2
        kcall KCALL_SIGNAL
        mov dx, NTF_SIG4
        kcall KCALL_SIGNAL
        mov dx, NTF_SIG
        kcall KCALL_RECV
        mov ax, bx
        report "three signals, one receive: bits (7)"
        mov dx, NTF_SIG
        kcall KCALL_POLL
        report "polled again: empty (8)"
        mov dx, NTF_BOUND               ; the server waits on its endpoint
        kcall KCALL_SIGNAL
        must
        ; ---- a server below this program, one above it, and a thread
        ; between them that keeps the CPU for a while once woken
        mov al, CAP_ENDPOINT
        mov si, EP_LOW
        call retype_object
        mov al, ROLE_SERVER
        mov bx, LOW_SPACE
        mov dx, LOW_THREAD
        call make_thread
        mov dx, LOW_SPACE
        mov si, EP_LOW
        mov di, W_EP
        mov al, COPY_COPY
        kcall KCALL_COPY
        must
        mov dx, LOW_THREAD
        mov cl, 1
        call start_thread
        mov al, ROLE_BUSY
        mov bx, BUSY_SPACE
        mov dx, BUSY_THREAD
        call make_thread
        mov dx, BUSY_SPACE
        mov si, NTF_SIG
        mov di, W_CTRL
        mov al, COPY_COPY
        kcall KCALL_COPY
        must
        mov dx, BUSY_THREAD
        mov cl, 2
        call start_thread
        mov cx, 1
        call sleep                      ; both wait: on the endpoint, the notification
        mov dx, EP_LOW
        call busy_call
        report "a client above its server: waited for the thread between (1)"
        mov dx, EP
        call busy_call
        report "a client below its server: waited (0)"
        ; ---- refused
        mov dx, MY_DATA
        kcall KCALL_RECV
        report "receive on a segment (1)"
        mov dx, NTF_SIG
        kcall KCALL_CALL
        report "call a notification (1)"
        mov dx, EP
        kcall KCALL_SIGNAL
        report "signal an endpoint (1)"
        mov al, NOTIFY_LABEL
        mov dx, EP
        xor bp, bp
        kcall KCALL_CALL
        report "a call labelled as a notification's bits (2)"
        mov si, SCRATCH
        kcall KCALL_SAVE_REPLY
        report "save a reply it does not owe (6)"
        mov dx, EP
        xor bp, bp
        kcall KCALL_POLL
        report "poll an endpoint nobody sends on (8)"
        mov dx, NTF_SLEEP
        xor cx, cx
        kcall KCALL_TIMER
        report "a timer of 0 ticks (2)"
        mov dx, SCRATCH
        kcall KCALL_DELETE
        report "delete an empty slot (1)"
        ; ---- a call nobody answers: only Ctrl+Break ends it
        mov al, CAP_ENDPOINT
        mov si, SCRATCH
        call retype_object
        PRINT "ipc: a call to an endpoint nobody receives on", CHAR_LF
        mov dx, SCRATCH
        xor bp, bp
        kcall KCALL_CALL
        report "it returned (never)"
        ; falls through

; ----------------------------------------------------------------------------
; done - the end of the test: "done", then keys, read for ever
;   In:       nothing
;   Out:      does not return
;   Destroys: everything
; ----------------------------------------------------------------------------
done:
        PRINT "ipc: done", CHAR_LF
.wait:
        mov al, KEY_WAIT
        sys SYS_READ_KEY
        jmp .wait

; ----------------------------------------------------------------------------
; timing - TEST_IPC_TIMING: the instructions a round trip took, from the
; ticks the calls took on Bochs, which runs BOCHS_IPS a second
;   In:       AX = the ticks
;   Out:      does not return
;   Destroys: everything
; ----------------------------------------------------------------------------
timing:
        mov bx, BOCHS_IPS / SYS_TICKS_HZ / CALLS
        mul bx
        push ax
        report "instructions a round trip on Bochs, about"
        pop ax
        cmp ax, TIMING_BUDGET
        jbe .budget
        PRINT "ipc: over the budget", CHAR_LF
        jmp done
.budget:
        PRINT "ipc: a round trip within the budget", CHAR_LF
        jmp done

; ----------------------------------------------------------------------------
; setup_failed - a call the test needs failed: say which, and stop
;   In:       the stack's top: the return address of the routine that failed
;   Out:      does not return
;   Destroys: everything
; ----------------------------------------------------------------------------
setup_failed:
        report "a setup call failed, status"
        jmp done.wait

; ----------------------------------------------------------------------------
; retype_object - a kernel object from the arena into a slot of its own
;   In:       AL = the type; SI = the slot
;   Out:      nothing (stops the test on a failure)
;   Destroys: AX, DX
; ----------------------------------------------------------------------------
retype_object:
        mov dx, UT_ARENA
        kcall KCALL_RETYPE
        must
        ret

; ----------------------------------------------------------------------------
; mint_mine - a badged copy of a capability of its own, into its own slot
;   In:       SI = the capability; DI = the slot; BX = the badge
;   Out:      nothing (stops the test on a failure)
;   Destroys: AX, CX, DX
; ----------------------------------------------------------------------------
mint_mine:
        mov dx, MY_SPACE
        mov al, COPY_MINT
        xor cl, cl
        kcall KCALL_COPY
        must
        ret

; ----------------------------------------------------------------------------
; make_thread - a worker: a space of 16 slots, a thread, the code copied, a
; data segment (its first word the role) and a stack moved in; configured
; at worker, not started
;   In:       AL = the role; BX = the space's slot; DX = the thread's slot
;   Out:      nothing (stops the test on a failure)
;   Destroys: AX, CX, SI, DI, ES
; ----------------------------------------------------------------------------
make_thread:
        push ax
        push dx
        mov dx, UT_ARENA
        mov al, CAP_SPACE
        mov si, bx
        mov cx, 16
        kcall KCALL_RETYPE
        must
        pop si                          ; the thread's slot
        push si
        mov al, CAP_THREAD
        kcall KCALL_RETYPE
        must
        mov dx, bx
        mov si, MY_CODE
        mov di, W_CODE
        mov al, COPY_COPY
        kcall KCALL_COPY
        must
        call scratch_segment
        pop dx
        pop ax
        push dx
        mov cx, SCRATCH
        mov es, cx
        xor ah, ah
        mov [es:0], ax                  ; the role
        push ds
        pop es
        mov dx, bx
        mov si, SCRATCH
        mov di, W_DATA
        mov al, COPY_MOVE
        kcall KCALL_COPY
        must
        call scratch_segment
        mov dx, bx
        mov si, SCRATCH
        mov di, W_STACK
        mov al, COPY_MOVE
        kcall KCALL_COPY
        must
        pop dx
        mov si, bx
        mov bx, worker
        mov al, THREAD_CONFIGURE
        mov cx, W_SIZE
        kcall KCALL_THREAD
        must
        mov bx, si
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
; make_client - a worker with the endpoint, minted with a badge, started at
; priority 1
;   In:       AL = the role; BX = the space's slot; DX = the thread's slot;
;             DI = the badge
;   Out:      nothing (stops the test on a failure)
;   Destroys: AX, BX, CX, SI, DI, ES
; ----------------------------------------------------------------------------
make_client:
        push di
        call make_thread
        pop di
        push dx
        mov dx, bx
        mov bx, di
        mov si, EP
        mov di, W_EP
        mov al, COPY_MINT
        xor cl, cl
        kcall KCALL_COPY
        must
        push dx                         ; a notification nobody signals: where
        mov dx, UT_ARENA                ; it waits once it is done
        mov al, CAP_NOTIFY
        mov si, SCRATCH
        kcall KCALL_RETYPE
        must
        pop dx
        mov si, SCRATCH
        mov di, W_CTRL
        mov al, COPY_MOVE
        kcall KCALL_COPY
        must
        pop dx
        mov cl, 1
        ; falls through

; ----------------------------------------------------------------------------
; start_thread - start a thread at a priority
;   In:       DX = the thread's slot; CL = the priority
;   Out:      nothing (stops the test on a failure)
;   Destroys: AX, CX
; ----------------------------------------------------------------------------
start_thread:
        mov al, THREAD_START
        xor ch, ch
        kcall KCALL_THREAD
        must
        ret

; ----------------------------------------------------------------------------
; call_server - a call on the endpoint
;   In:       AL = the label; BP = a capability to pass, or 0
;   Out:      BX = the reply's first word (stops the test on a failure)
;   Destroys: AX, CX, DX, SI, DI
; ----------------------------------------------------------------------------
call_server:
        mov dx, EP
        kcall KCALL_CALL
        must
        ret

; ----------------------------------------------------------------------------
; busy_call - wake the thread between the servers, then call one (label 1:
; an echo), and say whether the answer waited for that thread
;   In:       DX = the server's endpoint
;   Out:      AX = 1 if the call took BUSY_TICKS or more, else 0
;   Destroys: BX, CX, DX, SI, DI, BP
; ----------------------------------------------------------------------------
busy_call:
        push dx
        mov dx, NTF_SIG
        kcall KCALL_SIGNAL
        must
        sys SYS_TICKS
        mov [t0], ax
        pop dx
        mov al, 1
        xor bp, bp
        kcall KCALL_CALL
        must
        sys SYS_TICKS
        sub ax, [t0]
        cmp ax, BUSY_TICKS
        mov ax, 1
        jae .done
        xor ax, ax
.done:
        ret

; ----------------------------------------------------------------------------
; sleep - CX ticks, on the kernel's timer and its own notification
;   In:       CX = ticks
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

; ============================================================================
; worker - a thread this program made: its part is the first word of its
; data. It has the code (a copy of this program's), its own data and stack,
; and what the program gave it: W_EP, and W_CTRL: the server's control
; notification, a client's private one, the busy thread's wake-up.
;   In:       its start: DS = ES = its data, SS:SP its stack
;   Out:      does not return
;   Destroys: everything
; ============================================================================
worker:
        mov ax, [0]
        cmp ax, ROLE_SERVER
        je server
        cmp ax, ROLE_A
        je client_a
        cmp ax, ROLE_BUSY
        je busy
        jmp client_queue

; ----------------------------------------------------------------------------
; server - receive, answer by label, for ever: 1 echo + 1; 2 write into the
; segment passed, delete it, 1; 3 keep it, answer its selector; 4 save the
; reply; 5 answer the saved one with 44, this one with 55; 6 answer, then
; wait on W_CTRL before receiving again; 7 answer the badge, and say it; a
; bound notification: say its bits
;   In:       its start
;   Out:      does not return
;   Destroys: everything
; ----------------------------------------------------------------------------
server:
        mov dx, W_EP
        mov bp, W_RSLOT
        kcall KCALL_RECV
.message:
        cmp al, NOTIFY_LABEL
        je .notified
        cmp al, 1
        je .echo
        cmp al, 2
        je .write
        cmp al, 3
        je .keep
        cmp al, 4
        je .save
        cmp al, 5
        je .both
        cmp al, 6
        je .hold
        mov si, line_badge              ; 7: who called
        mov ax, dx
        call wline
        mov bx, dx
        jmp .reply
.echo:
        inc bx
        jmp .reply
.write:
        xor bx, bx
        test bp, bp
        jz .reply
        mov es, bp
        mov word [es:0], 'OK'           ; 4B4Fh, 19279
        push ds
        pop es
        mov dx, bp
        kcall KCALL_DELETE
        mov bx, 1
        jmp .reply
.keep:
        mov bx, bp
        jmp .reply
.save:
        mov si, W_SAVED
        kcall KCALL_SAVE_REPLY
        jmp server
.both:
        mov dx, W_SAVED
        mov bx, 44
        kcall KCALL_SEND                ; the saved reply, first
        mov bx, 55
        jmp .reply
.hold:
        mov dx, W_CTRL                  ; answer, then wait to be woken
        kcall KCALL_REPLY_RECV
        jmp server
.notified:
        mov si, line_notified
        mov ax, bx
        call wline
        jmp server
.reply:
        mov dx, W_EP
        mov bp, W_RSLOT
        kcall KCALL_REPLY_RECV
        jmp .message

; ----------------------------------------------------------------------------
; client_a - a call the server saves and answers later; say the answer
;   In:       its start
;   Out:      does not return
;   Destroys: everything
; ----------------------------------------------------------------------------
client_a:
        mov al, 4
        mov dx, W_EP
        xor bp, bp
        kcall KCALL_CALL
        mov si, line_later
        mov ax, bx
        call wline
        jmp spin

; ----------------------------------------------------------------------------
; client_queue - one call, queued behind others; say its badge as answered
;   In:       its start
;   Out:      does not return
;   Destroys: everything
; ----------------------------------------------------------------------------
client_queue:
        mov al, 7
        mov dx, W_EP
        xor bp, bp
        kcall KCALL_CALL
        mov si, line_served
        mov ax, bx
        call wline
        ; falls through

; ----------------------------------------------------------------------------
; busy - the thread between the servers: woken through W_CTRL, it keeps the
; CPU for BUSY_TICKS, then waits again
;   In:       its start
;   Out:      does not return
;   Destroys: everything
; ----------------------------------------------------------------------------
busy:
        mov dx, W_CTRL
        kcall KCALL_RECV
        kcall KCALL_TICKS
        mov si, ax
.spin:
        kcall KCALL_TICKS
        sub ax, si
        cmp ax, BUSY_TICKS
        jb .spin
        jmp busy

; ----------------------------------------------------------------------------
; spin - a worker that is done: it waits for good, on a notification nobody
; signals, so that the others at its priority run
;   In:       nothing
;   Out:      does not return
;   Destroys: everything
; ----------------------------------------------------------------------------
spin:
        mov dx, W_CTRL
        kcall KCALL_RECV
        jmp spin

; ----------------------------------------------------------------------------
; wline - a worker's line, in one SYS_WRITE: a text from the code, a word
; in hexadecimal, a line feed (built in its own data at W_LINE)
;   In:       SI = the text (in the code: zero-terminated); AX = the word
;   Out:      nothing
;   Destroys: AX, BX, CX, SI, DI, ES
; ----------------------------------------------------------------------------
wline:
        push ds
        pop es
        mov di, W_LINE
        mov bx, ax
.copy:
        mov al, [cs:si]
        test al, al
        jz .number
        stosb
        inc si
        jmp .copy
.number:
        mov cx, 4
.digit:
        rol bx, 4
        mov al, bl
        and al, 15
        add al, '0'
        cmp al, '9'
        jbe .put
        add al, 'A' - '0' - 10
.put:
        stosb
        loop .digit
        mov al, CHAR_LF
        stosb
        mov cx, di
        mov si, W_LINE
        sub cx, si
        kcall KCALL_LOG
        ret

line_badge          db "server: a call from badge ", 0
line_notified       db "server: notified, bits ", 0
line_later          db "client A: the saved reply answered, with ", 0
line_served         db "client: served, badge ", 0

%include "uprint.asm"
%include "format.asm"
