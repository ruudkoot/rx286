; ============================================================================
; rx286 - tests/programs/rings.asm
; Attacks from ring 1 and ring 2 (roadmap l4.md L7, The attacks): the
; program the root starts in ring 1 (TEST_RING1) or ring 2 (TEST_RING2),
; asking for IOPL (MF_IOPL) as a driver would.
;
; At each start it takes the next attack from its table (its data survives
; the restarts), prints the attack's name, and runs it; the OS server
; reports a fault and starts it again. The first says which IOPL the kernel
; gave it: 1 in ring 1, 0 in ring 2, whatever it asked. In ring 2: IN, OUT,
; CLI, the kernel's data, and binding the timer's line, for which it holds
; no capability. In ring 1, with IOPL 1: HLT, LGDT, LIDT, LMSW, CLTS, LTR,
; LLDT and the kernel's data: a ring-1 driver may touch ports, never the
; CPU's tables or the kernel's memory. tests/rings holds the lines.
; ============================================================================

cpu 286
bits 16
%include "build.inc"
%include "selectors.inc"
%include "program.inc"
%include "kcalls.inc"

FLAGS_IOPL          equ 0x3000
FLAGS_IOPL_SHIFT    equ 12
PORT_KEYBOARD       equ 0x60
PORT_POST           equ 0x80

begin_udata
next_attack         dw 0
table_pointer       dw 0, 0, 0          ; LGDT's and LIDT's six bytes
end_udata

; ----------------------------------------------------------------------------
; entry - run the next attack, or end
;   In:       its start: DS = ES = its data
;   Out:      does not return
;   Destroys: everything
; ----------------------------------------------------------------------------
entry:
        mov bx, [next_attack]
        inc word [next_attack]
        mov si, attack_table
.find:
        cmp word [si], 0
        je .done                        ; past the last attack
        test bx, bx
        jz .found
        add si, 2
.skip:
        lodsb
        test al, al
        jnz .skip
        dec bx
        jmp .find
.found:
        mov bx, [si]
        add si, 2
        call print_str
        call print_newline
        jmp bx
.done:
        PRINT "rings: done", CHAR_LF
.wait:
        mov al, KEY_WAIT
        sys SYS_READ_KEY
        jmp .wait

; ----------------------------------------------------------------------------
; attacks - each one, from entry; one that does not fault starts the next
;   In:       DS = ES = its data
;   Out:      does not return
;   Destroys: everything
; ----------------------------------------------------------------------------
attacks:
.iopl:  pushf                           ; what the kernel gave it
        pop ax
        and ax, FLAGS_IOPL
        shr ax, FLAGS_IOPL_SHIFT
        push ax
        PRINT "rings: its IOPL: "
        pop ax
        call print_dec
        call print_newline
        jmp entry
.in:    in al, PORT_KEYBOARD
        jmp entry
.out:   out PORT_POST, al
        jmp entry
.cli:   cli
        jmp entry
.hlt:   hlt
        jmp entry
.lgdt:  lgdt [table_pointer]
        jmp entry
.lidt:  lidt [table_pointer]
        jmp entry
.lmsw:  smsw ax
.lmsw.load:
        lmsw ax
        jmp entry
.clts:  clts
        jmp entry
.ltr:   mov ax, SEL_TSS
.ltr.load:
        ltr ax
        jmp entry
.lldt:  xor ax, ax
.lldt.load:
        lldt ax
        jmp entry
.kdata: mov ax, SEL_KDATA
.kdata.load:
        mov es, ax
        jmp entry
.irq:   mov dx, SEL_UCODE               ; no capability names the timer's line
        mov al, IRQ_BIND
        xor si, si
        kcall KCALL_IRQ
        xor ah, ah
        push ax
        PRINT "rings: refused, status "
        pop ax
        call print_dec
        call print_newline
        jmp entry

begin_udata
; Each attack: where it starts, then its name; a zero word ends the table.
%macro attack 2
        dw %2
        db "rings: ", %1, 0
%endmacro
attack_table:
        attack "IOPL", attacks.iopl
%ifdef TEST_RING2
        attack "in", attacks.in
        attack "out", attacks.out
        attack "cli", attacks.cli
        attack "kernel data", attacks.kdata
        attack "bind the timer's line", attacks.irq
%else
        attack "hlt", attacks.hlt
        attack "lgdt", attacks.lgdt
        attack "lidt", attacks.lidt
        attack "lmsw", attacks.lmsw
        attack "clts", attacks.clts
        attack "ltr", attacks.ltr
        attack "lldt", attacks.lldt
        attack "kernel data", attacks.kdata
%endif
        dw 0
end_udata

%include "uprint.asm"
%include "format.asm"
