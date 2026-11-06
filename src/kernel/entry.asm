; ============================================================================
; rx286 - src/kernel/entry.asm
; The kernel's real-mode entry: into protected mode, and nothing else.
;
; The loader jumps to KERNEL_SEG:0000 with interrupts and NMI off. This code
; turns A20 on (roadmap os-server.md P3), loads the GDT and IDT from constant
; pseudo-descriptors, sets PE and MP in the MSW, and jumps far to the
; protected-mode start; nothing returns to real
; mode but a reset (Intel 10.4.2). The 8259As, the LDT and everything else
; are set up in protected mode (start.asm).
; ============================================================================

; ----------------------------------------------------------------------------
; entry - enter protected mode
;   In:       CS = KERNEL_SEG; interrupts off (the loader)
;   Out:      does not return: jumps to SEL_KCODE:pm_start
;   Destroys: AX, DS (and BX, CX, DX, SI, DI in test images that sum the
;             image)
; ----------------------------------------------------------------------------
entry:
        cli
        mov ax, cs
        mov ds, ax
%ifdef TEST_IMAGE_SUM
        ; The boot tests' proof that the loader brought every byte, each in
        ; its place: a Fletcher sum of KERNEL.BIN's words (the second sum
        ; weighs each word by its position), before anything writes to it;
        ; a paragraph at a time, since the image may pass 64 KB.
        mov cx, [MODULE_TABLE_OFF + MH_PARAGRAPHS]
        xor bx, bx                      ; the plain sum
        xor dx, dx                      ; the sum of the plain sums
.paragraph:
        xor si, si
        mov di, 8
.sum:
        add bx, [si]
        add dx, bx
        add si, 2
        dec di
        jnz .sum
        mov ax, ds
        inc ax
        mov ds, ax
        loop .paragraph
        mov ax, cs
        mov ds, ax
        mov [KDATA_OFF + test_image_sum - KDATA_VSTART], dx
%endif
        ; A20 on, through the 8042's output port (IBM 1-41): the memory
        ; above 1 MB is the root's (roadmap os-server.md P3); never off again
        call a20_wait
        mov al, KBC_CMD_WRITE_PORT
        out KBC_COMMAND, al
        call a20_wait
        mov al, KBC_PORT_A20
        out KBC_DATA, al
        call a20_wait
        lgdt [KDATA_OFF + gdt_pointer - KDATA_VSTART]
        lidt [KDATA_OFF + idt_pointer - KDATA_VSTART]
        smsw ax
        or ax, MSW_PE | MSW_MP
        lmsw ax
        jmp SEL_KCODE:pm_start          ; flushes the prefetch queue, loads CS

; ----------------------------------------------------------------------------
; a20_wait - until the 8042 can take a byte
;   In:       nothing
;   Out:      nothing
;   Destroys: AL
; ----------------------------------------------------------------------------
a20_wait:
        in al, KBC_STATUS
        test al, KBC_STATUS_IBF
        jnz a20_wait
        ret
