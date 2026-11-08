; ============================================================================
; rx286 - src/kernel/revoke.asm
; Delete and revoke (roadmap l4.md L12, D8; os-server.md D9): capabilities
; go, objects die with the last capability to them, and memory goes back to
; its untyped.
;
; Every capability has a parent: the slot it was copied, minted or granted
; from, or the untyped it was retyped from. Each parent keeps its children
; in a ring, linked both ways (SH_NEXT, SH_PREV), whose first its SH_CHILD
; names, so that nothing looks through every slot of every space
; (os-server.md D9, as seL4 keeps its derivation tree). Only the first
; child names the parent (SH_PARENT); the others hold 0 there, and find it
; back along the ring (parent_find), so that a delete puts its children in
; its place in its parent's ring, and a move names its new slot, at once,
; telling only the first child, however many there are (P15). A capability
; with no parent is in no ring: its SH_PREV is 0.
; KCALL_REVOKE deletes the first child of a capability until it has none,
; and an untyped revoked has none of its memory used any more: its
; watermark goes back to 0, and the next retype reuses it, zeroed (l4.md
; X14).
;
; Each kernel object - an object anywhere, named by its descriptor's
; selector, which ES holds while the kernel works on it (os-server.md P3) -
; counts the capabilities to it (OBJ_REFS, T_REFS, SP_REFS, irq_refs), and
; dies with the last, its descriptor back to the pool (obj_free): an endpoint's queued threads
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
revoke_object       dw 0                ; revoke_root's: what a revoke revokes (P15)
revoke_type         db 0
dead_spaces         times SPACE_MAX dw 0    ; spaces that died, their slots to empty
dead_count          dw 0
list_bytes          dw 0
unlink_type         db 0
                    db 0
unlink_object       dw 0
ring_next           dw 0, 0             ; ring_*'s: a capability's next, previous and
ring_prev           dw 0, 0             ;    parent (space, slot; the parent 0 unless
ring_parent         dw 0, 0             ;    it is the first), a ring's first and last,
ring_first          dw 0, 0             ;    and a move's old slot (P15)
ring_last           dw 0, 0
ring_old            dw 0, 0
ring_child          dw 0, 0             ; child_link's: the new child
irq_refs            times IRQ_LINES dw 0    ; the capabilities to each interrupt line
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
;   Out:      ES:SI = the shadow entry
;   Destroys: nothing else
; ----------------------------------------------------------------------------
shadow_at:
        push ax
        push di
        call slot_at
        pop di
        pop ax
        ret

; ----------------------------------------------------------------------------
; child_link - a new capability made a child of another, first in its ring
; of children (os-server.md P15); its own children none
;   In:       BX, AX = the parent's space and slot (BX 0: it has none, and
;             it is in no ring); DX, CX = the child's
;   Out:      nothing
;   Destroys: nothing
; ----------------------------------------------------------------------------
child_link:
        push ax
        push bx
        push cx
        push dx
        push di
        push si
        push es
        mov [ring_parent], bx
        mov [ring_parent + 2], ax
        mov [ring_child], dx
        mov [ring_child + 2], cx
        mov bx, dx
        mov ax, cx
        call shadow_at                  ; ES:SI = the child's
        call ring_out
        xor ax, ax
        mov [es:si + SH_CHILD], ax
        mov [es:si + SH_CHILD_SLOT], ax
        cmp word [ring_parent], 0
        je .done                        ; no parent: in no ring
        mov ax, [ring_parent]           ; it names the parent, alone in its ring
        mov [es:si + SH_PARENT], ax     ;    so far
        mov ax, [ring_parent + 2]
        mov [es:si + SH_PARENT_SLOT], ax
        mov [es:si + SH_NEXT], dx
        mov [es:si + SH_NEXT_SLOT], cx
        mov [es:si + SH_PREV], dx
        mov [es:si + SH_PREV_SLOT], cx
        mov bx, [ring_parent]
        mov ax, [ring_parent + 2]
        mov di, SH_CHILD
        call link_get                   ; DX, CX = the parent's old first
        mov [ring_first], dx
        mov [ring_first + 2], cx
        mov dx, [ring_child]
        mov cx, [ring_child + 2]
        call link_set                   ; the child its first
        cmp word [ring_first], 0
        je .done                        ; its only one
        mov bx, [ring_first]
        mov ax, [ring_first + 2]
        mov di, SH_PREV
        call link_get                   ; DX, CX = the last
        mov [ring_last], dx
        mov [ring_last + 2], cx
        mov dx, [ring_child]            ; the old first: after the child, and
        mov cx, [ring_child + 2]        ;    first no longer
        call link_set
        xor dx, dx
        xor cx, cx
        mov di, SH_PARENT
        call link_set
        mov bx, [ring_last]             ; the last: before the child
        mov ax, [ring_last + 2]
        mov dx, [ring_child]
        mov cx, [ring_child + 2]
        mov di, SH_NEXT
        call link_set
        mov bx, dx
        mov ax, cx
        mov dx, [ring_last]
        mov cx, [ring_last + 2]
        mov di, SH_PREV
        call link_set
        mov dx, [ring_first]
        mov cx, [ring_first + 2]
        mov di, SH_NEXT
        call link_set
