; ============================================================================
; rx286 - src/kernel/cap.asm
; Capabilities and the kernel's memory: untyped memory, retype, spaces and
; their slots, copy, move and mint, threads made from capabilities, and the
; kernel's calls on INT 31h (roadmap l4.md L3; D4, D7, D8, D20).
;
; The kernel allocates nothing of its own after its start. Its objects -
; spaces, threads, endpoints, notifications - live in the arena, the upper
; half of its data segment's 64 KB, and are made by retyping untyped memory
; that a program holds as a capability; memory for programs' segments is
; retyped likewise, from untyped memory outside the arena, and zeroed
; (l4.md X14). A space is an LDT and a shadow entry for each of its slots:
; a slot's selector is the capability's name. A segment capability is the
; descriptor itself, checked by the CPU on every use; every other capability
; is an all-zero descriptor, invisible to the program (l4.md E2), and its
; shadow entry says what it is. The GDT gives each space an LDT descriptor
; and each thread a kernel stack from two pools, and holds nothing else a
; program could load. No call here waits, so they need not be serialised as
; the system calls are (thread.asm).
; ============================================================================

ARENA_PARA          equ ARENA_PHYS >> 4
%ifdef TEST_CAPS
BOOT_SLOTS          equ 16              ; room for the capabilities a test gives
%else
BOOT_SLOTS          equ LDT_ENTRIES     ; a program's space as the image describes it
%endif

begin_kdata
; The kernel's own untyped memory: the arena, from which it makes the first
; spaces and threads at start; what is left is given out (TEST_CAPS; the
; root, later). Laid out as a shadow entry.
boot_untyped:
        db CAP_UNTYPED, 0
        dw ARENA_PARA, ARENA_SIZE >> 4, 0, 0, 0
        times SHADOW_SIZE - 12 db 0
; The memory for programs' segments, likewise.
memory_untyped:
        db CAP_UNTYPED, 0
        dw UMEM_PHYS >> 4, UMEM_SIZE >> 4, 0, 0, 0
        times SHADOW_SIZE - 12 db 0
thread_list         times THREAD_MAX dw 0   ; every thread, in the order made
thread_count        dw 0
kcall_table:
        dw kc_done.nosys, kc_done.nosys, kc_done.nosys, kc_done.nosys   ; 0-3: IPC (L4)
        dw kc_done.nosys, kc_done.nosys, kc_done.nosys             ; 4-6: IPC (L4)
        dw kc_retype                                ; KCALL_RETYPE
        dw kc_copy                                  ; KCALL_COPY
        dw kc_thread                                ; KCALL_THREAD
        dw kc_done.nosys, kc_done.nosys                       ; 10, 11: interrupts, timer
        dw kc_segment                               ; KCALL_SEGMENT
        dw kc_done.nosys, kc_done.nosys, kc_done.nosys, kc_done.nosys   ; 13-16
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
boot_name           dw 0
boot_stack          dw 0
boot_table          dw 0
boot_space          dw 0
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
; untyped_carve - room in untyped memory for an object, the watermark moved
;   In:       SI = the untyped's shadow entry; CX = the object's paragraphs;
;             DX = its alignment in paragraphs (a power of two)
;   Out:      CF clear and AX = its base in paragraphs; CF set if no room
;   Destroys: DX
; ----------------------------------------------------------------------------
untyped_carve:
        push bx
        mov ax, [si + SH_WATERMARK]
        mov bx, [si + SH_SIZE]
        call retype_place               ; AX = its place, DX = the new watermark
        jc .done
        mov [si + SH_WATERMARK], dx
        add ax, [si + SH_OBJECT]
