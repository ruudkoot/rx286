kernel_tss:
    dw      0               ; previous task link
    dw      0xd000          ; SP0                   STATIC
    dw      0x10            ; SS0                   STATIC
    dw      0               ; SP1                   STATIC
    dw      0               ; SS1                   STATIC
    dw      0               ; SP2                   STATIC
    dw      0               ; SS2                   STATIC
    dw      task2           ; IP
    dw      0               ; FLAGS
    dw      0               ; AX
    dw      0               ; CX
    dw      0               ; DX
    dw      0               ; BX
    dw      0xc000          ; SP
    dw      0               ; BP
    dw      0               ; SI
    dw      0               ; DI
    dw      0               ; ES
    dw      0               ; CS
    dw      0               ; SS
    dw      0               ; DS
    dw      0               ; LDT                   STATIC
    
timer_tss:
    dw      0               ; previous task link
    dw      0xd800          ; SP0                   STATIC
    dw      0x10            ; SS0                   STATIC
    dw      0               ; SP1                   STATIC
    dw      0               ; SS1                   STATIC
    dw      0               ; SP2                   STATIC
    dw      0               ; SS2                   STATIC
    dw      irq0            ; IP
    dw      0               ; FLAGS
    dw      0               ; AX
    dw      0               ; CX
    dw      0               ; DX
    dw      0               ; BX
    dw      0xc800          ; SP
    dw      0               ; BP
    dw      0               ; SI
    dw      0               ; DI
    dw      0x18            ; ES
    dw      0x08            ; CS
    dw      0x10            ; SS
    dw      0x10            ; DS
    dw      0               ; LDT                   STATIC

task1_tss:
    dw      0                   ; previous task link
    dw      0xb000              ; SP0                   STATIC
    dw      0x10                ; SS0                   STATIC
    dw      0                   ; SP1                   STATIC
    dw      0                   ; SS1                   STATIC
    dw      0                   ; SP2                   STATIC
    dw      0                   ; SS2                   STATIC
    dw      task1               ; IP
    dw      0000001000000000b   ; FLAGS
    dw      0                   ; AX
    dw      0                   ; CX
    dw      0                   ; DX
    dw      0                   ; BX
    dw      0xe000              ; SP
    dw      0                   ; BP
    dw      0                   ; SI
    dw      0                   ; DI
    dw      0x1b                ; ES
    dw      0x33                ; CS
    dw      0X3b                ; SS
    dw      0x3B                ; DS
    dw      0                   ; LDT                   STATIC
    
task2_tss:
    dw      0                   ; previous task link
    dw      0xa000              ; SP0                   STATIC
    dw      0x10                ; SS0                   STATIC
    dw      0                   ; SP1                   STATIC
    dw      0                   ; SS1                   STATIC
    dw      0                   ; SP2                   STATIC
    dw      0                   ; SS2                   STATIC
    dw      task2               ; IP
    dw      0000001000000000b   ; FLAGS
    dw      0                   ; AX
    dw      0                   ; CX
    dw      0                   ; DX
    dw      0                   ; BX
    dw      0xd000              ; SP
    dw      0                   ; BP
    dw      0                   ; SI
    dw      0                   ; DI
    dw      0x1b                ; ES
    dw      0x33                ; CS
    dw      0X3b                ; SS
    dw      0x3B                ; DS
    dw      0                   ; LDT                   STATIC