.done:
        pop es
        pop si
        pop di
        pop dx
        pop cx
        pop bx
        pop ax
        ret

; ----------------------------------------------------------------------------
; link_get - one of a capability's links, a space and a slot
;   In:       BX, AX = the capability; DI = the link's offset in its shadow
;             entry (SH_PARENT, SH_PREV, SH_NEXT, SH_CHILD)
;   Out:      DX, CX = what it names (0: nothing)
;   Destroys: nothing else
; ----------------------------------------------------------------------------
link_get:
        push si
        push es
        call shadow_at
        add si, di
        mov dx, [es:si]
        mov cx, [es:si + 2]
        pop es
        pop si
        ret

; ----------------------------------------------------------------------------
; link_set - one of a capability's links set
;   In:       BX, AX = the capability; DI = the link's offset in its shadow
;             entry; DX, CX = what it is to name (0: nothing)
;   Out:      nothing
;   Destroys: nothing
; ----------------------------------------------------------------------------
link_set:
        push si
        push es
        call shadow_at
        add si, di
        mov [es:si], dx
        mov [es:si + 2], cx
        pop es
        pop si
        ret

; ----------------------------------------------------------------------------
; ring_out - a capability's links to its parent and its siblings cleared:
; in no ring
;   In:       ES:SI = its shadow entry
;   Out:      nothing
;   Destroys: nothing
; ----------------------------------------------------------------------------
ring_out:
        push ax
        xor ax, ax
        mov [es:si + SH_PARENT], ax
        mov [es:si + SH_PARENT_SLOT], ax
        mov [es:si + SH_PREV], ax
        mov [es:si + SH_PREV_SLOT], ax
        mov [es:si + SH_NEXT], ax
        mov [es:si + SH_NEXT_SLOT], ax
        pop ax
        ret

; ----------------------------------------------------------------------------
; ring_read - a capability's next, previous and parent into ring_next,
; ring_prev and ring_parent (the parent 0 unless it is the first)
;   In:       ES:SI = its shadow entry
;   Out:      nothing
;   Destroys: nothing
; ----------------------------------------------------------------------------
ring_read:
        push ax
        mov ax, [es:si + SH_NEXT]
        mov [ring_next], ax
        mov ax, [es:si + SH_NEXT_SLOT]
        mov [ring_next + 2], ax
        mov ax, [es:si + SH_PREV]
        mov [ring_prev], ax
        mov ax, [es:si + SH_PREV_SLOT]
        mov [ring_prev + 2], ax
        mov ax, [es:si + SH_PARENT]
        mov [ring_parent], ax
        mov ax, [es:si + SH_PARENT_SLOT]
        mov [ring_parent + 2], ax
        pop ax
        ret

; ----------------------------------------------------------------------------
; ring_leave - a capability out of its parent's ring: its previous and its
; next each other's; if it was the first, its next is, naming the parent
;   In:       BX, AX = the capability, in a ring
;   Out:      it in no ring
;   Destroys: nothing
; ----------------------------------------------------------------------------
ring_leave:
        push ax
        push bx
        push cx
        push dx
        push di
        push si
        push es
        call shadow_at
        call ring_read
        call ring_out
        cmp [ring_next], bx
        jne .others
        cmp [ring_next + 2], ax
        jne .others
        mov bx, [ring_parent]           ; alone: the first, its parent's only child
        mov ax, [ring_parent + 2]
        xor dx, dx
        xor cx, cx
        mov di, SH_CHILD
        call link_set
        jmp .done
