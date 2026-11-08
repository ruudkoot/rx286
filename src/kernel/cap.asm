; ============================================================================
; rx286 - src/kernel/cap.asm
; Capabilities and the kernel's memory: untyped memory, retype, spaces and
; their slots, copy, move and mint, threads made from capabilities, and the
; kernel's calls on INT 31h (roadmap l4.md L3; D4, D7, D8, D20).
;
; The kernel allocates nothing of its own after its start. Its objects -
; spaces, threads, endpoints, notifications - are made by retyping untyped
; memory that a program holds as a capability, anywhere in memory; each has
; a descriptor of its own from the GDT's pool, DPL 0, whose selector is its
; name, and the kernel reaches it with ES (os-server.md P3, D9 C). Memory
; for programs' segments is retyped from any untyped likewise, and zeroed
; (l4.md X14); a watermark never gives the same memory twice, so a segment
; never lies over an object. A space is an LDT and a shadow entry for each
; of its slots: a slot's selector is the capability's name. A segment
; capability is the descriptor itself, checked by the CPU on every use;
; every other capability is an all-zero descriptor, invisible to the program
; (l4.md E2), and its shadow entry says what it is. The GDT gives each
; space a second descriptor for its LDT, and holds nothing a program could
; load. These calls run with interrupts off from start to end, but for
; their windows (a revocation's, a retype's zeroing), where they may give
; way and resume (thread.asm). At its start the kernel makes one space and
; one thread, the root's, from the image's first module, and gives the root
; everything else (l4.md L5).
; ============================================================================

ARENA_PARA          equ ARENA_PHYS >> 4
RETYPE_PIECE        equ 2048            ; bytes zeroed between windows: about 0.8 ms on an AT
ROOT_MODULE         equ MODULE_TABLE_VOFF + MODULE_HEADER_SIZE  ; the first entry

begin_kdata
; The kernel's own untyped memory: the arena, from which it makes the
; root's space and thread at start; what is left is the root's. Laid out as
; a shadow entry.
boot_untyped:
        db CAP_UNTYPED, 0
        dw ARENA_PARA, ARENA_SIZE >> 4, 0, 0, 0
        times SHADOW_SIZE - 12 db 0
; The memory for programs' segments, likewise, from the image's end
; (umem_size): the root's data and stack first.
memory_untyped:
        db CAP_UNTYPED, 0
        dw 0, 0, 0, 0, 0
        times SHADOW_SIZE - 12 db 0
; Extended memory, if the CMOS says there is some (ext_detect): the root's
; slots 3 and 4, each under 1 MB (an untyped's size is 16 bits of
; paragraphs); 0 bytes if none
ext_untyped_a:
        db CAP_UNTYPED, 0
        times SHADOW_SIZE - 2 db 0
ext_untyped_b:
        db CAP_UNTYPED, 0
        times SHADOW_SIZE - 2 db 0
ext_kb              dw 0                ; the extended memory found, in KB
thread_list         times THREAD_MAX dw 0   ; every thread, in the order made
thread_count        dw 0
obj_free_count      dw 0                ; the GDT pool's free descriptors (OBJ_FREE_OFF)
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
        dw kc_seal                                  ; KCALL_SEAL
        dw kc_resize                                ; KCALL_RESIZE
kcall_table_end:
msg_thread_made     db "thread", 0
; Temporaries of the calls: no kernel call waits, so none is ever two deep.
call_place          dw 0                ; a window's place: the frame's call
resize_slot         dw 0                ; kc_resize's: the segment's slot
resize_offset       dw 0                ;    its paragraphs from its untyped's start
resize_untyped      dw 0                ;    its untyped's slot
resize_space        dw 0                ;    the caller's space, where the walk ends
resize_paras        dw 0                ;    its new size, in paragraphs
resize_limit        dw 0                ;    and as a limit
copy_shadow         dw 0
copy_descriptor     dw 0
copy_slot           dw 0
copy_source_space   dw 0
retype_paragraphs   dw 0
retype_base         dw 0
retype_base_low     dw 0
retype_base_high    db 0
retype_base_para_high db 0
retype_parent_slot  dw 0                ; the untyped's slot: the new capability's parent
copy_dest_space     dw 0                ; a move's destination: its children go there
copy_dest_slot      dw 0
boot_space          dw 0
boot_thread         dw 0
boot_base           times 3 db 0        ; boot_root's: a segment's base
boot_descriptor     times 8 db 0
frame_thread        dw 0                ; THREAD_FRAME's thread, across its checks
end_kdata

%if (kcall_table_end - kcall_table) / 2 != KCALL_COUNT
  %error "cap.asm: kcall_table does not match KCALL_COUNT"
%endif

; ----------------------------------------------------------------------------
; kcall_handler - the handler of vector 31h: dispatch on the caller's AH
;   In:       BP = the frame; DS = ES = SEL_KDATA
;   Out:      the frame's AL = the status (CF with an error), and what the
;             call returns
;   Destroys: AX, BX, CX, DX, SI, DI, ES
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
;   Out:      ES = the space; SI = the shadow entry, DI = the descriptor
;   Destroys: AX
; ----------------------------------------------------------------------------
slot_at:
        push dx
        mov es, bx
        mov di, ax
        shl di, 3
        add di, SP_LDT                  ; the descriptor
        mov si, [es:SP_SLOTS]
        shl si, 3
        add si, SP_LDT                  ; past the LDT: the shadow entries
        mov dx, SHADOW_SIZE
        mul dx
        add si, ax
        pop dx
        ret

; ----------------------------------------------------------------------------
; slot_of - the slot a selector names in a space
;   In:       BX = the space; AX = the selector
;   Out:      ES = the space; CF clear, AX = the slot, SI = its shadow
;             entry, DI = its descriptor; CF set if the selector names no
;             slot of the space
;   Destroys: nothing else
; ----------------------------------------------------------------------------
slot_of:
        push cx
        mov es, bx
        mov cx, [es:SP_SLOTS]
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
;   Out:      ES = its space; CF clear, SI = the shadow entry, DI = the
;             descriptor, AX = the slot; CF set if the selector names no
;             capability of that type
;   Destroys: nothing else
; ----------------------------------------------------------------------------
cap_get:
        call cap_lookup
        jc .done
        cmp [es:si + SH_TYPE], cl
        je .done
        stc
.done:
        ret

; ----------------------------------------------------------------------------
; cap_lookup - a slot of the running thread's, whatever it holds
;   In:       AX = its selector
;   Out:      ES = its space; CF clear, SI = the shadow entry, DI = the
;             descriptor, AX = the slot; CF set if the selector names no slot
;   Destroys: nothing else
; ----------------------------------------------------------------------------
cap_lookup:
        push bx
        mov es, [cur_thread]
        mov bx, [es:T_SPACE]
        call slot_of
        pop bx
        ret