.done:
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
        cmp word [si + SH_OBJECT], ARENA_PARA
        jne .refuse
        shr cx, 4
        mov dx, cx                      ; aligned to its size
        call untyped_carve
        mov cl, al                      ; (keep AX's place across the error path)
        jc .full
        sub ax, ARENA_PARA
        shl ax, 4
        add ax, ARENA_OFF
        mov bx, ax
        mov cx, dx                      ; zero it (l4.md X14): its paragraphs
        shl cx, 3                       ; ... as words: (watermark - place) * 8
        mov dx, [si + SH_WATERMARK]
        sub dx, [si + SH_OBJECT]
        shl dx, 4
        add dx, ARENA_OFF               ; DX = the object's end
        mov cx, dx
        sub cx, bx
        shr cx, 1
        push ds
        pop es
        mov di, bx
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
; phys_zero - zero memory by its physical address, through SEL_SCRATCH
;   In:       DL:AX = the base; CX = bytes (even, up to 64 KB; 0 for 64 KB)
;   Out:      nothing
;   Destroys: AX, CX, DI, ES
; ----------------------------------------------------------------------------
phys_zero:
        push bx
        push cx
        mov di, gdt + SEL_SCRATCH
        dec cx
        mov [di], cx                    ; the limit
        mov [di + 2], ax
        mov [di + 4], dl
        mov byte [di + 5], ACC_KDATA
        mov word [di + 6], 0
        pop cx
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
        pop bx
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
        add ax, KDATA_PHYS & 0xFFFF     ; its base: kdata's, plus the offset
        mov [di + 2], ax
        mov al, KDATA_PHYS >> 16
        adc al, 0
        mov [di + 4], al
        mov byte [di + 5], ACC_LDT
        mov word [di + 6], 0
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
        add ax, KDATA_PHYS & 0xFFFF
        mov [di + 2], ax
        mov al, KDATA_PHYS >> 16
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
; boot_program - at start: a program's space and thread, from the kernel's
; own untyped memory, its segments copied from a table of descriptors (the
; programs the kernel's image carries; the root's job, from L5)
;   In:       SI = the descriptors (LDT_ENTRIES of them); CX = its stack's
;             size; AX = its name; DS = SEL_KDATA
;   Out:      BX = the thread, configured, not started
;   Destroys: AX, CX, DX, SI, DI, ES
; ----------------------------------------------------------------------------
boot_program:
        mov [boot_name], ax
        mov [boot_stack], cx
        mov [boot_table], si
        mov si, boot_untyped
        mov cx, BOOT_SLOTS
        call space_make                 ; BX = the space
        ASSERT nc, "boot_program: no room for a space"
        mov [boot_space], bx
        xor ax, ax
.slot:
        push ax
        mov bx, [boot_space]
        call slot_at                    ; SI, DI = the slot
        pop ax
        push ax
        mov bx, ax
        shl bx, 3
        add bx, [boot_table]
        call slot_put_descriptor
        pop ax
        inc ax
        cmp ax, LDT_ENTRIES
        jb .slot
        mov si, boot_untyped
        call tcb_make                   ; BX = the thread
        ASSERT nc, "boot_program: no room for a thread"
        mov ax, [boot_name]
        mov [bx + T_NAME], ax
        mov ax, [boot_stack]
        mov [bx + T_USTACK_TOP], ax
        mov word [bx + T_ENTRY], 0
        mov byte [bx + T_RING], RPL_USER
        mov di, [boot_space]
        mov [bx + T_SPACE], di
        mov ax, [di + SP_GDT_SELECTOR]
        mov [bx + T_LDT], ax
        add di, SP_LDT
        mov [bx + T_LDT_LIVE], di
        mov ax, [boot_table]
        mov [bx + T_LDT_PRISTINE], ax
        or byte [bx + T_FLAGS], TF_CONFIGURED
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
        call cap_get                    ; SI = the untyped
        jc kc_done.cap
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
        jmp kc_done.ok
.segment:
        ; Only data, present, of DPL 1-3, and never from the arena (l4.md X14)
        mov al, [bp + FRAME_BX]
        and al, ACC_PRESENT | ACC_SEGMENT | ACC_CODE | ACC_EXPAND_DOWN
        cmp al, ACC_PRESENT | ACC_SEGMENT
        jne .arg
        test byte [bp + FRAME_BX], ACC_DPL_MASK
        jz .arg
        cmp word [si + SH_OBJECT], ARENA_PARA
        je .cap
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
        jmp kc_done.ok
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
        jmp kc_done.ok
.move:
        xor ax, ax                      ; the source slot empties: ES:DI its descriptor
        mov cx, 4
        rep stosw
        mov di, si
        mov cx, SHADOW_SIZE / 2
        rep stosw
        jmp kc_done.ok

; ----------------------------------------------------------------------------
; kc_thread - KCALL_THREAD: configure a thread made by retype (its space,
; entry and stack), or start it at a priority. A space's slots 0, 1 and 2
; are its program's code, data and stack; slot 0's DPL is the thread's
; ring, and IOPL 1 goes to a thread of ring 1 that asks for it, to no other
; (l4.md D11)
;   In:       BP = the frame (DX thread, AL THREAD_*; configure: SI space,
;             BX IP, CX SP; start: CL priority, CH 1 for IOPL)
;   Out:      the frame's status
;   Destroys: AX, BX, CX, DX, SI, DI
; ----------------------------------------------------------------------------
kc_thread:
        mov ax, [bp + FRAME_DX]
        mov cl, CAP_THREAD
        call cap_get
        jc kc_done.cap
        mov bx, [si + SH_OBJECT]        ; the thread
        cmp byte [bx + T_STATE], TS_FREE
        jne kc_done.state                   ; started already
        mov al, [bp + FRAME_AX]
        cmp al, THREAD_CONFIGURE
        je .configure
        cmp al, THREAD_START
        je .start
        jmp kc_done.arg
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
        mov word [bx + T_LDT_PRISTINE], 0
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
        test ch, 1
        jz .go
        cmp byte [bx + T_RING], 1       ; IOPL only for a ring-1 thread
        jne .go
        or byte [bx + T_FLAGS], TF_IOPL
.go:
        call thread_init                ; into its ready queue
        jmp kc_done.ok

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