.others:
        mov bx, [ring_prev]             ; its previous and its next: each other's
        mov ax, [ring_prev + 2]
        mov dx, [ring_next]
        mov cx, [ring_next + 2]
        mov di, SH_NEXT
        call link_set
        mov dx, bx
        mov cx, ax
        mov bx, [ring_next]
        mov ax, [ring_next + 2]
        mov di, SH_PREV
        call link_set
        cmp word [ring_parent], 0
        je .done
        mov dx, [ring_parent]           ; it was the first: the next is
        mov cx, [ring_parent + 2]
        mov di, SH_PARENT
        call link_set
        mov dx, bx
        mov cx, ax
        mov bx, [ring_parent]
        mov ax, [ring_parent + 2]
        mov di, SH_CHILD
        call link_set
.done:
        pop es
        pop si
        pop di
        pop dx
        pop cx
        pop bx
        pop ax
        ret

; ----------------------------------------------------------------------------
; ring_replace - a capability's ring of children in its place in its
; parent's ring, at once, however many they are (os-server.md P15): only
; its first child is told, which names the parent if the capability was the
; first, else nothing; the capability in no ring, with no children
;   In:       BX, AX = the capability, in a ring, with children
;   Out:      nothing
;   Destroys: nothing
; ----------------------------------------------------------------------------
ring_replace:
        push ax
        push bx
        push cx
        push dx
        push di
        push si
        push es
        push bx
        push ax
        call shadow_at
        call ring_read
        call ring_out
        mov dx, [es:si + SH_CHILD]      ; its first child, and its last
        mov cx, [es:si + SH_CHILD_SLOT]
        mov word [es:si + SH_CHILD], 0
        mov word [es:si + SH_CHILD_SLOT], 0
        mov [ring_first], dx
        mov [ring_first + 2], cx
        mov bx, dx
        mov ax, cx
        mov di, SH_PREV
        call link_get
        mov [ring_last], dx
        mov [ring_last + 2], cx
        pop ax
        pop bx
        cmp [ring_next], bx
        jne .others
        cmp [ring_next + 2], ax
        je .parent                      ; alone: the children are the whole ring
.others:
        mov bx, [ring_prev]             ; previous, first ... last, next
        mov ax, [ring_prev + 2]
        mov dx, [ring_first]
        mov cx, [ring_first + 2]
        mov di, SH_NEXT
        call link_set
        mov bx, dx
        mov ax, cx
        mov dx, [ring_prev]
        mov cx, [ring_prev + 2]
        mov di, SH_PREV
        call link_set
        mov bx, [ring_last]
        mov ax, [ring_last + 2]
        mov dx, [ring_next]
        mov cx, [ring_next + 2]
        mov di, SH_NEXT
        call link_set
        mov bx, dx
        mov ax, cx
        mov dx, [ring_last]
        mov cx, [ring_last + 2]
        mov di, SH_PREV
        call link_set
.parent:
        mov bx, [ring_first]            ; the first child: names the parent if
        mov ax, [ring_first + 2]        ;    it is the first now, else nothing
        mov dx, [ring_parent]
        mov cx, [ring_parent + 2]
        mov di, SH_PARENT
        call link_set
        test dx, dx
        jz .done
        mov dx, bx                      ; the parent's first: it
        mov cx, ax
        mov bx, [ring_parent]
        mov ax, [ring_parent + 2]
        mov di, SH_CHILD
        call link_set
.done:
        pop es
        pop si
        pop di
        pop dx
        pop cx
        pop bx
        pop ax
        ret

; ----------------------------------------------------------------------------
; children_free - the children of a capability in no ring (one with no
; parent) each in no ring, with no parent, as it is: a walk of them, with an
; interrupt window every CHILDREN_WINDOW, where no thread gives way (P15)
;   In:       ES:SI = the capability's shadow entry (with children); DS =
;             SEL_KDATA; interrupts off
;   Out:      its children none
;   Destroys: nothing
; ----------------------------------------------------------------------------
children_free:
        push ax
        push bx
        push di
        push si
        push es
        mov bx, [es:si + SH_CHILD]
        mov ax, [es:si + SH_CHILD_SLOT]
        mov word [es:si + SH_CHILD], 0
        mov word [es:si + SH_CHILD_SLOT], 0
        mov [ring_first], bx
        mov [ring_first + 2], ax
        xor di, di                      ; DI = children walked
.child:
        call shadow_at                  ; ES:SI = a child's
        mov bx, [es:si + SH_NEXT]
        mov ax, [es:si + SH_NEXT_SLOT]
        call ring_out
        inc di
        test di, CHILDREN_WINDOW - 1
        jnz .walked
        IWINDOW (VEC_KCALL << 8) | KCALL_DELETE
