; ============================================================================
; rx286 - src/kernel/entry.asm
; The kernel's real-mode entry: into protected mode, and nothing else.
;
; The loader jumps to KERNEL_SEG:0000 with interrupts and NMI off. This code
; loads the GDT and IDT from constant pseudo-descriptors, sets PE and MP in
; the MSW, and jumps far to the protected-mode start; nothing returns to real
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
        lgdt [KDATA_OFF + gdt_pointer - KDATA_VSTART]
        lidt [KDATA_OFF + idt_pointer - KDATA_VSTART]
        smsw ax
        or ax, MSW_PE | MSW_MP
        lmsw ax
        jmp SEL_KCODE:pm_start          ; flushes the prefetch queue, loads CS
