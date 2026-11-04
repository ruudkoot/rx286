; ============================================================================
; rx286 - src/kernel/ipc.asm
; Synchronous IPC: endpoints, notifications, replies, the kernel's timer
; (roadmap l4.md L4; D5, D6).
;
; A message is a label (AL) and four words (BX, CX, SI, DI), with the badge
; of the sender's capability (DX) and at most one capability (named by the
; sender's BP, landing in the slot the receiver named by its BP; l4.md D5).
; Nothing but registers is copied: a sender's message is in its frame, at
; the top of its kernel stack in the arena, and delivery writes it into the
; receiver's frame. An endpoint holds a queue of senders or of receivers;
; whoever comes second does the transfer. A call leaves the receiver owing a
; reply: a link in its control block, which it may save into a slot and
; answer later; a sequence number keeps a stale reply from answering a later
; call (E10). A notification is a word of bits: a signal ORs the
; capability's badge into it; a receive returns and clears it, and a thread
; bound to it gets its bits even while it waits on an endpoint. There are no
; timeouts (l4.md D6): the kernel's timer signals a notification. A thread
; waits for IPC inside its own kernel call, on its own kernel stack; a
; restart (Ctrl+Break, a 287 error) takes it out of any queue.
; ============================================================================

TIMER_MAX           equ 8               ; timers armed at once
TIMER_SIZE          equ 6
TM_NOTIFY           equ 0               ; the notification, or 0: free
TM_BITS             equ 2
TM_DUE              equ 4               ; the tick (its low word) it fires at

begin_kdata
timers              times TIMER_MAX * TIMER_SIZE db 0
ipc_calling         db 0                ; TI_CALLING for KCALL_CALL, 0 for KCALL_SEND
ipc_poll            db 0                ; 1 for KCALL_POLL
dl_sender_frame     dw 0                ; deliver's temporaries
dl_receiver_frame   dw 0
dl_shadow           dw 0
dl_slot             dw 0
end_kdata

; ----------------------------------------------------------------------------
; thread_frame - where a thread's frame is: the top of its kernel stack,
; since every kernel call comes from ring 3
;   In:       BX = the thread
;   Out:      DI = its frame (kdata)
;   Destroys: nothing
; ----------------------------------------------------------------------------
thread_frame:
        lea di, [bx + TCB_OBJECT_SIZE - FRAME_SIZE_USER]
        ret

; ----------------------------------------------------------------------------
; frame_status - a status into a frame: AX (AH 0), CF if not KE_OK
;   In:       DI = the frame; AL = KE_*
;   Out:      nothing
;   Destroys: AH
; ----------------------------------------------------------------------------
frame_status:
        xor ah, ah
        mov [di + FRAME_AX], ax
        and word [di + FRAME_FLAGS], ~FLAGS_CF
        test al, al
        jz .done
        or word [di + FRAME_FLAGS], FLAGS_CF
.done:
        ret

; ----------------------------------------------------------------------------
; ep_push - a thread to the tail of an endpoint's queue
;   In:       SI = the endpoint; BX = the thread
;   Out:      nothing
;   Destroys: AX
; ----------------------------------------------------------------------------
ep_push:
        mov word [bx + T_NEXT], 0
        mov ax, [si + E_TAIL]
        test ax, ax
        jz .first
        push di
        mov di, ax
        mov [di + T_NEXT], bx
        pop di
        jmp .tail
.first:
        mov [si + E_HEAD], bx
.tail:
        mov [si + E_TAIL], bx
        ret

; ----------------------------------------------------------------------------
; ep_pop - the head of an endpoint's queue, taken out (idle once empty)
;   In:       SI = the endpoint (its queue not empty)
;   Out:      BX = the thread
;   Destroys: AX
; ----------------------------------------------------------------------------
ep_pop:
        mov bx, [si + E_HEAD]
        mov ax, [bx + T_NEXT]
        mov [si + E_HEAD], ax
        test ax, ax
        jnz .done
        mov word [si + E_TAIL], 0
        mov byte [si + E_KIND], EK_IDLE
.done:
        ret

