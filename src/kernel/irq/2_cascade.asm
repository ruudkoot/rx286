irq2:
    inc     byte [es:20]
    cld
    mov     di,0
    mov     ax,0x2a52
    mov     cx,1600
    rep stosw
    jmp stop
