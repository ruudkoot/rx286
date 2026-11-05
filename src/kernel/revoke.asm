; ============================================================================
; rx286 - src/kernel/revoke.asm
; Delete and revoke (roadmap l4.md L12, D8): capabilities go, objects die
; with the last capability to them, and memory goes back to its untyped.
;
; Every capability records its parent: the slot it was copied, minted or
; granted from, or the untyped it was retyped from (since L3; retype's from
; L12). A delete gives its children to its parent, so the tree holds; a
; move takes its children with it. KCALL_REVOKE deletes everything below a
; capability, a leaf at a time, and an untyped revoked has none of its
; memory used any more: its watermark goes back to 0, and the next retype
; reuses it, zeroed (l4.md X14).
;
; When the last capability to an object goes, the object dies: an
; endpoint's queued threads and a notification's waiter fail with KE_CAP; a
; thread stops for good, and every reply and link naming it is cleared; a
; space's threads stop and lose it, and its slots are emptied in turn - from
; a list, not by recursion, since a kernel stack is small - and its LDT's
; descriptor goes back to the pool once no thread names it. A thread that
; loses its own last capability, or its space, dies at its way back
; (thread_die). The tree is searched slot by slot, over every space: a
; revoke is slow (and runs with interrupts off), but kill is rare.
; ============================================================================

begin_kdata
space_list          times SPACE_MAX dw 0    ; every space, in the order made
space_bytes         dw 0                ; its length, in bytes
dead_spaces         times SPACE_MAX dw 0    ; spaces that died, their slots to empty
dead_count          dw 0
scan_space          dw 0                ; cap_find_child's: the space it is in
revoke_space        dw 0                ; kc_revoke's: what it revokes
revoke_slot         dw 0
end_kdata

; ----------------------------------------------------------------------------
; space_list_add - a new space into the list
;   In:       BX = the space; DS = SEL_KDATA
;   Out:      nothing
;   Destroys: nothing
; ----------------------------------------------------------------------------
space_list_add:
        push di
        mov di, [space_bytes]
        mov [space_list + di], bx
        add word [space_bytes], 2
        pop di
        ret

; ----------------------------------------------------------------------------
; space_unlist - a space out of the list
;   In:       BX = the space; DS = SEL_KDATA
;   Out:      nothing
;   Destroys: nothing
; ----------------------------------------------------------------------------
space_unlist:
        push si
        mov si, space_list
        call list_remove
        jc .done
        sub word [space_bytes], 2
.done:
        pop si
        ret

; ----------------------------------------------------------------------------
; thread_unlist - a thread out of the list of threads
;   In:       BX = the thread; DS = SEL_KDATA
;   Out:      CF clear; or CF set: it was not there
;   Destroys: nothing
; ----------------------------------------------------------------------------
thread_unlist:
        push ax
        push cx
        push si
        mov ax, [thread_count]
        shl ax, 1
        push ax
        mov [list_bytes], ax
        mov si, thread_list
        call list_remove
        pop ax
        jc .done
        dec word [thread_count]
        clc
.done:
        pop si
        pop cx
        pop ax
        ret

begin_kdata
list_bytes          dw 0
end_kdata