; ----------------------------------------------------------------------------
; ep_remove - a thread out of an endpoint's queue, wherever it is
;   In:       SI = the endpoint; BX = the thread (in its queue)
;   Out:      nothing
;   Destroys: AX
; ----------------------------------------------------------------------------
ep_remove:
        push di
        xor di, di                      ; DI = the one before it
        mov ax, [si + E_HEAD]
.find:
        test ax, ax
        jz .done                        ; not there after all
        cmp ax, bx
        je .found
        mov di, ax
        mov ax, [di + T_NEXT]
        jmp .find
.found:
        mov ax, [bx + T_NEXT]
        test di, di
        jz .head
        mov [di + T_NEXT], ax
        jmp .tail
.head:
        mov [si + E_HEAD], ax
.tail:
        cmp [si + E_TAIL], bx
        jne .done
        mov [si + E_TAIL], di
.done:
        cmp word [si + E_HEAD], 0
        jne .out
        mov word [si + E_TAIL], 0
        mov byte [si + E_KIND], EK_IDLE
.out:
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
;   Destroys: AX, CX, DX, DI
; ----------------------------------------------------------------------------
deliver:
        push si
        push bx
        mov bx, si
        call thread_frame
        mov [dl_sender_frame], di
        pop bx
        push bx
        call thread_frame
        mov [dl_receiver_frame], di
        mov si, [dl_sender_frame]
        mov ax, [si + FRAME_BX]
        mov [di + FRAME_BX], ax
        mov ax, [si + FRAME_CX]
        mov [di + FRAME_CX], ax
        mov ax, [si + FRAME_SI]
        mov [di + FRAME_SI], ax
        mov ax, [si + FRAME_DI]
        mov [di + FRAME_DI], ax
        mov al, [si + FRAME_AX]         ; the label
        call frame_status               ; (AH 0, CF clear: a label is not an error)
        and word [di + FRAME_FLAGS], ~FLAGS_CF
        pop bx
        pop si
        push si
        push bx
        mov ax, [si + T_BADGE]
        mov [di + FRAME_DX], ax
        mov word [di + FRAME_BP], 0
        test byte [si + T_IPC], TI_GRANT
        jz .done
        cmp word [bx + T_RSLOT], 0
        je .done
        ; the destination: the receiver's slot, empty
        push si
        mov ax, [bx + T_RSLOT]
        mov bx, [bx + T_SPACE]
        call slot_of                    ; SI, DI
        mov [dl_shadow], si
        mov dx, di
        pop si
        jc .done
        mov di, [dl_shadow]
        cmp byte [di + SH_TYPE], CAP_EMPTY
        jne .done
        ; the source: the sender's slot, not empty
        mov di, [dl_sender_frame]
        mov ax, [di + FRAME_BP]
        mov bx, [si + T_SPACE]
        call slot_of                    ; AX = its slot; SI, DI
        jc .done
        cmp byte [si + SH_TYPE], CAP_EMPTY
        je .done
        mov [dl_slot], ax
        push ds
        pop es
        cld
        push si
        mov si, di                      ; the descriptor, 8 bytes
        mov di, dx
        mov cx, 4
        rep movsw
        pop si
        mov di, [dl_shadow]             ; the shadow entry, 16 bytes
        mov cx, SHADOW_SIZE / 2
        rep movsw
        mov di, [dl_shadow]
        mov [di + SH_PARENT], bx        ; its parent: the sender's space and slot
        mov ax, [dl_slot]
        mov [di + SH_PARENT_SLOT], ax
        pop bx                          ; the receiver: BP = the selector, at its ring
        push bx
        mov ax, [bx + T_RSLOT]
        and ax, ~CPL_MASK
        or al, [bx + T_RING]
        mov di, [dl_receiver_frame]
        mov [di + FRAME_BP], ax
.done:
        pop bx
        pop si
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
        inc word [si + T_CALLS]
        mov ax, [si + T_CALLS]
        mov [bx + T_REPLY], si
        mov [bx + T_REPLY_SEQ], ax
        mov byte [si + T_STATE], TS_REPLY
        mov [si + T_WAIT_OBJ], bx
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
        mov si, bx
        mov bx, [si + T_REPLY]
        test bx, bx
        jz .done
        mov word [si + T_REPLY], 0
        mov cx, [si + T_REPLY_SEQ]
        mov dx, si
        call reply_valid
        jc .done
        call thread_frame
        mov al, KE_STATE
        call frame_status
        call ready_push