; ----------------------------------------------------------------------------
; untyped_carve - room in untyped memory for an object, at the watermark,
; which moves (every alignment is a paragraph since os-server.md P3, so no
; room is skipped and no hole kept, as l4.md L10's was: P15)
;   In:       ES:SI = the untyped's shadow entry; CX = the object's
;             paragraphs; DX = its alignment in paragraphs (a power of two)
;   Out:      CF clear and DL:AX = its base paragraph (20 bits: above 1 MB
;             too, os-server.md P3); CF set if no room
;   Destroys: DH
; ----------------------------------------------------------------------------
untyped_carve:
        push bx
        push cx
        push dx
        mov ax, [es:si + SH_WATERMARK]  ; (every alignment a paragraph: no room
        mov bx, [es:si + SH_SIZE]       ;    skipped, no hole kept: P15)
        call retype_place               ; AX = its place, DX = the new watermark
        jc .done
        mov [es:si + SH_WATERMARK], dx
        pop dx
        mov dl, [es:si + SH_HIGH]
        add ax, [es:si + SH_OBJECT]
        adc dl, 0
        pop cx
        pop bx
        clc
        ret
.done:
        pop dx
        pop cx
        pop bx
        ret

; ----------------------------------------------------------------------------
; para_phys - a paragraph's physical address
;   In:       DL:AX = the paragraph (20 bits)
;   Out:      DL:AX = its physical address (24 bits)
;   Destroys: nothing
; ----------------------------------------------------------------------------
para_phys:
        push cx
        shl dl, 4                       ; bits 20-23
        mov ch, ah
        shr ch, 4                       ; bits 16-19
        or dl, ch
        shl ax, 4
        pop cx
        ret

; ----------------------------------------------------------------------------
; obj_take - a descriptor of the GDT's pool, for an object or a space's LDT
; (os-server.md P3)
;   In:       DS = SEL_KDATA
;   Out:      CF clear and BX = its selector; CF set if none is left
;   Destroys: nothing
; ----------------------------------------------------------------------------
obj_take:
        cmp word [obj_free_count], 0
        je .none
        push di
        dec word [obj_free_count]
        mov di, [obj_free_count]
        shl di, 1
        mov bx, [OBJ_FREE_OFF + di]
        pop di
        clc
        ret
.none:
        stc
        ret

; ----------------------------------------------------------------------------
; obj_free - a descriptor back to the pool, an object's that died or a dead
; space's LDT's. It keeps what it described until it is taken again, so
; that a segment register that still holds it, popped, loads harmlessly
;   In:       BX = the selector; DS = SEL_KDATA
;   Out:      nothing
;   Destroys: nothing
; ----------------------------------------------------------------------------
obj_free:
        push di
%ifdef WITH_CHECKS
 %ifndef TEST_STRETCH                   ; (it would lengthen what that measures)
        push cx                         ; never freed twice: once in the stack
        push ax
        mov cx, [obj_free_count]
        mov di, OBJ_FREE_OFF
        jcxz .unique
.scan:
        cmp [di], bx
        jne .next
        mov ax, sp
        mov di, ax
        mov ax, [ss:di + 6]             ; the caller
        LOG_NUMBER "obj_free: freed twice, from ", ax
        LOG_NUMBER "obj_free: the selector ", bx
        ASSERT z, "obj_free: a descriptor freed twice"
.next:
        add di, 2
        loop .scan
.unique:
        pop ax
        pop cx
 %endif
%endif
        mov di, [obj_free_count]
        shl di, 1
        mov [OBJ_FREE_OFF + di], bx
        inc word [obj_free_count]
        pop di
        ret

; ----------------------------------------------------------------------------
; object_make - a kernel object, zeroed, from untyped memory anywhere
; (os-server.md P3): its memory carved at a paragraph, its own descriptor
; from the GDT's pool, its selector its name
;   In:       ES:SI = the untyped's shadow entry; CX = the object's bytes (a
;             multiple of 16)
;   Out:      CF clear and BX = the object; CF set and AL = KE_POOL (no
;             descriptor) or KE_MEM (no room)
;   Destroys: AX, CX, DX, DI
; ----------------------------------------------------------------------------
object_make:
        call obj_take                   ; a descriptor first: nothing to undo after
        jc .pool
        push cx
        shr cx, 4
        mov dx, 1
        call untyped_carve              ; DL:AX = its place, in paragraphs
        pop cx
        jc .full
        mov di, bx
        add di, GDT_OFF
        dec cx
        mov [di], cx                    ; its limit
        inc cx
        call para_phys                  ; DL:AX = its base
        mov [di + 2], ax
        mov [di + 4], dl
        mov byte [di + 5], ACC_KDATA
        mov word [di + 6], 0
        push es                         ; zeroed (l4.md X14): exactly its bytes
        mov es, bx
        xor di, di
        shr cx, 1
        xor ax, ax
        cld
        rep stosw
        pop es
        clc
        ret
.full:
        call obj_free
        mov al, KE_MEM
        stc
        ret
.pool:
        mov al, KE_POOL
        ret

; ----------------------------------------------------------------------------
; scratch_window - one of the kernel's windows on memory, set to some
;   In:       DI = its descriptor (GDT_OFF + SEL_SCRATCH or SEL_SCRATCH2); DL:AX =
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
;   Destroys: AX, CX, DI, ES (SEL_KDATA)
; ----------------------------------------------------------------------------
phys_zero:
        mov di, GDT_OFF + SEL_SCRATCH
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
; zero_pieces - the running thread's carved paragraphs zeroed (T_ZERO_BASE,
; T_ZERO_PARAS), a piece of RETYPE_PIECE bytes at a time with a window after
; each when they are more, so that a stretch with interrupts off stays short
; (os-server.md P2, X7: 64 KB at once took about 26 ms, E4). Its progress is
; T_ZERO_DONE, where the call resumes if the thread gives way (kpreempt). A
; revoke that gives the untyped's memory back meanwhile cancels it before
; it writes another byte (retypes_cancel, os-server.md P15)
;   In:       BP = the frame (its AH the call); the running thread's T_ZERO_*
;   Out:      CF set if cancelled; ES = the running thread
;   Destroys: AX, CX, DX, SI, DI
; ----------------------------------------------------------------------------
zero_pieces:
        mov es, [cur_thread]
        cmp word [es:T_ZERO_SLOT], ZERO_CANCELLED
        je .cancelled                   ; its memory given back meanwhile (P15)
        mov cx, [es:T_ZERO_PARAS]
        sub cx, [es:T_ZERO_DONE]        ; CX = paragraphs left
        jz .zeroed
        cmp cx, RETYPE_PIECE / 16
        jbe .piece
        mov cx, RETYPE_PIECE / 16
.piece:
        mov ax, [es:T_ZERO_BASE]
        mov dl, [es:T_ZERO_HIGH]
        add ax, [es:T_ZERO_DONE]
        adc dl, 0
        add [es:T_ZERO_DONE], cx
        call para_phys                  ; DL:AX = the piece
        shl cx, 4                       ; its bytes
        call phys_zero
        mov es, [cur_thread]
        mov ax, [es:T_ZERO_DONE]
        cmp ax, [es:T_ZERO_PARAS]
        jae .zeroed
        call call_place_set
        KWINDOW [call_place]
        jmp zero_pieces
.zeroed:
        clc
        ret
.cancelled:
        stc
        ret

; ----------------------------------------------------------------------------
; call_place_set - call_place: the frame's call, as a window's place (the
; stretches' measure names it)
;   In:       BP = the frame
;   Out:      call_place
;   Destroys: nothing
; ----------------------------------------------------------------------------
call_place_set:
        push ax
        mov al, [bp + FRAME_AX + 1]
        mov ah, VEC_KCALL
        mov [call_place], ax
        pop ax
        ret

; ----------------------------------------------------------------------------
; call_iwindow - an interrupt window in a walk inside a call, where no
; thread gives way (IWINDOW), at the frame's call's place
;   In:       BP = the frame; interrupts off
;   Out:      nothing
;   Destroys: nothing
; ----------------------------------------------------------------------------
call_iwindow:
        call call_place_set
        IWINDOW [call_place]
        ret

; ----------------------------------------------------------------------------
; retype_zero - the running thread's new segment zeroed (zero_pieces); then
; the retype goes on only if the caller's space lives, its slot is still
; empty and the untyped still holds what was carved
;   In:       BP = the frame (DX the untyped, SI the slot); the running
;             thread's T_ZERO_*
;   Out:      CF set if the retype cannot go on
;   Destroys: AX, BX, CX, DX, SI, DI, ES
; ----------------------------------------------------------------------------
retype_zero:
        call zero_pieces
        jc .changed
        mov ax, [es:T_SPACE]            ; everything as it was?
        test ax, ax
        jz .changed
        mov dx, [es:T_ZERO_BASE]
        add dx, [es:T_ZERO_PARAS]       ; DX = the carved end
        mov bx, ax
        call space_alive
        jc .changed
        mov ax, [bp + FRAME_SI]
        call slot_of
        jc .changed
        cmp byte [es:si + SH_TYPE], CAP_EMPTY
        jne .changed
        mov ax, [bp + FRAME_DX]
        call slot_of
        jc .changed
        cmp byte [es:si + SH_TYPE], CAP_UNTYPED
        jne .changed
        sub dx, [es:si + SH_OBJECT]     ; the carved end, from the untyped's start
        cmp dx, [es:si + SH_WATERMARK]
        ja .changed                     ; revoked and given out again
        clc
        ret
.changed:
        stc
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
        mov di, GDT_OFF + SEL_SCRATCH
        call scratch_window
        mov ax, bx
        mov dl, dh
        mov di, GDT_OFF + SEL_SCRATCH2
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
; space_make - a space of so many slots, from untyped memory: an object, an
; LDT descriptor of the pool for its LDT, every slot empty; KE_POOL past
; SPACE_MAX spaces
;   In:       ES:SI = the untyped's shadow entry; CX = slots (a power of two,
;             SPACE_SLOTS_MIN to SPACE_SLOTS_MAX)
;   Out:      CF clear and BX = the space; CF set and AL = KE_*
;   Destroys: AX, CX, DX, DI
; ----------------------------------------------------------------------------
space_make:
        mov al, KE_POOL
        cmp word [space_bytes], SPACE_MAX * 2   ; (the list of spaces full: refused
        jb .room                        ;    before anything is taken, P15)
        stc
        ret
