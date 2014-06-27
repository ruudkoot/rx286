irq12:  ; PS/2 Mouse
    inc     byte [es:40]
    mov     di,0
    mov     ax,0x2a5c
    mov     cx,1600
    rep stosw
    jmp stop
