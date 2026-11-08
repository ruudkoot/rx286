; ============================================================================
; rx286 - src/kernel/ipc.asm
; Synchronous IPC: endpoints, notifications, replies, the kernel's timer
; (roadmap l4.md L4; D5, D6).
;
; A message is a label (AL) and four words (BX, CX, SI, DI), with the badge
; of the sender's capability (DX) and at most one capability (named by the
; sender's BP, landing in the slot the receiver named by its BP; l4.md D5).
; Nothing but registers is copied: a sender's message is in its frame (at
; the top of the kernel's stack while it runs, else in its control block),
; and delivery writes it into the receiver's frame. An endpoint holds a
; queue of senders or of receivers; whoever comes second does the transfer.
; A call leaves the receiver owing a reply: a link in its control block,
; which it may save into a slot and answer later; a sequence number keeps a
; stale reply from answering a later call (E10). A notification is a word of
; bits: a signal ORs the capability's badge into it; a receive returns and
; clears it, and a thread bound to it gets its bits even while it waits on
; an endpoint. There are no timeouts (l4.md D6): the kernel's timer signals
; a notification. A thread waiting for IPC has nothing left to do in the
; kernel (thread.asm); a restart (Ctrl+Break, a 287 error) takes it out of
; any queue. Endpoints, notifications and threads are objects named by their
; selectors, which ES holds while the kernel works on one (os-server.md P3).
; ============================================================================

TIMER_MAX           equ 48              ; timers armed at once: one a notification; enough for
                                        ;    every thread of the OS server's, each waiting
                                        ;    for its lock a tick at a time, and the drivers
                                        ;    (memory.md M1: 16 ran out at 23 processes)
TIMER_TICKS_MAX     equ 0x7FFF          ; ten minutes and more
TIMER_SIZE          equ 6
TM_NOTIFY           equ 0               ; the notification, or 0: free
TM_BITS             equ 2
TM_DUE              equ 4               ; the tick (its low word) it fires at

begin_kdata
timers              times TIMER_MAX * TIMER_SIZE db 0
ipc_calling         db 0                ; TI_CALLING for KCALL_CALL, 0 for KCALL_SEND
ipc_poll            db 0                ; 1 for KCALL_POLL
dl_ipc              db 0                ; deliver's temporaries
                    db 0
dl_cap              dw 0
dl_badge            dw 0
dl_sender           dw 0
dl_receiver         dw 0
dl_src_space        dw 0
dl_src_slot         dw 0
dl_dst_space        dw 0
dl_dst_slot         dw 0
dl_dst_shadow       dw 0
dl_dst_desc         dw 0
end_kdata

; ----------------------------------------------------------------------------
; thread_frame - where a thread's frame is: the running thread's at the top
; of the kernel's stack (KFRAME), any other's in its control block
;   In:       BX = the thread
;   Out:      ES:DI = its frame
;   Destroys: nothing
; ----------------------------------------------------------------------------
thread_frame:
        cmp bx, [cur_thread]
        je .running
        mov es, bx
        mov di, T_FRAME
        ret
.running:
        push ds
        pop es
        mov di, KFRAME
        ret

; ----------------------------------------------------------------------------
; frame_status - a status into a frame: AX (AH 0), CF if not KE_OK
;   In:       ES:DI = the frame; AL = KE_*
;   Out:      nothing
;   Destroys: AH
; ----------------------------------------------------------------------------
frame_status:
        xor ah, ah
        mov [es:di + FRAME_AX], ax
        and word [es:di + FRAME_FLAGS], ~FLAGS_CF
        test al, al
        jz .done
        or word [es:di + FRAME_FLAGS], FLAGS_CF
.done:
        ret

; ----------------------------------------------------------------------------
; ep_push - a thread to the tail of an endpoint's queue
;   In:       SI = the endpoint; BX = the thread
;   Out:      nothing
;   Destroys: AX
; ----------------------------------------------------------------------------
ep_push:
        push es
        mov es, bx
        mov word [es:T_NEXT], 0
        mov es, si
        mov ax, [es:E_TAIL]
        test ax, ax
        jz .first
        mov es, ax
        mov [es:T_NEXT], bx
        mov es, si
        jmp .tail
.first:
        mov [es:E_HEAD], bx
.tail:
        mov [es:E_TAIL], bx
        pop es
        ret

; ----------------------------------------------------------------------------
; ep_pop - the head of an endpoint's queue, taken out (idle once empty)
;   In:       SI = the endpoint (its queue not empty)
;   Out:      BX = the thread
;   Destroys: AX
; ----------------------------------------------------------------------------
ep_pop:
        push es
        mov es, si
        mov bx, [es:E_HEAD]
        mov es, bx
        mov ax, [es:T_NEXT]
        mov es, si
        mov [es:E_HEAD], ax
        test ax, ax
        jnz .done
        mov word [es:E_TAIL], 0
        mov byte [es:E_KIND], EK_IDLE
.done:
        pop es
        ret

