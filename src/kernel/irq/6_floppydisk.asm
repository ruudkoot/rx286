irq6:
    inc     byte [es:28]
    cld
    mov     di,0
    mov     ax,0x2a56
    mov     cx,1600
    rep stosw
    jmp stop
