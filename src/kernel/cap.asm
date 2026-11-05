; ============================================================================
; rx286 - src/kernel/cap.asm
; Capabilities and the kernel's memory: untyped memory, retype, spaces and
; their slots, copy, move and mint, threads made from capabilities, and the
; kernel's calls on INT 31h (roadmap l4.md L3; D4, D7, D8, D20).
;
; The kernel allocates nothing of its own after its start. Its objects -
; spaces, threads, endpoints, notifications - live in the arena, within its
; data segment's 64 KB, and are made by retyping untyped memory that a
; program holds as a capability; memory for programs' segments is
; retyped likewise, from untyped memory outside the arena, and zeroed
; (l4.md X14). A space is an LDT and a shadow entry for each of its slots:
; a slot's selector is the capability's name. A segment capability is the
; descriptor itself, checked by the CPU on every use; every other capability
; is an all-zero descriptor, invisible to the program (l4.md E2), and its
; shadow entry says what it is. The GDT gives each space an LDT descriptor
; and each thread a kernel stack from two pools, and holds nothing else a
; program could load. No call here waits, so they need not be serialised as
; the system calls are (thread.asm). At its start the kernel makes one
; space and one thread, the root's, from the image's first module, and
; gives the root everything else (l4.md L5).
; ============================================================================

ARENA_PARA          equ ARENA_PHYS >> 4
ROOT_MODULE         equ MODULE_TABLE_VOFF + MODULE_HEADER_SIZE  ; the first entry

begin_kdata
; The kernel's own untyped memory: the arena, from which it makes the
; root's space and thread at start; what is left is the root's. Laid out as
; a shadow entry.
boot_untyped:
        db CAP_UNTYPED, 0
        dw ARENA_PARA, ARENA_SIZE >> 4, 0, 0, 0
        times SHADOW_SIZE - 12 db 0
; The memory for programs' segments, likewise: the root's data and stack
; first.
memory_untyped:
        db CAP_UNTYPED, 0
        dw UMEM_PHYS >> 4, UMEM_SIZE >> 4, 0, 0, 0
        times SHADOW_SIZE - 12 db 0
thread_list         times THREAD_MAX dw 0   ; every thread, in the order made
thread_count        dw 0
kcall_table:
        dw kc_done.nosys                            ; 0
        dw kc_call                                  ; KCALL_CALL (ipc.asm)
        dw kc_reply_recv                            ; KCALL_REPLY_RECV
        dw kc_recv                                  ; KCALL_RECV
        dw kc_send                                  ; KCALL_SEND
        dw kc_signal                                ; KCALL_SIGNAL
        dw kc_poll                                  ; KCALL_POLL
        dw kc_retype                                ; KCALL_RETYPE
        dw kc_copy                                  ; KCALL_COPY
        dw kc_thread                                ; KCALL_THREAD
        dw kc_irq                                   ; KCALL_IRQ
        dw kc_timer                                 ; KCALL_TIMER
        dw kc_segment                               ; KCALL_SEGMENT
        dw kc_delete                                ; KCALL_DELETE
        dw kc_save_reply                            ; KCALL_SAVE_REPLY
        dw kc_revoke                                ; KCALL_REVOKE (revoke.asm)
        dw kc_test                                  ; KCALL_TEST
        dw kc_log                                   ; KCALL_LOG (log.asm)
        dw kc_ticks                                 ; KCALL_TICKS
kcall_table_end:
msg_thread_made     db "thread", 0
; Temporaries of the calls: no kernel call waits, so none is ever two deep.
copy_shadow         dw 0
copy_descriptor     dw 0
copy_slot           dw 0
retype_paragraphs   dw 0
retype_base         dw 0
retype_base_low     dw 0
retype_base_high    db 0
retype_parent_slot  dw 0                ; the untyped's slot: the new capability's parent
copy_dest_space     dw 0                ; a move's destination: its children go there
copy_dest_slot      dw 0
boot_space          dw 0
boot_thread         dw 0
boot_base           times 3 db 0        ; boot_root's: a segment's base
boot_descriptor     times 8 db 0
end_kdata

%if (kcall_table_end - kcall_table) / 2 != KCALL_COUNT
  %error "cap.asm: kcall_table does not match KCALL_COUNT"
%endif

; ----------------------------------------------------------------------------
; kcall_handler - the handler of vector 31h: dispatch on the caller's AH
;   In:       BP = the frame; DS = ES = SEL_KDATA
;   Out:      the frame's AL = the status (CF with an error), and what the
;             call returns
;   Destroys: AX, BX, CX, DX, SI, DI
; ----------------------------------------------------------------------------
kcall_handler:
        mov bl, [bp + FRAME_AX + 1]
        cmp bl, KCALL_COUNT
        jae kc_done.nosys
        xor bh, bh
        shl bx, 1
        jmp [kcall_table + bx]

; ----------------------------------------------------------------------------
; kc_done - the end of a call: its status in the frame's AL (AH 0), CF if an
; error; each local label sets a status and ends the call so
;   In:       AL = KE_* (kc_done itself); BP = the frame
;   Out:      nothing
;   Destroys: AX
; ----------------------------------------------------------------------------
kc_done:
        xor ah, ah
        mov [bp + FRAME_AX], ax
        and word [bp + FRAME_FLAGS], ~FLAGS_CF
        test al, al
        jz .return
        or word [bp + FRAME_FLAGS], FLAGS_CF
.return:
        ret
.ok:
        mov al, KE_OK
        jmp kc_done
.cap:
        mov al, KE_CAP
        jmp kc_done
.arg:
        mov al, KE_ARG
        jmp kc_done
.mem:
        mov al, KE_MEM
        jmp kc_done
.slot:
        mov al, KE_SLOT
        jmp kc_done
.pool:
        mov al, KE_POOL
        jmp kc_done
.state:
        mov al, KE_STATE
        jmp kc_done
.nosys:
        mov al, KE_NOSYS
        jmp kc_done
.empty:
        mov al, KE_EMPTY
        jmp kc_done

; ----------------------------------------------------------------------------
; slot_at - a space's slot: its shadow entry and its LDT descriptor
;   In:       BX = the space; AX = the slot (below its SP_SLOTS)
;   Out:      SI = the shadow entry, DI = the descriptor
;   Destroys: AX
; ----------------------------------------------------------------------------
slot_at:
        push dx
        mov di, ax
        shl di, 3
        add di, bx
        add di, SP_LDT                  ; the descriptor
        mov si, [bx + SP_SLOTS]
        shl si, 3
        add si, bx
        add si, SP_LDT                  ; past the LDT: the shadow entries
        mov dx, SHADOW_SIZE
        mul dx
        add si, ax
        pop dx
        ret

