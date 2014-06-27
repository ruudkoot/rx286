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
    ; mess with the crtc
    MOV     DX,03D4h
    MOV     AL,13
    OUT     DX,AL
    INC     DX
    MOV     AL,[crtc_start]
    OUT     DX,AL
    INC     BYTE [crtc_start]
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

crtc_start:
    DB      00h