.room:
        call obj_take                   ; BX = the LDT's descriptor
        mov al, KE_POOL
        jc .done
        push bx
        push cx                         ; the slots
        mov ax, cx                      ; bytes: the header, then a descriptor
        mov dx, SLOT_SIZE               ; and a shadow entry a slot, aligned
        mul dx                          ; to a paragraph (os-server.md P2)
        add ax, SP_HEADER_SIZE
        mov cx, ax
        call object_make                ; BX = the space, zeroed
        pop cx
        pop dx                          ; DX = the LDT's selector
        jc .undo
        push es
        mov es, bx
        mov [es:SP_SLOTS], cx
        mov [es:SP_GDT_SELECTOR], dx
        pop es
        mov di, bx                      ; its LDT: the object's base, plus SP_LDT
        add di, GDT_OFF
        mov ax, [di + 2]
        mov dl, [di + 4]
        add ax, SP_LDT
        adc dl, 0
        push es
        mov es, bx
        mov di, [es:SP_GDT_SELECTOR]
        pop es
        add di, GDT_OFF
        mov [di + 2], ax
        mov [di + 4], dl
        shl cx, 3
        dec cx
        mov [di], cx                    ; the LDT's limit
        mov byte [di + 5], ACC_LDT
        mov word [di + 6], 0
        call space_list_add
        clc
.done:
        ret
.undo:
        push bx
        mov bx, dx
        call obj_free
        pop bx
        stc
        ret

; ----------------------------------------------------------------------------
; tcb_make - a thread, from untyped memory: its control block (its frame at
; its end: no kernel stack of its own, os-server.md P3), in the list of
; threads; not yet started
;   In:       ES:SI = the untyped's shadow entry
;   Out:      CF clear and BX = the thread; CF set and AL = KE_*
;   Destroys: AX, CX, DX, DI
; ----------------------------------------------------------------------------
tcb_make:
        mov al, KE_POOL
        mov cx, [thread_count]
        cmp cx, THREAD_MAX
        jae .refuse
        mov cx, TCB_OBJECT_SIZE
        call object_make                ; BX = the control block, zeroed
        jc .done
        push es
        mov es, bx
        mov word [es:T_NAME], msg_thread_made
        mov byte [es:T_SLICE], SLICE_TICKS
        pop es
        mov di, [thread_count]
        shl di, 1
        mov [thread_list + di], bx
        inc word [thread_count]
        clc
.done:
        ret
.refuse:
        stc
        ret

; ----------------------------------------------------------------------------
; slot_put_descriptor - a segment capability into an empty slot: a copy of a
; descriptor, and a shadow entry with its memory
;   In:       ES:SI = the shadow entry, ES:DI = the slot's descriptor;
;             DS:BX = the descriptor to copy
;   Out:      nothing
;   Destroys: AX
; ----------------------------------------------------------------------------
slot_put_descriptor:
        mov ax, [bx]
        mov [es:di], ax
        mov ax, [bx + 2]
        mov [es:di + 2], ax
        mov ax, [bx + 4]
        mov [es:di + 4], ax
        mov word [es:di + 6], 0
        test byte [es:di + 5], ACC_PRESENT
        jz .empty                       ; an empty descriptor: an empty slot
        mov byte [es:si + SH_TYPE], CAP_SEGMENT
        push cx
        push dx
        mov ax, [es:di + 2]             ; the base in paragraphs: 24 bits, shifted 4
        shr ax, 4
        mov dl, [es:di + 4]
        xor dh, dh
        shl dx, 12
        or ax, dx
        mov [es:si + SH_OBJECT], ax
        mov al, [es:di + 4]             ; bits 16-19 of the paragraph
        shr al, 4
        mov [es:si + SH_HIGH], al
        mov ax, [es:di]                 ; the size in paragraphs: (limit + 16) / 16
        add ax, 16
        rcr ax, 1
        shr ax, 3
        mov [es:si + SH_SIZE], ax
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
        call umem_size
        call ext_detect
        push ds
        pop es
        mov si, boot_untyped
        mov cx, ROOT_SLOTS
        call space_make                 ; BX = the space
        ASSERT nc, "boot_root: no room for a space"
        mov [boot_space], bx
        push ds
        pop es
        mov si, boot_untyped
        call tcb_make                   ; BX = the thread
        ASSERT nc, "boot_root: no room for a thread"
        mov [boot_thread], bx
        mov es, bx
        mov si, ROOT_MODULE
        mov [es:T_NAME], si             ; (M_NAME: zero-terminated)
        mov al, [si + M_RING]
        mov [es:T_RING], al
        mov al, [si + M_PRIORITY]
        mov [es:T_PRIO], al
        mov ax, [si + M_ENTRY]
        mov [es:T_ENTRY], ax
        mov ax, [si + M_STACK]
        mov [es:T_USTACK_TOP], ax
        mov di, [boot_space]
        mov [es:T_SPACE], di
        push es
        mov es, di
        mov ax, [es:SP_GDT_SELECTOR]
        pop es
        mov [es:T_LDT], ax
        or byte [es:T_FLAGS], TF_CONFIGURED
        push ds
        pop es
        ; slots 0, 1, 2: its code; its data and stack, from the memory for
        ; segments
        mov si, ROOT_MODULE
        xor ax, ax
        call boot_module_code
        call boot_root_data
        ; slots 3, 4: what is left of the untyped memory; with extended
        ; memory, that, and what is left below 1 MB in two slots more
        cmp word [ext_untyped_a + SH_SIZE], 0
        je .low
        mov ax, ROOT_SLOT_UNTYPED
        mov dx, ext_untyped_a
        call boot_slot_shadow
        mov ax, ROOT_SLOT_ARENA
        mov dx, ext_untyped_b
        call boot_slot_shadow
        mov ax, ROOT_SLOT_LOW_UNTYPED
        mov dx, memory_untyped
        call boot_slot_shadow
        mov ax, ROOT_SLOT_LOW_ARENA
        mov dx, boot_untyped
        call boot_slot_shadow
        jmp .untyped
.low:
        mov ax, ROOT_SLOT_UNTYPED
        mov dx, memory_untyped
        call boot_slot_shadow
        mov ax, ROOT_SLOT_ARENA
        mov dx, boot_untyped
        call boot_slot_shadow
.untyped:
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
        call slot_at                    ; ES = the space
        mov byte [es:si + SH_TYPE], CAP_SPACE
        mov [es:si + SH_OBJECT], bx
        mov word [es:SP_REFS], 1
        mov ax, ROOT_SLOT_THREAD
        call slot_at
        mov byte [es:si + SH_TYPE], CAP_THREAD
        mov ax, [boot_thread]
        mov [es:si + SH_OBJECT], ax
        mov es, ax
        mov word [es:T_REFS], 1
        ; the screen's text pages, for the console driver (l4.md L8;
        ; os-server.md P11: all eight)
        mov ax, VIDEO_PHYS & 0xFFFF
        mov dl, VIDEO_PHYS >> 16
        mov cx, VIDEO_PAGE * VIDEO_PAGES - 1
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
        mov byte [es:si + SH_TYPE], CAP_IRQ
        mov [es:si + SH_OBJECT], cx
        mov di, cx
        shl di, 1
        mov word [irq_refs + di], 1
.kept:
        inc cx
        cmp cx, IRQ_LINES
        jb .line
        ; the other modules: each one's code and its data as assembled
        mov cx, [MODULE_TABLE_VOFF + MH_COUNT]
        dec cx
        cmp cx, (ROOT_SLOT_LOW_UNTYPED - ROOT_SLOT_MODULE) / 2
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
; umem_size - the memory for programs' segments: from the image's end - the
; module table's length, which the loader checked against the file - on a
; kilobyte, to the EGA's memory (os-server.md P15: the image may grow
; without taking memory from programs until it does)
;   In:       DS = SEL_KDATA
;   Out:      memory_untyped's base and size
;   Destroys: AX
; ----------------------------------------------------------------------------
umem_size:
        mov ax, [MODULE_TABLE_VOFF + MH_PARAGRAPHS]
        add ax, KERNEL_SEG + (UMEM_ALIGN >> 4) - 1
        and ax, ~((UMEM_ALIGN >> 4) - 1)
        mov [memory_untyped + SH_OBJECT], ax
        neg ax
        add ax, UMEM_END >> 4
        mov [memory_untyped + SH_SIZE], ax
        ret

