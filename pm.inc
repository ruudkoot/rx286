inrm:
    ;disable interrupts
    cli
    ;setup gdt
    mov     bx,gdtdescriptor
    lgdt    [bx]
    ;setup idt
    mov     bx,idtdescriptor
    lidt    [bx]
    ;enter protected mode
    smsw    ax
    or      ax,1
    lmsw    ax
    jmp     08h:inpm

inpm:
    ;setup segment and stack registers
    mov     ax,0x10
    mov     ds,ax
    mov     ss,ax
    mov     ax,0x18
    mov     es,ax
    xor     ax,ax
    mov     sp,ax
    ; draw screen
    cld
    mov     di,0
    mov     ax,0x4F30
    mov     cx,80
    rep     stosw
    ; jump to kernel
    jmp     main

align 512