; ----------------------------------------------------------------------------
; ep_remove - a thread out of an endpoint's queue, wherever it is
;   In:       SI = the endpoint; BX = the thread (in its queue)
;   Out:      nothing
;   Destroys: AX
; ----------------------------------------------------------------------------
ep_remove:
        push di
        push es
        xor di, di                      ; DI = the one before it
        mov es, si
        mov ax, [es:E_HEAD]
.find:
        test ax, ax
        jz .done                        ; not there after all
        cmp ax, bx
        je .found
        mov di, ax
        mov es, ax
        mov ax, [es:T_NEXT]
        jmp .find
.found:
        mov es, bx
        mov ax, [es:T_NEXT]
        test di, di
        jz .head
        mov es, di
        mov [es:T_NEXT], ax
        jmp .tail
.head:
        mov es, si
        mov [es:E_HEAD], ax
.tail:
        mov es, si
        cmp [es:E_TAIL], bx
        jne .done
        mov [es:E_TAIL], di
.done:
        mov es, si
        cmp word [es:E_HEAD], 0
        jne .out
        mov word [es:E_TAIL], 0
        mov byte [es:E_KIND], EK_IDLE
.out:
        pop es
        pop di
        ret

; ----------------------------------------------------------------------------
; deliver - a message from a sender to a receiver: the label, four words,
; the badge as DX, and the capability the sender's BP names into the slot
; the receiver named, if it passes one and that slot is empty (else the
; message arrives without it: BP = 0)
;   In:       SI = the sender; BX = the receiver
;   Out:      the receiver's frame: AX the label, BX CX SI DI, DX the badge,
;             BP the selector the capability arrived in, or 0; CF clear
;   Destroys: AX, CX, DX, DI, ES
; ----------------------------------------------------------------------------
deliver:
        mov [dl_sender], si
        mov [dl_receiver], bx
        mov es, si
        mov ax, [es:T_BADGE]
        mov [dl_badge], ax
        mov al, [es:T_IPC]
        mov [dl_ipc], al
        mov bx, si
        call thread_frame               ; ES:DI = the sender's frame
        push es
        push di
        mov bx, [dl_receiver]
        call thread_frame               ; ES:DI = the receiver's
        pop si
        pop ax
        push ds
        mov ds, ax                      ; DS:SI = the sender's
        mov ax, [si + FRAME_BX]
        mov [es:di + FRAME_BX], ax
        mov ax, [si + FRAME_CX]
        mov [es:di + FRAME_CX], ax
        mov ax, [si + FRAME_SI]
        mov [es:di + FRAME_SI], ax
        mov ax, [si + FRAME_DI]
        mov [es:di + FRAME_DI], ax
        mov cx, [si + FRAME_BP]         ; the capability it passes
        mov al, [si + FRAME_AX]         ; the label: AH 0, CF clear (no error)
        pop ds
        xor ah, ah
        mov [es:di + FRAME_AX], ax
        and word [es:di + FRAME_FLAGS], ~FLAGS_CF
        mov ax, [dl_badge]
        mov [es:di + FRAME_DX], ax
        mov word [es:di + FRAME_BP], 0
        test byte [dl_ipc], TI_GRANT
        jz .done
        mov [dl_cap], cx
        mov es, bx
        mov ax, [es:T_RSLOT]
        test ax, ax
        jz .done
        ; the destination: the receiver's slot, empty
        mov bx, [es:T_SPACE]
        mov [dl_dst_space], bx
        call slot_of                    ; ES = its space, SI, DI; AX = the slot
        jc .done
        cmp byte [es:si + SH_TYPE], CAP_EMPTY
        jne .done
        mov [dl_dst_slot], ax
        mov [dl_dst_shadow], si
        mov [dl_dst_desc], di
        ; the source: the sender's slot, not empty
        mov es, [dl_sender]
        mov bx, [es:T_SPACE]
        mov [dl_src_space], bx
        mov ax, [dl_cap]
        call slot_of                    ; ES = its space; AX = its slot; SI, DI
        jc .done
        mov cl, [es:si + SH_TYPE]
        cmp cl, CAP_EMPTY
        je .done
        cmp cl, CAP_UNTYPED
        je .done                        ; untyped is moved, never shared: two
        cmp cl, CAP_REPLY               ; retypes would carve the same memory;
        je .done                        ; a reply is answered once (l4.md L13)
        mov [dl_src_slot], ax
        mov dx, [dl_dst_space]          ; from the sender's space (DS) to the
        mov bx, [dl_dst_desc]           ; receiver's (ES)
        mov ax, [dl_dst_shadow]
        push ds
        push es
        pop ds
        mov es, dx
        cld
        push si
        mov si, di                      ; the descriptor, 8 bytes
        mov di, bx
        mov cx, 4
        rep movsw
        pop si
        mov di, ax                      ; the shadow entry
        mov cx, SHADOW_SIZE / 2
        rep movsw
        pop ds
        mov bx, [dl_src_space]          ; a child of the sender's slot
        mov ax, [dl_src_slot]
        mov dx, [dl_dst_space]
        mov cx, [dl_dst_slot]
        call child_link
        mov es, dx
        mov si, [dl_dst_shadow]
        mov al, [es:si + SH_TYPE]
        mov dx, [es:si + SH_OBJECT]
        call obj_ref
        mov es, [dl_receiver]           ; the receiver: BP = the selector, at its ring
        mov ax, [es:T_RSLOT]
        and ax, ~CPL_MASK
        or al, [es:T_RING]
        mov bx, [dl_receiver]
        call thread_frame
        mov [es:di + FRAME_BP], ax