; ----------------------------------------------------------------------------
; ext_detect - extended memory (roadmap os-server.md P3, D18 B): its size
; as the POST found it (CMOS 30h-31h), if A20 is on - the entry turned it
; on, and a word written at 1 MB must not show at 0 - split in two untyped
; under 1 MB each from 1 MB on: a quarter for objects (ext_untyped_b), the
; rest for segments (ext_untyped_a)
;   In:       DS = SEL_KDATA; interrupts and NMI off
;   Out:      ext_kb; ext_untyped_a and _b (sizes 0 if none)
;   Destroys: AX, BX, CX, DX, DI, ES
; ----------------------------------------------------------------------------
ext_detect:
        mov al, CMOS_EXT_HIGH | CMOS_NMI_DISABLE
        out CMOS_INDEX, al
        in al, CMOS_DATA
        mov ah, al
        mov al, CMOS_EXT_LOW | CMOS_NMI_DISABLE
        out CMOS_INDEX, al
        in al, CMOS_DATA
        push ax
        mov al, CMOS_REG_D              ; NMI on again, as pm_start left it (P15)
        out CMOS_INDEX, al
        pop ax
        cmp ax, EXT_KB_MAX
        jbe .sized
        mov ax, EXT_KB_MAX
.sized:
        mov [ext_kb], ax
        test ax, ax
        jz .none
        mov di, GDT_OFF + SEL_SCRATCH   ; A20: 1 MB, and its alias at 0
        mov ax, 0
        mov dl, 0x10
        mov cx, 16
        call scratch_window
        mov di, GDT_OFF + SEL_SCRATCH2
        xor dl, dl
        call scratch_window
        push ds
        mov ax, SEL_SCRATCH2
        mov ds, ax
        mov ax, SEL_SCRATCH
        mov es, ax
        mov bx, [0]                     ; the word at 0, kept
        xor cx, cx                      ; CX = 1 if it is an alias
        mov word [es:0], EXT_PROBE
        cmp word [0], EXT_PROBE
        jne .apart
        not word [es:0]
        cmp word [0], ~EXT_PROBE & 0xFFFF
        jne .apart
        inc cx
.apart:
        mov [0], bx
        pop ds
        push ds
        pop es
        jcxz .a20
        jmp .wraps                      ; the writes at 1 MB showed at 0
.a20:
        mov ax, [ext_kb]                ; KB to paragraphs: 64 each
        mov dx, 64
        mul dx                          ; DX:AX = all of it
        mov bx, ax
        mov cx, dx                      ; CX:BX = all of it
        shr dx, 1                       ; a quarter for objects...
        rcr ax, 1
        shr dx, 1
        rcr ax, 1
        test dx, dx
        jz .objects
        mov ax, 0xFFFF                  ; (under 1 MB)
.objects:
        mov [ext_untyped_b + SH_SIZE], ax
        sub bx, ax                      ; ... the rest for segments
        sbb cx, 0
        jz .segments
        mov bx, 0xFFFF
.segments:
        mov [ext_untyped_a + SH_SIZE], bx
        mov word [ext_untyped_a + SH_OBJECT], 0     ; from 1 MB
        mov byte [ext_untyped_a + SH_HIGH], 1
        mov [ext_untyped_b + SH_OBJECT], bx         ; then the objects'
        mov byte [ext_untyped_b + SH_HIGH], 1
        TRACE "kernel: extended memory for the root"
        ret
.wraps:
        LOG "kernel: A20 is off: the extended memory is not used"
.none:
        mov word [ext_kb], 0
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
        add ax, [si + M_DATA_AT]        ; past the zeros the image leaves out
        adc dl, 0
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
        push ds
        pop es
        mov si, memory_untyped
        mov dx, 1
        call untyped_carve              ; DL:AX = its base paragraph
        ASSERT nc, "boot_carve: no memory for the root"
        call para_phys
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
        call slot_at                    ; ES:SI, ES:DI = the slot
        mov bx, boot_descriptor
        call slot_put_descriptor
        push ds
        pop es
        pop si
        ret

; ----------------------------------------------------------------------------
; boot_slot_shadow - an untyped capability of the kernel's into a slot of
; the root's space: what the root's own space, thread, data and stack left
; of it, so that no revoke of it can give theirs out again (l4.md L13)
;   In:       AX = the slot; DX = the shadow entry
;   Out:      nothing
;   Destroys: AX, BX, CX, SI, DI, ES
; ----------------------------------------------------------------------------
boot_slot_shadow:
        mov bx, [boot_space]
        call slot_at                    ; ES:SI = the slot's shadow entry
        mov di, si
        mov si, dx
        mov cx, SHADOW_SIZE / 2
        cld
        rep movsw
        sub di, SHADOW_SIZE             ; the copy: from the watermark on
        mov ax, [es:di + SH_WATERMARK]
        add [es:di + SH_OBJECT], ax
        sub [es:di + SH_SIZE], ax
        xor ax, ax
        mov [es:di + SH_WATERMARK], ax
        mov [es:di + SH_PREV], ax       ; (in no list)
        mov [es:di + SH_PREV_SLOT], ax
        push ds
        pop es
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
        mov es, [cur_thread]
        cmp byte [es:T_CONT], CONT_RESUMED
        jne .fresh
        cmp word [es:T_ZERO_PARAS], 0
        jne retype_segment              ; it gave way while its segment was zeroed
.fresh:
        mov bx, [es:T_SPACE]            ; the destination: an empty slot
        mov ax, [bp + FRAME_SI]
        call slot_of
        jc kc_done.cap
        cmp byte [es:si + SH_TYPE], CAP_EMPTY
        jne kc_done.slot
        mov ax, [bp + FRAME_DX]
        mov cl, CAP_UNTYPED
        call cap_get                    ; ES:SI = the untyped, AX its slot
        jc kc_done.cap
        mov [retype_parent_slot], ax
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
        jmp kc_done.arg
.space:
        mov cx, [bp + FRAME_CX]         ; a power of two, within the bounds
        cmp cx, SPACE_SLOTS_MIN
        jb kc_done.arg
        cmp cx, SPACE_SLOTS_MAX
        ja kc_done.arg
        mov ax, cx
        dec ax
        test ax, cx
        jnz kc_done.arg
        call space_make
        jc kc_done
        jmp .made
.object:
        cmp al, CAP_THREAD
        jne .small
        call tcb_make
        jc kc_done
        jmp .made
.small:
        call object_make
        jc kc_done
.made:
        call retype_destination         ; ES:SI = the destination
        mov al, [bp + FRAME_AX]
        mov [es:si + SH_TYPE], al
        mov [es:si + SH_OBJECT], bx
        mov byte [es:si + SH_RIGHTS], RIGHTS_ALL
        jmp retype_parent
.untyped:
        ; Untyped from untyped (l4.md L12): CX paragraphs, which a revoke of
        ; the new one gives back to it whole
        mov cx, [bp + FRAME_CX]
        test cx, cx
        jz kc_done.arg
        mov dx, 1
        call untyped_carve              ; DL:AX = its base paragraph
        jc kc_done.mem
        call retype_destination
        mov byte [es:si + SH_TYPE], CAP_UNTYPED
        mov [es:si + SH_OBJECT], ax
        mov [es:si + SH_HIGH], dl
        mov ax, [bp + FRAME_CX]
        mov [es:si + SH_SIZE], ax
        jmp retype_parent