; ----------------------------------------------------------------------------
; slot_of - the slot a selector names in a space
;   In:       BX = the space; AX = the selector
;   Out:      CF clear, AX = the slot, SI = its shadow entry, DI = its
;             descriptor; CF set if the selector names no slot of the space
;   Destroys: nothing else
; ----------------------------------------------------------------------------
slot_of:
        push cx
        mov cx, [bx + SP_SLOTS]
        call selector_slot
        pop cx
        jc .done
        push ax
        call slot_at
        pop ax
        clc
.done:
        ret

; ----------------------------------------------------------------------------
; cap_get - a capability of the running thread's, of one type
;   In:       AX = its selector; CL = the type (CAP_*)
;   Out:      CF clear, SI = the shadow entry, DI = the descriptor, AX = the
;             slot; CF set if the selector names no capability of that type
;   Destroys: nothing else
; ----------------------------------------------------------------------------
cap_get:
        push bx
        mov bx, [cur_thread]
        mov bx, [bx + T_SPACE]
        call slot_of
        pop bx
        jc .done
        cmp [si + SH_TYPE], cl
        je .done
        stc
.done:
        ret

; ----------------------------------------------------------------------------
; untyped_carve - room in untyped memory for an object: in the hole an
; earlier object's alignment left, if it fits there (l4.md L10: the arena's
; objects of 16, 512 and 4,096 bytes left a quarter of it in holes); else at
; the watermark, which moves, and the room skipped to align it becomes the
; hole if it is larger than the one kept
;   In:       SI = the untyped's shadow entry; CX = the object's paragraphs;
;             DX = its alignment in paragraphs (a power of two)
;   Out:      CF clear and AX = its base in paragraphs; CF set if no room
;   Destroys: nothing else
; ----------------------------------------------------------------------------
untyped_carve:
        push bx
        push cx
        push dx
        mov ax, [si + SH_HOLE]
        mov bx, [si + SH_HOLE_END]
        call retype_place               ; within the hole?
        jc .watermark
        mov [si + SH_HOLE], dx          ; the hole now starts past it
        jmp .placed
.watermark:
        pop dx
        push dx
        mov ax, [si + SH_WATERMARK]
        mov bx, [si + SH_SIZE]
        call retype_place               ; AX = its place, DX = the new watermark
        jc .done
        mov bx, ax
        sub bx, [si + SH_WATERMARK]     ; BX = the room skipped
        mov cx, [si + SH_HOLE_END]
        sub cx, [si + SH_HOLE]          ; CX = the hole kept
        cmp bx, cx
        jbe .kept
        mov bx, [si + SH_WATERMARK]
        mov [si + SH_HOLE], bx
        mov [si + SH_HOLE_END], ax
.kept:
        mov [si + SH_WATERMARK], dx
.placed:
        add ax, [si + SH_OBJECT]
        clc
.done:
        pop dx
        pop cx
        pop bx
        ret

; ----------------------------------------------------------------------------
; arena_object - a kernel object of the arena, zeroed: from the arena's
; untyped only (l4.md D7)
;   In:       SI = the untyped's shadow entry; CX = the object's bytes (a
;             power of two, at least 16): it is aligned to its size
;   Out:      CF clear and BX = the object (an offset of kdata); CF set and
;             AL = KE_CAP (not the arena's) or KE_MEM (no room)
;   Destroys: AX, CX, DX, DI, ES
; ----------------------------------------------------------------------------
arena_object:
        mov al, KE_CAP
        call untyped_in_arena
        jc .refuse
        push cx                         ; its bytes
        shr cx, 4
        mov dx, cx                      ; aligned to its size
        call untyped_carve              ; AX = its place, in paragraphs
        pop cx
        jc .full
        sub ax, ARENA_PARA
        shl ax, 4
        add ax, ARENA_OFF
        mov bx, ax                      ; BX = the object
        push ds                         ; zeroed (l4.md X14): exactly its bytes
        pop es
        mov di, bx
        shr cx, 1
        xor ax, ax
        cld
        rep stosw
        clc
        ret
.full:
        mov al, KE_MEM
.refuse:
        stc
        ret

; ----------------------------------------------------------------------------
; scratch_window - one of the kernel's windows on memory, set to some
;   In:       DI = its descriptor (gdt + SEL_SCRATCH or SEL_SCRATCH2); DL:AX =
;             the base; CX = bytes (0 for 64 KB)
;   Out:      nothing
;   Destroys: nothing
; ----------------------------------------------------------------------------
scratch_window:
        push cx
        dec cx
        mov [di], cx                    ; the limit
        mov [di + 2], ax
        mov [di + 4], dl
        mov byte [di + 5], ACC_KDATA
        mov word [di + 6], 0
        pop cx
        ret

; ----------------------------------------------------------------------------
; phys_zero - zero memory by its physical address, through SEL_SCRATCH
;   In:       DL:AX = the base; CX = bytes (even, up to 64 KB; 0 for 64 KB)
;   Out:      nothing
;   Destroys: AX, CX, DI, ES
; ----------------------------------------------------------------------------
phys_zero:
        mov di, gdt + SEL_SCRATCH
        call scratch_window
        mov ax, SEL_SCRATCH
        mov es, ax
        xor di, di
        xor ax, ax
        shr cx, 1
        jnz .words
        mov cx, 0x8000                  ; 64 KB
.words:
        cld
        rep stosw
        push ds
        pop es
        ret

; ----------------------------------------------------------------------------
; phys_copy - copy memory by physical addresses, through SEL_SCRATCH (the
; destination) and SEL_SCRATCH2 (the source)
;   In:       DL:AX = the destination; DH:BX = the source; CX = bytes (even,
;             1 to 65,534)
;   Out:      nothing
;   Destroys: AX, CX, DX, SI, DI, ES
; ----------------------------------------------------------------------------
phys_copy:
        mov di, gdt + SEL_SCRATCH
        call scratch_window
        mov ax, bx
        mov dl, dh
        mov di, gdt + SEL_SCRATCH2
        call scratch_window
        push ds
        mov ax, SEL_SCRATCH
        mov es, ax
        mov ax, SEL_SCRATCH2
        mov ds, ax
        xor si, si
        xor di, di
        shr cx, 1
        cld
        rep movsw
        pop ds
        push ds
        pop es
        ret

; ----------------------------------------------------------------------------
; pool_take - a free descriptor of one of the GDT's pools: all zeros
;   In:       AX = the pool's first selector; CX = its descriptors
;   Out:      CF clear and AX = the free one's selector; CF set if none
;   Destroys: CX, DI
; ----------------------------------------------------------------------------
pool_take:
        mov di, gdt
        add di, ax
.slot:
        cmp byte [di + 5], 0            ; the access byte: 0 is free
        je .found
        add di, 8
        add ax, 8
        loop .slot
        stc
        ret
.found:
        clc
        ret

; ----------------------------------------------------------------------------
; space_make - a space of so many slots, from untyped memory: its LDT's
; descriptor from the pool, every slot empty
;   In:       SI = the untyped's shadow entry; CX = slots (a power of two,
;             SPACE_SLOTS_MIN to SPACE_SLOTS_MAX)
;   Out:      CF clear and BX = the space; CF set and AL = KE_*
;   Destroys: AX, CX, DX, DI, ES
; ----------------------------------------------------------------------------
space_make:
        push cx
        mov ax, SEL_LDT_POOL            ; a descriptor first: nothing to undo after
        mov cx, SPACE_MAX
        call pool_take
        pop cx
        jnc .pooled
        mov al, KE_POOL
        ret
