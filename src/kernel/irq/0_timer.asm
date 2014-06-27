irq0_pre:
    iret
irq0:   ;timer
    inc     byte [es:16]
    mov     al,0x20
    out     0x20,al
    mov     cx, [timer_tss]
    xor     cx,0x8
    mov     [timer_tss], cx
    jmp     irq0_pre
