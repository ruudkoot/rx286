irq3:
    inc     byte [es:22]
    cld
    mov     di,0
    mov     ax,0x2a53
    mov     cx,1600
    rep stosw
    jmp stop
