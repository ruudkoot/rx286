org 0x7c00

start:
    ;load kernel
    xor     ax,ax
    mov     es,ax
    mov     ax,0x020e   ; read 14 sectors
    mov     cx,0x0005   ; from track 0, sector 5
    xor     dx,dx       ; head 0, drive 0
    mov     bx,0x0600   ; to 0000:0600
    int     0x13
    jmp     0:600h

%include "488.inc"

boot_signature:
    dw      0xaa55
