; ============================================================================
; rx286 - src/kernel/thread.asm
; Threads: their control blocks, the switch, the scheduler, the idle loop,
; waiting, and the lock around the log (roadmap l4.md L2, L10).
;
; Each thread runs a program in rings 1-3 with an LDT of its own. The kernel
; has one stack (roadmap os-server.md P3, D9 B; l4.md D3 B): SP0 points at
; the end of the running thread's control block, so every interrupt from
; its ring builds its frame there, and the kernel then works on its stack,
; SEL_KSTACK, which is empty whenever a thread runs in its ring. Nothing of
; a thread's stays on it: schedule never returns to its caller, and what a
; thread still has to do in the kernel when it runs again is its T_CONT -
; nothing but the way back, its program's first start, the rest of its
; fault's call, or the rest of a kernel call (dispatch). One TSS, a
; software switch (D2). Eight fixed priorities, round robin within each on
; SLICE_TICKS (D9); a table gives the highest non-empty queue, since the 286
; has no BSF. When no thread is ready the kernel idles on its stack.
;
; A thread waits inside the kernel only for its turn at the log, and then
; only until the next interrupt: every IRQ wakes every waiting thread, which
; calls again (call_enter; l4.md X15). Every other wait is IPC's, whose
; results its waker writes into its frame. Preemption happens on the way
; back to its ring and at the kernel's own interrupt windows (kpreempt),
; where the call gives way and is resumed later (CONT_KCALL), never in the
; middle of a handler.
; ============================================================================

begin_kdata
; The kernel's own context: the start, then the idle loop, on SEL_KSTACK.
; (Threads are objects of the arena: cap.asm makes them.)
idle_tcb:
        dw 0, 0                         ; T_CONT, T_LOG_DONE
        db TS_RUNNING, 0                ; T_STATE, T_PRIO
        dw 0, SEL_NULL, 0, 0            ; T_NEXT, T_LDT (none), T_ZERO_PARAS, T_USTACK_TOP
        db 0, 0                         ; T_RESTART, T_FPU_VALID
        dw msg_thread_idle              ; T_NAME
        times TCB_SIZE - T_SLICE db 0
cur_thread          dw idle_tcb         ; the thread running
fg_thread           dw idle_tcb         ; START_FOREGROUND's: the test hooks follow it
call_owner          dw 0                ; the thread writing to the log, or 0
resched             db 0                ; a thread should give way: at the next chance
ready_mask          db 0                ; bit n: queue n is not empty
rq_head             times PRIORITIES dw 0
rq_tail             times PRIORITIES dw 0
msg_thread_idle     db "idle", 0
; prio_table - for a mask of non-empty queues, the highest priority in it
prio_table:
%assign m 0
%rep 256
  %assign h 0
  %assign b 0
  %rep PRIORITIES
    %if m & (1 << b)
      %assign h b
    %endif
    %assign b b + 1
  %endrep
        db h
  %assign m m + 1
%endrep
end_kdata


; ----------------------------------------------------------------------------
; threads_start - start the root's thread, which builds and starts every
; other (roadmap l4.md L5), and become the idle loop
;   In:       on the kernel stack (SEL_KSTACK), interrupts off; DS = SEL_KDATA
;   Out:      does not return
;   Destroys: everything
; ----------------------------------------------------------------------------
threads_start:
        mov byte [con_off], 1           ; the screen: the console driver's from now
        call boot_root                  ; BX = its thread (cap.asm)
        call thread_init
        TRACE "kernel: the root ready"
        ; falls through

