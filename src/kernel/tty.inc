tty_cursorposition  dw  800

; PRINT STRING TO TTY
;    DS:SI  = string
;       CX  = length
;       DH  = attribute
;    ES     = VIDEO MEMORY

tty_print:
    ; MOV     AX, 0x18
    ; MOV     ES, AX
    MOV     DI, [tty_cursorposition]
tty_print_1:
    MOV     DL, BYTE [SI]
    INC     SI
    CMP     DL, 0Ah                     ; Newline
    JE      tty_print_newline
    MOV     [ES:DI], DX
    ADD     DI, 2
tty_print_2:
    CMP     DI, 4000                    ; Scroll
    JGE     tty_print_scroll
    DEC     CX
    JNZ     tty_print_1
    MOV     [tty_cursorposition], DI
    RET
tty_print_newline:
    MOV     AX, DI
    MOV     BL, 160
    DIV     BL
    MOV     BL, AH
    XOR     BH, BH
    MOV     AX, 160
    SUB     AX, BX
    ADD     DI, AX                      ; Add remainder
    CMP     DI, 4000                    ; Scroll
    JGE     tty_print_scroll
    JMP     tty_print_2
tty_print_scroll:
    PUSH    CX
    PUSH    DI
    PUSH    DS
    MOV     CX, ES
    MOV     DS, CX
    MOV     CX, 1920
    MOV     SI, 320
    MOV     DI, 160
    CLD
    REP     MOVSW
    MOV     CX, 80
    MOV     DI, 3840
    XOR     AX, AX
    REP     STOSW
    POP     DS
    POP     DI
    POP     CX
    SUB     DI, 160
    JMP     tty_print_2
    
; CONVERT NUMBER TO HEXADECIMAL STRING
;       AX  = NUMBER
;       DI  = STRING BUFFER (4 BYTES)
;   PRESERVES
;       DH      (ATTRIBUTE FOR tty_print)
tty_hexify:
    XOR     BH, BH
    MOV     BL, AH
    SHR     BL, 4
    MOV     DL, [tty_hexdigits+BX]
    MOV     [DI], DL
    MOV     BL, AH
    AND     BL, 0Fh
    MOV     DL, [tty_hexdigits+BX]
    MOV     [DI+1], DL
    MOV     BL, AL
    SHR     BL, 4
    MOV     DL, [tty_hexdigits+BX]
    MOV     [DI+2], DL
    MOV     BL, AL
    AND     BL, 0Fh
    MOV     DL, [tty_hexdigits+BX]
    MOV     [DI+3], DL
    RET
    
tty_hexdigits:
    DB      '0123456789ABCDEF'
