irq15:  ; hd1
    inc     byte [es:46]
    ; read status register
    mov     dx,0x177
    in      al,dx
    ; transfer sector
    mov     cx,256
    mov     di,hd1_sectorbuffer
    mov     dx,0x170
    rep     insw
    ; read a sector from hd0
    mov     dx,0x1f2
    mov     al,1
    out     dx,al           ; count
    inc     dx
    out     dx,al           ; sector
    inc     dx
    out     dx,al           ; cyl lsb
    inc     dx
    out     dx,al           ; cyl msb
    inc     dx
    mov     al,10100000b
    out     dx,al           ; 101;drive;head
    inc     dx
    mov     al,0x20
    ;out     dx,al           ; read sector
    ; end of interrupt
    mov     al,0x20
    out     0xa0,al
    out     0x20,al
    iret

hd1_sectorbuffer:
%include "256.inc"
%include "256.inc"