; ----------------------------------------------------------------------------
; idle_loop - run the best ready thread; when there is none, halt with
; interrupts on until one is (on the kernel's stack, which nothing of a
; thread's is on: l4.md X8)
;   In:       cur_thread = idle_tcb; interrupts off; DS = SEL_KDATA
;   Out:      does not return
;   Destroys: everything
; ----------------------------------------------------------------------------
idle_loop:
        mov sp, KSTACK_TOP
        mov byte [resched], 0
        call ready_pop
        test bx, bx
        jnz dispatch
        STRETCH_END
        sti
        hlt
        cli
        STRETCH_BEGIN 0xFFFF
        jmp idle_loop

; ----------------------------------------------------------------------------
; thread_init - make a thread ready to start its program at its entry: its
; frame as an interrupt from its ring would leave it, its first start to do
;   In:       BX = the thread; DS = ES = SEL_KDATA; interrupts off
;   Out:      the thread in its ready queue
;   Destroys: AX, CX, DI
; ----------------------------------------------------------------------------
thread_init:
        lea di, [bx + T_FRAME]
        xor ax, ax
        mov cx, FRAME_SIZE_USER / 2
        cld
        rep stosw
        ; slots 0, 1, 2 of its space: code, data, stack, at its ring
        mov al, [bx + T_RING]
        xor ah, ah
        or ax, SEL_UDATA & ~CPL_MASK
        mov [bx + T_FRAME + FRAME_ES], ax
        mov [bx + T_FRAME + FRAME_DS], ax
        add ax, SEL_USTACK - SEL_UDATA
        mov [bx + T_FRAME + FRAME_USER_SS], ax
        sub ax, SEL_USTACK - SEL_UCODE
        mov [bx + T_FRAME + FRAME_CS], ax
        mov ax, [bx + T_ENTRY]
        mov [bx + T_FRAME + FRAME_IP], ax
        call thread_flags
        mov [bx + T_FRAME + FRAME_FLAGS], ax
        mov ax, [bx + T_USTACK_TOP]
        mov [bx + T_FRAME + FRAME_USER_SP], ax
        mov byte [bx + T_CONT], CONT_FIRST
        jmp ready_push

; ----------------------------------------------------------------------------
; thread_flags - the FLAGS a thread's program starts with: IF on, IOPL 1 if
; it is a ring-1 thread that asked for it (roadmap l4.md D11), else 0
;   In:       BX = the thread
;   Out:      AX = the FLAGS
;   Destroys: nothing
; ----------------------------------------------------------------------------
thread_flags:
        mov ax, FLAGS_USER_START
        test byte [bx + T_FLAGS], TF_IOPL
        jz .done
        or ax, FLAGS_IOPL1
.done:
        ret

; ----------------------------------------------------------------------------
; thread_first - a new thread's first run (CONT_FIRST): start its program,
; through the way back to its ring
;   In:       BP = its frame; DS = ES = SEL_KDATA; interrupts off
;   Out:      does not return: IRET to the program
;   Destroys: everything
; ----------------------------------------------------------------------------
thread_first:
        TRACE "kernel: a thread starts its program"
        call program_reset
        jmp isr_exit

; ----------------------------------------------------------------------------
; dispatch - run a thread: the kernel's stack emptied, the thread's context
; taken up, then what it still has to do in the kernel (T_CONT), then the
; way back to its ring
;   In:       BX = the thread (not idle_tcb); DS = SEL_KDATA; interrupts off
;   Out:      does not return
;   Destroys: everything
; ----------------------------------------------------------------------------
dispatch:
        mov sp, KSTACK_TOP
        mov [cur_thread], bx
        mov byte [bx + T_STATE], TS_RUNNING
        mov byte [bx + T_SLICE], SLICE_TICKS
        inc word [bx + T_RUNS]
        mov al, [bx + T_RESTART]
        mov [restart_pending], al
        lea ax, [bx + TCB_SIZE]         ; SP0: its frame's end
        mov [tss + TSS286_SP0], ax
        lldt [bx + T_LDT]
        call fpu_switch                 ; TS set unless it owns the 287
        lea bp, [bx + T_FRAME]
        mov al, [bx + T_CONT]
        mov byte [bx + T_CONT], CONT_NONE
        cmp al, CONT_KCALL
        je .kcall
        cmp al, CONT_FIRST
        je thread_first
        cmp al, CONT_FAULT
        jae fault_resume                ; AL: CONT_FAULT or CONT_FAULT_WAY
        jmp isr_exit
.kcall:
        ; the rest of a kernel call: dead spaces it left half emptied first,
        ; then the call again, which finds its progress (T_CONT says so)
        call dead_flush
        mov bx, [cur_thread]
        mov byte [bx + T_CONT], CONT_RESUMED
        call kcall_handler
        mov bx, [cur_thread]
        mov byte [bx + T_CONT], CONT_NONE
        jmp isr_exit

; ----------------------------------------------------------------------------
; schedule - the running thread stops running (it waits, gives way, or
; stops): run the best ready thread, or the idle loop. What the thread
; still has to do in the kernel is its T_CONT, and its results its frame's
;   In:       DS = SEL_KDATA; interrupts off
;   Out:      does not return
;   Destroys: everything
; ----------------------------------------------------------------------------
schedule:
        mov bx, [cur_thread]
        mov al, [restart_pending]       ; its own, kept
        mov [bx + T_RESTART], al
        mov byte [resched], 0
        call ready_pop
        test bx, bx
        jnz dispatch
        mov bx, idle_tcb
        mov [cur_thread], bx
        mov byte [restart_pending], 0
        lldt [bx + T_LDT]
        call fpu_switch
        jmp idle_loop

; ----------------------------------------------------------------------------
; preempt - the running thread gives way to the best ready one, and
; schedule: to the tail of its queue if its time slice is over, else to the
; head, keeping its place, since a more urgent thread took the CPU from it
;   In:       DS = SEL_KDATA; interrupts off
;   Out:      does not return (returns at once for the idle loop)
;   Destroys: everything
; ----------------------------------------------------------------------------
preempt:
        mov bx, [cur_thread]
        cmp bx, idle_tcb
        je .done
        cmp byte [bx + T_SLICE], 0
        je .slice_over
        call ready_first
        jmp schedule
.slice_over:
        call ready_push
        jmp schedule
.done:
        ret

; ----------------------------------------------------------------------------
; kpreempt - a point inside a kernel call, between interrupt windows, where
; the running thread gives way if a more urgent one is ready. The call is
; resumed when the thread runs again (CONT_KCALL): every caller keeps its
; progress where the call finds it again (os-server.md P3)
;   In:       DS = SEL_KDATA; interrupts off
;   Out:      nothing, if it does not give way
;   Destroys: nothing (everything, if it gives way)
; ----------------------------------------------------------------------------
kpreempt:
%ifdef WITH_TEST_HOOKS
        cmp word [test_give_way], 0     ; TEST_GIVE_WAY: these windows give way
        je .urgent
        dec word [test_give_way]
        jmp .give_way
.urgent:
%endif
        cmp byte [resched], 0
        je .done
.give_way:
        push bx
        mov bx, [cur_thread]
        cmp bx, idle_tcb
        je .idle
        mov byte [bx + T_CONT], CONT_KCALL
        jmp preempt
.idle:
        pop bx
.done:
        ret

; ----------------------------------------------------------------------------
; kwait - before any thread runs: wait with interrupts on until the next
; interrupt (the probes and the kernel's own 287 test, ksleep)
;   In:       DS = SEL_KDATA; interrupts off; the idle loop's context
;   Out:      nothing, after an interrupt
;   Destroys: nothing
; ----------------------------------------------------------------------------
kwait:
        STRETCH_END
        sti                             ; STI acts after HLT has begun: an
        hlt                             ; interrupt already pending still wakes it
        cli
        STRETCH_BEGIN 0xFFFF
        ret

; ----------------------------------------------------------------------------
; call_enter - into the log's writes (KCALL_LOG): one thread at a time, so
; that lines never mix (l4.md X15); a thread that finds another writing
; waits until the next interrupt, and calls again (CONT_KCALL)
;   In:       DS = SEL_KDATA; interrupts off; in a kernel call
;   Out:      the running thread holds the log (or it waits: no return)
;   Destroys: nothing
; ----------------------------------------------------------------------------
call_enter:
        push ax
        mov ax, [call_owner]
        test ax, ax
        jz .take
        cmp ax, [cur_thread]
        je .held                        ; its own, kept while it gave way
        mov bx, [cur_thread]
        mov byte [bx + T_CONT], CONT_KCALL
        mov byte [bx + T_STATE], TS_WAITING
        jmp schedule                    ; wake_waiters readies it
.take:
        mov ax, [cur_thread]
        mov [call_owner], ax
.held:
        pop ax
        ret

; ----------------------------------------------------------------------------
; call_leave - out of the log's writes
;   In:       DS = SEL_KDATA
;   Out:      nothing
;   Destroys: nothing
; ----------------------------------------------------------------------------
call_leave:
        push ax
        mov ax, [cur_thread]
        cmp [call_owner], ax            ; (a stop may have given its turn up)
        jne .done
        mov word [call_owner], 0
.done:
        pop ax
        ret

; ----------------------------------------------------------------------------
; wake_waiters - after an interrupt: every thread waiting inside the kernel
; is ready again, to look at what it waits for
;   In:       DS = SEL_KDATA; interrupts off
;   Out:      nothing
;   Destroys: nothing
; ----------------------------------------------------------------------------
wake_waiters:
        push bx
        push cx
        push si
        mov si, thread_list
        mov cx, [thread_count]
        jcxz .done
.thread:
        mov bx, [si]
        cmp byte [bx + T_STATE], TS_WAITING
        jne .next
        call ready_push
.next:
        add si, 2
        loop .thread
.done:
        pop si
        pop cx
        pop bx
        ret

; ----------------------------------------------------------------------------
; thread_tick - a tick of the running thread: its time, its slice; at the
; slice's end, give way if a thread of its priority or above is ready
;   In:       DS = SEL_KDATA; interrupts off
;   Out:      nothing
;   Destroys: nothing
; ----------------------------------------------------------------------------
thread_tick:
        push ax
        push bx
        push cx
        mov bx, [cur_thread]
        cmp bx, idle_tcb
        je .done
        inc word [bx + T_RUN_TICKS]
        dec byte [bx + T_SLICE]
        jnz .done
        mov cl, [bx + T_PRIO]
        mov al, [ready_mask]
        shr al, cl                      ; queues of its priority and above
        jz .again
        mov byte [resched], 1           ; (its slice 0: to the back of its queue)
        jmp .done
.again:
        mov byte [bx + T_SLICE], SLICE_TICKS    ; nobody to give way to
.done:
        pop cx
        pop bx
        pop ax
        ret

; ----------------------------------------------------------------------------
; thread_restart - ask for a thread's program to start again: at once if it
; runs, else when it next does (its kept restart_pending). A thread waiting
; for a server's reply takes the server's thread with it if that thread
; serves it alone (TF_SESSION: the OS server's, l4.md L6), whose wait in
; the kernel on its behalf is then given up too.
;   In:       BX = the thread; DS = SEL_KDATA
;   Out:      nothing
;   Destroys: nothing
; ----------------------------------------------------------------------------
thread_restart:
        cmp bx, [cur_thread]
        jne .other
        mov byte [restart_pending], 1
        ret
.other:
        mov byte [bx + T_RESTART], 1
        cmp byte [bx + T_STATE], TS_REPLY
        jne .cancel
        push bx
        mov bx, [bx + T_WAIT_OBJ]       ; the server
        test byte [bx + T_FLAGS], TF_SESSION
        jz .alone
        call thread_restart
.alone:
        pop bx
.cancel:
        jmp ipc_cancel                  ; waiting in IPC: it wakes, to restart

; ----------------------------------------------------------------------------
; thread_suspended - the running thread stops on its way back to its ring
; (THREAD_SUSPEND; os-server.md P2): its registers kept in its frame, which
; THREAD_FRAME may read and write meanwhile; its suspender's notification
; signalled; THREAD_START resumes it, through the way back afresh
;   In:       BX = the running thread; BP = its frame; DS = SEL_KDATA;
;             interrupts off
;   Out:      does not return
;   Destroys: everything
; ----------------------------------------------------------------------------
thread_suspended:
        and byte [bx + T_FLAGS], ~TF_SUSPEND & 0xFF
        or byte [bx + T_FLAGS], TF_SUSPENDED
        mov byte [bx + T_STATE], TS_STOPPED
        mov si, [bx + T_SUSPEND_NOTIFY]
        test si, si
        jz .stopped
        mov word [bx + T_SUSPEND_NOTIFY], 0
        mov ax, [bx + T_SUSPEND_BADGE]
        test ax, ax
        jnz .bits
        inc ax                          ; a capability without a badge signals 1
.bits:
        call ntf_signal
.stopped:
        jmp schedule                    ; THREAD_START readies it: the way back

; ----------------------------------------------------------------------------
; thread_stop - a thread stopped (KCALL_THREAD's THREAD_STOP; roadmap l4.md
; L11): as a restart, its IPC wait given up and its session's server
; started again; then off its ready queue, and its turn at the log given up.
; Started again (THREAD_START), it goes on from where it stopped inside the
; kernel, and its way back starts its program at its entry
;   In:       BX = the thread, started, not the running one; DS = SEL_KDATA;
;             interrupts off
;   Out:      nothing
;   Destroys: nothing
; ----------------------------------------------------------------------------
thread_stop:
        call thread_restart
        cmp [call_owner], bx
        jne .queue
        mov word [call_owner], 0
.queue:
        cmp byte [bx + T_STATE], TS_READY
        jne .stopped
        call ready_remove
.stopped:
        mov byte [bx + T_STATE], TS_STOPPED
        ret

; ----------------------------------------------------------------------------
; ready_remove - a thread out of its ready queue, wherever it is in it
;   In:       BX = the thread, ready; DS = SEL_KDATA; interrupts off
;   Out:      nothing
;   Destroys: nothing
; ----------------------------------------------------------------------------
ready_remove:
        push ax
        push cx
        push si
        push di
        mov cl, [bx + T_PRIO]
        xor ch, ch
        mov si, cx
        shl si, 1
        xor di, di                      ; DI = the one before it, 0 at the head
        mov ax, [rq_head + si]
.find:
        test ax, ax
        jz .done                        ; not there
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
        mov [rq_head + si], ax
.tail:
        cmp [rq_tail + si], bx
        jne .done
        mov [rq_tail + si], di
        test di, di
        jnz .done
        mov al, 1                       ; the queue is empty
        shl al, cl
        not al
        and [ready_mask], al
.done:
        pop di
        pop si
        pop cx
        pop ax
        ret

; ----------------------------------------------------------------------------
; ready_push - a thread to the tail of its priority's queue; a reschedule if
; it is more urgent than the running one
;   In:       BX = the thread; DS = SEL_KDATA; interrupts off
;   Out:      nothing
;   Destroys: nothing
; ----------------------------------------------------------------------------
ready_push:
        push ax
        push cx
        push si
        mov byte [bx + T_STATE], TS_READY
        mov word [bx + T_NEXT], 0
        mov cl, [bx + T_PRIO]
        xor ch, ch
        mov si, cx
        shl si, 1
        mov ax, [rq_tail + si]
        test ax, ax
        jz .first
        push di
        mov di, ax
        mov [di + T_NEXT], bx
        pop di
        jmp .tail
.first:
        mov [rq_head + si], bx
.tail:
        mov [rq_tail + si], bx
.mark:
        mov al, 1
        shl al, cl
        or [ready_mask], al
        mov si, [cur_thread]
        cmp si, idle_tcb
        je .urgent
        cmp cl, [si + T_PRIO]
        jbe .done
.urgent:
        mov byte [resched], 1
.done:
        pop si
        pop cx
        pop ax
        ret

; ----------------------------------------------------------------------------
; ready_first - a thread to the head of its priority's queue: it runs before
; the others there (IPC's direct switch); a reschedule as ready_push
;   In:       BX = the thread; DS = SEL_KDATA; interrupts off
;   Out:      nothing
;   Destroys: nothing
; ----------------------------------------------------------------------------
ready_first:
        push ax
        push cx
        push si
        mov byte [bx + T_STATE], TS_READY
        mov cl, [bx + T_PRIO]
        xor ch, ch
        mov si, cx
        shl si, 1
        mov ax, [rq_head + si]
        mov [bx + T_NEXT], ax
        mov [rq_head + si], bx
        test ax, ax
        jnz ready_push.mark
        mov [rq_tail + si], bx
        jmp ready_push.mark

; ----------------------------------------------------------------------------
; ready_pop - the head of the highest non-empty queue, taken out of it
;   In:       DS = SEL_KDATA; interrupts off
;   Out:      BX = the thread, or 0 if none is ready
;   Destroys: nothing
; ----------------------------------------------------------------------------
ready_pop:
        push ax
        push cx
        push si
        xor bx, bx
        mov al, [ready_mask]
        test al, al
        jz .done
        mov bx, prio_table
        xlatb                           ; AL = the highest priority ready
        mov cl, al
        xor ah, ah
        mov si, ax
        shl si, 1
        mov bx, [rq_head + si]
        mov ax, [bx + T_NEXT]
        mov [rq_head + si], ax
        test ax, ax
        jnz .done
        mov word [rq_tail + si], 0
        mov al, 1
        shl al, cl
        not al
        and [ready_mask], al
.done:
        pop si
        pop cx
        pop ax
        ret

%ifdef WITH_CHECKS
begin_kdata
msg_dump_thread     db "thread ", 0
msg_dump_priority   db " priority ", 0
msg_dump_stack      db "the kernel's stack used ", 0
msg_dump_states     db " free", 0, " ready", 0, " running", 0, " waiting", 0
                    db " sending", 0, " receiving", 0, " awaiting its reply", 0
                    db " awaiting a notification", 0, " stopped", 0
end_kdata

; ----------------------------------------------------------------------------
; thread_dump - debug and test builds: every thread, its state and
; priority; then how deep the kernel's one stack has ever been (the
; watermark pm_start fills it with); on the AT's Sys Req key, and on a panic
;   In:       DS = SEL_KDATA; interrupts off
;   Out:      nothing
;   Destroys: AX, BX, CX, DX, SI, DI, ES
; ----------------------------------------------------------------------------
thread_dump:
        xor di, di
.thread:
        cmp di, [thread_count]
        jae .done
        push di
        shl di, 1
        mov bx, [thread_list + di]
        mov al, ATTR_KERNEL
        call con_set_attr
        mov si, msg_log_prefix
        call kputs
        mov si, msg_dump_thread
        call kputs
        mov si, [bx + T_NAME]
        call kputs
        mov si, msg_dump_states         ; the state's name: skip T_STATE strings
        mov cl, [bx + T_STATE]
.state:
        test cl, cl
        jz .named
.skip:
        lodsb
        test al, al
        jnz .skip
        dec cl
        jmp .state
.named:
        call kputs
        mov si, msg_dump_priority
        call kputs
        mov al, [bx + T_PRIO]
        xor ah, ah
        xor dx, dx
        call kput_dec32
        mov al, CHAR_LF
        call kputc
        mov al, ATTR_NORMAL
        call con_set_attr
        pop di
        inc di
        jmp .thread
.done:
        mov al, ATTR_KERNEL
        call con_set_attr
        mov si, msg_log_prefix
        call kputs
        mov si, msg_dump_stack
        call kputs
        call kstack_used                ; AX = bytes
        xor dx, dx
        call kput_dec32
        mov al, CHAR_LF
        call kputc
        mov al, ATTR_NORMAL
        jmp con_set_attr

; ----------------------------------------------------------------------------
; kstack_used - how much of the kernel's stack was ever used
;   In:       DS = ES = SEL_KDATA
;   Out:      AX = bytes, from its top to the deepest word written
;   Destroys: CX, DI
; ----------------------------------------------------------------------------
kstack_used:
        mov di, KSTACK_BOTTOM
        mov ax, STACK_FILL
        mov cx, KSTACK_SIZE / 2
        cld
        repe scasw                      ; past the untouched words
        mov ax, KSTACK_TOP
        sub ax, di
        add ax, 2                       ; DI is past the first word written
        ret
%endif