.walked:
        cmp bx, [ring_first]
        jne .child
        cmp ax, [ring_first + 2]
        jne .child
        pop es
        pop si
        pop di
        pop bx
        pop ax
        ret

; ----------------------------------------------------------------------------
; parent_find - a capability's parent: the first of its ring names it, the
; others nothing (a delete or a move tells the first alone, P15), so it is
; found back along SH_PREV, with an interrupt window every CHILDREN_WINDOW,
; where no thread gives way
;   In:       ES:SI = its shadow entry; BP = the frame (its AH the call)
;   Out:      BX, AX = the parent's space and slot (BX 0: it has none)
;   Destroys: nothing else
; ----------------------------------------------------------------------------
parent_find:
        push cx
        push si
        push es
        xor cx, cx
.look:
        mov bx, [es:si + SH_PARENT]
        test bx, bx
        jnz .found
        mov bx, [es:si + SH_PREV]
        test bx, bx
        jz .done                        ; in no ring: none
        mov ax, [es:si + SH_PREV_SLOT]
        call shadow_at
        inc cx
        test cx, CHILDREN_WINDOW - 1
        jnz .look
        call call_iwindow
        jmp .look
.found:
        mov ax, [es:si + SH_PARENT_SLOT]
.done:
        pop es
        pop si
        pop cx
        ret

