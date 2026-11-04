; rx286 - tools/testdata/slips.asm: check-286's own test. Every line whose
; comment says SLIP must be flagged, and no other. Assembled as 386 code on purpose.
cpu 386
bits 16
        mov eax, 1              ; SLIP
        movzx ax, bl            ; SLIP
        pushad                  ; SLIP
        mov ax, [ebx]           ; SLIP
        mov ax, [es:ebx]        ; SLIP
        rep a32 movsb           ; SLIP
        lock a32 inc word [ebx] ; SLIP
        a32 lodsb               ; SLIP
        o32 lodsw               ; SLIP
        mov ax, fs              ; SLIP
        mov gs, ax              ; SLIP
        mov ax, [fs:bx]         ; SLIP
        push fs                 ; SLIP
        mov cr0, eax            ; SLIP
        jecxz $                 ; SLIP
        bt ax, 3                ; SLIP
        fsin                    ; SLIP
        fucompp                 ; SLIP
        fucom st1               ; SLIP
label:  shld ax, bx, 4          ; SLIP
        times 2 bsf ax, bx      ; SLIP
        ; the 286's own, which must pass
        pusha
        popa
        push word 0x1234
        imul ax, bx, 3
        shl ax, 4
        enter 4, 0
        leave
        bound ax, [bx]
        lgdt [bx]
        lidt [bx]
        lmsw ax
        smsw ax
        clts
        ltr ax
        lldt ax
        verr ax
        verw ax
        lar ax, bx
        lsl ax, bx
        arpl [bx], ax
        loadall286
        mov ax, [es:bx]
        rep movsw
        lock inc word [bx]
        mov ax, ds
        mov es, ax
        fsetpm
        fstsw ax
        fnstsw ax
        fsqrt
        fldpi
        fbstp [bx]
        db 0x66, 0x67, 0x0F, 0xA0
message db 0x66, 0x65, 0x64, 0
table   dw 0x6766
pad     times 2 db 0x67
        dw 0x6766
        times 4 db 0x66
        jmp near label