.done:
        mov bx, [dl_receiver]
        mov si, [dl_sender]
        ret

; ----------------------------------------------------------------------------
; ipc_link - a call delivered: the receiver owes the caller a reply, and the
; caller waits for it (a reply already owed is answered with KE_STATE: only
; one can be owed at a time)
;   In:       BX = the receiver; SI = the caller
;   Out:      nothing
;   Destroys: AX, CX, DX, DI
; ----------------------------------------------------------------------------
ipc_link:
        call reply_abandon
        push es
        mov es, si
        inc word [es:T_CALLS]
        mov ax, [es:T_CALLS]
        mov byte [es:T_STATE], TS_REPLY
        mov [es:T_WAIT_OBJ], bx
        mov es, bx
        mov [es:T_REPLY], si
        mov [es:T_REPLY_SEQ], ax
        pop es
        ret

; ----------------------------------------------------------------------------
; reply_abandon - a reply owed that will never come: its caller, if it still
; waits for it, gets KE_STATE
;   In:       BX = the thread that owes it
;   Out:      its T_REPLY clear
;   Destroys: AX, CX, DX, DI
; ----------------------------------------------------------------------------
reply_abandon:
        push bx
        push si
        push es
        mov si, bx
        mov es, si
        mov bx, [es:T_REPLY]
        test bx, bx
        jz .done
        mov word [es:T_REPLY], 0
        mov cx, [es:T_REPLY_SEQ]
        mov dx, si
        call reply_valid
        jc .done
        call thread_frame
        mov al, KE_STATE
        call frame_status
        call ready_push
.done:
        pop es
        pop si
        pop bx
        ret

; ----------------------------------------------------------------------------
; reply_valid - does a thread still wait for this reply?
;   In:       BX = the caller; CX = the T_CALLS it had; DX = the server
;   Out:      CF clear if so
;   Destroys: nothing
; ----------------------------------------------------------------------------
reply_valid:
        push es
        mov es, bx
        cmp byte [es:T_STATE], TS_REPLY
        jne .stale
        cmp [es:T_WAIT_OBJ], dx
        jne .stale
        cmp [es:T_CALLS], cx
        jne .stale
        pop es
        clc
        ret
.stale:
        pop es
        stc
        ret

; ----------------------------------------------------------------------------
; ipc_wake - a thread that IPC wakes, made ready: first in its queue if it is
; at least as urgent as the running thread, which then runs it next when it
; waits (Liedtke's direct switch, with seL4's rule about priorities: l4.md
; D5); else last, and the scheduler chooses
;   In:       BX = the thread
;   Out:      nothing
;   Destroys: AX
; ----------------------------------------------------------------------------
ipc_wake:
        push es
        mov es, bx
        mov al, [es:T_PRIO]
        mov es, [cur_thread]
        cmp al, [es:T_PRIO]
        pop es
        jb ready_push
        jmp ready_first

; ----------------------------------------------------------------------------
; reply_send - a reply: the running thread's four words (its frame's BX CX
; SI DI) into the caller's frame, which wakes
;   In:       BX = the caller (not the running thread); CX = the T_CALLS it
;             had; DX = the server; BP = the running thread's frame
;   Out:      CF clear if delivered; CF set if the caller waits no more
;   Destroys: AX, DI, ES
; ----------------------------------------------------------------------------
reply_send:
        call reply_valid
        jc .done
        call thread_frame
        mov ax, [bp + FRAME_BX]
        mov [es:di + FRAME_BX], ax
        mov ax, [bp + FRAME_CX]
        mov [es:di + FRAME_CX], ax
        mov ax, [bp + FRAME_SI]
        mov [es:di + FRAME_SI], ax
        mov ax, [bp + FRAME_DI]
        mov [es:di + FRAME_DI], ax
        mov al, KE_OK
        call frame_status
        call ipc_wake
        clc
.done:
        ret

; ----------------------------------------------------------------------------
; kc_call - KCALL_CALL: a message on an endpoint, then a wait for its reply
;   In:       BP = the frame (DX the capability, AL the label, BX CX SI DI,
;             BP a capability to pass or 0)
;   Out:      the frame's status, and the reply in BX CX SI DI
;   Destroys: AX, BX, CX, DX, SI, DI, ES
; ----------------------------------------------------------------------------
kc_call:
        mov byte [ipc_calling], TI_CALLING
        jmp ipc_send

; ----------------------------------------------------------------------------
; kc_send - KCALL_SEND: a message on an endpoint, with no reply; on a saved
; reply, that reply
;   In:       BP = the frame, as kc_call's
;   Out:      the frame's status
;   Destroys: AX, BX, CX, DX, SI, DI, ES
; ----------------------------------------------------------------------------
kc_send:
        mov byte [ipc_calling], 0
        ; falls through

