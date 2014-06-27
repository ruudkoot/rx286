irq11:
    inc     byte [es:38]
    cld
    mov     di,0
    mov     ax,0x2a5b
    mov     cx,1600
    rep stosw
    jmp stop
