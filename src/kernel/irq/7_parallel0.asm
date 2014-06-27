irq7:
    inc     byte [es:30]
    cld
    mov     di,0
    mov     ax,0x2a57
    mov     cx,1600
    rep stosw
    jmp stop