; ----------------------------------------------------------------------------
; cap_moved - a capability moved to another slot (KCALL_COPY's move): its
; previous and next in its ring, its parent if it is the first, its first
; child, and the back link of a saved reply's caller name the new slot; at
; once, however many children it has (P15)
;   In:       BX, AX = the old space and slot; DX, CX = the new
;   Out:      nothing
;   Destroys: nothing
; ----------------------------------------------------------------------------
cap_moved:
        push ax
        push bx
        push cx
        push dx
        push si
        push di
        push es
        mov [ring_old], bx
        mov [ring_old + 2], ax
        mov bx, dx
        mov ax, cx
        call shadow_at                  ; ES:SI = the new one's
        cmp word [es:si + SH_PREV], 0
        je .reply                       ; in no ring
        call ring_read
        mov ax, [ring_old]
        cmp [ring_next], ax
        jne .others
        mov ax, [ring_old + 2]
        cmp [ring_next + 2], ax
        jne .others
        mov [es:si + SH_NEXT], dx       ; alone: itself, in the new slot
        mov [es:si + SH_NEXT_SLOT], cx
        mov [es:si + SH_PREV], dx
        mov [es:si + SH_PREV_SLOT], cx
        jmp .first
.others:
        mov bx, [ring_prev]
        mov ax, [ring_prev + 2]
        mov di, SH_NEXT
        call link_set
        mov bx, [ring_next]
        mov ax, [ring_next + 2]
        mov di, SH_PREV
        call link_set
.first:
        cmp word [ring_parent], 0
        je .reply
        mov bx, [ring_parent]           ; the first: its parent's first
        mov ax, [ring_parent + 2]
        mov di, SH_CHILD
        call link_set
.reply:
        mov bx, [ring_old]
        mov ax, [ring_old + 2]
        cmp byte [es:si + SH_TYPE], CAP_REPLY
        jne .children
        mov di, [es:si + SH_OBJECT]     ; the caller it is owed to
        test di, di
        jz .children
        push es
        mov es, di
        cmp [es:T_SAVED_SPACE], bx
        jne .not_saved
        cmp [es:T_SAVED_SLOT], ax
        jne .not_saved
        mov [es:T_SAVED_SPACE], dx
        mov [es:T_SAVED_SLOT], cx
.not_saved:
        pop es
.children:
        mov bx, [es:si + SH_CHILD]      ; its first child names it
        mov ax, [es:si + SH_CHILD_SLOT]
        test bx, bx
        jz .done
        mov di, SH_PARENT
        call link_set
.done:
        pop es
        pop di
        pop si
        pop dx
        pop cx
        pop bx
        pop ax
        ret

; ----------------------------------------------------------------------------
; cap_delete_at - a capability deleted: its children in its place in its
; parent's ring (in no ring, if it has none), its slot emptied, and its
; object dead if it was the last capability to it. Nothing looks through
; the slots, nor through its children: a delete's time grows with neither
; (os-server.md D9, P15)
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
        call shadow_at                  ; ES:SI = its shadow entry
        cmp word [es:si + SH_CHILD], 0
        je .childless
        cmp word [es:si + SH_PREV], 0
        je .free
        call ring_replace               ; its children in its place
        jmp .unlinked
.free:
        call children_free              ; no parent: theirs none either
        jmp .unlinked
.childless:
        cmp word [es:si + SH_PREV], 0
        je .unlinked
        call ring_leave
.unlinked:
        mov al, [es:si + SH_TYPE]
        mov [unlink_type], al
        mov ax, [es:si + SH_OBJECT]
        mov [unlink_object], ax
        cmp byte [unlink_type], CAP_REPLY
        jne .clear
        call reply_unlink               ; (AX the caller; DX, CX the slot)
.clear:
        mov bx, dx
        mov ax, cx
        call slot_at                    ; ES:SI, ES:DI = the slot
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

; ----------------------------------------------------------------------------
; reply_unlink - a saved reply gone from a slot: the back link of the caller
; it was owed to cleared, if it names that slot
;   In:       AX = the caller (0: a reply superseded, owed to nobody); DX, CX
;             = the slot's space and slot
;   Out:      nothing
;   Destroys: nothing
; ----------------------------------------------------------------------------
reply_unlink:
        test ax, ax
        jz .done
        push es
        mov es, ax
        cmp [es:T_SAVED_SPACE], dx
        jne .other
        cmp [es:T_SAVED_SLOT], cx
        jne .other
        mov word [es:T_SAVED_SPACE], 0
        mov word [es:T_SAVED_SLOT], 0
.other:
        pop es
.done:
        ret

; ----------------------------------------------------------------------------
; obj_refs - where a kernel object counts the capabilities to it
;   In:       AL = the type; DX = the object (its SH_OBJECT)
;   Out:      CF clear, ES:DI = the count; CF set if the type is no kernel
;             object's (memory, a reply)
;   Destroys: nothing
; ----------------------------------------------------------------------------
obj_refs:
        cmp al, CAP_IRQ
        je .irq
        mov di, OBJ_REFS
        cmp al, CAP_ENDPOINT
        je .object
        cmp al, CAP_NOTIFY
        je .object
        mov di, T_REFS
        cmp al, CAP_THREAD
        je .object
        mov di, SP_REFS
        cmp al, CAP_SPACE
        je .object
        stc
        ret
.object:
        mov es, dx
        clc
        ret
.irq:
        push ds
        pop es
        mov di, dx
        shl di, 1
        add di, irq_refs
        clc
        ret

; ----------------------------------------------------------------------------
; obj_ref - one more capability to an object, if it is a kernel object
;   In:       AL = the type; DX = the object
;   Out:      nothing
;   Destroys: nothing
; ----------------------------------------------------------------------------
obj_ref:
        push di
        push es
        call obj_refs
        jc .done
        inc word [es:di]
.done:
        pop es
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
        push es
        call obj_refs
        jc .lives
        dec word [es:di]
        jnz .lives
        stc
        jmp .done
.lives:
        clc
.done:
        pop es
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
; cap_last - an object whose last capability has just gone: dead, if it is
; a kernel object
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
; and no thread's faults go to it any more; its descriptor back to the pool
;   In:       BX = the endpoint
;   Out:      nothing
;   Destroys: AX, BX, CX, SI, DI, ES
; ----------------------------------------------------------------------------
endpoint_destroy:
        mov si, bx
.queued:
        mov es, si
        mov bx, [es:E_HEAD]
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
        mov es, [thread_list + di]
        pop di
        cmp [es:T_FAULT], si
        jne .next
        mov word [es:T_FAULT], 0
.next:
        inc di
        jmp .thread
.done:
        mov bx, si
        jmp obj_free

; ----------------------------------------------------------------------------
; notify_destroy - a notification dies: its waiter fails with KE_CAP, its
; thread and interrupt lines are unbound, its timer stopped, no suspend
; signals it; its descriptor back to the pool
;   In:       BX = the notification
;   Out:      nothing
;   Destroys: AX, BX, CX, SI, DI, ES
; ----------------------------------------------------------------------------
notify_destroy:
        mov si, bx
        xor di, di                      ; a suspend that was to signal it: not
.suspender:
        cmp di, [thread_count]
        jae .waiter
        push di
        shl di, 1
        mov es, [thread_list + di]
        pop di
        cmp [es:T_SUSPEND_NOTIFY], si
        jne .next_suspender
        mov word [es:T_SUSPEND_NOTIFY], 0
.next_suspender:
        inc di
        jmp .suspender
.waiter:
        mov es, si
        mov bx, [es:N_WAITER]
        test bx, bx
        jz .bound
        mov al, KE_CAP
        call ipc_fail
.bound:
        mov es, si
        mov bx, [es:N_BOUND]
        test bx, bx
        jz .lines
        mov word [es:N_BOUND], 0
        mov es, bx
        mov word [es:T_BOUND], 0
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
        mov bx, si
        jmp obj_free

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
; thread_destroy - a thread dies: stopped for good and forgotten, its
; descriptor back to the pool; the running thread dies at its way back
; instead (thread_die)
;   In:       BX = the thread
;   Out:      nothing
;   Destroys: AX, CX, DX, SI, DI, ES
; ----------------------------------------------------------------------------
thread_destroy:
        cmp bx, [cur_thread]
        jne .other
        mov es, bx
        or byte [es:T_FLAGS], TF_DEAD
        ret
.other:
        call thread_unlist
        jc .done                        ; dead already
        mov es, bx
        cmp byte [es:T_STATE], TS_FREE
        je .stopped
        cmp byte [es:T_STATE], TS_STOPPED
        je .stopped
        call thread_stop
.stopped:
        mov es, bx
        mov byte [es:T_STATE], TS_FREE
        call thread_forget
        call obj_free
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
        mov word [fg_thread], SEL_IDLE
.log:
        cmp [call_owner], bx
        jne .notify
        mov word [call_owner], 0
.notify:
        mov es, bx
        mov si, [es:T_BOUND]
        test si, si
        jz .others
        mov es, si
        mov word [es:N_BOUND], 0
.others:
        xor di, di                      ; the threads it was linked to
.thread:
        cmp di, [thread_count]
        jae .replies
        push di
        shl di, 1
        mov si, [thread_list + di]
        pop di
        mov es, si
        cmp [es:T_REPLY], bx
        jne .caller
        mov word [es:T_REPLY], 0        ; a reply owed to it: nobody waits
.caller:
        cmp byte [es:T_STATE], TS_REPLY
        jne .next
        cmp [es:T_WAIT_OBJ], bx
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
        mov es, bx
        mov ax, [es:T_SAVED_SLOT]       ; the saved reply owed to it: gone (a
        mov bx, [es:T_SAVED_SPACE]      ; reply has no parent and no child)
        test bx, bx
        jz .done
        call slot_at                    ; ES:SI, ES:DI
        call slot_clear
.done:
        mov bx, dx
        mov es, bx
        mov word [es:T_SAVED_SPACE], 0
        mov word [es:T_SAVED_SLOT], 0
        ret

; ----------------------------------------------------------------------------
; space_destroy - a space dies: its threads stop and lose it, and its
; slots wait in dead_spaces to be emptied (dead_flush)
;   In:       BX = the space
;   Out:      nothing
;   Destroys: AX, CX, SI, DI, ES
; ----------------------------------------------------------------------------
space_destroy:
        mov es, bx
        cmp byte [es:SP_DEAD], 0
        jne .done
        mov byte [es:SP_DEAD], 1
        xor di, di
.thread:
        cmp di, [thread_count]
        jae .listed
        push di
        shl di, 1
        mov si, [thread_list + di]
        pop di
        mov es, si
        cmp [es:T_SPACE], bx
        jne .next
        cmp si, [cur_thread]
        jne .stop
        or byte [es:T_FLAGS], TF_ORPHAN ; the running thread: at its way back
        jmp .next
.stop:
        push bx
        mov bx, si
        cmp byte [es:T_STATE], TS_FREE
        je .free
        cmp byte [es:T_STATE], TS_STOPPED
        je .free
        call thread_stop
.free:
        call thread_unconfigure         ; to be configured again, if at all
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
; thread_unconfigure - a thread whose space died, free, to be configured
; again: nothing of its last life kept but its capabilities - no flag (but
; TF_DEAD), no suspender's notification, no call's progress, not the keys
; (os-server.md P15)
;   In:       BX = the thread; DS = SEL_KDATA
;   Out:      ES = the thread
;   Destroys: nothing else
; ----------------------------------------------------------------------------
thread_unconfigure:
        mov es, bx
        mov byte [es:T_STATE], TS_FREE
        and byte [es:T_FLAGS], TF_DEAD
        mov word [es:T_SPACE], 0
        mov word [es:T_SUSPEND_NOTIFY], 0
        mov word [es:T_LOG_DONE], 0
        mov word [es:T_ZERO_PARAS], 0
        cmp [fg_thread], bx
        jne .done
        mov word [fg_thread], SEL_IDLE
.done:
        ret

; ----------------------------------------------------------------------------
; dead_flush - the slots of every dead space emptied, which may kill more:
; the last one listed first, from where its emptying got to (SP_FLUSH), a
; window after each capability deleted, so that a call that gives way meets
; it again (kpreempt); then each out of the list, and its descriptors back
; to the pool if no thread names it
;   In:       DS = SEL_KDATA; interrupts off
;   Out:      nothing
;   Destroys: nothing
; ----------------------------------------------------------------------------
dead_flush:
        push ax
        push bx
        push si
        push di
        push es
.space:
        mov di, [dead_count]
        test di, di
        jz .done
        dec di
        shl di, 1
        mov bx, [dead_spaces + di]
.slot:
        mov es, bx
        mov ax, [es:SP_FLUSH]
        cmp ax, [es:SP_SLOTS]
        jae .emptied
        inc word [es:SP_FLUSH]
        push ax
        call slot_at                    ; ES:SI = its shadow entry
        pop ax
        cmp byte [es:si + SH_TYPE], CAP_EMPTY
        je .slot
        call cap_delete_at
        KWINDOW (VEC_KCALL << 8) | KCALL_REVOKE
        jmp .space                      ; (a delete may have killed another)
.emptied:
        dec word [dead_count]
        call space_unlist
        call space_release
        jmp .space
.done:
        pop es
        pop di
        pop si
        pop bx
        pop ax
        ret

; ----------------------------------------------------------------------------
; space_release - a dead space's descriptors (its LDT's and its own) back
; to the pool, once it is emptied and out of the list and no thread names
; it (the running thread, which dies or stops at its way back, releases it
; then)
;   In:       BX = the space
;   Out:      nothing
;   Destroys: nothing
; ----------------------------------------------------------------------------
space_release:
        push ax
        push si
        push di
        push es
        xor di, di
