; ============================================================================
; rx286 - tests/programs/fuzz.asm
; The fuzzer's program: random bytes as code, in ring 3 (roadmap M8).
;
; At each start it makes 256 random bytes from a seed (one time in four
; starting with a call, so calls get random arguments: INT 30h, or the
; kernel's INT 31h with selectors of slots in DX, SI, DI and BP; roadmap
; l4.md L4), random registers, random DS and ES among the selectors a
; program might hold, and jumps into the bytes through SEL_UFUZZ, the test
; builds' code alias of its own data.
; Whatever the bytes do ends in a fault, a system call that restarts it, or
; the kernel's watchdog; the kernel counts the starts, checks its code and
; tables at each, and ends the test after FUZZ_ITERATIONS (test.asm).
;
; The seed is the first word of the data, where the kernel finds it to
; report a failing iteration; the random code may overwrite it, which only
; makes the next seed another random one.
; ============================================================================

cpu 286
bits 16
%include "build.inc"
%include "selectors.inc"
%include "program.inc"
%include "kcalls.inc"

FUZZ_BYTES          equ 256
FUZZ_CODE           equ 0x0100          ; where the bytes go in the data segment
SEED_MIX            equ 0x9E37          ; spreads consecutive seeds apart
SYSCALL_EVERY       equ 4               ; one iteration in four starts with a call...
KCALL_EVERY         equ 4               ; ...INT 31h if the seed has this bit, else INT 30h
INT_30H             equ 0x30CD          ; CD 30, as a little-endian word
INT_31H             equ 0x31CD
SYSCALL_FUNCTIONS   equ 16              ; AH in those iterations: every call, and as many past them
KCALL_FUNCTIONS     equ 32

begin_udata
seed                dw 0                ; must stay the first word (test.asm)
started             db 0
                    times FUZZ_CODE - ($ - seed) db 0
fuzz_code           times FUZZ_BYTES db 0
end_udata

; ----------------------------------------------------------------------------
; entry - the next iteration: random bytes, random registers, jump
;   In:       the kernel's start (program.inc)
;   Out:      does not return
;   Destroys: everything
; ----------------------------------------------------------------------------
entry:
        cld
        cmp byte [started], 0
        jne .run
        mov byte [started], 1
        PRINT "fuzz: starting", CHAR_LF
.run:
        mov ax, [seed]
        inc ax
        mov [seed], ax
        mov bx, SEED_MIX
        mul bx
        or ax, 1                        ; xorshift's state must not be zero
        mov di, fuzz_code
        mov cx, FUZZ_BYTES / 2
.fill:
        call xorshift
        stosw
        loop .fill
        ; One iteration in four starts with a system call, which then runs
        ; with random registers and selectors.
        test byte [seed], SYSCALL_EVERY - 1
        jnz .registers
        mov word [fuzz_code], INT_30H
        test byte [seed], KCALL_EVERY
        jz .registers
        mov word [fuzz_code], INT_31H
.registers:
        ; DS and ES from the table (DS is loaded last), random registers.
        call xorshift
        mov bx, ax
        and bx, SELECTOR_CHOICES - 1
        shl bx, 1
        push word [cs:selector_choices + bx]    ; DS, popped last
        call xorshift
        mov bx, ax
        and bx, SELECTOR_CHOICES - 1
        shl bx, 1
        mov es, [cs:selector_choices + bx]      ; may fault: an iteration too
        call xorshift
        mov cx, ax
        call xorshift
        mov si, ax
        call xorshift
        mov di, ax
        call xorshift
        mov bp, ax
        call xorshift
        mov dx, ax
        call xorshift
        mov bx, ax
        test byte [seed], SYSCALL_EVERY - 1
        jnz .last
        test byte [seed], KCALL_EVERY
        jz .last
        ; The kernel's calls name capabilities by selector: mostly slots.
        push bx
        mov bx, dx
        call slot_choice
        mov dx, bx
        mov bx, si
        call slot_choice
        mov si, bx
        mov bx, di
        call slot_choice
        mov di, bx
        mov bx, bp
        call slot_choice
        mov bp, bx
        pop bx
.last:
        call xorshift                   ; AX: the state is not needed after this
        test byte [seed], SYSCALL_EVERY - 1
        jnz .go
        test byte [seed], KCALL_EVERY
        jnz .kcall
        and ah, SYSCALL_FUNCTIONS - 1   ; a call, or one past them
        and ch, 0x0F                    ; a length write may take
        jmp .go
.kcall:
        and ah, KCALL_FUNCTIONS - 1     ; a call, or one past them
.go:
        pop ds                          ; may fault too
        jmp SEL_UFUZZ:FUZZ_CODE

; ----------------------------------------------------------------------------
; xorshift - the next of a 16-bit xorshift sequence (7, 9, 8)
;   In:       AX = the state (not zero)
;   Out:      AX = the next state, also the random number
;   Destroys: nothing
; ----------------------------------------------------------------------------
xorshift:
        push dx
        mov dx, ax
        shl dx, 7
        xor ax, dx
        mov dx, ax
        shr dx, 9
        xor ax, dx
        mov dx, ax
        shl dx, 8
        xor ax, dx
        pop dx
        ret

; ----------------------------------------------------------------------------
; slot_choice - a selector for a kernel call's argument, from a random word
;   In:       BX = the random word
;   Out:      BX = the selector: its low bits choose from slot_choices
;   Destroys: nothing
; ----------------------------------------------------------------------------
slot_choice:
        and bx, SLOT_CHOICES - 1
        shl bx, 1
        mov bx, [cs:slot_choices + bx]
        ret

; A kernel call's selectors: each of the program's eight slots (its code,
; data, stack and fuzz alias, and four empty), a slot past its space, the
; null selector, a GDT one, and a slot at the wrong privilege.
slot_choices        dw 0x07, 0x0F, 0x17, 0x1F, 0x27, 0x2F, 0x37, 0x3F
                    dw 0x47, 0x00, SEL_KDATA, 0x0C, 0x07, 0x0F, 0x17, 0x1F
SLOT_CHOICES        equ 16

; The selectors DS and ES may get: mostly the program's own, the null one
; and the fuzzer's code alias; one in eight the program may not load.
selector_choices    dw SEL_UDATA, SEL_USTACK, SEL_UCODE, SEL_NULL
                    dw SEL_UFUZZ, SEL_UDATA, SEL_USTACK, SEL_KDATA
SELECTOR_CHOICES    equ 8

%include "uprint.asm"
%include "format.asm"
