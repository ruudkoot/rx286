irq4:
    inc     byte [es:24]
    cld
    mov     di,0
    mov     ax,0x2a54
    mov     cx,1600
    rep stosw
    jmp stop