.listed:
        cmp di, [space_bytes]           ; still listed: dead_flush releases it
        jae .unlisted
        cmp [space_list + di], bx
        je .named
        add di, 2
        jmp .listed
.unlisted:
        xor di, di
.thread:
        cmp di, [thread_count]
        jae .free
        push di
        shl di, 1
        mov es, [thread_list + di]
        pop di
        cmp [es:T_SPACE], bx
        je .named
        inc di
        jmp .thread
.free:
        mov es, bx
        mov ax, [es:SP_GDT_SELECTOR]
        test ax, ax
        jz .named                       ; released already
        mov word [es:SP_GDT_SELECTOR], 0
        push bx
        mov bx, ax
        call obj_free                   ; its LDT's descriptor
        pop bx
        call obj_free                   ; its own
.named:
        pop es
        pop di
        pop si
        pop ax
        ret

; ----------------------------------------------------------------------------
; thread_die - the running thread, dead (TF_DEAD): forgotten, its descriptor
; back to the pool, and never run again; its space released if dead too
;   In:       DS = SEL_KDATA; interrupts off
;   Out:      does not return
;   Destroys: everything
; ----------------------------------------------------------------------------
thread_die:
        mov bx, [cur_thread]
        call thread_unlist
        mov es, bx
        mov byte [es:T_STATE], TS_FREE
        call thread_forget
        mov es, bx
        mov si, [es:T_SPACE]
        call obj_free
        test si, si
        jz .gone
        mov es, si
        cmp byte [es:SP_DEAD], 0
        je .gone
        mov bx, si
        call space_release              ; LDTR keeps it until the switch