.segment:
        ; Only data, present, of DPL 1-3; from any untyped, as objects are
        ; (os-server.md P3): a watermark never gives the same memory twice
        mov al, [bp + FRAME_BX]
        and al, ACC_PRESENT | ACC_SEGMENT | ACC_CODE | ACC_EXPAND_DOWN
        cmp al, ACC_PRESENT | ACC_SEGMENT
        jne kc_done.arg
        test byte [bp + FRAME_BX], ACC_DPL_MASK
        jz kc_done.arg
        mov cx, [bp + FRAME_CX]
        test cx, cx
        jz kc_done.arg
        add cx, 15
        rcr cx, 1                       ; (a carry is bit 16: up to 64 KB)
        shr cx, 3                       ; CX = paragraphs
        mov dx, 1
        call untyped_carve              ; DL:AX = its base paragraph
        jc kc_done.mem
        mov es, [cur_thread]            ; zeroed in pieces: what a resumed call
        mov [es:T_ZERO_BASE], ax        ; finds again (retype_zero)
        mov [es:T_ZERO_HIGH], dl
        mov [es:T_ZERO_PARAS], cx
        mov word [es:T_ZERO_DONE], 0
        mov ax, [retype_parent_slot]
        mov [es:T_ZERO_SLOT], ax
        jmp retype_segment