.pooled:
        push ax                         ; the LDT's selector
        push cx                         ; the slots
        mov ax, cx                      ; bytes: the header, 8 a descriptor, the shadows
        mov dx, 8 + SHADOW_SIZE
        mul dx
        add ax, SP_HEADER_SIZE
        mov cx, 16                      ; rounded up to a power of two
.size:
        cmp cx, ax
        jae .sized
        shl cx, 1
        jmp .size
.sized:
        call arena_object               ; BX = the space, zeroed
        pop cx
        pop dx                          ; DX = the LDT's selector
        jc .done
        mov [bx + SP_SLOTS], cx
        mov [bx + SP_GDT_SELECTOR], dx
        mov di, gdt
        add di, dx
        shl cx, 3
        dec cx
        mov [di], cx                    ; the LDT's limit
        mov ax, bx
        add ax, SP_LDT
        add ax, KDATA_BASE & 0xFFFF     ; its base: kdata's, plus the offset
        mov [di + 2], ax
        mov al, KDATA_BASE >> 16
        adc al, 0
        mov [di + 4], al
        mov byte [di + 5], ACC_LDT
        mov word [di + 6], 0
        call space_list_add
        clc
.done:
        ret

; ----------------------------------------------------------------------------
; tcb_make - a thread, from untyped memory: its control block, its kernel
; stack's descriptor from the pool, in the list of threads; not yet started
;   In:       SI = the untyped's shadow entry
;   Out:      CF clear and BX = the thread; CF set and AL = KE_*
;   Destroys: AX, CX, DX, DI, ES
; ----------------------------------------------------------------------------
tcb_make:
        mov al, KE_POOL
        mov cx, [thread_count]
        cmp cx, THREAD_MAX
        jae .refuse
        mov ax, SEL_STACK_POOL
        mov cx, THREAD_MAX
        call pool_take
        jnc .pooled
        mov al, KE_POOL
.refuse:
        stc
        ret
.pooled:
        push ax
        mov cx, TCB_OBJECT_SIZE
        call arena_object               ; BX = the control block, zeroed
        pop dx                          ; DX = its stack's selector
        jc .done
        mov [bx + T_STACK], dx
        mov di, gdt
        add di, dx
        mov word [di], TCB_STACK_SIZE - 1
        mov ax, bx
        add ax, TCB_STACK_OFF
        add ax, KDATA_BASE & 0xFFFF
        mov [di + 2], ax
        mov al, KDATA_BASE >> 16
        adc al, 0
        mov [di + 4], al
        mov byte [di + 5], ACC_KDATA
        mov word [di + 6], 0
        mov word [bx + T_NAME], msg_thread_made
        mov byte [bx + T_SLICE], SLICE_TICKS
        mov di, [thread_count]
        shl di, 1
        mov [thread_list + di], bx
        inc word [thread_count]
        clc
.done:
        ret

; ----------------------------------------------------------------------------
; slot_put_descriptor - a segment capability into an empty slot: a copy of a
; descriptor, and a shadow entry with its memory
;   In:       SI = the shadow entry, DI = the slot's descriptor; DS:BX = the
;             descriptor to copy
;   Out:      nothing
;   Destroys: AX
; ----------------------------------------------------------------------------
slot_put_descriptor:
        mov ax, [bx]
        mov [di], ax
        mov ax, [bx + 2]
        mov [di + 2], ax
        mov ax, [bx + 4]
        mov [di + 4], ax
        mov word [di + 6], 0
        test byte [di + 5], ACC_PRESENT
        jz .empty                       ; an empty descriptor: an empty slot
        mov byte [si + SH_TYPE], CAP_SEGMENT
        push cx
        push dx
        mov ax, [di + 2]                ; the base in paragraphs: 24 bits, shifted 4
        shr ax, 4
        mov dl, [di + 4]
        xor dh, dh
        shl dx, 12
        or ax, dx
        mov [si + SH_OBJECT], ax
        mov ax, [di]                    ; the size in paragraphs: (limit + 16) / 16
        add ax, 16
        rcr ax, 1
        shr ax, 3
        mov [si + SH_SIZE], ax
        pop dx
        pop cx
.empty:
        ret