; ----------------------------------------------------------------------------
; ipc_send - the body of kc_call and kc_send
;   In:       BP = the frame; ipc_calling
;   Out:      as kc_call
;   Destroys: AX, BX, CX, DX, SI, DI, ES
; ----------------------------------------------------------------------------
ipc_send:
        mov ax, [bp + FRAME_DX]
        call cap_lookup                 ; ES:SI = its shadow entry
        jc kc_done.cap
        cmp byte [es:si + SH_TYPE], CAP_REPLY
        jne .endpoint
        cmp byte [ipc_calling], 0       ; a reply is sent, never called (P15)
        jne kc_done.cap
        jmp .reply
.endpoint:
        cmp byte [es:si + SH_TYPE], CAP_ENDPOINT
        jne kc_done.cap
        test byte [es:si + SH_RIGHTS], RIGHT_SEND
        jz kc_done.cap
        cmp byte [bp + FRAME_AX], NOTIFY_LABEL
        je kc_done.arg                  ; a bound notification's label: no sender's
        mov dx, [es:si + SH_BADGE]
        mov cl, [es:si + SH_RIGHTS]
        mov si, [es:si + SH_OBJECT]     ; SI = the endpoint
        mov bx, [cur_thread]
        mov es, bx
        mov al, [ipc_calling]
        mov [es:T_IPC], al
        mov [es:T_BADGE], dx
        cmp word [bp + FRAME_BP], 0
        je .send
        test cl, RIGHT_GRANT
        jz kc_done.arg                  ; no capability through this endpoint
        push si
        push bx
        mov ax, [bp + FRAME_BP]
        mov bx, [es:T_SPACE]
        call slot_of
        jc .no_cap
        mov al, [es:si + SH_TYPE]
        pop bx
        pop si
        cmp al, CAP_EMPTY
        je kc_done.cap
        mov es, bx
        or byte [es:T_IPC], TI_GRANT
.send:
        mov es, bx
        test byte [es:T_IPC], TI_CALLING
        jnz ep_call
        mov es, si
        cmp byte [es:E_KIND], EK_RECV
        jne ep_queue
        ; a receiver waits: the message now
        mov dx, bx                      ; the sender
        call ep_pop                     ; BX = the receiver
        mov si, dx
        call deliver
        call ready_push
        jmp kc_done.ok
.no_cap:
        pop bx
        pop si
        jmp kc_done.cap
.reply:
        ; ES:SI = the saved reply's shadow entry, ES:DI its descriptor, AX
        ; its slot: the caller's back link names it no more
        mov es, [cur_thread]
        mov dx, [es:T_SPACE]            ; DX, CX = its space and slot
        mov cx, ax
        mov bx, dx
        call slot_at                    ; ES:SI, ES:DI again
        mov ax, [es:si + SH_OBJECT]     ; the caller (0: superseded, owed to nobody)
        call reply_unlink
        push si
        push di
        test ax, ax
        stc
        jz .sent
        push es
        mov bx, ax                      ; the caller
        mov cx, [es:si + SH_SEQ]
        mov dx, [es:si + SH_SERVER]
        call reply_send
        pop es
.sent:
        pop di
        pop si
        pushf
        call slot_clear                 ; a reply is sent once
        popf
        jc kc_done.state
        jmp kc_done.ok

; ----------------------------------------------------------------------------
; ep_call - the running thread calls on an endpoint (its message in its
; frame, T_IPC and T_BADGE set): to the first receiver, or queued; it waits
; for the reply, which comes in its frame
;   In:       SI = the endpoint; BX = the running thread
;   Out:      does not return: its T_CONT, then the way back, when it runs
;             again
;   Destroys: everything
; ----------------------------------------------------------------------------
ep_call:
        mov es, si
        cmp byte [es:E_KIND], EK_RECV
        jne ep_queue
        mov dx, bx                      ; the caller
        call ep_pop                     ; BX = the receiver
        mov si, dx
        call deliver
        call ipc_link
        call ipc_wake
        jmp schedule

; ----------------------------------------------------------------------------
; ep_queue - the running thread waits in an endpoint's queue of senders
;   In:       SI = the endpoint (no receiver waits); BX = the running thread
;   Out:      does not return: when it runs again, the receiver (or a
;             cancel) has set its frame's status
;   Destroys: everything
; ----------------------------------------------------------------------------
ep_queue:
        call ep_push
        mov es, si
        mov byte [es:E_KIND], EK_SEND
        mov es, bx
        mov byte [es:T_STATE], TS_SEND
        mov [es:T_WAIT_OBJ], si
        jmp schedule