.gone:
        jmp schedule_gone               ; never back: nobody makes it ready

; ----------------------------------------------------------------------------
; thread_orphan - the running thread, whose space died (TF_ORPHAN): free, to
; be configured again (its capabilities live on), and off to another; its
; space released now that it names it no longer
;   In:       DS = SEL_KDATA; interrupts off
;   Out:      does not return: THREAD_CONFIGURE and THREAD_START begin it
;             afresh
;   Destroys: everything
; ----------------------------------------------------------------------------
thread_orphan:
        mov bx, [cur_thread]
        mov es, bx
        mov si, [es:T_SPACE]
        call thread_unconfigure
        test si, si
        jz .gone
        push bx
        mov bx, si
        call space_release              ; LDTR keeps it until the switch
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
;   Destroys: AX, BX, CX, DX, SI, DI, ES
; ----------------------------------------------------------------------------
kc_revoke:
        mov es, [cur_thread]
        cmp byte [es:T_CONT], CONT_RESUMED
        je .child                       ; after giving way: where it was
        mov bx, [es:T_SPACE]
        mov ax, [bp + FRAME_DX]
        call slot_of                    ; AX = the slot, ES:SI its shadow entry
        jc kc_done.cap
        cmp byte [es:si + SH_TYPE], CAP_EMPTY
        je kc_done.cap
        mov cl, [es:si + SH_TYPE]
        mov dx, [es:si + SH_OBJECT]
        mov es, [cur_thread]
        mov [es:T_REVOKE_SPACE], bx
        mov [es:T_REVOKE_SLOT], ax
        mov [es:T_REVOKE_TYPE], cl      ; (what is there, checked again after each
        mov [es:T_REVOKE_OBJECT], dx    ;    window: P15)