.done:
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
        cmp byte [bx + T_STATE], TS_REPLY
        jne .stale
        cmp [bx + T_WAIT_OBJ], dx
        jne .stale
        cmp [bx + T_CALLS], cx
        jne .stale
        clc
        ret
.stale:
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
        push si
        mov si, [cur_thread]
        mov al, [bx + T_PRIO]
        cmp al, [si + T_PRIO]
        pop si
        jb ready_push
        jmp ready_first

; ----------------------------------------------------------------------------
; reply_send - a reply: four words into the caller's frame, which wakes
;   In:       BX = the caller; CX = the T_CALLS it had; DX = the server;
;             SI = the frame the reply's words are in, as an offset of kdata
;             (thread_frame: never BP, an offset of a kernel stack's segment)
;   Out:      CF clear if delivered; CF set if the caller waits no more
;   Destroys: AX, DI
; ----------------------------------------------------------------------------
reply_send:
        call reply_valid
        jc .done
        call thread_frame
        mov ax, [si + FRAME_BX]
        mov [di + FRAME_BX], ax
        mov ax, [si + FRAME_CX]
        mov [di + FRAME_CX], ax
        mov ax, [si + FRAME_SI]
        mov [di + FRAME_SI], ax
        mov ax, [si + FRAME_DI]
        mov [di + FRAME_DI], ax
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
;   Destroys: AX, BX, CX, DX, SI, DI
; ----------------------------------------------------------------------------
kc_call:
        mov byte [ipc_calling], TI_CALLING
        jmp ipc_send

; ----------------------------------------------------------------------------
; kc_send - KCALL_SEND: a message on an endpoint, with no reply; on a saved
; reply, that reply
;   In:       BP = the frame, as kc_call's
;   Out:      the frame's status
;   Destroys: AX, BX, CX, DX, SI, DI
; ----------------------------------------------------------------------------
kc_send:
        mov byte [ipc_calling], 0
        ; falls through

; ----------------------------------------------------------------------------
; ipc_send - the body of kc_call and kc_send
;   In:       BP = the frame; ipc_calling
;   Out:      as kc_call
;   Destroys: AX, BX, CX, DX, SI, DI
; ----------------------------------------------------------------------------
ipc_send:
        mov ax, [bp + FRAME_DX]
        mov cl, CAP_REPLY
        call cap_get
        jnc .reply
        mov ax, [bp + FRAME_DX]
        mov cl, CAP_ENDPOINT
        call cap_get
        jc kc_done.cap
        test byte [si + SH_RIGHTS], RIGHT_SEND
        jz kc_done.cap
        cmp byte [bp + FRAME_AX], NOTIFY_LABEL
        je kc_done.arg                  ; a bound notification's label: no sender's
        mov bx, [cur_thread]
        mov al, [ipc_calling]
        mov [bx + T_IPC], al
        mov ax, [si + SH_BADGE]
        mov [bx + T_BADGE], ax
        cmp word [bp + FRAME_BP], 0
        je .send
        test byte [si + SH_RIGHTS], RIGHT_GRANT
        jz kc_done.arg                  ; no capability through this endpoint
        push si
        push bx
        mov ax, [bp + FRAME_BP]
        mov bx, [bx + T_SPACE]
        call slot_of
        mov al, [si + SH_TYPE]
        pop bx
        pop si
        jc kc_done.cap
        cmp al, CAP_EMPTY
        je kc_done.cap
        or byte [bx + T_IPC], TI_GRANT
.send:
        mov si, [si + SH_OBJECT]        ; the endpoint
        test byte [bx + T_IPC], TI_CALLING
        jnz ep_call
        cmp byte [si + E_KIND], EK_RECV
        jne ep_queue
        ; a receiver waits: the message now
        mov dx, bx                      ; the sender
        call ep_pop                     ; BX = the receiver
        mov si, dx
        call deliver
        call ready_push
        jmp kc_done.ok
.reply:
        push si
        push di
        mov bx, [cur_thread]
        call thread_frame               ; the reply's words: this frame's, as kdata
        mov bx, [si + SH_OBJECT]        ; the caller
        mov cx, [si + SH_SEQ]
        mov dx, [si + SH_SERVER]
        mov si, di
        call reply_send
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
;   Out:      returns when it runs again
;   Destroys: AX, BX, CX, DX, SI, DI
; ----------------------------------------------------------------------------
ep_call:
        cmp byte [si + E_KIND], EK_RECV
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
;   Out:      returns when it runs again: the receiver (or a cancel) has set
;             its frame's status
;   Destroys: AX
; ----------------------------------------------------------------------------
ep_queue:
        call ep_push
        mov byte [si + E_KIND], EK_SEND
        mov byte [bx + T_STATE], TS_SEND
        mov [bx + T_WAIT_OBJ], si
        jmp schedule

; ----------------------------------------------------------------------------
; ipc_fault - the running thread's fault, as a call on its fault endpoint
; (l4.md D18): the vector as the label, BX the error code, CX:SI the CS:IP,
; DI the flags, with its capability's badge; it waits for the reply, whose
; BX is where it starts again
;   In:       BP = its frame (from rings 1-3); BX = the thread; DI = FAULT_*
;   Out:      its T_ENTRY the reply's BX, if a reply came (KE_STATE: a
;             restart cancelled the wait)
;   Destroys: AX, BX, CX, DX, SI, DI
; ----------------------------------------------------------------------------
ipc_fault:
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
        mov byte [bx + T_IPC], TI_CALLING
        mov ax, [bx + T_FAULT_BADGE]
        mov [bx + T_BADGE], ax
        mov si, [bx + T_FAULT]
        call ep_call
        cmp byte [bp + FRAME_AX], KE_OK
        jne .done
        mov bx, [cur_thread]
        mov ax, [bp + FRAME_BX]
        mov [bx + T_ENTRY], ax