; ----------------------------------------------------------------------------
; boot_root - at start: the root's space and thread, from the image's first
; module and the kernel's own untyped memory (roadmap l4.md L5), with the
; capabilities the root starts with (kcalls.inc, ROOT_SLOT_*): its code,
; its data (initialised from the module) and its stack; what is left of the
; memory for segments and of the arena, as untyped; the module table and
; each other module's code and data, read-only; its own space and thread;
; the screen's text page; every interrupt line the kernel does not keep
;   In:       DS = ES = SEL_KDATA
;   Out:      BX = the root's thread, configured, not started
;   Destroys: AX, CX, DX, SI, DI, ES
; ----------------------------------------------------------------------------
boot_root:
        mov si, boot_untyped
        mov cx, ROOT_SLOTS
        call space_make                 ; BX = the space
        ASSERT nc, "boot_root: no room for a space"
        mov [boot_space], bx
        mov si, boot_untyped
        call tcb_make                   ; BX = the thread
        ASSERT nc, "boot_root: no room for a thread"
        mov [boot_thread], bx
        mov si, ROOT_MODULE
        mov [bx + T_NAME], si           ; (M_NAME: zero-terminated)
        mov al, [si + M_RING]
        mov [bx + T_RING], al
        mov al, [si + M_PRIORITY]
        mov [bx + T_PRIO], al
        mov ax, [si + M_ENTRY]
        mov [bx + T_ENTRY], ax
        mov ax, [si + M_STACK]
        mov [bx + T_USTACK_TOP], ax
        mov di, [boot_space]
        mov [bx + T_SPACE], di
        mov ax, [di + SP_GDT_SELECTOR]
        mov [bx + T_LDT], ax
        lea ax, [di + SP_LDT]
        mov [bx + T_LDT_LIVE], ax
        or byte [bx + T_FLAGS], TF_CONFIGURED
        ; slots 0, 1, 2: its code; its data and stack, from the memory for
        ; segments
        mov si, ROOT_MODULE
        xor ax, ax
        call boot_module_code
        call boot_root_data
        ; slots 3, 4: what is left of the untyped memory
        mov ax, ROOT_SLOT_UNTYPED
        mov dx, memory_untyped
        call boot_slot_shadow
        mov ax, ROOT_SLOT_ARENA
        mov dx, boot_untyped
        call boot_slot_shadow
        ; slot 5: the module table, read-only
        mov ax, MODULE_TABLE_PHYS & 0xFFFF
        mov dl, MODULE_TABLE_PHYS >> 16
        mov cx, MODULE_TABLE_SIZE - 1
        call root_read_access
        mov bx, ROOT_SLOT_MODULES
        call boot_slot_segment
        ; slots 6, 7: its own space and thread
        mov bx, [boot_space]
        mov ax, ROOT_SLOT_SPACE
        call slot_at
        mov byte [si + SH_TYPE], CAP_SPACE
        mov [si + SH_OBJECT], bx
        mov ax, ROOT_SLOT_THREAD
        call slot_at
        mov byte [si + SH_TYPE], CAP_THREAD
        mov ax, [boot_thread]
        mov [si + SH_OBJECT], ax
        ; the screen's text page, for the console driver (l4.md L8)
        mov ax, VIDEO_PHYS & 0xFFFF
        mov dl, VIDEO_PHYS >> 16
        mov cx, VIDEO_SIZE - 1
        mov dh, ACC_PRESENT | (1 << ACC_DPL_SHIFT) | ACC_SEGMENT | ACC_RW | ACC_ACCESSED
        mov bx, ROOT_SLOT_VIDEO
        call boot_slot_segment
        ; every interrupt line the kernel does not keep
        mov bx, [boot_space]
        xor cx, cx
.line:
        cmp cx, IRQ_CASCADE
        je .kept
        mov di, cx
        shl di, 1
        cmp word [irq_drivers + di], 0
        jne .kept
        mov ax, ROOT_SLOT_IRQ
        add ax, cx
        call slot_at
        mov byte [si + SH_TYPE], CAP_IRQ
        mov [si + SH_OBJECT], cx
.kept:
        inc cx
        cmp cx, IRQ_LINES
        jb .line
        ; the other modules: each one's code and its data as assembled
        mov cx, [MODULE_TABLE_VOFF + MH_COUNT]
        dec cx
        cmp cx, (ROOT_SLOTS - ROOT_SLOT_MODULE) / 2
        ASSERT be, "boot_root: more modules than the root has slots for"
        mov si, ROOT_MODULE
        mov ax, ROOT_SLOT_MODULE
.module:
        jcxz .done
        add si, MODULE_ENTRY_SIZE
        push cx
        push ax
        call boot_module_code
        pop ax
        inc ax
        push ax
        call boot_module_data
        pop ax
        inc ax
        pop cx
        dec cx
        jmp .module
.done:
        mov bx, [boot_thread]
        ret

; ----------------------------------------------------------------------------
; boot_module_code - a module's code, as a segment, into a slot of the
; root's space: of the DPL its table entry says
;   In:       SI = the module's entry; AX = the slot
;   Out:      nothing
;   Destroys: AX, BX, CX, DX, DI
; ----------------------------------------------------------------------------
boot_module_code:
        mov bx, ax
        mov ax, [si + M_CODE]
        call module_base                ; DL:AX
        mov cx, [si + M_CODE_SIZE]
        dec cx
        mov dh, [si + M_RING]
        shl dh, ACC_DPL_SHIFT
        or dh, ACC_PRESENT | ACC_SEGMENT | ACC_CODE | ACC_RW | ACC_ACCESSED
        jmp boot_slot_segment

; ----------------------------------------------------------------------------
; boot_module_data - a module's data as assembled, as a read-only segment of
; the root's (at least a byte), into a slot of the root's space
;   In:       SI = the module's entry; AX = the slot
;   Out:      nothing
;   Destroys: AX, BX, CX, DX, DI
; ----------------------------------------------------------------------------
boot_module_data:
        mov bx, ax
        mov ax, [si + M_DATA]
        call module_base                ; DL:AX
        mov cx, [si + M_DATA_SIZE]
        jcxz .limit
        dec cx
.limit:
        call root_read_access
        jmp boot_slot_segment

; ----------------------------------------------------------------------------
; root_read_access - the access byte of read-only data at the root's ring
;   In:       nothing
;   Out:      DH = the access byte
;   Destroys: nothing
; ----------------------------------------------------------------------------
root_read_access:
        mov dh, [ROOT_MODULE + M_RING]
        shl dh, ACC_DPL_SHIFT
        or dh, ACC_PRESENT | ACC_SEGMENT | ACC_ACCESSED
        ret

; ----------------------------------------------------------------------------
; boot_root_data - the root's data and stack, from the memory for segments:
; its data initialised from its module, the rest of it and its stack zeroed
;   In:       nothing
;   Out:      slots 1 and 2 of the root's space
;   Destroys: AX, BX, CX, DX, SI, DI, ES
; ----------------------------------------------------------------------------
boot_root_data:
        mov si, ROOT_MODULE
        mov cx, [si + M_DATA_ROOM]
        call boot_carve                 ; DL:AX = its base, zeroed
        mov [boot_base], ax
        mov [boot_base + 2], dl
        mov si, ROOT_MODULE
        mov ax, [si + M_DATA]
        call module_base
        mov bx, ax
        mov dh, dl                      ; DH:BX = its data as assembled
        mov cx, [si + M_DATA_SIZE]
        jcxz .copied
        inc cx
        and cx, ~1
        mov ax, [boot_base]
        mov dl, [boot_base + 2]
        call phys_copy
