handler0:
    cld
    mov     di,0
    mov     ax,0x2a40
    mov     cx,1600
    rep stosw
    jmp stop
handler1:
    cld
    mov     di,0
    mov     ax,0x2a41
    mov     cx,1600
    rep stosw
    jmp stop
handler2:
    cld
    mov     di,0
    mov     ax,0x2a42
    mov     cx,1600
    rep stosw
    jmp stop
handler3:
    cld
    mov     di,0
    mov     ax,0x2a43
    mov     cx,1600
    rep stosw
    jmp stop
handler4:
    cld
    mov     di,0
    mov     ax,0x2a44
    mov     cx,1600
    rep stosw
    jmp stop
handler5:
    cld
    mov     di,0
    mov     ax,0x2a45
    mov     cx,1600
    rep stosw
    jmp stop
handler6:
    cld
    mov     di,0
    mov     ax,0x2a46
    mov     cx,1600
    rep stosw
    jmp stop
handler7:
    cld
    mov     di,0
    mov     ax,0x2a47
    mov     cx,1600
    rep stosw
    jmp stop
handler8:   ; timer
    cld
    mov     di,0
    mov     ax,0x2a48
    mov     cx,1600
    rep stosw
    jmp stop
handler9:
    cld
    mov     di,0
    mov     ax,0x2a49
    mov     cx,1600
    rep stosw
    jmp stop
handler10:
    cld
    mov     di,0
    mov     ax,0x2a4a
    mov     cx,1600
    rep stosw
    jmp stop
handler11:
    cld
    mov     di,0
    mov     ax,0x2a4b
    mov     cx,1600
    rep stosw
    jmp stop
handler12:
    inc     byte [es:24]
    mov     al,0x20
    out     0x20,al
    iret
handler13:
    cld
    mov     di,0
    mov     ax,0x2a4d
    mov     cx,1600
    rep stosw
    jmp stop
handler14:
    cld
    mov     di,0
    mov     ax,0x2a4e
    mov     cx,1600
    rep stosw
    jmp stop
handler15:
    cld
    mov     di,0
    mov     ax,0x2a4f
    mov     cx,1600
    rep stosw
    jmp stop

%include "irq/0_timer.asm"
%include "irq/1_keyboard.asm"    
%include "irq/2_cascade.asm"
%include "irq/3_serial1.asm"
%include "irq/4_serial0.asm"
%include "irq/5_parallel1.asm"
%include "irq/6_floppydisk.asm"
%include "irq/7_parallel0.asm"
%include "irq/8_realtimeclock.asm"
%include "irq/9_harddisk3.asm"
%include "irq/10.asm"
%include "irq/11_harddisk2.asm"
%include "irq/12_mouse.asm"
%include "irq/13_math.asm"
%include "irq/14_harddisk0.asm"
%include "irq/15_harddisk1.asm"
