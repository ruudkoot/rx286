; ============================================================================
; rx286 - src/kernel/revoke.asm
; Delete and revoke (roadmap l4.md L12, D8; os-server.md D9): capabilities
; go, objects die with the last capability to them, and memory goes back to
; its untyped.
;
; Every capability records its parent: the slot it was copied, minted or
; granted from, or the untyped it was retyped from. Each parent keeps its
; children in a list (SH_CHILD, then each child's SH_NEXT), so that nothing
; looks through every slot of every space (os-server.md D9, as seL4 keeps
; its derivation tree). A delete gives its children to its parent, first in
; the parent's list, so the tree holds; a move takes its children with it.
; KCALL_REVOKE deletes the first child of a capability until it has none,
; and an untyped revoked has none of its memory used any more: its
; watermark goes back to 0, and the next retype reuses it, zeroed (l4.md
; X14).
;
; Each kernel object counts the capabilities to it (OBJ_REFS, T_REFS,
; SP_REFS, irq_refs), and dies with the last: an endpoint's queued threads
; and a notification's waiter fail with KE_CAP; a thread stops for good, and
; every reply and link naming it is cleared (the saved reply owed to it by
; its back link, T_SAVED_SPACE); a space's threads stop and lose it, and its
; slots are emptied in turn - from a list, not by recursion, since a kernel
; stack is small - and its LDT's descriptor goes back to the pool once no
; thread names it. A thread that loses its own last capability dies at its
; way back (thread_die); one that loses its space stops there, free to be
; configured again (thread_orphan). A revoke lets interrupts in, and a more
; urgent thread run, after each capability it deletes and between a dead
; space's slots (KWINDOW).
; ============================================================================

begin_kdata
space_list          times SPACE_MAX dw 0    ; every space, in the order made
space_bytes         dw 0                ; its length, in bytes
dead_spaces         times SPACE_MAX dw 0    ; spaces that died, their slots to empty
dead_count          dw 0
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
; shadow_at - a slot's shadow entry
;   In:       BX = the space; AX = the slot
;   Out:      SI = the shadow entry
;   Destroys: nothing
; ----------------------------------------------------------------------------
shadow_at:
        push ax
        push di
        call slot_at
        pop di
        pop ax
        ret

; ----------------------------------------------------------------------------
; child_link - a new capability made a child of another, first in its list;
; its own list of children empty
;   In:       BX, AX = the parent's space and slot (BX 0: it has none); DX,
;             CX = the child's
;   Out:      nothing
;   Destroys: nothing
; ----------------------------------------------------------------------------
child_link:
        push si
        push di
        xchg bx, dx
        xchg ax, cx
        call shadow_at                  ; SI = the child's
        xchg bx, dx
        xchg ax, cx
        mov [si + SH_PARENT], bx
        mov [si + SH_PARENT_SLOT], ax
        xor di, di
        mov [si + SH_CHILD], di
        mov [si + SH_CHILD_SLOT], di
        mov [si + SH_NEXT], di
        mov [si + SH_NEXT_SLOT], di
        test bx, bx
        jz .done
        mov di, si
        call shadow_at                  ; SI = the parent's
        push word [si + SH_CHILD]
        pop word [di + SH_NEXT]
        push word [si + SH_CHILD_SLOT]
        pop word [di + SH_NEXT_SLOT]
        mov [si + SH_CHILD], dx
        mov [si + SH_CHILD_SLOT], cx
.done:
        pop di
        pop si
        ret

; ----------------------------------------------------------------------------
; link_find - the link that names a capability in its parent's list: the
; parent's SH_CHILD, or a sibling's SH_NEXT
;   In:       SI = a shadow entry whose parent is the capability's; DX, CX =
;             the capability's space and slot
;   Out:      DI = the link (the space's word, then the slot's)
;   Destroys: nothing
; ----------------------------------------------------------------------------
link_find:
        push ax
        push bx
        push si
        mov bx, [si + SH_PARENT]
        mov ax, [si + SH_PARENT_SLOT]
        call shadow_at
        lea di, [si + SH_CHILD]
.link:
        mov bx, [di]
        mov ax, [di + 2]
        cmp bx, dx
        jne .next
        cmp ax, cx
        je .found
.next:
        test bx, bx
        ASSERT nz, "link_find: a capability not in its parent's list"
        call shadow_at
        lea di, [si + SH_NEXT]
        jmp .link
.found:
        pop si
        pop bx
        pop ax
        ret

; ----------------------------------------------------------------------------
; children_adopt - a capability's children given to its parent, first in
; the parent's list; in no list, if it has no parent
;   In:       SI = the capability's shadow entry
;   Out:      its list of children empty
;   Destroys: nothing
; ----------------------------------------------------------------------------
children_adopt:
        push ax
        push bx
        push cx
        push dx
        push di
        mov bx, [si + SH_CHILD]
        test bx, bx
        jz .done
        mov ax, [si + SH_CHILD_SLOT]
        mov dx, [si + SH_PARENT]        ; DX, CX = the new parent
        mov cx, [si + SH_PARENT_SLOT]
        push si
.child:
        call shadow_at                  ; SI = a child's
        mov [si + SH_PARENT], dx
        mov [si + SH_PARENT_SLOT], cx
        mov bx, [si + SH_NEXT]
        mov ax, [si + SH_NEXT_SLOT]
        test dx, dx
        jnz .linked
        mov word [si + SH_NEXT], 0      ; no parent: no list
        mov word [si + SH_NEXT_SLOT], 0
.linked:
        test bx, bx
        jnz .child
        mov di, si                      ; DI = the last child's
        pop si
        test dx, dx
        jz .emptied
        push si
        mov bx, dx
        mov ax, cx
        call shadow_at                  ; SI = the new parent's
        mov ax, [si + SH_CHILD]         ; after the last: the parent's first
        mov [di + SH_NEXT], ax
        mov ax, [si + SH_CHILD_SLOT]
        mov [di + SH_NEXT_SLOT], ax
        pop di                          ; DI = the capability's
        mov ax, [di + SH_CHILD]
        mov [si + SH_CHILD], ax
        mov ax, [di + SH_CHILD_SLOT]
        mov [si + SH_CHILD_SLOT], ax
        mov si, di
.emptied:
        mov word [si + SH_CHILD], 0
        mov word [si + SH_CHILD_SLOT], 0
.done:
        pop di
        pop dx
        pop cx
        pop bx
        pop ax
        ret

; ----------------------------------------------------------------------------
; cap_moved - a capability moved to another slot (KCALL_COPY's move): its
; parent's link and its children's parent name the new slot, and so does
; the back link of a saved reply's caller
;   In:       BX, AX = the old space and slot; DX, CX = the new; SI = the new
;             one's shadow entry, the old's copied
;   Out:      nothing
;   Destroys: nothing
; ----------------------------------------------------------------------------
cap_moved:
        push ax
        push bx
        push si
        push di
        cmp word [si + SH_PARENT], 0
        je .children
        push dx
        push cx
        mov dx, bx
        mov cx, ax
        call link_find                  ; DI = the link that named the old
        pop cx
        pop dx
        mov [di], dx
        mov [di + 2], cx
.children:
        cmp byte [si + SH_TYPE], CAP_REPLY
        jne .child_first
        mov di, [si + SH_OBJECT]        ; the caller it is owed to
        test di, di
        jz .child_first
        cmp [di + T_SAVED_SPACE], bx
        jne .child_first
        cmp [di + T_SAVED_SLOT], ax
        jne .child_first
        mov [di + T_SAVED_SPACE], dx
        mov [di + T_SAVED_SLOT], cx
.child_first:
        mov bx, [si + SH_CHILD]
        mov ax, [si + SH_CHILD_SLOT]
.child:
        test bx, bx
        jz .done
        call shadow_at
        mov [si + SH_PARENT], dx
        mov [si + SH_PARENT_SLOT], cx
        mov bx, [si + SH_NEXT]
        mov ax, [si + SH_NEXT_SLOT]
        jmp .child
.done:
        pop di
        pop si
        pop bx
        pop ax
        ret

; ----------------------------------------------------------------------------
; cap_delete_at - a capability deleted: out of its parent's list, its
; children given to its parent, its slot emptied, and its object dead if it
; was the last capability to it. Nothing looks through the slots: a delete's
; time does not grow with the number of spaces (os-server.md D9)
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
        mov dx, bx
        mov cx, ax
        call shadow_at                  ; SI = its shadow entry
        cmp word [si + SH_PARENT], 0
        je .adopt
        call link_find                  ; DI = the link that names it
        mov ax, [si + SH_NEXT]          ; out of its parent's list
        mov [di], ax
        mov ax, [si + SH_NEXT_SLOT]
        mov [di + 2], ax
.adopt:
        call children_adopt
        mov al, [si + SH_TYPE]
        mov [unlink_type], al
        mov ax, [si + SH_OBJECT]
        mov [unlink_object], ax
        cmp byte [unlink_type], CAP_REPLY
        jne .clear
        call reply_unlink
.clear:
        mov ax, cx
        call slot_at                    ; SI, DI = the slot
        call slot_clear
        mov al, [unlink_type]
        mov dx, [unlink_object]
        call obj_unref
        jnc .done                       ; another names its object: it lives
        call cap_last
.done:
        pop es
        pop di
        pop si
        pop dx
        pop cx
        pop bx
        pop ax
        ret

begin_kdata
unlink_type         db 0
                    db 0
unlink_object       dw 0
irq_refs            times IRQ_LINES dw 0    ; the capabilities to each interrupt line
end_kdata

; ----------------------------------------------------------------------------
; reply_unlink - a saved reply gone from a slot: the back link of the caller
; it was owed to cleared, if it names that slot
;   In:       AX = the caller (0: a reply superseded, owed to nobody); DX, CX
;             = the slot's space and slot
;   Out:      nothing
;   Destroys: nothing
; ----------------------------------------------------------------------------
reply_unlink:
        push di
        mov di, ax
        test di, di
        jz .done
        cmp [di + T_SAVED_SPACE], dx
        jne .done
        cmp [di + T_SAVED_SLOT], cx
        jne .done
        mov word [di + T_SAVED_SPACE], 0
        mov word [di + T_SAVED_SLOT], 0
.done:
        pop di
        ret

; ----------------------------------------------------------------------------
; obj_refs - where a kernel object counts the capabilities to it
;   In:       AL = the type; DX = the object (its SH_OBJECT)
;   Out:      CF clear, DI = the count; CF set if the type is no kernel
;             object's (memory, a reply)
;   Destroys: nothing
; ----------------------------------------------------------------------------
obj_refs:
        mov di, dx
        cmp al, CAP_ENDPOINT
        je .small
        cmp al, CAP_NOTIFY
        je .small
        cmp al, CAP_THREAD
        je .thread
        cmp al, CAP_SPACE
        je .space
        cmp al, CAP_IRQ
        jne .none
        shl di, 1
        add di, irq_refs
        clc
        ret
.small:
        add di, OBJ_REFS
        clc
        ret
.thread:
        add di, T_REFS
        clc
        ret
.space:
        add di, SP_REFS
        clc
        ret
.none:
        stc
        ret

; ----------------------------------------------------------------------------
; obj_ref - one more capability to an object, if it is a kernel object
;   In:       AL = the type; DX = the object
;   Out:      nothing
;   Destroys: nothing
; ----------------------------------------------------------------------------
obj_ref:
        push di
        call obj_refs
        jc .done
        inc word [di]
.done:
        pop di
        ret

; ----------------------------------------------------------------------------
; obj_unref - one capability fewer to an object
;   In:       AL = the type; DX = the object
;   Out:      CF set if that was the last to a kernel object
;   Destroys: nothing
; ----------------------------------------------------------------------------
obj_unref:
        push di
        call obj_refs
        jc .lives
        dec word [di]
        jnz .lives
        stc
        jmp .done
.lives:
        clc
.done:
        pop di
        ret


; ----------------------------------------------------------------------------
; cap_is_object - is a type a kernel object's, which dies with its last
; capability? (Segments and untyped are memory: nothing dies)
;   In:       AL = the type
;   Out:      ZF set if so
;   Destroys: nothing
; ----------------------------------------------------------------------------
cap_is_object:
        cmp al, CAP_ENDPOINT
        je .done
        cmp al, CAP_NOTIFY
        je .done
        cmp al, CAP_THREAD
        je .done
        cmp al, CAP_SPACE
        je .done
        cmp al, CAP_IRQ
.done:
        ret

; ----------------------------------------------------------------------------
; cap_last - an object whose last capability has just gone (cap_unlink
; found no other): dead, if it is a kernel object
;   In:       AL = the type; DX = the object
;   Out:      nothing
;   Destroys: AX, BX, CX, DX, SI, DI, ES
; ----------------------------------------------------------------------------
cap_last:
        call cap_is_object
        jne .done
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
        xor di, di                      ; a suspend that was to signal it: not
.suspender:
        cmp di, [thread_count]
        jae .waiter
        push di
        shl di, 1
        mov bx, [thread_list + di]
        pop di
        cmp [bx + T_SUSPEND_NOTIFY], si
        jne .next_suspender
        mov word [bx + T_SUSPEND_NOTIFY], 0
.next_suspender:
        inc di
        jmp .suspender
.waiter:
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
; keys', the log's; replies it is owed or owes, the saved one by its back
; link
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
        mov dx, bx
        mov ax, [bx + T_SAVED_SLOT]     ; the saved reply owed to it: gone (a
        mov bx, [bx + T_SAVED_SPACE]    ; reply has no parent and no child)
        test bx, bx
        jz .done
        call slot_at                    ; SI, DI
        call slot_clear
.done:
        mov bx, dx
        mov word [bx + T_SAVED_SPACE], 0
        mov word [bx + T_SAVED_SLOT], 0
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
        or byte [si + T_FLAGS], TF_ORPHAN   ; the running thread: at its way back
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
        KWINDOW (VEC_KCALL << 8) | KCALL_REVOKE
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
        call thread_forget
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
        jmp schedule                    ; never back: nobody makes it ready

; ----------------------------------------------------------------------------
; thread_orphan - the running thread, whose space died (TF_ORPHAN): free, to
; be configured again (its capabilities live on), and off to another; its
; space's LDT freed now that it names it no longer
;   In:       DS = SEL_KDATA; interrupts off
;   Out:      does not return: THREAD_CONFIGURE and THREAD_START begin it
;             afresh
;   Destroys: everything
; ----------------------------------------------------------------------------
thread_orphan:
        mov bx, [cur_thread]
        and byte [bx + T_FLAGS], ~(TF_ORPHAN | TF_CONFIGURED | TF_SESSION) & 0xFF
        mov byte [bx + T_STATE], TS_FREE
        mov si, [bx + T_SPACE]
        mov word [bx + T_SPACE], 0
        test si, si
        jz .gone
        push bx
        mov bx, si
        call space_free_ldt             ; LDTR keeps it until the switch
        pop bx
.gone:
        jmp schedule                    ; never back: thread_init starts it anew

; ----------------------------------------------------------------------------
; kc_revoke - KCALL_REVOKE: every capability below a slot of the caller's
; deleted: its first child, whose own children become its first, until it
; has none (l4.md L12; os-server.md D9), with a window after each (l4.md
; L13). What it revokes is kept in the thread, since another thread may
; revoke meanwhile, and the call resumes there if it gives way (kpreempt).
; An untyped's memory is free again; a revoke cut short by a restart
; leaves the rest of the tree as it was
;   In:       BP = the frame (DX the slot)
;   Out:      the frame's status (KE_CAP: an empty slot)
;   Destroys: AX, BX, CX, DX, SI, DI
; ----------------------------------------------------------------------------
kc_revoke:
        mov bx, [cur_thread]
        cmp byte [bx + T_CONT], CONT_RESUMED
        je .child                       ; after giving way: where it was
        mov ax, [bp + FRAME_DX]
        mov bx, [bx + T_SPACE]
        call slot_of                    ; AX = the slot, SI its shadow entry
        jc kc_done.cap
        cmp byte [si + SH_TYPE], CAP_EMPTY
        je kc_done.cap
        mov si, [cur_thread]
        mov [si + T_REVOKE_SPACE], bx
        mov [si + T_REVOKE_SLOT], ax
.child:
        call revoke_root                ; BX, AX, SI: the slot
        jc kc_done.ok                   ; emptied meanwhile, or its space gone
        mov bx, [si + SH_CHILD]
        test bx, bx
        jz .revoked
        mov ax, [si + SH_CHILD_SLOT]
        call cap_delete_at              ; its children now the slot's first
        call dead_flush
        call revoke_window
        jc kc_done.ok
        jmp .child
.revoked:
        cmp byte [si + SH_TYPE], CAP_UNTYPED
        jne kc_done.ok
        xor ax, ax                      ; nothing made from it is left
        mov [si + SH_WATERMARK], ax
        mov [si + SH_HOLE], ax
        mov [si + SH_HOLE_END], ax
        jmp kc_done.ok

; ----------------------------------------------------------------------------
; revoke_root - the slot the running thread's revoke empties below
;   In:       its T_REVOKE_SPACE, T_REVOKE_SLOT
;   Out:      CF clear, BX = the space, AX = the slot, SI = its shadow
;             entry; CF set if the space is dead or the slot empty
;   Destroys: DI
; ----------------------------------------------------------------------------
revoke_root:
        mov si, [cur_thread]
        mov bx, [si + T_REVOKE_SPACE]
        mov ax, [si + T_REVOKE_SLOT]
        call space_alive
        jc .done
        push ax
        call slot_at
        pop ax
        cmp byte [si + SH_TYPE], CAP_EMPTY  ; (CF clear: nothing is below 0)
        jne .done
        stc
.done:
        ret

; ----------------------------------------------------------------------------
; revoke_window - a window between a revoke's stretches; a thread to restart
; goes no further
;   In:       DS = SEL_KDATA; interrupts off
;   Out:      CF set if the thread is to restart
;   Destroys: nothing
; ----------------------------------------------------------------------------
revoke_window:
        KWINDOW (VEC_KCALL << 8) | KCALL_REVOKE
        cmp byte [restart_pending], 1   ; CF clear if set
        cmc
        ret

; ----------------------------------------------------------------------------
; space_alive - is a space still listed, and not dead?
;   In:       BX = the space
;   Out:      CF clear if so
;   Destroys: nothing
; ----------------------------------------------------------------------------
space_alive:
        push di
        xor di, di
.space:
        cmp di, [space_bytes]
        jae .gone
        cmp [space_list + di], bx
        je .listed
        add di, 2
        jmp .space
.listed:
        cmp byte [bx + SP_DEAD], 0
        jne .gone
        pop di
        clc
        ret
.gone:
        pop di
        stc
        ret
