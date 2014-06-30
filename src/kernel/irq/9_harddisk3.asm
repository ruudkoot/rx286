irq9:  ; hdc3
    inc     byte [es:44]
    ; read status register
    mov     dx,0x1f7
    in      al,dx
    ; transfer sector
    mov     cx,256
    mov     di,hd0_sectorbuffer
    mov     dx,0x1f0
    rep     insw
    ; read a sector from hd1
    mov     dx,0x172
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
    out     dx,al           ; read sector
    ; end of interrupt
    mov     al,0x20
    out     0xa0,al
    out     0x20,al
    iret
    
hd3_sectorbuffer:
%include "256.inc"
%include "256.inc"