; ----------------------------------------------------------------------------
; ipc_fault - the running thread's fault, as a call on its fault endpoint
; (l4.md D18): the vector as the label, BX the error code, CX:SI the CS:IP,
; DI the flags, with its capability's badge; it waits for the reply, whose
; BX is where it starts again (fault_resume, when it runs again). A
; THREAD_SUSPEND ends the wait (KE_SUSPENDED), and its registers are as they
; were at the fault, kept meanwhile in T_FAULT_REGS (os-server.md P2)
;   In:       BP = its frame (from rings 1-3); BX = the thread, its T_CONT
;             CONT_FAULT or CONT_FAULT_WAY; DI = FAULT_*
;   Out:      does not return
;   Destroys: everything
; ----------------------------------------------------------------------------
ipc_fault:
        mov es, bx
        mov ax, [bp + FRAME_AX]         ; what the message and its end change
        mov [es:T_FAULT_REGS], ax
        mov ax, [bp + FRAME_BX]
        mov [es:T_FAULT_REGS + 2], ax
        mov ax, [bp + FRAME_CX]
        mov [es:T_FAULT_REGS + 4], ax
        mov ax, [bp + FRAME_DX]
        mov [es:T_FAULT_REGS + 6], ax
        mov ax, [bp + FRAME_SI]
        mov [es:T_FAULT_REGS + 8], ax
        mov ax, [bp + FRAME_DI]
        mov [es:T_FAULT_REGS + 10], ax
        mov ax, [bp + FRAME_BP]
        mov [es:T_FAULT_REGS + 12], ax
        mov ax, [bp + FRAME_FLAGS]
        mov [es:T_FAULT_REGS + 14], ax
        mov ax, [bp + FRAME_VECTOR]
        mov [bp + FRAME_AX], ax
        mov ax, [bp + FRAME_ERROR]
        mov [bp + FRAME_BX], ax
        mov ax, [bp + FRAME_CS]
        mov [bp + FRAME_CX], ax
        mov ax, [bp + FRAME_IP]
        mov [bp + FRAME_SI], ax
        mov [bp + FRAME_DI], di
        mov word [bp + FRAME_BP], 0
        mov byte [es:T_IPC], TI_CALLING | TI_FAULT
        mov ax, [es:T_FAULT_BADGE]
        mov [es:T_BADGE], ax
        mov si, [es:T_FAULT]
        jmp ep_call

; ----------------------------------------------------------------------------
; fault_resume - a thread whose fault's call has ended, when it runs again
; (CONT_FAULT, CONT_FAULT_WAY): restarted at the reply's BX, or as a
; restart left it; or, suspended meanwhile (KE_SUSPENDED), its registers as
; at the fault, and stopped
;   In:       AL = its T_CONT; BX = the thread; BP = its frame; DS =
;             SEL_KDATA; interrupts off
;   Out:      does not return: the way back
;   Destroys: everything
; ----------------------------------------------------------------------------
fault_resume:
        mov es, bx
        and byte [es:T_IPC], ~TI_FAULT & 0xFF
        mov ah, [bp + FRAME_AX]
        cmp ah, KE_SUSPENDED
        je .suspended
        cmp ah, KE_OK
        jne .restart
        mov dx, [bp + FRAME_BX]
        mov [es:T_ENTRY], dx
.restart:
        push ds
        pop es
        call restart_program
        cmp al, CONT_FAULT_WAY
        jne isr_exit
        call way_back_again             ; found by the way back: counted there
        jmp isr_exit.check_segments
.suspended:
        mov ax, [es:T_FAULT_REGS]
        mov [bp + FRAME_AX], ax
        mov ax, [es:T_FAULT_REGS + 2]
        mov [bp + FRAME_BX], ax
        mov ax, [es:T_FAULT_REGS + 4]
        mov [bp + FRAME_CX], ax
        mov ax, [es:T_FAULT_REGS + 6]
        mov [bp + FRAME_DX], ax
        mov ax, [es:T_FAULT_REGS + 8]
        mov [bp + FRAME_SI], ax
        mov ax, [es:T_FAULT_REGS + 10]
        mov [bp + FRAME_DI], ax
        mov ax, [es:T_FAULT_REGS + 12]
        mov [bp + FRAME_BP], ax
        mov ax, [es:T_FAULT_REGS + 14]
        mov [bp + FRAME_FLAGS], ax
        jmp thread_suspended

; ----------------------------------------------------------------------------
; slot_clear - empty a slot: its descriptor and its shadow entry
;   In:       ES = the space; SI = the shadow entry; DI = the descriptor
;   Out:      nothing
;   Destroys: AX, CX, DI
; ----------------------------------------------------------------------------
slot_clear:
        cld
        xor ax, ax
        mov cx, 4
        rep stosw
        mov di, si
        mov cx, SHADOW_SIZE / 2
        rep stosw
        ret

; ----------------------------------------------------------------------------
; kc_reply_recv - KCALL_REPLY_RECV: the reply owed, then a receive
;   In:       BP = the frame (BX CX SI DI the reply, DX, BP as kc_recv)
;   Out:      as kc_recv
;   Destroys: AX, BX, CX, DX, SI, DI, ES
; ----------------------------------------------------------------------------
kc_reply_recv:
        mov dx, [cur_thread]
        mov es, dx
        mov bx, [es:T_REPLY]
        test bx, bx
        jz kc_recv
        mov word [es:T_REPLY], 0
        mov cx, [es:T_REPLY_SEQ]
        call reply_send                 ; a caller that waits no more: nothing
        jmp kc_recv