.child:
        call revoke_root                ; BX, AX, ES:SI: the slot
        jc kc_done.state                ; emptied or another there meanwhile, or its
                                        ;    space gone (P15)
        mov bx, [es:si + SH_CHILD]
        test bx, bx
        jz .revoked
        mov ax, [es:si + SH_CHILD_SLOT]
        call cap_delete_at              ; its children now the slot's first
        call dead_flush
        call revoke_window
        jc kc_done.ok
        jmp .child
.revoked:
        cmp byte [es:si + SH_TYPE], CAP_UNTYPED
        jne kc_done.ok
        cmp word [dead_count], 0        ; a dead space still to empty: emptied and
        je .give_back                   ;    released first, its memory perhaps this
        call dead_flush                 ;    untyped's (P15)
        call revoke_window
        jc kc_done.ok
        jmp .child
.give_back:
        call retypes_cancel             ; a retype zeroing in it: to go no further
        xor ax, ax                      ; nothing made from it is left
        mov [es:si + SH_WATERMARK], ax
        jmp kc_done.ok

; ----------------------------------------------------------------------------
; revoke_root - the slot the running thread's revoke empties below
;   In:       its T_REVOKE_SPACE, T_REVOKE_SLOT
;   Out:      CF clear, BX = the space, AX = the slot, ES:SI = its shadow
;             entry; CF set if the space is dead or the slot empty
;   Destroys: DI
; ----------------------------------------------------------------------------
revoke_root:
        mov es, [cur_thread]
        mov bx, [es:T_REVOKE_OBJECT]
        mov [revoke_object], bx
        mov bl, [es:T_REVOKE_TYPE]
        mov [revoke_type], bl
        mov bx, [es:T_REVOKE_SPACE]
        mov ax, [es:T_REVOKE_SLOT]
        call space_alive
        jc .done
        push ax
        call slot_at
        pop ax
        mov di, [es:si + SH_OBJECT]     ; what was revoked, still there? (P15)
        cmp di, [revoke_object]
        jne .other
        push ax
        mov al, [es:si + SH_TYPE]
        cmp al, [revoke_type]
        pop ax
        jne .other
        clc
        ret
.other:
        stc
.done:
        ret

; ----------------------------------------------------------------------------
; retypes_cancel - every thread's segment retype still zeroing memory of an
; untyped that a revoke gives back marked ZERO_CANCELLED, so that it writes
; nothing more there, nor makes its segment (retype_zero; os-server.md P15)
;   In:       ES:SI = the untyped's shadow entry; DS = SEL_KDATA
;   Out:      nothing
;   Destroys: nothing
; ----------------------------------------------------------------------------
retypes_cancel:
        push ax
        push bx
        push cx
        push dx
        push di
        mov ax, [es:si + SH_OBJECT]     ; DL:AX = its first paragraph, CX its size
        mov dl, [es:si + SH_HIGH]
        mov cx, [es:si + SH_SIZE]
        xor di, di
.thread:
        cmp di, [thread_count]
        jae .done
        push es
        mov bx, di
        shl bx, 1
        mov es, [thread_list + bx]
        cmp word [es:T_ZERO_PARAS], 0
        je .next
        mov bx, [es:T_ZERO_BASE]        ; its retype's base, from the untyped's
        mov dh, [es:T_ZERO_HIGH]
        sub bx, ax
        sbb dh, dl
        jnz .next                       ; (below it, or 1 MB beyond)
        cmp bx, cx
        jae .next
        mov word [es:T_ZERO_SLOT], ZERO_CANCELLED
.next:
        pop es
        inc di
        jmp .thread
.done:
        pop di
        pop dx
        pop cx
        pop bx
        pop ax
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
        push es
        mov es, bx
        cmp byte [es:SP_DEAD], 0
        pop es
        jne .gone
        pop di
        clc
        ret
.gone:
        pop di
        stc
        ret