.copied:
        mov ax, [boot_base]
        mov dl, [boot_base + 2]
        mov si, ROOT_MODULE
        mov cx, [si + M_DATA_ROOM]
        mov bx, 1
        call boot_root_segment
        mov cx, [si + M_STACK]
        call boot_carve
        mov si, ROOT_MODULE
        mov cx, [si + M_STACK]
        mov bx, 2
        ; falls through

; ----------------------------------------------------------------------------
; boot_root_segment - writable data at the root's ring into a slot of its
; space
;   In:       BX = the slot; DL:AX = the base; CX = bytes (1 or more)
;   Out:      nothing
;   Destroys: AX, BX, CX, DX, DI
; ----------------------------------------------------------------------------
boot_root_segment:
        dec cx
        mov dh, [ROOT_MODULE + M_RING]
        shl dh, ACC_DPL_SHIFT
        or dh, ACC_PRESENT | ACC_SEGMENT | ACC_RW | ACC_ACCESSED
        jmp boot_slot_segment

; ----------------------------------------------------------------------------
; boot_carve - memory for one of the root's segments, zeroed
;   In:       CX = bytes (even, 2 to 65,534)
;   Out:      DL:AX = its base
;   Destroys: BX, CX, SI, DI, ES
; ----------------------------------------------------------------------------
boot_carve:
        push cx
        add cx, 15
        shr cx, 4
        mov si, memory_untyped
        mov dx, 1
        call untyped_carve              ; AX = its base in paragraphs
        ASSERT nc, "boot_carve: no memory for the root"
        mov dx, ax
        shl ax, 4
        shr dx, 12
        pop cx
        push ax
        push dx
        call phys_zero
        pop dx
        pop ax
        ret

; ----------------------------------------------------------------------------
; module_base - a part of the image as a physical address
;   In:       AX = paragraphs from the image's start
;   Out:      DL:AX = its physical address
;   Destroys: nothing
; ----------------------------------------------------------------------------
module_base:
        add ax, KERNEL_SEG
        mov dl, ah
        shr dl, 4
        shl ax, 4
        ret

; ----------------------------------------------------------------------------
; boot_slot_segment - a segment capability into a slot of the root's space
;   In:       BX = the slot; DL:AX = the base; CX = the limit; DH = the
;             access byte
;   Out:      nothing
;   Destroys: AX, BX, DI
; ----------------------------------------------------------------------------
boot_slot_segment:
        push si
        mov [boot_descriptor], cx
        mov [boot_descriptor + 2], ax
        mov [boot_descriptor + 4], dl
        mov [boot_descriptor + 5], dh
        mov ax, bx
        mov bx, [boot_space]
        call slot_at                    ; SI, DI = the slot
        mov bx, boot_descriptor
        call slot_put_descriptor
        pop si
        ret

; ----------------------------------------------------------------------------
; boot_slot_shadow - an untyped capability of the kernel's into a slot of
; the root's space: a copy of its shadow entry
;   In:       AX = the slot; DX = the shadow entry
;   Out:      nothing
;   Destroys: AX, BX, CX, SI, DI, ES
; ----------------------------------------------------------------------------
boot_slot_shadow:
        mov bx, [boot_space]
        call slot_at
        mov di, si
        mov si, dx
        push ds
        pop es
        mov cx, SHADOW_SIZE / 2
        cld
        rep movsw
        ret

; ----------------------------------------------------------------------------
; kc_retype - KCALL_RETYPE: untyped memory into an object, its capability
; into an empty slot of the caller's
;   In:       BP = the frame (DX untyped, AL type, SI the slot; a segment: CX
;             bytes, BL its access byte; a space: CX slots)
;   Out:      the frame's status
;   Destroys: AX, BX, CX, DX, SI, DI, ES
; ----------------------------------------------------------------------------
kc_retype:
        mov ax, [bp + FRAME_DX]
        mov cl, CAP_UNTYPED
        call cap_get                    ; SI = the untyped, AX its slot
        jc kc_done.cap
        mov [retype_parent_slot], ax
        push si
        mov ax, [bp + FRAME_SI]
        mov bx, [cur_thread]
        mov bx, [bx + T_SPACE]
        call slot_of                    ; SI, DI = the destination
        mov bx, si
        pop si
        jc kc_done.cap
        cmp byte [bx + SH_TYPE], CAP_EMPTY
        jne kc_done.slot
        push bx                         ; the destination's shadow
        push di                         ; and descriptor
        mov al, [bp + FRAME_AX]
        cmp al, CAP_SEGMENT
        je .segment
        cmp al, CAP_UNTYPED
        je .untyped
        cmp al, CAP_SPACE
        je .space
        mov cx, TCB_OBJECT_SIZE
        cmp al, CAP_THREAD
        je .object
        mov cx, SMALL_OBJECT_SIZE
        cmp al, CAP_ENDPOINT
        je .object
        cmp al, CAP_NOTIFY
        je .object
        jmp .arg
.space:
        mov cx, [bp + FRAME_CX]         ; a power of two, within the bounds
        cmp cx, SPACE_SLOTS_MIN
        jb .arg
        cmp cx, SPACE_SLOTS_MAX
        ja .arg
        mov ax, cx
        dec ax
        test ax, cx
        jnz .arg
        call space_make
        jc .error
        jmp .made
.object:
        cmp al, CAP_THREAD
        jne .small
        call tcb_make
        jc .error
        jmp .made
.small:
        call arena_object
        jc .error
.made:
        pop di
        pop si                          ; the destination
        mov al, [bp + FRAME_AX]
        mov [si + SH_TYPE], al
        mov [si + SH_OBJECT], bx
        mov byte [si + SH_RIGHTS], RIGHTS_ALL
        jmp retype_parent
.untyped:
        ; Untyped from untyped (l4.md L12): CX paragraphs, which a revoke of
        ; the new one gives back to it whole
        mov cx, [bp + FRAME_CX]
        test cx, cx
        jz .arg
        mov dx, 1
        call untyped_carve              ; AX = its base in paragraphs
        jc .mem
        pop di
        pop si
        mov byte [si + SH_TYPE], CAP_UNTYPED
        mov [si + SH_OBJECT], ax
        mov ax, [bp + FRAME_CX]
        mov [si + SH_SIZE], ax
        jmp retype_parent