; ----------------------------------------------------------------------------
; retype_destination - the retype's destination slot, in the caller's space
;   In:       BP = the frame (SI the slot's selector, checked already)
;   Out:      ES:SI = its shadow entry, ES:DI = its descriptor
;   Destroys: nothing else
; ----------------------------------------------------------------------------
retype_destination:
        push ax
        push bx
        mov es, [cur_thread]
        mov bx, [es:T_SPACE]
        mov ax, [bp + FRAME_SI]
        call slot_of
        pop bx
        pop ax
        ret

; ----------------------------------------------------------------------------
; retype_segment - the rest of a segment's retype: its memory zeroed, then
; its capability into the slot; where a resumed call goes on
;   In:       BP = the frame; the running thread's T_ZERO_*
;   Out:      the frame's status
;   Destroys: AX, BX, CX, DX, SI, DI, ES
; ----------------------------------------------------------------------------
retype_segment:
        call retype_zero
        mov es, [cur_thread]
        mov ax, [es:T_ZERO_BASE]
        mov cx, [es:T_ZERO_PARAS]
        mov dx, [es:T_ZERO_SLOT]
        mov word [es:T_ZERO_PARAS], 0
        jc .changed
        mov [retype_base], ax
        mov [retype_paragraphs], cx
        mov [retype_parent_slot], dx
        mov dl, [es:T_ZERO_HIGH]
        mov [retype_base_para_high], dl
        call para_phys                  ; DL:AX = its base
        mov [retype_base_low], ax
        mov [retype_base_high], dl
        call retype_destination         ; ES:SI, ES:DI
        mov ax, [bp + FRAME_CX]
        dec ax
        mov [es:di], ax                 ; the limit
        mov ax, [retype_base_low]
        mov [es:di + 2], ax
        mov al, [retype_base_high]
        mov [es:di + 4], al
        mov al, [bp + FRAME_BX]
        or al, ACC_ACCESSED             ; preset, as every descriptor of rx286's
        mov [es:di + 5], al
        mov word [es:di + 6], 0
        mov byte [es:si + SH_TYPE], CAP_SEGMENT
        mov ax, [retype_base]
        mov [es:si + SH_OBJECT], ax
        mov al, [retype_base_para_high]
        mov [es:si + SH_HIGH], al
        mov ax, [retype_paragraphs]
        mov [es:si + SH_SIZE], ax
        jmp retype_parent
.changed:
        mov al, KE_STATE                ; changed during the zeroing's windows
        jmp kc_done

; ----------------------------------------------------------------------------
; retype_parent - the end of a retype: the new capability is a child of the
; untyped it came from, so a revoke of the untyped deletes it (l4.md L12);
; a new object's first capability
;   In:       ES:SI = the new capability's shadow entry; BP = the frame
;   Out:      the frame's status, KE_OK
;   Destroys: AX, BX, CX, DX
; ----------------------------------------------------------------------------
retype_parent:
        mov bx, es                      ; (the caller's space)
        mov ax, [retype_parent_slot]
        mov dx, bx
        mov cx, [bp + FRAME_SI]
        shr cx, 3                       ; the new one's slot
        call child_link
        mov al, [es:si + SH_TYPE]
        mov dx, [es:si + SH_OBJECT]
        call obj_ref
        jmp kc_done.ok

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
        mov bx, [es:si + SH_OBJECT]
        mov ax, [bp + FRAME_DI]
        call slot_of                    ; ES = the destination's space
        jc kc_done.cap
        cmp byte [es:si + SH_TYPE], CAP_EMPTY
        jne kc_done.slot
        mov [copy_shadow], si
        mov [copy_descriptor], di
        mov [copy_dest_space], bx
        mov [copy_dest_slot], ax
        ; the source: a slot of the caller's that holds something
        mov ax, [bp + FRAME_SI]
        mov es, [cur_thread]
        mov bx, [es:T_SPACE]
        mov [copy_source_space], bx
        call slot_of                    ; ES = the caller's space; AX its slot
        jc kc_done.cap
        cmp byte [es:si + SH_TYPE], CAP_EMPTY
        je kc_done.cap
        cmp bx, [copy_dest_space]
        jne .other
        cmp ax, [copy_dest_slot]
        je kc_done.cap                  ; the same slot
.other:
        mov [copy_slot], ax
        mov al, [bp + FRAME_AX]
        cmp al, COPY_MOVE
        je .copy
        cmp byte [es:si + SH_TYPE], CAP_UNTYPED
        je kc_done.arg                  ; untyped is moved, never shared
        cmp byte [es:si + SH_TYPE], CAP_REPLY
        je kc_done.arg                  ; nor a reply, answered once
        cmp al, COPY_COPY
        je .copy
        cmp al, COPY_MINT
        jne kc_done.arg
        cmp byte [es:si + SH_TYPE], CAP_ENDPOINT
        je .mintable
        cmp byte [es:si + SH_TYPE], CAP_NOTIFY
        jne kc_done.arg
.mintable:
        cmp word [es:si + SH_BADGE], 0  ; badged once, badged for good
        jne kc_done.arg
        cmp word [bp + FRAME_BX], 0
        je kc_done.arg
.copy:
        ; from the caller's space (DS, for the copy) to the destination's
        mov ax, [copy_dest_space]
        mov bx, [copy_descriptor]
        mov dx, [copy_shadow]
        push si
        push di
        push ds
        push es
        pop ds
        mov es, ax
        cld
        push si
        mov si, di                      ; the descriptor
        mov di, bx
        mov cx, 4
        rep movsw
        pop si
        mov di, dx                      ; the shadow entry
        mov cx, SHADOW_SIZE / 2
        rep movsw
        pop ds
        pop di
        pop si
        cmp byte [bp + FRAME_AX], COPY_MOVE
        je .move
        mov bx, [copy_source_space]     ; a copy: the source's child
        mov ax, [copy_slot]
        mov dx, [copy_dest_space]
        mov cx, [copy_dest_slot]
        call child_link
        mov es, dx
        mov bx, [copy_shadow]
        mov al, [es:bx + SH_TYPE]
        mov dx, [es:bx + SH_OBJECT]
        call obj_ref
        cmp byte [bp + FRAME_AX], COPY_MINT
        jne kc_done.ok
        mov ax, [bp + FRAME_BX]
        mov [es:bx + SH_BADGE], ax
        mov al, [bp + FRAME_CX]         ; fewer rights, if CL names them
        test al, al
        jz kc_done.ok
        and [es:bx + SH_RIGHTS], al
        jmp kc_done.ok
.move:
        mov es, [copy_source_space]     ; the source slot empties
        call slot_clear
        mov bx, [copy_source_space]     ; its place in the tree, and its
        mov ax, [copy_slot]             ; children, go with it (l4.md L12)
        mov dx, [copy_dest_space]
        mov cx, [copy_dest_slot]
        call cap_moved
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
;   Destroys: AX, BX, CX, DX, SI, DI, ES
; ----------------------------------------------------------------------------
kc_thread:
        mov ax, [bp + FRAME_DX]
        mov cl, CAP_THREAD
        call cap_get
        jc kc_done.cap
        mov bx, [es:si + SH_OBJECT]     ; the thread
        mov es, bx
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
        cmp al, THREAD_SUSPEND
        je .suspend
        cmp al, THREAD_FRAME
        je .frame
        cmp al, THREAD_FPU
        je .fpu
        cmp byte [es:T_STATE], TS_STOPPED
        je .stopped
        cmp byte [es:T_STATE], TS_FREE
        jne kc_done.state               ; started already
        cmp al, THREAD_CONFIGURE
        je .configure
        cmp al, THREAD_START
        je .start
        jmp kc_done.arg
.fpu:
        ; another thread's 287 state into this one, not running (P15)
        cmp byte [es:T_STATE], TS_FREE
        je .fpu_target
        cmp byte [es:T_STATE], TS_STOPPED
        jne kc_done.state
.fpu_target:
        mov ax, [bp + FRAME_SI]
        mov cl, CAP_THREAD
        push bx
        call cap_get                    ; ES:SI = the source's shadow entry
        pop bx
        jc kc_done.cap
        mov dx, [es:si + SH_OBJECT]
        call fpu_copy                   ; (BX the target, DX the source)
        push ds
        pop es
        jmp kc_done.ok
.bind:
        mov ax, [bp + FRAME_SI]         ; its notification, bound both ways
        mov cl, CAP_NOTIFY
        call cap_get
        jc kc_done.cap
        test byte [es:si + SH_RIGHTS], RIGHT_RECV
        jz kc_done.cap
        mov si, [es:si + SH_OBJECT]
        mov es, bx
        mov di, [es:T_BOUND]            ; one each: the thread's old notification...
        test di, di
        jz .unbound
        mov es, di
        mov word [es:N_BOUND], 0
.unbound:
        mov es, si
        mov di, [es:N_BOUND]            ; ...and the notification's old thread, unbound
        test di, di
        jz .bound
        mov es, di
        mov word [es:T_BOUND], 0
.bound:
        mov es, bx
        mov [es:T_BOUND], si
        mov es, si
        mov [es:N_BOUND], bx
        jmp kc_done.ok
.fault:
        mov ax, [bp + FRAME_SI]         ; its fault endpoint, and the badge
        mov cl, CAP_ENDPOINT
        call cap_get
        jc kc_done.cap
        test byte [es:si + SH_RIGHTS], RIGHT_SEND
        jz kc_done.cap
        mov ax, [es:si + SH_OBJECT]
        mov dx, [es:si + SH_BADGE]
        mov es, bx
        mov [es:T_FAULT], ax
        mov [es:T_FAULT_BADGE], dx
        jmp kc_done.ok
.restart:
        cmp byte [es:T_STATE], TS_FREE
        je kc_done.state                ; not started
        call thread_restart
        jmp kc_done.ok
.stop:
        cmp byte [es:T_STATE], TS_FREE
        je kc_done.state                ; not started
        cmp byte [es:T_STATE], TS_STOPPED
        je kc_done.state
        cmp bx, [cur_thread]
        je kc_done.arg                  ; a thread does not stop itself
        call thread_stop
        jmp kc_done.ok
.info:
        mov al, [es:T_STATE]
        mov ah, [es:T_PRIO]
        mov [bp + FRAME_BX], ax
        mov ax, [es:T_RUNS]
        mov [bp + FRAME_CX], ax
        jmp kc_done.ok
.stopped:
        cmp al, THREAD_START            ; a stopped thread: started again, at
        jne kc_done.state               ; its entry, at the priority given; or a
        mov cx, [bp + FRAME_CX]         ; suspended one where it was
        cmp cl, PRIORITY_MAX
        ja kc_done.arg
        mov [es:T_PRIO], cl
        and byte [es:T_FLAGS], ~TF_SUSPENDED & 0xFF
        call ready_push
        jmp kc_done.ok
.suspend:
        ; stopped on its way back to its ring (thread_suspended), so that a
        ; kernel call it is in ends first, its results in the frame and the
        ; log's turn given up (os-server.md E11); of ring 3 only, not the
        ; caller, not stopped
        cmp bx, [cur_thread]
        je kc_done.arg
        cmp byte [es:T_RING], RPL_USER
        jne kc_done.arg
        cmp byte [es:T_STATE], TS_FREE
        je kc_done.state
        cmp byte [es:T_STATE], TS_STOPPED
        je kc_done.state
        test byte [es:T_FLAGS], TF_SUSPEND
        jnz .suspend_marked
        xor dx, dx                      ; DX:CX = the notification and badge, or 0
        xor cx, cx
        mov ax, [bp + FRAME_SI]
        test ax, ax
        jz .suspend_set
        mov cl, CAP_NOTIFY
        call cap_get
        jc kc_done.cap
        test byte [es:si + SH_RIGHTS], RIGHT_SEND
        jz kc_done.cap
        mov dx, [es:si + SH_OBJECT]
        mov cx, [es:si + SH_BADGE]
.suspend_set:
        mov es, bx
        mov [es:T_SUSPEND_NOTIFY], dx
        mov [es:T_SUSPEND_BADGE], cx
        or byte [es:T_FLAGS], TF_SUSPEND
        test byte [es:T_IPC], TI_FAULT
        jz kc_done.ok
        cmp byte [es:T_STATE], TS_SEND
        je .fault_wait
        cmp byte [es:T_STATE], TS_REPLY
        jne kc_done.ok
.fault_wait:
        mov al, KE_SUSPENDED            ; waiting for its fault's reply: it
        call ipc_fail                   ; stops at once, at the fault
        jmp kc_done.ok
.suspend_marked:
        ; marked already: KE_STATE, unless it faulted before it stopped and
        ; waits for its fault's reply, which a mark alone never ends; then it
        ; stops at once, at the fault, for the notification first named
        ; (os-server.md P10)
        test byte [es:T_IPC], TI_FAULT
        jz kc_done.state
        cmp byte [es:T_STATE], TS_SEND
        je .fault_wait
        cmp byte [es:T_STATE], TS_REPLY
        je .fault_wait
        jmp kc_done.state
.frame:
        ; the frame of a suspended thread - in its control block, since it
        ; does not run - to or from the caller's bytes, checked as the log's
        ; are (check_buffer): TFR_SIZE of them at SI:DI
        test byte [es:T_FLAGS], TF_SUSPENDED
        jz kc_done.state
        cmp byte [es:T_STATE], TS_STOPPED   ; (and stopped: no frame of a thread that
        jne kc_done.state               ;    runs or is ready, os-server.md P15)
        mov [frame_thread], bx
        mov ax, [bp + FRAME_SI]
        mov si, [bp + FRAME_DI]
        mov cx, TFR_SIZE
        cmp byte [bp + FRAME_BX], FRAME_WRITE
        je .frame_write
        cmp byte [bp + FRAME_BX], FRAME_READ
        jne kc_done.arg
        call check_buffer_writable      ; ES = the caller's segment
        jc kc_done.cap
        mov di, si                      ; ES:DI the caller's, DS:SI the frame
        push ds
        mov ds, bx
        mov si, T_FRAME
        cld
        mov cx, TFR_SIZE / 2
        rep movsw
        pop ds
        push ds
        pop es
        jmp kc_done.ok
.frame_write:
        call check_buffer               ; ES = the caller's segment
        jc kc_done.cap
        push ds
        push es
        pop ds                          ; DS:SI the caller's, ES:DI the frame
        mov es, bx
        mov di, T_FRAME
        cld
        mov cx, TFR_VECTOR / 2          ; the registers before the kernel's words
        rep movsw
        add si, TFR_IP - TFR_VECTOR
        add di, TFR_IP - TFR_VECTOR
        mov cx, (TFR_SIZE - TFR_IP) / 2 ; IP, CS, FLAGS, SP, SS
        rep movsw
        pop ds
        call thread_flags               ; IF on and the thread's IOPL, whatever was
        and word [es:T_FRAME + FRAME_FLAGS], FLAGS_USER_KEEP   ; written; NT never (E6)
        or [es:T_FRAME + FRAME_FLAGS], ax
        mov al, [es:T_RING]             ; CS's and SS's RPL the thread's ring, whatever
        xor ah, ah                      ;    was written: the way back checks them at
        and word [es:T_FRAME + FRAME_CS], ~RPL_MASK     ; it (os-server.md P15)
        or [es:T_FRAME + FRAME_CS], ax
        and word [es:T_FRAME + FRAME_USER_SS], ~RPL_MASK
        or [es:T_FRAME + FRAME_USER_SS], ax
        cmp byte [es:T_CONT], CONT_KCALL    ; stopped in a call half done: the call
        jne .frame_written              ;    is given up, the thread goes back with
        mov byte [es:T_CONT], CONT_NONE ;    the frame written, nothing of the call
        mov word [es:T_ZERO_PARAS], 0   ;    kept (P15)
        mov word [es:T_LOG_DONE], 0
        cmp [call_owner], bx
        jne .frame_written
        mov word [call_owner], 0
.frame_written:
        push ds
        pop es
        jmp kc_done.ok
.configure:
        mov ax, [bp + FRAME_SI]
        mov cl, CAP_SPACE
        call cap_get
        jc kc_done.cap
        mov dx, [es:si + SH_OBJECT]     ; the space
        mov es, dx
        mov al, [es:SP_LDT + 5]         ; slot 0: present code, its DPL the ring
        mov ah, al
        and ah, ACC_PRESENT | ACC_SEGMENT | ACC_CODE | ACC_EXPAND_DOWN
        cmp ah, ACC_PRESENT | ACC_SEGMENT | ACC_CODE
        jne kc_done.arg                 ; (and not conforming: os-server.md X1)
        and al, ACC_DPL_MASK
        mov cl, ACC_DPL_SHIFT
        shr al, cl
        test al, al
        jz kc_done.arg                  ; never ring 0
        mov cx, [es:SP_GDT_SELECTOR]
        call thread_module_name         ; (ES = the space)
        mov es, bx
        mov [es:T_RING], al
        mov [es:T_SPACE], dx
        mov [es:T_LDT], cx
        mov ax, [bp + FRAME_BX]
        mov [es:T_ENTRY], ax
        mov ax, [bp + FRAME_CX]
        mov [es:T_USTACK_TOP], ax
        or byte [es:T_FLAGS], TF_CONFIGURED
        jmp kc_done.ok
.start:
        test byte [es:T_FLAGS], TF_CONFIGURED
        jz kc_done.state
        mov cx, [bp + FRAME_CX]
        cmp cl, PRIORITY_MAX
        ja kc_done.arg
        mov [es:T_PRIO], cl
        test ch, START_FOREGROUND | START_SESSION
        jz .iopl
        push es
        mov es, [cur_thread]            ; chosen by ring 1 or 2 only
        cmp byte [es:T_RING], RPL_USER
        pop es
        je kc_done.arg
        test ch, START_SESSION
        jz .foreground
        or byte [es:T_FLAGS], TF_SESSION
.foreground:
        test ch, START_FOREGROUND
        jz .iopl
        or byte [es:T_FLAGS], TF_FOREGROUND
        mov [fg_thread], bx
.iopl:
        test ch, START_IOPL
        jz .go
        cmp byte [es:T_RING], 1         ; IOPL only for a ring-1 thread
        jne .go
        or byte [es:T_FLAGS], TF_IOPL
.go:
        call thread_init                ; into its ready queue
%ifdef TEST_FUZZ
        call test_fuzz_alias
%endif
        jmp kc_done.ok

; ----------------------------------------------------------------------------
; kc_seal - KCALL_SEAL: a data segment of DPL 3 made readable code of DPL 3
; (os-server.md P2, E5, D6), if no copy of it remains (no SR_PARENT: none
; was ever made, or a revoke took them) and its parent is the untyped it was
; retyped from, so that no writable alias of it is left anywhere. A DS or ES
; that holds it is reloaded on the way back, as the code. Never another DPL,
; nor conforming code (X1)
;   In:       BP = the frame (DX the segment)
;   Out:      the frame's status
;   Destroys: AX, BX, CX, SI, DI
; ----------------------------------------------------------------------------
kc_seal:
        mov ax, [bp + FRAME_DX]
        mov cl, CAP_SEGMENT
        call cap_get                    ; ES:SI the shadow entry, ES:DI the descriptor
        jc kc_done.cap
        mov al, [es:di + 5]
        and al, ACC_PRESENT | ACC_DPL_MASK | ACC_SEGMENT | ACC_CODE | ACC_EXPAND_DOWN
        cmp al, ACC_PRESENT | ACC_DPL3 | ACC_SEGMENT
        jne kc_done.arg                 ; data of DPL 3, expand-up
        cmp word [es:si + SH_CHILD], 0
        jne kc_done.state               ; a copy of it lives
        call parent_find                ; BX, AX = its parent
        test bx, bx
        jz kc_done.state
        push es
        push di
        call slot_at
        cmp byte [es:si + SH_TYPE], CAP_UNTYPED
        pop di
        pop es
        jne kc_done.state               ; its parent must be the untyped it came from
        mov byte [es:di + 5], ACC_UCODE ; present, DPL 3, code, readable, accessed
        jmp kc_done.ok

; ----------------------------------------------------------------------------
; kc_resize - KCALL_RESIZE: a data segment made longer or shorter in place,
; within the untyped it was retyped from, the last thing carved there, with
; every copy of it, so that a process's heap grows without a copy
; (os-server.md P15). The untyped must be the caller's: a segment alone,
; moved to another space, takes no more of it. New bytes are zeroed a piece
; at a time, as a retype's (zero_pieces), carved first so that nothing else
; takes them meanwhile; a shorter segment gives its end back to the
; untyped. A thread that holds a copy in a segment register loads it again
; on its way back to its ring, as after every kernel entry
;   In:       BP = the frame (DX the segment, CX its bytes)
;   Out:      the frame's status
;   Destroys: AX, BX, CX, DX, SI, DI, ES
; ----------------------------------------------------------------------------
kc_resize:
        mov es, [cur_thread]
        cmp byte [es:T_CONT], CONT_RESUMED
        jne .fresh
        cmp word [es:T_ZERO_PARAS], 0
        jne resize_grow                 ; it gave way while its new bytes were zeroed
.fresh:
        call resize_find                ; ES:SI the segment, ES:BX its untyped
        jc kc_done
        mov cx, [bp + FRAME_CX]
        test cx, cx
        jz kc_done.arg
        add cx, 15
        rcr cx, 1                       ; (a carry is bit 16)
        shr cx, 3                       ; CX = its new paragraphs
        mov ax, [resize_offset]
        add ax, [es:si + SH_SIZE]       ; its end, in the untyped
        cmp ax, [es:bx + SH_WATERMARK]
        jne kc_done.state               ; something carved after it
        mov ax, [resize_offset]
        add ax, cx
        jc kc_done.mem
        cmp ax, [es:bx + SH_SIZE]
        ja kc_done.mem
        mov [es:bx + SH_WATERMARK], ax  ; its new end: carved, or given back
        mov ax, [es:si + SH_SIZE]
        cmp cx, ax
        jbe resize_set                  ; no longer: nothing to zero
        sub cx, ax                      ; CX = the paragraphs it gains
        mov dx, [es:si + SH_OBJECT]
        mov bl, [es:si + SH_HIGH]
        add dx, ax
        adc bl, 0                       ; BL:DX = its old end
        mov ax, [resize_untyped]
        mov es, [cur_thread]
        mov [es:T_ZERO_BASE], dx
        mov [es:T_ZERO_HIGH], bl
        mov [es:T_ZERO_PARAS], cx
        mov word [es:T_ZERO_DONE], 0
        mov [es:T_ZERO_SLOT], ax
        ; fall through

; ----------------------------------------------------------------------------
; resize_grow - the rest of a longer segment's KCALL_RESIZE: its new
; paragraphs zeroed, then, if everything is as it was - the segment where
; it was, as long, its untyped's watermark still past what it gains - it
; and its copies made longer; where a resumed call goes on
;   In:       BP = the frame; the running thread's T_ZERO_*
;   Out:      the frame's status
;   Destroys: AX, BX, CX, DX, SI, DI, ES
; ----------------------------------------------------------------------------
resize_grow:
        call zero_pieces                ; ES = the running thread
        mov dx, [es:T_ZERO_BASE]
        mov cl, [es:T_ZERO_HIGH]
        mov di, [es:T_ZERO_PARAS]
        mov word [es:T_ZERO_PARAS], 0
        jc kc_done.state                ; its untyped revoked meanwhile
        push cx
        push dx
        push di
        call resize_find                ; ES:SI the segment, ES:BX its untyped
        pop di
        pop dx
        pop cx
        jc kc_done.state
        mov ax, [es:si + SH_OBJECT]     ; its end where the new bytes start?
        mov ch, [es:si + SH_HIGH]
        add ax, [es:si + SH_SIZE]
        adc ch, 0
        cmp ax, dx
        jne kc_done.state
        cmp ch, cl
        jne kc_done.state
        mov cx, [es:si + SH_SIZE]       ; CX = its new paragraphs
        add cx, di
        mov ax, [resize_offset]
        add ax, cx
        cmp ax, [es:bx + SH_WATERMARK]
        jne kc_done.state               ; its untyped's watermark moved meanwhile
        ; fall through

; ----------------------------------------------------------------------------
; resize_set - a segment's new size, in it and in each capability derived
; from it: a walk down SH_CHILD, around each ring by SH_NEXT and back up to
; the parent its first names, with
; an interrupt window every CHILDREN_WINDOW, where no thread gives way
; (IWINDOW), so that nothing changes the tree meanwhile
;   In:       BP = the frame (CX bytes); ES = the caller's space; CX = the
;             new paragraphs; resize_slot
;   Out:      the frame's status, KE_OK
;   Destroys: AX, BX, CX, DX, SI, DI
; ----------------------------------------------------------------------------
resize_set:
        mov [resize_paras], cx
        mov ax, [bp + FRAME_CX]
        dec ax
        mov [resize_limit], ax
        mov bx, es
        mov [resize_space], bx
        mov ax, [resize_slot]
        call resize_one
        xor cx, cx                      ; capabilities since the last window
.down:
        call shadow_at                  ; ES:SI = this one's
        mov dx, [es:si + SH_CHILD]
        test dx, dx
        jz .across
        mov ax, [es:si + SH_CHILD_SLOT]
        mov bx, dx
        jmp .visit
.across:
        cmp bx, [resize_space]          ; its children done: back at the segment?
        jne .sibling
        cmp ax, [resize_slot]
        je kc_done.ok
.sibling:
        mov bx, [es:si + SH_NEXT]
        mov ax, [es:si + SH_NEXT_SLOT]
        call shadow_at                  ; ES:SI = the next's
        cmp word [es:si + SH_PARENT], 0
        je .visit                       ; not the first again: a sibling
        mov bx, [es:si + SH_PARENT]     ; the ring done: up to its parent, which
        mov ax, [es:si + SH_PARENT_SLOT]    ; the first names
        call shadow_at
        jmp .across
.visit:
        call resize_one
        inc cx
        cmp cx, CHILDREN_WINDOW
        jb .down
        xor cx, cx
        IWINDOW (VEC_KCALL << 8) | KCALL_RESIZE
        jmp .down

; ----------------------------------------------------------------------------
; resize_one - one capability of the segment's given its new size: its
; shadow entry's paragraphs, its descriptor's limit
;   In:       BX = the space; AX = the slot; resize_paras, resize_limit
;   Out:      nothing
;   Destroys: nothing
; ----------------------------------------------------------------------------
resize_one:
        push ax
        push si
        push di
        push es
        call slot_at                    ; ES:SI the shadow entry, ES:DI the descriptor
        cmp byte [es:si + SH_TYPE], CAP_SEGMENT
        jne .done                       ; (every copy of a segment is one)
        mov ax, [resize_paras]
        mov [es:si + SH_SIZE], ax
        mov ax, [resize_limit]
        mov [es:di], ax
.done:
        pop es
        pop di
        pop si
        pop ax
        ret

; ----------------------------------------------------------------------------
; resize_find - the segment a KCALL_RESIZE names: data, expand-up, its
; parent an untyped in the caller's own space, which it lies in
;   In:       BP = the frame (DX the segment)
;   Out:      CF clear: ES = the caller's space, SI = the segment's shadow
;             entry, BX = its untyped's, resize_slot, resize_offset,
;             resize_untyped; CF set:
;             AL = the status
;   Destroys: AX, DX, DI
; ----------------------------------------------------------------------------
resize_find:
        push cx
        mov ax, [bp + FRAME_DX]
        mov cl, CAP_SEGMENT
        call cap_get                    ; ES:SI, ES:DI, AX the slot
        mov cl, KE_CAP
        jc .refuse
        mov [resize_slot], ax
        mov al, [es:di + 5]
        and al, ACC_PRESENT | ACC_SEGMENT | ACC_CODE | ACC_EXPAND_DOWN
        mov cl, KE_ARG
        cmp al, ACC_PRESENT | ACC_SEGMENT
        jne .refuse                     ; data, expand-up
        mov cl, KE_STATE
        call parent_find                ; BX, AX = its parent
        mov dx, es
        cmp bx, dx
        jne .refuse                     ; its parent in another space, or none
        mov [resize_untyped], ax
        push si
        call slot_at                    ; ES:SI = its parent's
        mov bx, si
        pop si
        cmp byte [es:bx + SH_TYPE], CAP_UNTYPED
        jne .refuse                     ; a copy of another segment
        mov ax, [es:si + SH_OBJECT]     ; its paragraphs from the untyped's start
        mov ch, [es:si + SH_HIGH]
        sub ax, [es:bx + SH_OBJECT]
        sbb ch, [es:bx + SH_HIGH]
        jnz .refuse                     ; (never: it lies in its untyped)
        mov [resize_offset], ax
        pop cx
        clc
        ret
.refuse:
        mov al, cl
        pop cx
        stc
        ret

; ----------------------------------------------------------------------------
; thread_module_name - a thread named after the module whose code its space's
; slot 0 holds, if any (the dump, the tests' reports)
;   In:       BX = the thread; ES = its space
;   Out:      its T_NAME
;   Destroys: nothing
; ----------------------------------------------------------------------------
thread_module_name:
        push ax
        push cx
        push dx
        push si
        mov ax, [es:SP_LDT + 2]         ; slot 0's base, in paragraphs (the
        shr ax, 4                       ; image's: below 1 MB)
        mov dl, [es:SP_LDT + 4]
        test dl, 0xF0
        jnz .done                       ; (code above 1 MB: no module's, P15)
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
        jmp .done
.named:
        push es
        mov es, bx
        mov [es:T_NAME], si
        pop es
.done:
        pop si
        pop dx
        pop cx
        pop ax
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
        mov bx, [es:si + SH_OBJECT]     ; the line
        mov al, [bp + FRAME_AX]
        cmp al, IRQ_ACK
        je .unmask
        cmp al, IRQ_BIND
        jne kc_done.arg
        mov ax, [bp + FRAME_SI]
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
        mov di, bx
        shl di, 1
        mov [irq_bits + di], ax
        mov ax, [es:si + SH_OBJECT]
        mov [irq_notify + di], ax
.unmask:
        call pic_unmask
        jmp kc_done.ok

; ----------------------------------------------------------------------------
; kc_test - KCALL_TEST: the hooks of debug and test builds (KE_NOSYS in
; release builds): the thread dump; in test builds, the bytes a key script
; gave the mouse or typed where the 8042 cannot, whether the OS server
; waits for a key, windows that give way (TEST_GIVE_WAY), the sound
; driver's probes (TEST_SOUND builds) and the attack program's (TEST_ATTACK
; builds)
;   In:       BP = the frame (AL TEST_*; TEST_READER, TEST_PROBE: BL;
;             TEST_SOUND_PROBE: BX; TEST_GIVE_WAY: CX)
;   Out:      the frame's BL = a byte; TEST_GIVE_WAY: CX the windows that
;             were still to give way; or KE_EMPTY
;   Destroys: AX, BX, CX, DX, SI, DI
; ----------------------------------------------------------------------------
kc_test:
        mov al, [bp + FRAME_AX]
%ifdef TEST_FUZZ
        mov bx, [cur_thread]            ; the fuzz program's random calls reach
        cmp bx, [fg_thread]             ; what a release kernel has, no test hook
        je kc_done.nosys                ; (os-server.md P15)
%endif
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
        cmp al, TEST_OVERRUN
        jne .not_overrun
        int VEC_MP                      ; vector 9, in ring 0 (fault.asm's rule)
        jmp kc_done.ok
.not_overrun:
%endif
        cmp al, TEST_READER
        je .reader
        cmp al, TEST_KEYS_READY
        je .ready
        cmp al, TEST_GIVE_WAY
        je .give_way
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
.give_way:
        mov ax, [bp + FRAME_CX]
        xchg ax, [test_give_way]
        mov [bp + FRAME_CX], ax         ; the windows that were still to give way
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
        mov ax, [es:di + 2]
        mov [bp + FRAME_AX], ax
        mov al, [es:di + 4]
        mov [bp + FRAME_DX], al
        mov byte [bp + FRAME_DX + 1], 0
        mov ax, [es:di]
        mov [bp + FRAME_CX], ax
        and word [bp + FRAME_FLAGS], ~FLAGS_CF
        ret
.refuse:
        mov word [bp + FRAME_AX], KE_CAP
        or word [bp + FRAME_FLAGS], FLAGS_CF
        ret
