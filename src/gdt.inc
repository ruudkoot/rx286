gdtdescriptor:
    dw      191
    dd      mygdt
mygdt:
    ; null (00h)
    dd 0
    dd 0
    ; code (08h)
    dw 0xFFFF    ; length, pt. 1
    dw 0x0000    ; start, pt. 1
    db 0x00      ; start, pt. 2
    db 10011010b ; present, cpl0, mustbe1, code, non-conforming, readable, unacc
    db 0
    db 0
    ; data (10h)
    dw 0xFFFF  ; length, pt. 1
    dw 0x0000  ; start, pt. 1
    db 0x00    ; start, pt. 2
    db 10010010b  ; data
    db 0
    db 0 
    ; video (18h)
    dw 0xFFFF  ; length, pt. 1
    dw 0x8000  ; start, pt. 1
    db 0x0B    ; start, pt. 2
    db 11110010b  ; data
    db 0
    db 0
    ; task1 tss (20h)
    dw      43
    dw      task1_tss
    db      0
    db      11100001b   ; available 286 tss, present
    db      0
    db      0
    ; task2 tss (28h)
    dw      43
    dw      task2_tss
    db      0
    db      11100011b   ; available 286 tss, present, busy
    db      0
    db      0
    ; code 3 (30h)
    dw 0xFFFF    ; length, pt. 1
    dw 0x0000    ; start, pt. 1
    db 0x00      ; start, pt. 2
    db 11111010b ; present, cpl0, mustbe1, code, non-conforming, readable, unacc
    db 0
    db 0
    ; data 3 (38h)
    dw 0xFFFF  ; length, pt. 1
    dw 0x0000  ; start, pt. 1
    db 0x00    ; start, pt. 2
    db 11110010b  ; data
    db 0
    db 0 
    ; kernel tss (40h)
    dw      43
    dw      kernel_tss
    db      0
    db      10000001b   ; available 286 tss, present
    db      0
    db      0
    ; timer tss (48h)
    dw      43
    dw      timer_tss
    db      0
    db      10000001b   ; available 286 tss, present
    db      0
    db      0
