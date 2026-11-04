; ============================================================================
; rx286 - src/kernel/start.asm
; The kernel's start in protected mode: its stacks, its task, its devices.
;
; entry.asm jumps here at CPL 0 with interrupts and NMI off. The order
; matters: the stacks are zeroed before one is used; the TSS is loaded before
; anything could interrupt from ring 3; LDTR is loaded with a null selector,
; since Bochs starts with a live LDT at address 0 (roadmap X8); the 8259As
; are reprogrammed before interrupts are enabled (X1); the devices are set
; up before their lines are unmasked. NMI comes on with the clock's set-up
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
; pm_start - set up the kernel, then run the program
;   In:       CS = SEL_KCODE, CPL 0; interrupts and NMI off
;   Out:      does not return
;   Destroys: everything
; ----------------------------------------------------------------------------
pm_start:
        mov ax, SEL_KDATA
        mov ds, ax
        cld
        zero_segment SEL_KSTACK, KSTACK_SIZE
        zero_segment SEL_DFSTACK, DFSTACK_SIZE
        zero_segment SEL_USTACK, USTACK_SIZE
        mov ax, SEL_KSTACK
        mov ss, ax
        mov sp, KSTACK_SIZE
        mov ax, SEL_KDATA
        mov es, ax
        mov ax, SEL_TSS
        ltr ax
        xor ax, ax                      ; no LDT
        lldt ax
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
        call kbd_init
        call rtc_init
        call dma_init
        call printer_init
        call mouse_init
%ifdef WITH_MODEM
        call modem_init
%endif
        call pic_unmask_all
        mov al, CMOS_REG_D              ; bit 7 clear: NMI on
        out CMOS_INDEX, al
        TRACE "kernel: timer, keyboard and clock ready; every IRQ line unmasked"
%ifdef TEST_IMAGE_SUM
        LOG_NUMBER "kernel image sum ", [test_image_sum]
%endif
.ready:
%ifdef WITH_TEST_HOOKS
        call test_start
%endif
%ifdef TEST_KEYBOARD
        jmp test_after_start
%endif
        jmp enter_program