.segment:
        ; Only data, present, of DPL 1-3, and never from the arena (l4.md X14)
        mov al, [bp + FRAME_BX]
        and al, ACC_PRESENT | ACC_SEGMENT | ACC_CODE | ACC_EXPAND_DOWN
        cmp al, ACC_PRESENT | ACC_SEGMENT
        jne .arg
        test byte [bp + FRAME_BX], ACC_DPL_MASK
        jz .arg
        call untyped_in_arena
        jnc .cap
        mov cx, [bp + FRAME_CX]
        jcxz .arg
        add cx, 15
        rcr cx, 1                       ; (a carry is bit 16: up to 64 KB)
        shr cx, 3                       ; CX = paragraphs
        mov [retype_paragraphs], cx
        mov dx, 1
        call untyped_carve              ; AX = its base in paragraphs
        jc .mem
        mov [retype_base], ax
        mov dx, ax                      ; DL:AX = its base
        shl ax, 4
        shr dx, 12
        mov [retype_base_low], ax
        mov [retype_base_high], dl
        mov cx, [bp + FRAME_CX]
        inc cx
        and cx, ~1                      ; bytes to zero, even (0: 64 KB)
        call phys_zero
        pop di                          ; the destination: descriptor
        pop si                          ; and shadow entry
        mov ax, [bp + FRAME_CX]
        dec ax
        mov [di], ax                    ; the limit
        mov ax, [retype_base_low]
        mov [di + 2], ax
        mov al, [retype_base_high]
        mov [di + 4], al
        mov al, [bp + FRAME_BX]
        or al, ACC_ACCESSED             ; preset, as every descriptor of rx286's
        mov [di + 5], al
        mov word [di + 6], 0
        mov byte [si + SH_TYPE], CAP_SEGMENT
        mov ax, [retype_base]
        mov [si + SH_OBJECT], ax
        mov ax, [retype_paragraphs]
        mov [si + SH_SIZE], ax
        jmp retype_parent
.cap:
        mov al, KE_CAP
        jmp .error
.mem:
        mov al, KE_MEM
        jmp .error
.arg:
        mov al, KE_ARG
.error:
        pop di
        pop si
        jmp kc_done

; ----------------------------------------------------------------------------
; retype_parent - the end of a retype: the new capability's parent is the
; untyped it came from, so a revoke of the untyped deletes it (l4.md L12)
;   In:       SI = the new capability's shadow entry; BP = the frame
;   Out:      the frame's status, KE_OK
;   Destroys: AX, BX
; ----------------------------------------------------------------------------
retype_parent:
        mov bx, [cur_thread]
        mov ax, [bx + T_SPACE]
        mov [si + SH_PARENT], ax
        mov ax, [retype_parent_slot]
        mov [si + SH_PARENT_SLOT], ax
        jmp kc_done.ok

; ----------------------------------------------------------------------------
; untyped_in_arena - does untyped memory lie in the arena? (kernel objects
; come from there only, segments never: l4.md X14)
;   In:       SI = the untyped's shadow entry
;   Out:      CF clear if so
;   Destroys: nothing
; ----------------------------------------------------------------------------
untyped_in_arena:
        cmp word [si + SH_OBJECT], ARENA_PARA
        jb .no
        cmp word [si + SH_OBJECT], ARENA_PARA + (ARENA_SIZE >> 4)
        jae .no
        clc
        ret
.no:
        stc
        ret

; ----------------------------------------------------------------------------
; kc_copy - KCALL_COPY: a capability of the caller's into an empty slot of a
; space it holds: a copy, a move, or a mint with a badge; a copy records its
; parent, for revocation (l4.md D8)
;   In:       BP = the frame (DX the space, SI the caller's slot, DI the
;             destination slot, AL COPY_*, BX a badge)
;   Out:      the frame's status
;   Destroys: AX, BX, CX, DX, SI, DI, ES
; ----------------------------------------------------------------------------
kc_copy:
        ; the destination: an empty slot of a space the caller holds
        mov ax, [bp + FRAME_DX]
        mov cl, CAP_SPACE
        call cap_get
        jc kc_done.cap
        mov bx, [si + SH_OBJECT]
        mov ax, [bp + FRAME_DI]
        call slot_of
        jc kc_done.cap
        cmp byte [si + SH_TYPE], CAP_EMPTY
        jne kc_done.slot
        mov [copy_shadow], si
        mov [copy_descriptor], di
        mov [copy_dest_space], bx
        mov [copy_dest_slot], ax
        ; the source: a slot of the caller's that holds something
        mov ax, [bp + FRAME_SI]
        mov bx, [cur_thread]
        mov bx, [bx + T_SPACE]
        call slot_of                    ; AX = its slot; SI, DI
        jc kc_done.cap
        cmp byte [si + SH_TYPE], CAP_EMPTY
        je kc_done.cap
        cmp di, [copy_descriptor]
        je kc_done.cap                      ; the same slot
        mov [copy_slot], ax
        mov al, [bp + FRAME_AX]
        cmp al, COPY_MOVE
        je .copy
        cmp byte [si + SH_TYPE], CAP_UNTYPED
        je kc_done.arg                      ; untyped is moved, never shared
        cmp al, COPY_COPY
        je .copy
        cmp al, COPY_MINT
        jne kc_done.arg
        cmp byte [si + SH_TYPE], CAP_ENDPOINT
        je .mintable
        cmp byte [si + SH_TYPE], CAP_NOTIFY
        jne kc_done.arg
.mintable:
        cmp word [si + SH_BADGE], 0     ; badged once, badged for good
        jne kc_done.arg
        cmp word [bp + FRAME_BX], 0
        je kc_done.arg
.copy:
        push ds
        pop es
        cld
        push si
        push di
        mov si, di                      ; the descriptor
        mov di, [copy_descriptor]
        mov cx, 4
        rep movsw
        pop di
        pop si
        push si
        push di
        mov di, [copy_shadow]           ; the shadow entry
        mov cx, SHADOW_SIZE / 2
        rep movsw
        pop di
        pop si
        mov bx, [copy_shadow]
        cmp byte [bp + FRAME_AX], COPY_MOVE
        je .move
        push si
        mov si, [cur_thread]            ; a copy: its parent is the source
        mov ax, [si + T_SPACE]
        pop si
        mov [bx + SH_PARENT], ax
        mov ax, [copy_slot]
        mov [bx + SH_PARENT_SLOT], ax
        cmp byte [bp + FRAME_AX], COPY_MINT
        jne kc_done.ok
        mov ax, [bp + FRAME_BX]
        mov [bx + SH_BADGE], ax
        mov al, [bp + FRAME_CX]         ; fewer rights, if CL names them
        test al, al
        jz kc_done.ok
        and [bx + SH_RIGHTS], al
        jmp kc_done.ok
