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
    
irq0_pre:
    iret
irq0:   ;timer
    inc     byte [es:16]
    mov     al,0x20
    out     0x20,al
    mov     cx, [timer_tss]
    xor     cx,0x8
    mov     [timer_tss], cx
    jmp     irq0_pre

irq1:   ; keyboard
    inc     byte [es:18]
    XOR     AH, AH
    in      al,0x60
    TEST    AL,0x80
    JNZ     irq1_1
    ;MOV     DI, keyboard_buffer
    ;CALL    tty_hexify
    ;MOV     AH, 02h
    ;MOV     SI, keyboard_buffer
    ;MOV     CX, 4
    ;CALL    tty_print
    MOV     BX, keyboard_translation
    XLAT
    MOV     [keyboard_buffer], AL
    MOV     DH, 09h
    MOV     SI, keyboard_buffer
    MOV     CX, 1
    CALL    tty_print
irq1_1:
    mov     al,0x20
    out     0x20,al
    iret
keyboard_buffer:
    DB      '????', 0Ah
keyboard_translation:    
            ;0123456789ABCDEF  
    DB      '??1234567890-=??'          ; ESCAPE, BACKSPACE, TAB
    DB      'QWERTYUIOP[]',0Ah,'?AS'    ; ENTER
    DB      'DFGHJKL;',0xFF,'`?\ZXCV'   ; SINGLE QUOTE
    DB      'BNM,./??? ??????'
    DB      '????????????????'
    DB      '????????????????'
    DB      '????????????????'
    DB      '????????????????'
    
    
irq2:
    inc     byte [es:20]
    cld
    mov     di,0
    mov     ax,0x2a52
    mov     cx,1600
    rep stosw
    jmp stop
irq3:
    inc     byte [es:22]
    cld
    mov     di,0
    mov     ax,0x2a53
    mov     cx,1600
    rep stosw
    jmp stop
irq4:
    inc     byte [es:24]
    cld
    mov     di,0
    mov     ax,0x2a54
    mov     cx,1600
    rep stosw
    jmp stop
irq5:
    inc     byte [es:26]
    cld
    mov     di,0
    mov     ax,0x2a55
    mov     cx,1600
    rep stosw
    jmp stop
irq6:
    inc     byte [es:28]
    cld
    mov     di,0
    mov     ax,0x2a56
    mov     cx,1600
    rep stosw
    jmp stop
irq7:
    inc     byte [es:30]
    cld
    mov     di,0
    mov     ax,0x2a57
    mov     cx,1600
    rep stosw
    jmp stop
irq8:
    inc     byte [es:32]
    mov     di,0
    mov     ax,0x2a58
    mov     cx,1600
    rep stosw
    jmp stop
irq9:
    inc     byte [es:34]
    mov     di,0
    mov     ax,0x2a59
    mov     cx,1600
    rep stosw
    jmp stop
irq10:
    inc     byte [es:36]
    cld
    mov     di,0
    mov     ax,0x2a5a
    mov     cx,1600
    rep stosw
    jmp stop
irq11:
    inc     byte [es:38]
    cld
    mov     di,0
    mov     ax,0x2a5b
    mov     cx,1600
    rep stosw
    jmp stop
irq12:  ; PS/2 Mouse
    inc     byte [es:40]
    mov     di,0
    mov     ax,0x2a5c
    mov     cx,1600
    rep stosw
    jmp stop
irq13:
    inc     byte [es:42]
    cld
    mov     di,0
    mov     ax,0x2a5d
    mov     cx,1600
    rep stosw
    jmp stop
irq14:  ; hd0
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
hd0_sectorbuffer:
%include "256.inc"
%include "256.inc"
hd1_sectorbuffer:
%include "256.inc"
%include "256.inc"