; ----------------------------------------------------------------------------
; list_remove - a word out of a list of words, the ones after it moved down
;   In:       SI = the list; BX = the word; [list_bytes] or [space_bytes]: its
;             length (space_list's own, else list_bytes)
;   Out:      CF clear; or CF set: not there
;   Destroys: nothing
; ----------------------------------------------------------------------------
list_remove:
        push ax
        push cx
        push di
        mov cx, [list_bytes]
        cmp si, space_list
        jne .length
        mov cx, [space_bytes]
.length:
        shr cx, 1
        jcxz .none
        mov di, si
.find:
        cmp [di], bx
        je .found
        add di, 2
        loop .find
.none:
        stc
        jmp .out
.found:
        dec cx                          ; the words after it
        jcxz .last
.move:
        mov ax, [di + 2]
        mov [di], ax
        add di, 2
        loop .move
.last:
        mov word [di], 0
        clc
.out:
        pop di
        pop cx
        pop ax
        ret

; ----------------------------------------------------------------------------
; cap_find_child - a capability whose parent is a slot, in any space
;   In:       BX = the parent's space; AX = its slot
;   Out:      CF clear, DX = the child's space, CX = its slot; or CF set
;   Destroys: nothing else
; ----------------------------------------------------------------------------
cap_find_child:
        push si
        push di
        push ax
        mov dx, ax                      ; DX = the parent's slot
        xor di, di
.space:
        cmp di, [space_bytes]
        jae .none
        mov si, [space_list + di]
        mov [scan_space], si
        mov cx, [si + SP_SLOTS]
        mov ax, cx
        shl ax, 3
        add si, ax
        add si, SP_LDT                  ; SI = its first shadow entry
        xor ax, ax
.slot:
        cmp byte [si + SH_TYPE], CAP_EMPTY
        je .next
        cmp [si + SH_PARENT], bx
        jne .next
        cmp [si + SH_PARENT_SLOT], dx
        jne .next
        mov cx, ax
        mov dx, [scan_space]
        pop ax
        clc
        jmp .out
.next:
        add si, SHADOW_SIZE
        inc ax
        loop .slot
        add di, 2
        jmp .space
.none:
        pop ax
        stc
.out:
        pop di
        pop si
        ret

; ----------------------------------------------------------------------------
; cap_reparent - every child of a slot made a child of another
;   In:       BX, AX = the old parent's space and slot; DX, CX = the new's
;             (0, 0: none)
;   Out:      nothing
;   Destroys: nothing
; ----------------------------------------------------------------------------
cap_reparent:
        push cx
        push dx
        push si
        push di
        push bp
        mov [reparent_space], dx
        mov [reparent_slot], cx
        mov bp, ax                      ; BP = the old parent's slot
        xor di, di
.space:
        cmp di, [space_bytes]
        jae .done
        mov si, [space_list + di]
        mov cx, [si + SP_SLOTS]
        mov dx, cx
        shl dx, 3
        add si, dx
        add si, SP_LDT
.slot:
        cmp byte [si + SH_TYPE], CAP_EMPTY
        je .next
        cmp [si + SH_PARENT], bx
        jne .next
        cmp [si + SH_PARENT_SLOT], bp
        jne .next
        mov dx, [reparent_space]
        mov [si + SH_PARENT], dx
        mov dx, [reparent_slot]
        mov [si + SH_PARENT_SLOT], dx
.next:
        add si, SHADOW_SIZE
        loop .slot
        add di, 2
        jmp .space
.done:
        pop bp
        pop di
        pop si
        pop dx
        pop cx
        ret

begin_kdata
reparent_space      dw 0
reparent_slot       dw 0
end_kdata

; ----------------------------------------------------------------------------
; cap_named - does any capability of a type name an object?
;   In:       AL = the type; DX = the object (SH_OBJECT)
;   Out:      CF set if one does
;   Destroys: nothing
; ----------------------------------------------------------------------------
cap_named:
        push cx
        push si
        push di
        xor di, di
.space:
        cmp di, [space_bytes]
        jae .none
        mov si, [space_list + di]
        mov cx, [si + SP_SLOTS]
        push cx
        shl cx, 3
        add si, cx
        add si, SP_LDT
        pop cx
.slot:
        cmp [si + SH_TYPE], al
        jne .next
        cmp [si + SH_OBJECT], dx
        je .named
.next:
        add si, SHADOW_SIZE
        loop .slot
        add di, 2
        jmp .space
.named:
        stc
        jmp .out
.none:
        clc
.out:
        pop di
        pop si
        pop cx
        ret

; ----------------------------------------------------------------------------
; cap_delete_at - a capability deleted: its children given to its parent,
; its slot emptied, and its object dead if it was the last capability to it
;   In:       BX = the space; AX = the slot (not empty); DS = SEL_KDATA;
;             interrupts off
;   Out:      nothing (dead spaces wait in dead_spaces: dead_flush)
;   Destroys: nothing
; ----------------------------------------------------------------------------
cap_delete_at:
        push ax
        push bx
        push cx
        push dx
        push si
        push di
        push es
        push ax
        call slot_at                    ; SI = the shadow entry, DI = the descriptor
        pop ax
        mov dx, [si + SH_PARENT]
        mov cx, [si + SH_PARENT_SLOT]
        call cap_reparent
        mov al, [si + SH_TYPE]
        mov dx, [si + SH_OBJECT]
        push ax
        push dx
        call slot_clear
        pop dx
        pop ax
        call cap_last
        pop es
        pop di
        pop si
        pop dx
        pop cx
        pop bx
        pop ax
        ret

; ----------------------------------------------------------------------------
; cap_last - an object whose capability has just gone: dead if no other
; capability names it (segments and untyped are memory: nothing dies)
;   In:       AL = the type; DX = the object
;   Out:      nothing
;   Destroys: AX, BX, CX, DX, SI, DI, ES
; ----------------------------------------------------------------------------
cap_last:
        cmp al, CAP_ENDPOINT
        je .object
        cmp al, CAP_NOTIFY
        je .object
        cmp al, CAP_THREAD
        je .object
        cmp al, CAP_SPACE
        je .object
        cmp al, CAP_IRQ
        jne .done
.object:
        call cap_named
        jc .done
        mov bx, dx
        cmp al, CAP_ENDPOINT
        je endpoint_destroy
        cmp al, CAP_NOTIFY
        je notify_destroy
        cmp al, CAP_THREAD
        je thread_destroy
        cmp al, CAP_SPACE
        je space_destroy
        jmp irq_unbind
.done:
        ret

; ----------------------------------------------------------------------------
; endpoint_destroy - an endpoint dies: its queued threads fail with KE_CAP,
; and no thread's faults go to it any more
;   In:       BX = the endpoint
;   Out:      nothing
;   Destroys: AX, BX, CX, SI, DI
; ----------------------------------------------------------------------------
endpoint_destroy:
        mov si, bx
.queued:
        mov bx, [si + E_HEAD]
        test bx, bx
        jz .faults
        mov al, KE_CAP
        call ipc_fail                   ; out of the queue
        jmp .queued
.faults:
        xor di, di
.thread:
        cmp di, [thread_count]
        jae .done
        push di
        shl di, 1
        mov bx, [thread_list + di]
        pop di
        cmp [bx + T_FAULT], si
        jne .next
        mov word [bx + T_FAULT], 0
.next:
        inc di
        jmp .thread
.done:
        ret

; ----------------------------------------------------------------------------
; notify_destroy - a notification dies: its waiter fails with KE_CAP, its
; thread and interrupt lines are unbound, its timer stopped
;   In:       BX = the notification
;   Out:      nothing
;   Destroys: AX, BX, CX, SI, DI
; ----------------------------------------------------------------------------
notify_destroy:
        mov si, bx
        mov bx, [si + N_WAITER]
        test bx, bx
        jz .bound
        mov al, KE_CAP
        call ipc_fail
.bound:
        mov bx, [si + N_BOUND]
        test bx, bx
        jz .lines
        mov word [bx + T_BOUND], 0
        mov word [si + N_BOUND], 0
.lines:
        xor bx, bx
.line:
        mov di, bx
        shl di, 1
        cmp [irq_notify + di], si
        jne .next_line
        call irq_unbind
.next_line:
        inc bx
        cmp bx, IRQ_LINES
        jb .line
        mov di, timers
        mov cx, TIMER_MAX
.timer:
        cmp [di + TM_NOTIFY], si
        jne .next_timer
        mov word [di + TM_NOTIFY], 0
.next_timer:
        add di, TIMER_SIZE
        loop .timer
        ret

; ----------------------------------------------------------------------------
; irq_unbind - an interrupt line no longer bound: masked, its notification
; forgotten
;   In:       BX = the line
;   Out:      nothing
;   Destroys: AX, DI
; ----------------------------------------------------------------------------
irq_unbind:
        mov di, bx
        shl di, 1
        mov word [irq_notify + di], 0
        mov word [irq_bits + di], 0
        jmp pic_mask

; ----------------------------------------------------------------------------
; thread_destroy - a thread dies: stopped for good and forgotten; the
; running thread dies at its way back instead (thread_die)
;   In:       BX = the thread
;   Out:      nothing
;   Destroys: AX, CX, DX, SI, DI, ES
; ----------------------------------------------------------------------------
thread_destroy:
        cmp bx, [cur_thread]
        jne .other
        or byte [bx + T_FLAGS], TF_DEAD
        ret
.other:
        call thread_unlist
        jc .done                        ; dead already
        cmp byte [bx + T_STATE], TS_FREE
        je .stopped
        cmp byte [bx + T_STATE], TS_STOPPED
        je .stopped
        call thread_stop
.stopped:
        mov byte [bx + T_STATE], TS_FREE
        call thread_forget
.done:
        ret

; ----------------------------------------------------------------------------
; thread_forget - every reference to a dead thread cleared: the 287's, the
; keys', the log's; replies it is owed or owes; its kernel stack's
; descriptor back to the pool
;   In:       BX = the thread, out of the list
;   Out:      nothing
;   Destroys: AX, CX, DX, SI, DI, ES
; ----------------------------------------------------------------------------
thread_forget:
        cmp [fpu_owner], bx
        jne .keys
        mov word [fpu_owner], 0
.keys:
        cmp [fg_thread], bx
        jne .log
        mov word [fg_thread], idle_tcb
.log:
        cmp [call_owner], bx
        jne .notify
        mov word [call_owner], 0
.notify:
        mov si, [bx + T_BOUND]
        test si, si
        jz .others
        mov word [si + N_BOUND], 0
.others:
        xor di, di                      ; the threads it was linked to
.thread:
        cmp di, [thread_count]
        jae .replies
        push di
        shl di, 1
        mov si, [thread_list + di]
        pop di
        cmp [si + T_REPLY], bx
        jne .caller
        mov word [si + T_REPLY], 0      ; a reply owed to it: nobody waits
.caller:
        cmp byte [si + T_STATE], TS_REPLY
        jne .next
        cmp [si + T_WAIT_OBJ], bx
        jne .next
        push bx                         ; waiting for its reply: it fails
        mov bx, si
        mov al, KE_CAP
        call ipc_fail
        pop bx
.next:
        inc di
        jmp .thread
.replies:
        mov al, CAP_REPLY               ; its saved replies: gone
        mov dx, bx
.reply:
        call cap_slot_of                ; SI, DI = a slot naming it
        jc .stack
        push ax
        push dx
        call slot_clear
        pop dx
        pop ax
        jmp .reply
.stack:
        mov bx, dx
        mov di, [bx + T_STACK]
        add di, gdt
        xor ax, ax
        mov [di], ax                    ; its stack's descriptor: back to the pool
        mov [di + 2], ax
        mov [di + 4], ax
        mov [di + 6], ax
        ret

; ----------------------------------------------------------------------------
; cap_slot_of - a slot holding a capability of a type that names an object
;   In:       AL = the type; DX = the object
;   Out:      CF clear and SI = its shadow entry, DI = its descriptor; or CF
;             set: none
;   Destroys: nothing else
; ----------------------------------------------------------------------------
cap_slot_of:
        push bx
        push cx
        push bp
        xor bp, bp
.space:
        cmp bp, [space_bytes]
        jae .none
        mov bx, [ds:space_list + bp]    ; (BP addresses SS but for this)
        mov cx, [bx + SP_SLOTS]
        lea di, [bx + SP_LDT]           ; DI = its first descriptor
        mov si, cx
        shl si, 3
        add si, di                      ; SI = its first shadow entry
.slot:
        cmp [si + SH_TYPE], al
        jne .next
        cmp [si + SH_OBJECT], dx
        je .found
.next:
        add si, SHADOW_SIZE
        add di, 8
        loop .slot
        add bp, 2
        jmp .space
.found:
        clc
        jmp .out
.none:
        stc
.out:
        pop bp
        pop cx
        pop bx
        ret

; ----------------------------------------------------------------------------
; space_destroy - a space dies: its threads stop and lose it, and its
; slots wait in dead_spaces to be emptied (dead_flush)
;   In:       BX = the space
;   Out:      nothing
;   Destroys: AX, CX, SI, DI
; ----------------------------------------------------------------------------
space_destroy:
        cmp byte [bx + SP_DEAD], 0
        jne .done
        mov byte [bx + SP_DEAD], 1
        xor di, di
.thread:
        cmp di, [thread_count]
        jae .listed
        push di
        shl di, 1
        mov si, [thread_list + di]
        pop di
        cmp [si + T_SPACE], bx
        jne .next
        cmp si, [cur_thread]
        jne .stop
        or byte [si + T_FLAGS], TF_DEAD ; the running thread: at its way back
        jmp .next
.stop:
        push bx
        mov bx, si
        cmp byte [bx + T_STATE], TS_FREE
        je .free
        cmp byte [bx + T_STATE], TS_STOPPED
        je .free
        call thread_stop
.free:
        mov byte [bx + T_STATE], TS_FREE    ; to be configured again, if at all
        and byte [bx + T_FLAGS], ~(TF_CONFIGURED | TF_SESSION) & 0xFF
        mov word [bx + T_SPACE], 0
        pop bx
.next:
        inc di
        jmp .thread
.listed:
        mov di, [dead_count]
        shl di, 1
        mov [dead_spaces + di], bx
        inc word [dead_count]
.done:
        ret

; ----------------------------------------------------------------------------
; dead_flush - the slots of every dead space emptied, which may kill more;
; then each out of the list, and its LDT's descriptor back to the pool if no
; thread names it
;   In:       DS = SEL_KDATA; interrupts off
;   Out:      nothing
;   Destroys: nothing
; ----------------------------------------------------------------------------
dead_flush:
        push ax
        push bx
        push si
        push di
.space:
        mov di, [dead_count]
        test di, di
        jz .done
        dec di
        mov [dead_count], di
        shl di, 1
        mov bx, [dead_spaces + di]
        xor ax, ax
.slot:
        cmp ax, [bx + SP_SLOTS]
        jae .emptied
        push ax
        call slot_at                    ; SI = its shadow entry
        pop ax
        cmp byte [si + SH_TYPE], CAP_EMPTY
        je .next
        call cap_delete_at
.next:
        inc ax
        jmp .slot
.emptied:
        call space_unlist
        call space_free_ldt
        jmp .space
.done:
        pop di
        pop si
        pop bx
        pop ax
        ret

; ----------------------------------------------------------------------------
; space_free_ldt - a dead space's LDT descriptor back to the pool, unless a
; thread still names the space (the running thread, which dies at its way
; back, and frees it then)
;   In:       BX = the space
;   Out:      nothing
;   Destroys: nothing
; ----------------------------------------------------------------------------
space_free_ldt:
        push ax
        push cx
        push si
        push di
        xor di, di
.thread:
        cmp di, [thread_count]
        jae .free
        push di
        shl di, 1
        mov si, [thread_list + di]
        pop di
        cmp [si + T_SPACE], bx
        je .named
        inc di
        jmp .thread
.free:
        mov di, [bx + SP_GDT_SELECTOR]
        test di, di
        jz .named
        mov word [bx + SP_GDT_SELECTOR], 0
        add di, gdt
        xor ax, ax
        mov [di], ax
        mov [di + 2], ax
        mov [di + 4], ax
        mov [di + 6], ax
.named:
        pop di
        pop si
        pop cx
        pop ax
        ret

; ----------------------------------------------------------------------------
; thread_die - the running thread, dead (TF_DEAD): forgotten, and never run
; again; its space's LDT freed if the space is dead too
;   In:       DS = SEL_KDATA; interrupts off
;   Out:      does not return
;   Destroys: everything
; ----------------------------------------------------------------------------
thread_die:
        mov bx, [cur_thread]
        call thread_unlist
        mov byte [bx + T_STATE], TS_FREE
        call thread_forget              ; its stack's descriptor too: SS keeps it
        mov si, [bx + T_SPACE]
        test si, si
        jz .gone
        cmp byte [si + SP_DEAD], 0
        je .gone
        push bx
        mov bx, si
        call space_free_ldt             ; LDTR keeps it until the switch
        pop bx
.gone:
        call schedule                   ; never back: nobody makes it ready
        jmp thread_die                  ; (not reached)

; ----------------------------------------------------------------------------
; kc_revoke - KCALL_REVOKE: every capability below a slot of the caller's
; deleted, a leaf at a time; an untyped's memory free again
;   In:       BP = the frame (DX the slot)
;   Out:      the frame's status (KE_CAP: an empty slot)
;   Destroys: AX, BX, CX, DX, SI, DI
; ----------------------------------------------------------------------------
kc_revoke:
        mov ax, [bp + FRAME_DX]
        mov bx, [cur_thread]
        mov bx, [bx + T_SPACE]
        call slot_of                    ; AX = the slot, SI its shadow entry
        jc kc_done.cap
        cmp byte [si + SH_TYPE], CAP_EMPTY
        je kc_done.cap
        mov [revoke_space], bx
        mov [revoke_slot], ax
.leaf:
        mov bx, [revoke_space]
        mov ax, [revoke_slot]
        call slot_at                    ; still there? (its space may have died)
        cmp byte [si + SH_TYPE], CAP_EMPTY
        je .revoked
        mov ax, [revoke_slot]
        call cap_find_child             ; DX, CX = a child
        jc .revoked
.down:
        mov bx, dx                      ; down to a leaf
        mov ax, cx
        call cap_find_child
        jnc .down
        call cap_delete_at              ; BX, AX: a leaf
        call dead_flush
        jmp .leaf
.revoked:
        mov bx, [revoke_space]
        mov ax, [revoke_slot]
        call slot_at
        cmp byte [si + SH_TYPE], CAP_UNTYPED
        jne kc_done.ok
        xor ax, ax                      ; nothing made from it is left
        mov [si + SH_WATERMARK], ax
        mov [si + SH_HOLE], ax
        mov [si + SH_HOLE_END], ax
        jmp kc_done.ok
