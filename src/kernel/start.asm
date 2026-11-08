; ============================================================================
; rx286 - src/kernel/start.asm
; The kernel's start in protected mode: its stacks, its task, its devices.
;
; entry.asm jumps here at CPL 0 with interrupts and NMI off. The order
; matters: the stacks are zeroed before one is used; the TSS is loaded before
; anything could interrupt from ring 3; LDTR is loaded with null until a
; thread runs, never left as Bochs' live one at address 0 (roadmap X8); the
; 8259As are reprogrammed before interrupts are enabled (X1); the devices
; are set up before their lines are unmasked. NMI comes on with the clock's set-up
; (any write of the CMOS index with bit 7 clear enables it), once every
; handler is in place.
; ============================================================================

; zero_segment selector, size - zero a segment with no stack in use
%macro zero_segment 2
        mov ax, %1
        mov es, ax
        xor di, di
        xor ax, ax
        mov cx, (%2) / 2
        rep stosw
%endmacro

begin_kdata
msg_banner          db "rx286, ", FLAVOUR_NAME, " build", CHAR_LF, 0
end_kdata

; ----------------------------------------------------------------------------
; gdt_init - the whole GDT at GDT_PHYS (os-server.md P3): the image's fixed
; part copied, the pool's descriptors zero, and each of them on the stack
; of free ones (cap.asm's obj_take), the pool's first on top; loaded
;   In:       DS = ES = SEL_KDATA; interrupts off
;   Out:      obj_free_count = OBJ_MAX
;   Destroys: AX, CX, SI, DI
; ----------------------------------------------------------------------------
gdt_init:
        mov si, gdt
        mov di, GDT_OFF
        mov cx, SEL_OBJ_POOL / 2
        cld
        rep movsw                       ; the fixed part
        xor ax, ax
        mov cx, OBJ_MAX * 4
        rep stosw                       ; the pool
        mov di, OBJ_FREE_OFF
        mov ax, SEL_OBJ_POOL + (OBJ_MAX - 1) * 8
        mov cx, OBJ_MAX
.free:
        stosw
        sub ax, 8
        loop .free
        mov word [obj_free_count], OBJ_MAX
        lgdt [gdt_full_pointer]
        ret

; ----------------------------------------------------------------------------
; pm_start - set up the kernel, then run the program
;   In:       CS = SEL_KCODE, CPL 0; interrupts and NMI off
;   Out:      does not return
;   Destroys: everything
; ----------------------------------------------------------------------------
pm_start:
        mov ax, SEL_KDATA
        mov ds, ax
        cld
        mov ax, SEL_KDATA               ; the kernel's stack (expand-down: not
        mov es, ax                      ; from offset 0)
        mov di, KSTACK_BOTTOM
%ifdef WITH_CHECKS
        mov ax, STACK_FILL              ; the watermark: how deep it ever gets
%else
        xor ax, ax
%endif
        mov cx, KSTACK_SIZE / 2
        rep stosw
        zero_segment SEL_DFSTACK, DFSTACK_SIZE
        mov ax, SEL_KSTACK
        mov ss, ax
        mov sp, KSTACK_TOP
        mov ax, SEL_KDATA
        mov es, ax
        call gdt_init
        mov ax, SEL_TSS
        ltr ax
        xor ax, ax                      ; no LDT until a thread runs: never Bochs'
        lldt ax                         ; live one at address 0 (roadmap X8)
        call pic_init
        call fpu_init
        call serial_quiet
%ifdef WITH_SERIAL
        call com_init
%endif
        call con_init
        mov al, ATTR_KERNEL
        call con_set_attr
        mov si, msg_banner
        call kputs
        mov al, ATTR_NORMAL
        call con_set_attr
        TRACE "kernel: protected mode; GDT, IDT, TSS and LDTR loaded"
        call timer_init
        call rtc_init                   ; the clock quiet: its driver reads it
        call pic_unmask_all
        mov al, CMOS_REG_D              ; bit 7 clear: NMI on
        out CMOS_INDEX, al
        TRACE "kernel: timer and clock ready; every IRQ line unmasked"
%ifdef TEST_IMAGE_SUM
        LOG_NUMBER "kernel image sum ", [test_image_sum]
%endif
.ready:
%ifdef WITH_TEST_HOOKS
        call test_start
%endif
        jmp threads_start
