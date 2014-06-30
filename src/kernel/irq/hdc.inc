%defmacro INB(port)
    mov     dx,port
    in      al,dx
%endmacro

%defmacro OUTB(port,x)
    mov     dx,port
    mov     al,x
    out     dx,al
%endmacro

%defmacro OUTFILEB(port,x1,x2,x3,x4,x5,x6)
    mov     dx,port
    mov     al,x1
    out     dx,al
    inc     dx
    mov     al,x2
    out     dx,al
    inc     dx
    mov     al,x3
    out     dx,al
    inc     dx
    mov     al,x4
    out     dx,al
    inc     dx
    mov     al,x5
    out     dx,al
    inc     dx
    mov     al,x6
    out     dx,al
    inc     dx
%endmacro
    


%defmacro PIC_EIO
    mov     al,0x20
    out     0xa0,al
    out     0x20,al
%endmacro

%define HDC_DATA    0
%define HDC_CMD     2
%define HDC_STATUS  7

%define HDC0_BASE   0x1f0
%define HDC1_BASE   0x170

%defmacro IRQ_HDC 2
    inc     byte [es:44+2*%1]
    ; read status register
    INB(%2+HDC_STATUS)
    ; transfer sector
    mov     cx,256
    mov     di,hd0_sectorbuffer
    mov     dx,%2+HDC_DATA
    rep     insw
    ; read another sector
    OUTFILEB(HDC1_BASE+HDC_CMD,1,1,1,1,10100000b,0x20)
    PIC_EOI
    iret
    
    hd0_sectorbuffer:
    %include "256.inc"
    %include "256.inc"
%endmacro
