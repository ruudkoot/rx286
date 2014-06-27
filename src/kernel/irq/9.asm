irq9:
    inc     byte [es:34]
    mov     di,0
    mov     ax,0x2a59
    mov     cx,1600
    rep stosw
    jmp stop
