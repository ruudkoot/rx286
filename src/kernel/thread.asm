; ============================================================================
; rx286 - src/kernel/thread.asm
; Threads: their control blocks, the switch, the scheduler, the idle loop,
; waiting, and the lock around the system calls (roadmap l4.md L2).
;
; Each thread runs a program in ring 3 with an LDT of its own, and has a
; kernel stack of its own (from SEL_STACK_POOL): SP0 points at its top while the
; thread runs, so every interrupt from ring 3 builds its frame there, and a
; thread that waits inside the kernel keeps its place on it (D3). switch_to
; saves the running thread's registers on its kernel stack, keeps SS:SP in
; its control block, and takes up the next one's: one TSS, a software switch
; (D2). Eight fixed priorities, round robin within each on SLICE_TICKS (D9);
; a table gives the highest non-empty queue, since the 286 has no BSF. When
; no thread is ready the kernel idles on its own stack (SEL_KSTACK), never on
; a thread's (l4.md X8).
;
; A thread waits inside the kernel only until the next interrupt (kwait):
; every IRQ wakes every waiting thread, which looks again at what it waits
; for. The system calls were written for one program and are not reentrant,
; so one thread at a time is inside them (call_enter; l4.md X15); a thread
; that waits for a key or SYS_WAIT's events lets others in meanwhile.
; Preemption happens on the way back to ring 3 and at the kernel's own
; interrupt windows (kpreempt), never in the middle of a handler.
; ============================================================================

begin_kdata
; The kernel's own context: the start, then the idle loop, on SEL_KSTACK.
; (Threads are objects of the arena: cap.asm makes them.)
idle_tcb:
        dw 0, 0                         ; T_SS, T_SP
        db TS_RUNNING, 0                ; T_STATE, T_PRIO
        dw 0, SEL_NULL, SEL_KSTACK, 0   ; T_NEXT, T_LDT (none), T_STACK, T_USTACK_TOP
        db 0, 0                         ; T_RESTART, T_FPU_VALID
        dw msg_thread_idle              ; T_NAME
        times TCB_SIZE - T_SLICE db 0
cur_thread          dw idle_tcb         ; the thread running
fg_thread           dw idle_tcb         ; the thread the keys and Ctrl+Break are for
call_owner          dw 0                ; the thread inside a system call, or 0
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
        call boot_root                  ; BX = its thread (cap.asm)
        call thread_init
        TRACE "kernel: the root ready"
        ; falls through

