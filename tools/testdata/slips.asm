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
        fstcw [fs:bx]           ; SLIP
%macro load 1
        mov ax, %1              ; SLIP (listed here for each expansion; only the second slips)
%endmacro
        load [bx]
        load [ebx]
cpu any
        fcmovb st0, st1         ; SLIP
        fcmovnbe st0, st1       ; SLIP
        fcomi st0, st1          ; SLIP
        fucomi st0, st1         ; SLIP
        fcomip st0, st1         ; SLIP
        fucomip st0, st1        ; SLIP
        fisttp word [bx]        ; SLIP
        fisttp dword [bx]       ; SLIP
        fisttp qword [bx]       ; SLIP
        ffreep st1              ; SLIP
        invlpg [bx]             ; SLIP
        rdtscp                  ; SLIP
        monitor                 ; SLIP
        jmpe ax                 ; SLIP
        nop
        align 4, mov eax, eax   ; SLIP
[list -] ; SLIP
        mov ecx, 3
[list +]
cpu 386
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
        feni
        fdisi
        fclex
        finit
        fsave [bx]
        frstor [bx]
        fstenv [bx]
        fldenv [bx]
        fldcw [bx]
        fild qword [bx]
        fistp qword [bx]
        fld tword [bx]
        fstp tword [bx]
        fbld [bx]
        fxch st1
        fcompp
        ffree st1
        fmul st1, st0
        fsubrp st1
        fdivp st1
        fcom st1
        fcomp st1
        fst st1
        fprem
        fxtract
        fscale
        frndint
        fpatan
        fptan
        f2xm1
        fyl2x
        fyl2xp1
        fdecstp
        fincstp
        fnop
        fchs
        fabs
        ftst
        fxam
        fld1
        fldz
        fldl2t
        fldl2e
        fldlg2
        fldln2
        sgdt [bx]
        sidt [bx]
        str ax
        sldt ax
        smsw [bx]
        lmsw [bx]
        align 4, db 0x66
        db 0x66, 0x67, 0x0F, 0xA0
message db 0x66, 0x65, 0x64, 0
table   dw 0x6766
pad     times 2 db 0x67
        dw 0x6766
        times 4 db 0x66
        jmp near label