.done:
        ret

; ----------------------------------------------------------------------------
; slot_clear - empty a slot: its descriptor and its shadow entry
;   In:       SI = the shadow entry; DI = the descriptor
;   Out:      nothing
;   Destroys: AX, CX, DI, ES
; ----------------------------------------------------------------------------
slot_clear:
        push ds
        pop es
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
;   Destroys: AX, BX, CX, DX, SI, DI
; ----------------------------------------------------------------------------
kc_reply_recv:
        mov dx, [cur_thread]
        mov si, dx
        mov bx, [si + T_REPLY]
        test bx, bx
        jz kc_recv
        mov word [si + T_REPLY], 0
        mov cx, [si + T_REPLY_SEQ]
        push bx
        mov bx, dx
        call thread_frame               ; the reply's words: this frame's, as kdata
        mov si, di                      ; (BP is an offset of the kernel stack's segment)
        pop bx
        call reply_send                 ; a caller that waits no more: nothing
        ; falls into kc_recv... through its entry
        jmp kc_recv

; ----------------------------------------------------------------------------
; kc_recv - KCALL_RECV: a message from an endpoint (or the bits of the
; thread's bound notification), or a notification's bits; it waits for one
;   In:       BP = the frame (DX the endpoint or notification, BP the
;             receive slot or 0)
;   Out:      the frame: AL the label (NOTIFY_LABEL for a bound
;             notification), DX the badge, BX CX SI DI, BP the capability
;             received; a notification's: BX its bits
;   Destroys: AX, BX, CX, DX, SI, DI
; ----------------------------------------------------------------------------
kc_recv:
        mov byte [ipc_poll], 0
        jmp ipc_recv

; ----------------------------------------------------------------------------
; kc_poll - KCALL_POLL: as kc_recv, but KE_EMPTY at once if nothing is there
;   In:       BP = the frame, as kc_recv's
;   Out:      as kc_recv, or KE_EMPTY
;   Destroys: AX, BX, CX, DX, SI, DI
; ----------------------------------------------------------------------------
kc_poll:
        mov byte [ipc_poll], 1
        ; falls through

; ----------------------------------------------------------------------------
; ipc_recv - the body of kc_recv and kc_poll
;   In:       BP = the frame; ipc_poll
;   Out:      as kc_recv
;   Destroys: AX, BX, CX, DX, SI, DI
; ----------------------------------------------------------------------------
ipc_recv:
        mov ax, [bp + FRAME_DX]
        mov cl, CAP_NOTIFY
        call cap_get
        jnc .notification
        mov ax, [bp + FRAME_DX]
        mov cl, CAP_ENDPOINT
        call cap_get
        jc kc_done.cap
        test byte [si + SH_RIGHTS], RIGHT_RECV
        jz kc_done.cap
        mov bx, [cur_thread]
        mov ax, [bp + FRAME_BP]         ; the receive slot: 0, or a slot of its own
        mov [bx + T_RSLOT], ax
        test ax, ax
        jz .slot_named
        push si
        push bx
        mov bx, [bx + T_SPACE]
        call slot_of
        pop bx
        pop si
        jc kc_done.cap
.slot_named:
        mov si, [si + SH_OBJECT]        ; the endpoint
        cmp byte [si + E_KIND], EK_SEND
        jne .none
        ; a sender waits: its message now
        mov dx, bx                      ; the receiver
        call ep_pop                     ; BX = the sender
        mov si, bx
        mov bx, dx
        call deliver
        test byte [si + T_IPC], TI_CALLING
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
        mov di, [bx + T_BOUND]          ; a bound notification's bits?
        test di, di
        jz .wait
        mov ax, [di + N_BITS]
        test ax, ax
        jz .wait
        mov word [di + N_BITS], 0
        jmp bound_bits
.wait:
        cmp byte [ipc_poll], 0
        jne kc_done.empty
        call ep_push
        mov byte [si + E_KIND], EK_RECV
        mov byte [bx + T_STATE], TS_RECV
        mov [bx + T_WAIT_OBJ], si
        jmp schedule                    ; a sender, a signal or a cancel sets the frame
.notification:
        test byte [si + SH_RIGHTS], RIGHT_RECV
        jz kc_done.cap
        mov si, [si + SH_OBJECT]
        mov ax, [si + N_BITS]
        test ax, ax
        jz .notify_wait
        mov word [si + N_BITS], 0
        mov [bp + FRAME_BX], ax
        jmp kc_done.ok
.notify_wait:
        cmp byte [ipc_poll], 0
        jne kc_done.empty
        mov bx, [cur_thread]
        cmp word [si + N_WAITER], 0
        jne kc_done.state               ; one waiter at a time
        mov [si + N_WAITER], bx
        mov byte [bx + T_STATE], TS_NOTIFY
        mov [bx + T_WAIT_OBJ], si
        jmp schedule                    ; a signal or a cancel sets the frame

; ----------------------------------------------------------------------------
; bound_bits - a bound notification's bits as a receive's message
;   In:       BX = the thread; AX = the bits
;   Out:      its frame: AL NOTIFY_LABEL, BX the bits, DX 0, BP 0, CF clear
;   Destroys: AX, DI
; ----------------------------------------------------------------------------
bound_bits:
        call thread_frame
        mov [di + FRAME_BX], ax
        mov al, NOTIFY_LABEL
        call frame_status
        and word [di + FRAME_FLAGS], ~FLAGS_CF
        mov word [di + FRAME_DX], 0
        mov word [di + FRAME_BP], 0
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
        mov bx, [si + N_WAITER]
        test bx, bx
        jz .bound
        mov word [si + N_WAITER], 0
        or ax, [si + N_BITS]
        mov word [si + N_BITS], 0
        call thread_frame
        mov [di + FRAME_BX], ax
        mov al, KE_OK
        call frame_status
        call ready_push
        jmp .done
.bound:
        mov bx, [si + N_BOUND]
        test bx, bx
        jz .keep
        cmp byte [bx + T_STATE], TS_RECV
        jne .keep
        or ax, [si + N_BITS]            ; it waits on an endpoint: off its queue
        mov word [si + N_BITS], 0
        push ax
        push si
        mov si, [bx + T_WAIT_OBJ]
        call ep_remove
        pop si
        pop ax
        call bound_bits
        call ready_push
        jmp .done
.keep:
        or [si + N_BITS], ax
.done:
        pop di
        pop bx
        ret

; ----------------------------------------------------------------------------
; kc_signal - KCALL_SIGNAL: the capability's badge (1 if it has none) into
; the notification's bits
;   In:       BP = the frame (DX the notification)
;   Out:      the frame's status
;   Destroys: AX, CX, SI, DI
; ----------------------------------------------------------------------------
kc_signal:
        mov ax, [bp + FRAME_DX]
        mov cl, CAP_NOTIFY
        call cap_get
        jc kc_done.cap
        test byte [si + SH_RIGHTS], RIGHT_SEND
        jz kc_done.cap
        mov ax, [si + SH_BADGE]
        test ax, ax
        jnz .bits
        mov ax, 1
.bits:
        mov si, [si + SH_OBJECT]
        call ntf_signal
        jmp kc_done.ok

; ----------------------------------------------------------------------------
; kc_timer - KCALL_TIMER: signal a notification once, CX ticks from now
; (with the capability's badge, or 1); the kernel's answer to timeouts
; (l4.md D6)
;   In:       BP = the frame (DX the notification, CX ticks, 1 or more)
;   Out:      the frame's status (KE_POOL: TIMER_MAX armed already)
;   Destroys: AX, BX, CX, SI, DI
; ----------------------------------------------------------------------------
kc_timer:
        mov ax, [bp + FRAME_DX]
        mov cl, CAP_NOTIFY
        call cap_get
        jc kc_done.cap
        test byte [si + SH_RIGHTS], RIGHT_SEND
        jz kc_done.cap
        cmp word [bp + FRAME_CX], 0
        je kc_done.arg
        mov di, timers
        mov cx, TIMER_MAX
.free:
        cmp word [di + TM_NOTIFY], 0
        je .found
        add di, TIMER_SIZE
        loop .free
        jmp kc_done.pool
.found:
        mov ax, [si + SH_BADGE]
        test ax, ax
        jnz .bits
        mov ax, 1
.bits:
        mov [di + TM_BITS], ax
        mov ax, [ticks]
        add ax, [bp + FRAME_CX]
        mov [di + TM_DUE], ax
        mov ax, [si + SH_OBJECT]
        mov [di + TM_NOTIFY], ax
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
; kc_delete - KCALL_DELETE: empty a slot of the caller's (what it named
; lives on: revocation is L12's)
;   In:       BP = the frame (DX the slot)
;   Out:      the frame's status
;   Destroys: AX, BX, CX, SI, DI, ES
; ----------------------------------------------------------------------------
kc_delete:
        mov ax, [bp + FRAME_DX]
        mov bx, [cur_thread]
        mov bx, [bx + T_SPACE]
        call slot_of
        jc kc_done.cap
        cmp byte [si + SH_TYPE], CAP_EMPTY
        je kc_done.cap
        call slot_clear
        jmp kc_done.ok

; ----------------------------------------------------------------------------
; kc_save_reply - KCALL_SAVE_REPLY: the reply the caller owes, into an empty
; slot as a capability, so that it can receive again and answer later
;   In:       BP = the frame (SI the slot)
;   Out:      the frame's status (KE_STATE: no reply owed)
;   Destroys: AX, BX, CX, SI, DI
; ----------------------------------------------------------------------------
kc_save_reply:
        mov bx, [cur_thread]
        cmp word [bx + T_REPLY], 0
        je kc_done.state
        mov ax, [bp + FRAME_SI]
        push bx
        mov bx, [bx + T_SPACE]
        call slot_of
        pop bx
        jc kc_done.cap
        cmp byte [si + SH_TYPE], CAP_EMPTY
        jne kc_done.slot
        mov byte [si + SH_TYPE], CAP_REPLY
        mov ax, [bx + T_REPLY]
        mov [si + SH_OBJECT], ax
        mov [si + SH_SERVER], bx
        mov ax, [bx + T_REPLY_SEQ]
        mov [si + SH_SEQ], ax
        mov word [bx + T_REPLY], 0
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
        push si
        push di
        mov al, [bx + T_STATE]
        mov si, [bx + T_WAIT_OBJ]
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
        call ep_remove
        jmp .wake
.notify:
        cmp [si + N_WAITER], bx
        jne .wake
        mov word [si + N_WAITER], 0
.wake:
        call thread_frame
        mov al, KE_STATE
        call frame_status
        call ready_push
.done:
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
