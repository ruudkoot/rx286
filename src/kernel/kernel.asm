%include "ivt.inc"      ; 0000h 1024    Interrupt Vector Table
%include "bda.inc"      ; 0400h  256    BIOS Data Area
%include "256.inc"      ; 0500h  256    Alignment (DOS Data Area)
%include "pm.inc"       ; 0600h  512    Protected Mode Initialization
%include "loadall.inc"  ; 0800h  
%include "gdt.inc"      ; 0866h         Global Descriptor Table
%include "idt.inc"      ;               Interrupt Descriptor Table
%include "tss.inc"      ;               Task State Segments
%include "irq.inc"      ;               Interrupt Serivce Routines
%include "pic.inc"      ;               Programmable Interrupt Controller
    
main:
    xor     sp,sp
    ; setup TR
    mov     ax,0x40
    ltr     ax
    ; draw screen
    cld
    mov     di,0
    mov     ax,0x3F20
    mov     cx,80
    rep     stosw
    ; re-init pic
    call    pic_init
    ; read a sector from hd0
    mov     dx,0x1f2
    mov     al,1
    out     dx,al           ; count
    inc     dx
    out     dx,al           ; sector
    inc     dx
    out     dx,al           ; cyl lsb
    inc     dx
    xor     al,al
    out     dx,al           ; cyl msb
    inc     dx
    mov     al,10100000b
    out     dx,al           ; 101;drive;head
    inc     dx
    mov     al,0x20
    out     dx,al           ; read sector
    ; start task1 (re-enables interrupts)
    jmp 0x23:task1
    
stop:
    hlt
    jmp stop
    
task1:
    MOV     DH, 07h
    MOV     SI, helloworld
    MOV     CX, 13
    CALL    tty_print
    MOV     SI, helloworld
    MOV     CX, 9
    CALL    tty_print
    MOV     AX, 4B7Fh
    MOV     DI, hexbuf
    CALL    tty_hexify
    MOV     DH, 0Fh
    MOV     SI, hexbuf
    MOV     CX, 11
    CALL    tty_print
task1_1:
    inc     byte [es:60]
    ;CALL    tty_readkey
    ;CMP     AL, 'h'
    ;JE      task1_h
    jmp     task1_1
    
helloworld:     DB  'Hello, world', 0Ah
hexbuf:         DB  'XXXX', 0Ah, 'blabla'

task2:
    inc     byte [es:62]
    jmp     task2
    
align 512
    
kernelstackbottom:
%include "256.inc"
kernelstacktop:
    dd      0
    
%include "tty.inc"
    
align 512