; ----------------------------------------------------------------------------
; idle_loop - run the best ready thread; when there is none, halt with
; interrupts on until one is (on the kernel's own stack: l4.md X8)
;   In:       cur_thread = idle_tcb; interrupts off; DS = SEL_KDATA
;   Out:      does not return
;   Destroys: everything
; ----------------------------------------------------------------------------
idle_loop:
        mov byte [resched], 0
        call ready_pop
        test bx, bx
        jnz .run
        sti
        hlt
        cli
        jmp idle_loop
.run:
        call switch_to
        jmp idle_loop

; Where a new thread's frame and its first switch_to's pushes lie
THREAD_FRAME        equ TCB_STACK_SIZE - FRAME_SIZE_USER
THREAD_START_SP     equ THREAD_FRAME - 2 - 16 - 4      ; a return address, PUSHA, DS, ES

; ----------------------------------------------------------------------------
; thread_init - make a thread ready to start its program at its entry: its
; kernel stack as an interrupt from ring 3 would leave it, under what
; switch_to pops
;   In:       BX = the thread; DS = SEL_KDATA; interrupts off
;   Out:      the thread in its ready queue
;   Destroys: AX, CX, DI, ES
; ----------------------------------------------------------------------------
thread_init:
        mov es, [bx + T_STACK]
        xor di, di
%ifdef WITH_CHECKS
        mov ax, STACK_FILL              ; the watermark: how deep the stack ever gets
%else
        xor ax, ax
%endif
        mov cx, TCB_STACK_SIZE / 2
        cld
        rep stosw
        xor ax, ax
        mov di, THREAD_START_SP
        mov cx, (TCB_STACK_SIZE - THREAD_START_SP) / 2
        rep stosw
        ; switch_to's: ES, DS, PUSHA's registers (zero), the return address
        mov word [es:THREAD_START_SP], SEL_KDATA
        mov word [es:THREAD_START_SP + 2], SEL_KDATA
        mov word [es:THREAD_START_SP + 20], thread_first
        ; the frame of an interrupt from ring 3, at the program's entry
        ; slots 0, 1, 2 of its space: code, data, stack, at its ring
        mov al, [bx + T_RING]
        xor ah, ah
        or ax, SEL_UDATA & ~CPL_MASK
        mov [es:THREAD_FRAME + FRAME_ES], ax
        mov [es:THREAD_FRAME + FRAME_DS], ax
        add ax, SEL_USTACK - SEL_UDATA
        mov [es:THREAD_FRAME + FRAME_USER_SS], ax
        sub ax, SEL_USTACK - SEL_UCODE
        mov [es:THREAD_FRAME + FRAME_CS], ax
        mov ax, [bx + T_ENTRY]
        mov [es:THREAD_FRAME + FRAME_IP], ax
        call thread_flags
        mov [es:THREAD_FRAME + FRAME_FLAGS], ax
        mov ax, [bx + T_USTACK_TOP]
        mov [es:THREAD_FRAME + FRAME_USER_SP], ax
        mov [bx + T_SS], es
        mov word [bx + T_SP], THREAD_START_SP
        push ds
        pop es
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
; thread_first - where a new thread's first switch_to returns: start its
; program, through the way back to ring 3
;   In:       SP at the frame; DS = ES = SEL_KDATA; interrupts off
;   Out:      does not return: IRET to the program
;   Destroys: everything
; ----------------------------------------------------------------------------
thread_first:
        mov bp, sp
        TRACE "kernel: a thread starts its program"
        call program_reset
        jmp isr_exit

; ----------------------------------------------------------------------------
; switch_to - run another thread; the running one's kernel context stays on
; its own stack until it is chosen again
;   In:       BX = the thread to run (not the running one); DS = SEL_KDATA;
;             interrupts off
;   Out:      returns when the running thread runs again
;   Destroys: nothing
; ----------------------------------------------------------------------------
switch_to:
        pusha
        push ds
        push es
        mov si, [cur_thread]
        mov [si + T_SS], ss
        mov [si + T_SP], sp
        mov al, [restart_pending]       ; the running thread's own, kept
        mov [si + T_RESTART], al
        mov al, [bx + T_RESTART]
        mov [restart_pending], al
        mov [cur_thread], bx
        mov byte [bx + T_STATE], TS_RUNNING
        mov byte [bx + T_SLICE], SLICE_TICKS
        inc word [bx + T_RUNS]
        mov ax, [bx + T_STACK]          ; SS0:SP0: the top of its kernel stack
        mov [tss + TSS286_SS0], ax
        mov word [tss + TSS286_SP0], TCB_STACK_SIZE
        lldt [bx + T_LDT]
        call fpu_switch                 ; TS set unless it owns the 287
        mov ss, [bx + T_SS]
        mov sp, [bx + T_SP]
        pop es
        pop ds
        popa
        ret

; ----------------------------------------------------------------------------
; schedule - the running thread stops (it waits, or is back in its ready
; queue): run the best ready thread, or the idle loop
;   In:       DS = SEL_KDATA; interrupts off
;   Out:      returns when the running thread runs again
;   Destroys: nothing
; ----------------------------------------------------------------------------
schedule:
        push bx
        mov byte [resched], 0
        call ready_pop
        test bx, bx
        jnz .chosen
        mov bx, idle_tcb
.chosen:
        cmp bx, [cur_thread]
        je .same
        call switch_to
.done:
        pop bx
        ret
.same:
        mov byte [bx + T_STATE], TS_RUNNING
        jmp .done

; ----------------------------------------------------------------------------
; preempt - the running thread gives way to the best ready one: to the tail
; of its queue, and schedule
;   In:       DS = SEL_KDATA; interrupts off
;   Out:      returns when the running thread runs again
;   Destroys: nothing
; ----------------------------------------------------------------------------
preempt:
        push bx
        mov bx, [cur_thread]
        cmp bx, idle_tcb
        je .done
        call ready_push
        call schedule
.done:
        pop bx
        ret

; ----------------------------------------------------------------------------
; kpreempt - a point inside the kernel, between interrupt windows, where the
; running thread may give way if a more urgent one is ready
;   In:       DS = SEL_KDATA; interrupts off
;   Out:      nothing
;   Destroys: nothing
; ----------------------------------------------------------------------------
kpreempt:
        cmp byte [resched], 0
        je .done
        call preempt
.done:
        ret

; ----------------------------------------------------------------------------
; kwait - wait inside the kernel until the next interrupt, letting other
; threads run meanwhile (before any thread runs: halt)
;   In:       DS = SEL_KDATA; interrupts off
;   Out:      nothing, after an interrupt
;   Destroys: nothing
; ----------------------------------------------------------------------------
kwait:
        push bx
        mov bx, [cur_thread]
        cmp bx, idle_tcb
        je .halt
        mov byte [bx + T_STATE], TS_WAITING
        call schedule
        pop bx
        ret
.halt:
        sti                             ; STI acts after HLT has begun: an
        hlt                             ; interrupt already pending still wakes it
        cli
        pop bx
        ret

; ----------------------------------------------------------------------------
; kwait_unlocked - as kwait, letting other threads into the system calls
; meanwhile: for waits that hold nothing of the calls' (a key, SYS_WAIT)
;   In:       DS = SEL_KDATA; interrupts off
;   Out:      nothing, after an interrupt, inside the calls again if it was
;   Destroys: nothing
; ----------------------------------------------------------------------------
kwait_unlocked:
        push ax
        mov ax, [cur_thread]
        cmp [call_owner], ax
        jne .wait
        mov word [call_owner], 0
        call kwait
        call call_enter
        pop ax
        ret
.wait:
        call kwait
        pop ax
        ret

; ----------------------------------------------------------------------------
; call_enter - into the system calls: one thread at a time (l4.md X15)
;   In:       DS = SEL_KDATA; interrupts off
;   Out:      the running thread holds the calls
;   Destroys: nothing
; ----------------------------------------------------------------------------
call_enter:
        push ax
.check:
        mov ax, [call_owner]
        test ax, ax
        jz .take
        call kwait                      ; until the next interrupt, then again
        jmp .check
.take:
        mov ax, [cur_thread]
        mov [call_owner], ax
        pop ax
        ret

; ----------------------------------------------------------------------------
; call_leave - out of the system calls
;   In:       DS = SEL_KDATA
;   Out:      nothing
;   Destroys: nothing
; ----------------------------------------------------------------------------
call_leave:
        mov word [call_owner], 0
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
        mov byte [bx + T_SLICE], SLICE_TICKS
        mov cl, [bx + T_PRIO]
        mov al, [ready_mask]
        shr al, cl                      ; queues of its priority and above
        jz .done
        mov byte [resched], 1
.done:
        pop cx
        pop bx
        pop ax
        ret

; ----------------------------------------------------------------------------
; thread_restart - ask for a thread's program to start again: at once if it
; runs, else when it next does (its kept restart_pending)
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
        jmp ipc_cancel                  ; waiting in IPC: it wakes, to restart

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
msg_dump_stack      db ", kernel stack used ", 0
msg_dump_states     db " free", 0, " ready", 0, " running", 0, " waiting", 0
                    db " sending", 0, " receiving", 0, " awaiting its reply", 0
                    db " awaiting a notification", 0
end_kdata

; ----------------------------------------------------------------------------
; thread_dump - debug and test builds: every thread, its state, priority and
; how deep its kernel stack has ever been (the watermark of thread_init);
; on the AT's Sys Req key, and on a panic
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
        mov si, msg_dump_stack
        call kputs
        push di
        call thread_stack_used          ; AX = bytes
        pop di
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
        ret

; ----------------------------------------------------------------------------
; thread_stack_used - how much of a thread's kernel stack was ever used
;   In:       BX = the thread; DS = SEL_KDATA
;   Out:      AX = bytes, from its top to the deepest word written
;   Destroys: CX, DI, ES
; ----------------------------------------------------------------------------
thread_stack_used:
        mov es, [bx + T_STACK]
        xor di, di
        mov ax, STACK_FILL
        mov cx, TCB_STACK_SIZE / 2
        cld
        repe scasw                      ; past the untouched words
        mov ax, TCB_STACK_SIZE
        sub ax, di
        add ax, 2                       ; DI is past the first word written
        ret
%endif
