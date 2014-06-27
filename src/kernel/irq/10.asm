irq10:
    inc     byte [es:36]
    cld
    mov     di,0
    mov     ax,0x2a5a
    mov     cx,1600
    rep stosw
    jmp stop
