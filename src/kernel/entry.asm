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
;   Destroys: AX, DS (and BX, CX, SI in test images that sum the file)
; ----------------------------------------------------------------------------
entry:
        cli
        mov ax, cs
        mov ds, ax
%ifdef TEST_IMAGE_SUM
        ; The boot tests' proof that the loader brought every byte: the sum
        ; of KERNEL.BIN's words, taken before anything writes to it.
        xor si, si
        xor bx, bx
        mov cx, KERNEL_FILE_SIZE / 2
.sum:
        add bx, [si]
        add si, 2
        loop .sum
        mov [KDATA_OFF + test_image_sum], bx
%endif
        lgdt [KDATA_OFF + gdt_pointer]
        lidt [KDATA_OFF + idt_pointer]
        smsw ax
        or ax, MSW_PE | MSW_MP
        lmsw ax
        jmp SEL_KCODE:pm_start          ; flushes the prefetch queue, loads CS
