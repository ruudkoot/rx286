idtdescriptor:
    dw      255
    dd      idt
idt:
    dw      handler0
    dw      0x0008
    db      0x00
    db      10000110b   ; present, 16-bit interrupt gate
    dw      0x000

    dw      handler1
    dw      0x0008
    db      0x00
    db      10000110b   ; present, 16-bit interrupt gate
    dw      0x000
    
    dw      handler2
    dw      0x0008
    db      0x00
    db      10000110b   ; present, 16-bit interrupt gate
    dw      0x000
    
    dw      handler3
    dw      0x0008
    db      0x00
    db      10000110b   ; present, 16-bit interrupt gate
    dw      0x000
    
    dw      handler4
    dw      0x0008
    db      0x00
    db      10000110b   ; present, 16-bit interrupt gate
    dw      0x000
    
    dw      handler5
    dw      0x0008
    db      0x00
    db      10000110b   ; present, 16-bit interrupt gate
    dw      0x000
    
    dw      handler6
    dw      0x0008
    db      0x00
    db      10000110b   ; present, 16-bit interrupt gate
    dw      0x000
    
    dw      handler7
    dw      0x0008
    db      0x00
    db      10000110b   ; present, 16-bit interrupt gate
    dw      0x000
    
    dw      handler8
    dw      0x0008
    db      0x00
    db      10000110b   ; present, 16-bit interrupt gate
    dw      0x000
    
    dw      handler9
    dw      0x0008
    db      0x00
    db      10000110b   ; present, 16-bit interrupt gate
    dw      0x000
    
    dw      handler10
    dw      0x0008
    db      0x00
    db      10000110b   ; present, 16-bit interrupt gate
    dw      0x000
    
    dw      handler11
    dw      0x0008
    db      0x00
    db      10000110b   ; present, 16-bit interrupt gate
    dw      0x000
    
    dw      handler12
    dw      0x0008
    db      0x00
    db      10000110b   ; present, 16-bit interrupt gate
    dw      0x000
    
    dw      handler13
    dw      0x0008
    db      0x00
    db      10000110b   ; present, 16-bit interrupt gate
    dw      0x000
    
    dw      handler14
    dw      0x0008
    db      0x00
    db      10000110b   ; present, 16-bit interrupt gate
    dw      0x000
    
    dw      handler15
    dw      0x0008
    db      0x00
    db      10000110b   ; present, 16-bit interrupt gate
    dw      0x000
    
    dw      0x0000
    dw      0x0048
    db      0x00
    db      10000101b   ; present, 16-bit task gate
    dw      0x0000
    
    dw      irq1
    dw      0x0008
    db      0x00
    db      10000110b   ; present, 16-bit interrupt gate
    dw      0x000
    
    dw      irq2
    dw      0x0008
    db      0x00
    db      10000110b   ; present, 16-bit interrupt gate
    dw      0x000
    
    dw      irq3
    dw      0x0008
    db      0x00
    db      10000110b   ; present, 16-bit interrupt gate
    dw      0x000
    
    dw      irq4
    dw      0x0008
    db      0x00
    db      10000110b   ; present, 16-bit interrupt gate
    dw      0x000
    
    dw      irq5
    dw      0x0008
    db      0x00
    db      10000110b   ; present, 16-bit interrupt gate
    dw      0x000
    
    dw      irq6
    dw      0x0008
    db      0x00
    db      10000110b   ; present, 16-bit interrupt gate
    dw      0x000
    
    dw      irq7
    dw      0x0008
    db      0x00
    db      10000110b   ; present, 16-bit interrupt gate
    dw      0x000
    
    dw      irq8
    dw      0x0008
    db      0x00
    db      10000110b   ; present, 16-bit interrupt gate
    dw      0x000
    
    dw      irq9
    dw      0x0008
    db      0x00
    db      10000110b   ; present, 16-bit interrupt gate
    dw      0x000
    
    dw      irq10
    dw      0x0008
    db      0x00
    db      10000110b   ; present, 16-bit interrupt gate
    dw      0x000
    
    dw      irq11
    dw      0x0008
    db      0x00
    db      10000110b   ; present, 16-bit interrupt gate
    dw      0x000
    
    dw      irq12
    dw      0x0008
    db      0x00
    db      10000110b   ; present, 16-bit interrupt gate
    dw      0x000
    
    dw      irq13
    dw      0x0008
    db      0x00
    db      10000110b   ; present, 16-bit interrupt gate
    dw      0x000
    
    dw      irq14
    dw      0x0008
    db      0x00
    db      10000110b   ; present, 16-bit interrupt gate
    dw      0x000
    
    dw      irq15
    dw      0x0008
    db      0x00
    db      10000110b   ; present, 16-bit interrupt gate
    dw      0x000