.move:
        xor ax, ax                      ; the source slot empties: ES:DI its descriptor
        mov cx, 4
        rep stosw
        mov di, si
        mov cx, SHADOW_SIZE / 2
        rep stosw
        mov bx, [cur_thread]            ; its children go with it (l4.md L12)
        mov bx, [bx + T_SPACE]
        mov ax, [copy_slot]
        mov dx, [copy_dest_space]
        mov cx, [copy_dest_slot]
        call cap_reparent
        jmp kc_done.ok

; ----------------------------------------------------------------------------
; kc_thread - KCALL_THREAD: configure a thread made by retype (its space,
; entry and stack), or start it at a priority; or, in any state, bind it to
; a notification (one each: binding again unbinds the old) or give it a
; fault endpoint (l4.md D18). A space's slots 0, 1 and 2 are its program's
; code, data and stack; slot 0's DPL is the thread's ring, and IOPL 1 goes
; to a thread of ring 1 that asks for it, to no other (l4.md D11). Restart
; starts a started thread's program again, as Ctrl+Break does (l4.md L6)
;   In:       BP = the frame (DX thread, AL THREAD_*; configure: SI space,
;             BX IP, CX SP; start: CL priority, CH START_*; bind: SI a
;             notification it may receive on; fault: SI an endpoint it may
;             send on)
;   Out:      the frame's status
;   Destroys: AX, BX, CX, DX, SI, DI
; ----------------------------------------------------------------------------
kc_thread:
        mov ax, [bp + FRAME_DX]
        mov cl, CAP_THREAD
        call cap_get
        jc kc_done.cap
        mov bx, [si + SH_OBJECT]        ; the thread
        mov al, [bp + FRAME_AX]
        cmp al, THREAD_BIND
        je .bind
        cmp al, THREAD_FAULT
        je .fault
        cmp al, THREAD_RESTART
        je .restart
        cmp al, THREAD_STOP
        je .stop
        cmp al, THREAD_INFO
        je .info
        cmp byte [bx + T_STATE], TS_STOPPED
        je .stopped
        cmp byte [bx + T_STATE], TS_FREE
        jne kc_done.state                   ; started already
        cmp al, THREAD_CONFIGURE
        je .configure
        cmp al, THREAD_START
        je .start
        jmp kc_done.arg
.bind:
        push bx                         ; its notification, bound both ways
        mov ax, [bp + FRAME_SI]
        mov cl, CAP_NOTIFY
        call cap_get
        pop bx
        jc kc_done.cap
        test byte [si + SH_RIGHTS], RIGHT_RECV
        jz kc_done.cap
        mov si, [si + SH_OBJECT]
        mov di, [bx + T_BOUND]          ; one each: the thread's old notification...
        test di, di
        jz .unbound
        mov word [di + N_BOUND], 0
.unbound:
        mov di, [si + N_BOUND]          ; ...and the notification's old thread, unbound
        test di, di
        jz .bound
        mov word [di + T_BOUND], 0
.bound:
        mov [bx + T_BOUND], si
        mov [si + N_BOUND], bx
        jmp kc_done.ok
.fault:
        push bx                         ; its fault endpoint, and the badge
        mov ax, [bp + FRAME_SI]
        mov cl, CAP_ENDPOINT
        call cap_get
        pop bx
        jc kc_done.cap
        test byte [si + SH_RIGHTS], RIGHT_SEND
        jz kc_done.cap
        mov ax, [si + SH_OBJECT]
        mov [bx + T_FAULT], ax
        mov ax, [si + SH_BADGE]
        mov [bx + T_FAULT_BADGE], ax
        jmp kc_done.ok
.restart:
        cmp byte [bx + T_STATE], TS_FREE
        je kc_done.state                ; not started
        call thread_restart
        jmp kc_done.ok
.stop:
        cmp byte [bx + T_STATE], TS_FREE
        je kc_done.state                ; not started
        cmp byte [bx + T_STATE], TS_STOPPED
        je kc_done.state
        cmp bx, [cur_thread]
        je kc_done.arg                  ; a thread does not stop itself
        call thread_stop
        jmp kc_done.ok
.info:
        mov al, [bx + T_STATE]
        mov ah, [bx + T_PRIO]
        mov [bp + FRAME_BX], ax
        mov ax, [bx + T_RUNS]
        mov [bp + FRAME_CX], ax
        jmp kc_done.ok
.stopped:
        cmp al, THREAD_START            ; a stopped thread: started again, at
        jne kc_done.state               ; its entry, at the priority given
        mov cx, [bp + FRAME_CX]
        cmp cl, PRIORITY_MAX
        ja kc_done.arg
        mov [bx + T_PRIO], cl
        call ready_push
        jmp kc_done.ok
.configure:
        push bx
        mov ax, [bp + FRAME_SI]
        mov cl, CAP_SPACE
        call cap_get
        pop bx
        jc kc_done.cap
        mov dx, [si + SH_OBJECT]        ; the space
        mov di, dx
        mov al, [di + SP_LDT + 5]       ; slot 0: present code, its DPL the ring
        mov ah, al
        and ah, ACC_PRESENT | ACC_SEGMENT | ACC_CODE
        cmp ah, ACC_PRESENT | ACC_SEGMENT | ACC_CODE
        jne kc_done.arg
        and al, ACC_DPL_MASK
        mov cl, ACC_DPL_SHIFT
        shr al, cl
        test al, al
        jz kc_done.arg                      ; never ring 0
        mov [bx + T_RING], al
        mov [bx + T_SPACE], dx
        mov ax, [di + SP_GDT_SELECTOR]
        mov [bx + T_LDT], ax
        add di, SP_LDT
        mov [bx + T_LDT_LIVE], di
        call thread_module_name
        mov ax, [bp + FRAME_BX]
        mov [bx + T_ENTRY], ax
        mov ax, [bp + FRAME_CX]
        mov [bx + T_USTACK_TOP], ax
        or byte [bx + T_FLAGS], TF_CONFIGURED
        jmp kc_done.ok
