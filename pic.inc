pic1_mask_save:     db      0x00
pic2_mask_save:     db      0x00

pic_init:
    ; save masks
    in      al,0x21
    mov     [pic1_mask_save],al
    in      al,0xa1
    mov     [pic2_mask_save],al
    ;start initialization
    mov     al,0x11
    out     0x20,al         ; reinit
    in      al,0x80
    mov     al,0x11
    out     0xa0,al         ; reinit
    in      al,0x80
    mov     al,0x10
    out     0x21,al         ; int 20h
    in      al,0x80
    mov     al,0x18
    out     0xa1,al         ; int 28h
    in      al,0x80
    mov     al,4
    out     0x21,al          ; master
    in      al,0x80
    mov     al,2
    out     0xa1,al          ; slave
    in      al,0x80
    mov     al,1
    out     0x21,al          ; 8086 mode
    in      al,0x80
    mov     al,1
    out     0xa1,al          ; 8086 mode
    in      al,0x80
    ; <s>restore masks</s> enable all interrupts
    mov     al,0x00         ;[pic1_mask_save]
    out     0x21,al
    mov     al,0x00         ;[pic2_mask_save]
    out     0xa1,al
    ret
