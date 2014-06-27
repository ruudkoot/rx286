irq8:
    inc     byte [es:32]
    mov     di,0
    mov     ax,0x2a58
    mov     cx,1600
    rep stosw
    jmp stop