.start:
        test byte [bx + T_FLAGS], TF_CONFIGURED
        jz kc_done.state
        mov cx, [bp + FRAME_CX]
        cmp cl, PRIORITY_MAX
        ja kc_done.arg
        mov [bx + T_PRIO], cl
        test ch, START_FOREGROUND | START_SESSION
        jz .iopl
        mov si, [cur_thread]            ; chosen by ring 1 or 2 only
        cmp byte [si + T_RING], RPL_USER
        je kc_done.arg
        test ch, START_SESSION
        jz .foreground
        or byte [bx + T_FLAGS], TF_SESSION
.foreground:
        test ch, START_FOREGROUND
        jz .iopl
        or byte [bx + T_FLAGS], TF_FOREGROUND
        mov [fg_thread], bx
.iopl:
        test ch, START_IOPL
        jz .go
        cmp byte [bx + T_RING], 1       ; IOPL only for a ring-1 thread
        jne .go
        or byte [bx + T_FLAGS], TF_IOPL
.go:
        call thread_init                ; into its ready queue
%ifdef TEST_FUZZ
        call test_fuzz_alias
%endif
        jmp kc_done.ok

; ----------------------------------------------------------------------------
; thread_module_name - a thread named after the module whose code its space's
; slot 0 holds, if any (the dump, the tests' reports)
;   In:       BX = the thread; DI = its space's LDT
;   Out:      its T_NAME
;   Destroys: AX, CX, DX, SI
; ----------------------------------------------------------------------------
thread_module_name:
        mov ax, [di + 2]                ; slot 0's base, in paragraphs
        shr ax, 4
        mov dl, [di + 4]
        xor dh, dh
        shl dx, 12
        or dx, ax
        sub dx, KERNEL_SEG              ; ... from the image's start
        mov si, ROOT_MODULE
        mov cx, [MODULE_TABLE_VOFF + MH_COUNT]
.module:
        cmp [si + M_CODE], dx
        je .named
        add si, MODULE_ENTRY_SIZE
        loop .module
        ret
.named:
        mov [bx + T_NAME], si
        ret

; ----------------------------------------------------------------------------
; kc_irq - KCALL_IRQ: an interrupt line bound to a notification, which its
; interrupts signal while it is masked until the driver acknowledges; or
; that acknowledgement (l4.md L7, D10)
;   In:       BP = the frame (DX the line's capability; AL IRQ_*; bind: SI a
;             notification it may send on)
;   Out:      the frame's status; the line unmasked
;   Destroys: AX, BX, CX, SI, DI
; ----------------------------------------------------------------------------
kc_irq:
        mov ax, [bp + FRAME_DX]
        mov cl, CAP_IRQ
        call cap_get
        jc kc_done.cap
        mov bx, [si + SH_OBJECT]        ; the line
        mov al, [bp + FRAME_AX]
        cmp al, IRQ_ACK
        je .unmask
        cmp al, IRQ_BIND
        jne kc_done.arg
        push bx
        mov ax, [bp + FRAME_SI]
        mov cl, CAP_NOTIFY
        call cap_get
        pop bx
        jc kc_done.cap
        test byte [si + SH_RIGHTS], RIGHT_SEND
        jz kc_done.cap
        mov ax, [si + SH_BADGE]
        test ax, ax
        jnz .bits
        mov ax, 1
.bits:
        mov di, bx
        shl di, 1
        mov [irq_bits + di], ax
        mov ax, [si + SH_OBJECT]
        mov [irq_notify + di], ax
.unmask:
        call pic_unmask
        jmp kc_done.ok

; ----------------------------------------------------------------------------
; kc_test - KCALL_TEST: the hooks of debug and test builds (KE_NOSYS in
; release builds): the thread dump; in test builds, the bytes a key script
; gave the mouse or typed where the 8042 cannot, whether the OS server
; waits for a key, the sound driver's probes (TEST_SOUND builds) and the
; attack program's (TEST_ATTACK builds)
;   In:       BP = the frame (AL TEST_*; TEST_READER, TEST_PROBE: BL;
;             TEST_SOUND_PROBE: BX)
;   Out:      the frame's BL = a byte; or KE_EMPTY
;   Destroys: AX, BX, CX, DX, SI, DI
; ----------------------------------------------------------------------------
kc_test:
        mov al, [bp + FRAME_AX]
%ifdef WITH_CHECKS
        cmp al, TEST_DUMP
        jne .hooks
        call thread_dump
        jmp kc_done.ok
.hooks:
%endif
%ifdef WITH_TEST_HOOKS
%ifdef TEST_SOUND
        cmp al, TEST_SOUND_PROBE
        jne .silence
        mov bx, [bp + FRAME_BX]
        call test_sound
        jmp kc_done.ok
.silence:
        cmp al, TEST_SILENCE_PROBE
        jne .attack
        call test_silence
        jmp kc_done.ok
.attack:
%endif
%ifdef TEST_ATTACK
        cmp al, TEST_PROBE
        je test_probe
%endif
        cmp al, TEST_READER
        je .reader
        cmp al, TEST_KEYS_READY
        je .ready
        mov bx, test_mouse_ring
        cmp al, TEST_MOUSE_BYTE
        je .byte
        mov bx, test_key_ring
        cmp al, TEST_KEY_BYTE
        jne kc_done.arg
.byte:
        call test_ring_pop
        jc kc_done.empty
        mov [bp + FRAME_BX], al
        jmp kc_done.ok
.reader:
        mov al, [bp + FRAME_BX]
        mov [test_reader], al
        jmp kc_done.ok
.ready:
        mov byte [test_keys_ready], 1
        jmp kc_done.ok
%else
        jmp kc_done.nosys
%endif

; ----------------------------------------------------------------------------
; kc_segment - KCALL_SEGMENT: a segment capability's physical base and
; limit, which a driver needs for DMA (l4.md L9)
;   In:       BP = the frame (DX the segment)
;   Out:      the frame's DL:AX = the base, CX = the limit; CF if not a
;             segment capability
;   Destroys: AX, CX, SI, DI
; ----------------------------------------------------------------------------
kc_segment:
        mov ax, [bp + FRAME_DX]
        mov cl, CAP_SEGMENT
        call cap_get
        jc .refuse
        mov ax, [di + 2]
        mov [bp + FRAME_AX], ax
        mov al, [di + 4]
        mov [bp + FRAME_DX], al
        mov byte [bp + FRAME_DX + 1], 0
        mov ax, [di]
        mov [bp + FRAME_CX], ax
        and word [bp + FRAME_FLAGS], ~FLAGS_CF
        ret
.refuse:
        mov word [bp + FRAME_AX], KE_CAP
        or word [bp + FRAME_FLAGS], FLAGS_CF
        ret
