irq5:
    inc     byte [es:26]
    cld
    mov     di,0
    mov     ax,0x2a55
    mov     cx,1600
    rep stosw
    jmp stop