; ----------------------------------------------------------------------------
; kc_recv - KCALL_RECV: a message from an endpoint (or the bits of the
; thread's bound notification), or a notification's bits; it waits for one
;   In:       BP = the frame (DX the endpoint or notification, BP the
;             receive slot or 0)
;   Out:      the frame: AL the label (NOTIFY_LABEL for a bound
;             notification), DX the badge, BX CX SI DI, BP the capability
;             received; a notification's: BX its bits
;   Destroys: AX, BX, CX, DX, SI, DI, ES
; ----------------------------------------------------------------------------
kc_recv:
        mov byte [ipc_poll], 0
        jmp ipc_recv

; ----------------------------------------------------------------------------
; kc_poll - KCALL_POLL: as kc_recv, but KE_EMPTY at once if nothing is there
;   In:       BP = the frame, as kc_recv's
;   Out:      as kc_recv, or KE_EMPTY
;   Destroys: AX, BX, CX, DX, SI, DI, ES
; ----------------------------------------------------------------------------
kc_poll:
        mov byte [ipc_poll], 1
        ; falls through

; ----------------------------------------------------------------------------
; ipc_recv - the body of kc_recv and kc_poll
;   In:       BP = the frame; ipc_poll
;   Out:      as kc_recv
;   Destroys: AX, BX, CX, DX, SI, DI, ES
; ----------------------------------------------------------------------------
ipc_recv:
        mov ax, [bp + FRAME_DX]
        call cap_lookup
        jc kc_done.cap
        cmp byte [es:si + SH_TYPE], CAP_NOTIFY
        je .notification
        cmp byte [es:si + SH_TYPE], CAP_ENDPOINT
        jne kc_done.cap
        test byte [es:si + SH_RIGHTS], RIGHT_RECV
        jz kc_done.cap
        mov si, [es:si + SH_OBJECT]     ; SI = the endpoint
        mov bx, [cur_thread]
        mov es, bx
        mov ax, [bp + FRAME_BP]         ; the receive slot: 0, or a slot of its own
        mov [es:T_RSLOT], ax
        test ax, ax
        jz .slot_named
        push si
        push bx
        mov bx, [es:T_SPACE]
        call slot_of
        pop bx
        pop si
        jc kc_done.cap
.slot_named:
        mov es, si
        cmp byte [es:E_KIND], EK_SEND
        jne .none
        ; a sender waits: its message now
        mov dx, bx                      ; the receiver
        call ep_pop                     ; BX = the sender
        mov si, bx
        mov bx, dx
        call deliver
        mov es, si
        test byte [es:T_IPC], TI_CALLING
        jz .was_send
        jmp ipc_link                    ; the sender now waits for the reply
.was_send:
        push bx
        mov bx, si
        call thread_frame
        mov al, KE_OK
        call frame_status
        call ready_push
        pop bx
        ret
.none:
        mov es, bx
        mov di, [es:T_BOUND]            ; a bound notification's bits?
        test di, di
        jz .wait
        mov es, di
        mov ax, [es:N_BITS]
        test ax, ax
        jz .wait
        mov word [es:N_BITS], 0
        jmp bound_bits
.wait:
        cmp byte [ipc_poll], 0
        jne kc_done.empty
        call ep_push
        mov es, si
        mov byte [es:E_KIND], EK_RECV
        mov es, bx
        mov byte [es:T_STATE], TS_RECV
        mov [es:T_WAIT_OBJ], si
        jmp schedule                    ; a sender, a signal or a cancel sets the frame
.notification:
        test byte [es:si + SH_RIGHTS], RIGHT_RECV
        jz kc_done.cap
        mov si, [es:si + SH_OBJECT]
        mov es, si
        mov ax, [es:N_BITS]
        test ax, ax
        jz .notify_wait
        mov word [es:N_BITS], 0
        mov [bp + FRAME_BX], ax
        jmp kc_done.ok
.notify_wait:
        cmp byte [ipc_poll], 0
        jne kc_done.empty
        mov bx, [cur_thread]
        cmp word [es:N_WAITER], 0
        jne kc_done.state               ; one waiter at a time
        mov [es:N_WAITER], bx
        mov es, bx
        mov byte [es:T_STATE], TS_NOTIFY
        mov [es:T_WAIT_OBJ], si
        jmp schedule                    ; a signal or a cancel sets the frame

; ----------------------------------------------------------------------------
; bound_bits - a bound notification's bits as a receive's message
;   In:       BX = the thread; AX = the bits
;   Out:      its frame: AL NOTIFY_LABEL, BX the bits, DX 0, BP 0, CF clear
;   Destroys: AX, DI, ES
; ----------------------------------------------------------------------------
bound_bits:
        call thread_frame
        mov [es:di + FRAME_BX], ax
        mov al, NOTIFY_LABEL
        call frame_status
        and word [es:di + FRAME_FLAGS], ~FLAGS_CF
        mov word [es:di + FRAME_DX], 0
        mov word [es:di + FRAME_BP], 0
        ret

; ----------------------------------------------------------------------------
; ntf_signal - bits into a notification: to the thread waiting on it, or to
; the thread bound to it if it waits on an endpoint, or kept
;   In:       SI = the notification; AX = the bits
;   Out:      nothing
;   Destroys: AX
; ----------------------------------------------------------------------------
ntf_signal:
        push bx
        push di
        push es
        mov es, si
        mov bx, [es:N_WAITER]
        test bx, bx
        jz .bound
        mov word [es:N_WAITER], 0
        or ax, [es:N_BITS]
        mov word [es:N_BITS], 0
        call thread_frame
        mov [es:di + FRAME_BX], ax
        mov al, KE_OK
        call frame_status
        call ready_push
        jmp .done
.bound:
        mov bx, [es:N_BOUND]
        test bx, bx
        jz .keep
        mov es, bx
        cmp byte [es:T_STATE], TS_RECV
        mov es, si
        jne .keep
        or ax, [es:N_BITS]              ; it waits on an endpoint: off its queue
        mov word [es:N_BITS], 0
        push ax
        push si
        mov es, bx
        mov si, [es:T_WAIT_OBJ]
        call ep_remove
        pop si
        pop ax
        call bound_bits
        call ready_push
        jmp .done
.keep:
        or [es:N_BITS], ax
.done:
        pop es
        pop di
        pop bx
        ret

; ----------------------------------------------------------------------------
; kc_signal - KCALL_SIGNAL: the capability's badge (1 if it has none) into
; the notification's bits
;   In:       BP = the frame (DX the notification)
;   Out:      the frame's status
;   Destroys: AX, CX, SI, DI, ES
; ----------------------------------------------------------------------------
kc_signal:
        mov ax, [bp + FRAME_DX]
        mov cl, CAP_NOTIFY
        call cap_get
        jc kc_done.cap
        test byte [es:si + SH_RIGHTS], RIGHT_SEND
        jz kc_done.cap
        mov ax, [es:si + SH_BADGE]
        test ax, ax
        jnz .bits
        mov ax, 1
.bits:
        mov si, [es:si + SH_OBJECT]
        call ntf_signal
        jmp kc_done.ok

; ----------------------------------------------------------------------------
; kc_timer - KCALL_TIMER: signal a notification once, CX ticks from now
; (with the capability's badge, or 1); the kernel's answer to timeouts
; (l4.md D6). A notification has one timer at most: arming it again
; replaces the one armed before, so waits that end early leave none behind
;   In:       BP = the frame (DX the notification, CX ticks, 1 or more)
;   Out:      the frame's status (KE_POOL: TIMER_MAX armed already)
;   Destroys: AX, BX, CX, SI, DI, ES
; ----------------------------------------------------------------------------
kc_timer:
        mov ax, [bp + FRAME_DX]
        mov cl, CAP_NOTIFY
        call cap_get
        jc kc_done.cap
        test byte [es:si + SH_RIGHTS], RIGHT_SEND
        jz kc_done.cap
        cmp word [bp + FRAME_CX], 0
        je kc_done.arg
        cmp word [bp + FRAME_CX], TIMER_TICKS_MAX
        ja kc_done.arg                  ; (a due tick is compared signed)
        mov bx, [es:si + SH_BADGE]
        mov ax, [es:si + SH_OBJECT]
        mov di, timers                  ; its own timer, armed again
        mov cx, TIMER_MAX
.own:
        cmp [di + TM_NOTIFY], ax
        je .found
        add di, TIMER_SIZE
        loop .own
        mov di, timers                  ; else a free one
        mov cx, TIMER_MAX
.free:
        cmp word [di + TM_NOTIFY], 0
        je .found
        add di, TIMER_SIZE
        loop .free
        jmp kc_done.pool
.found:
        test bx, bx
        jnz .bits
        mov bx, 1
.bits:
        mov [di + TM_BITS], bx
        mov [di + TM_NOTIFY], ax
        mov ax, [ticks]
        add ax, [bp + FRAME_CX]
        mov [di + TM_DUE], ax
        jmp kc_done.ok

; ----------------------------------------------------------------------------
; timers_tick - every tick: signal each timer that is due
;   In:       DS = SEL_KDATA; interrupts off
;   Out:      nothing
;   Destroys: nothing
; ----------------------------------------------------------------------------
timers_tick:
        push ax
        push cx
        push si
        push di
        mov di, timers
        mov cx, TIMER_MAX
.timer:
        mov si, [di + TM_NOTIFY]
        test si, si
        jz .next
        mov ax, [ticks]
        sub ax, [di + TM_DUE]
        js .next                        ; not yet (within 32,767 ticks)
        mov word [di + TM_NOTIFY], 0
        mov ax, [di + TM_BITS]
        call ntf_signal
.next:
        add di, TIMER_SIZE
        loop .timer
        pop di
        pop si
        pop cx
        pop ax
        ret

; ----------------------------------------------------------------------------
; kc_delete - KCALL_DELETE: empty a slot of the caller's; its children
; become its parent's, and the last capability to an object takes the
; object with it (revoke.asm; l4.md L12)
;   In:       BP = the frame (DX the slot)
;   Out:      the frame's status
;   Destroys: AX, BX, CX, SI, DI, ES
; ----------------------------------------------------------------------------
kc_delete:
        mov es, [cur_thread]
        cmp byte [es:T_CONT], CONT_RESUMED
        je kc_done.ok                   ; deleted, and the dead spaces emptied since
        mov bx, [es:T_SPACE]
        mov ax, [bp + FRAME_DX]
        call slot_of
        jc kc_done.cap
        cmp byte [es:si + SH_TYPE], CAP_EMPTY
        je kc_done.cap
        call cap_delete_at              ; BX, AX: the space and slot (revoke.asm)
        call dead_flush
        jmp kc_done.ok

; ----------------------------------------------------------------------------
; kc_save_reply - KCALL_SAVE_REPLY: the reply the caller owes, into an empty
; slot as a capability, so that it can receive again and answer later
;   In:       BP = the frame (SI the slot)
;   Out:      the frame's status (KE_STATE: no reply owed)
;   Destroys: AX, BX, CX, DX, SI, DI, ES
; ----------------------------------------------------------------------------
kc_save_reply:
        mov bx, [cur_thread]
        mov es, bx
        mov di, [es:T_REPLY]            ; DI = the caller
        test di, di
        jz kc_done.state
        mov dx, [es:T_SPACE]
        mov ax, [bp + FRAME_SI]
        push di
        push bx
        mov bx, dx
        call slot_of                    ; ES = its space; AX = the slot
        pop bx
        pop di
        jc kc_done.cap
        cmp byte [es:si + SH_TYPE], CAP_EMPTY
        jne kc_done.slot
        mov byte [es:si + SH_TYPE], CAP_REPLY
        mov [es:si + SH_OBJECT], di
        mov [es:si + SH_SERVER], bx
        push es
        mov es, bx
        mov cx, [es:T_REPLY_SEQ]
        mov word [es:T_REPLY], 0
        pop es
        mov [es:si + SH_SEQ], cx
        mov cx, ax                      ; DX, CX = the slot
        push bx
        mov es, di                      ; an older reply saved for it is stale:
        mov bx, [es:T_SAVED_SPACE]      ; it is owed to nobody now, and the
        test bx, bx                     ; caller's back link names this one
        jz .linked
        mov ax, [es:T_SAVED_SLOT]
        call shadow_at                  ; ES:SI = that one's shadow entry
        mov word [es:si + SH_OBJECT], 0
        mov es, di
.linked:
        pop bx
        mov [es:T_SAVED_SPACE], dx
        mov [es:T_SAVED_SLOT], cx
        jmp kc_done.ok

; ----------------------------------------------------------------------------
; ipc_cancel - a thread waiting in IPC wakes with KE_STATE, out of any
; queue: to restart (Ctrl+Break, a 287 error)
;   In:       BX = the thread (not the running one)
;   Out:      nothing
;   Destroys: nothing
; ----------------------------------------------------------------------------
ipc_cancel:
        push ax
        mov al, KE_STATE
        call ipc_fail
        pop ax
        ret

; ----------------------------------------------------------------------------
; ipc_fail - as ipc_cancel, with a status of the caller's choice: KE_CAP
; when the endpoint or notification it waits on, or the thread whose reply
; it awaits, has died (revoke.asm)
;   In:       BX = the thread; AL = the status; DS = SEL_KDATA; interrupts off
;   Out:      nothing
;   Destroys: nothing
; ----------------------------------------------------------------------------
ipc_fail:
        push ax
        push si
        push di
        push es
        mov ah, al                      ; AH = the status
        mov es, bx
        mov al, [es:T_STATE]
        mov si, [es:T_WAIT_OBJ]
        cmp al, TS_SEND
        je .queued
        cmp al, TS_RECV
        je .queued
        cmp al, TS_NOTIFY
        je .notify
        cmp al, TS_REPLY
        je .wake
        jmp .done                       ; not waiting in IPC
.queued:
        push ax
        call ep_remove                  ; (AX: AH the status)
        pop ax
        jmp .wake
.notify:
        mov es, si
        cmp [es:N_WAITER], bx
        jne .wake
        mov word [es:N_WAITER], 0
.wake:
        call thread_frame
        mov al, ah
        call frame_status
        call ready_push
.done:
        pop es
        pop di
        pop si
        pop ax
        ret

; ----------------------------------------------------------------------------
; ipc_reset - the running thread's program starts again: a reply it owes
; will not come (its caller gets KE_STATE)
;   In:       DS = SEL_KDATA; interrupts off
;   Out:      nothing
;   Destroys: nothing
; ----------------------------------------------------------------------------
ipc_reset:
        push ax
        push bx
        push cx
        push dx
        push di
        mov bx, [cur_thread]
        call reply_abandon
        pop di
        pop dx
        pop cx
        pop bx
        pop ax
        ret
