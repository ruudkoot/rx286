irq13:
    inc     byte [es:42]
    cld
    mov     di,0
    mov     ax,0x2a5d
    mov     cx,1600
    rep stosw
    jmp stop
