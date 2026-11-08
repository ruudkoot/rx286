; ============================================================================
; rx286 - tests/programs/fuzz.asm
; The fuzzer's program: random bytes as code, in ring 3 (roadmap M8).
;
; At each start it makes 256 random bytes from a seed (one time in four
; starting with a call, so calls get random arguments: a far call of
; fuzz_sys, a call on the OS server (os_px, a PX_* number or one past them;
; roadmap os-server.md P14), or the kernel's INT 31h with selectors of
; slots in DX, SI, DI and BP; roadmap l4.md L4), random registers, random
; DS and ES among the selectors it holds and the null one, and jumps into
; the bytes through SEL_UFUZZ, the test builds' code alias of its own data.
; Whatever the bytes do ends in a fault, a call that restarts it (PX_EXIT),
; or the kernel's watchdog, which starts it again, and the server's thread
; for it with it, from a wait; the kernel counts the starts, checks its
; code and tables, and ends the test after FUZZ_ITERATIONS (test.asm).
;
; The fuzz program is no process: the server answers it PX_WRITE, PX_READ,
; PX_NANOSLEEP and PX_EXIT alone, ENOSYS to the rest. So that the first two
; get past their descriptor to the buffer's checks, a call on the server
; has BX 0, 1, 2 or 3 half the time, and SI and DI near the data's limit
; half the time, CX under 256. A kernel call's SI is an offset near the
; data's limit half the time too (KCALL_LOG's buffer), and its CX under
; 4096, LOG_MAX. The bytes on the log the random code makes are its
; KCALL_LOG's and its PX_WRITE's (os-server.md P15).
;
; The seed is the first word of the data, where the kernel finds it to
; report a failing iteration; the random code may overwrite it, which only
; makes the next seed another random one. TEST_FUZZ_SEED=n starts at seed n,
; to replay one: its random bytes and registers, though not the slots and
; the server's state the earlier iterations left.
; ============================================================================

cpu 286
bits 16
%include "build.inc"
%include "selectors.inc"
%include "program.inc"
%include "kcalls.inc"
%include "os.inc"

FUZZ_BYTES          equ 256
FUZZ_CODE           equ 0x0100          ; where the bytes go in the data segment
SEED_MIX            equ 0x9E37          ; spreads consecutive seeds apart
SYSCALL_EVERY       equ 4               ; one iteration in four starts with a call...
KCALL_EVERY         equ 4               ; ...INT 31h if the seed has this bit, else the server
CALL_FAR            equ 0x9A            ; CALL ptr16:16
INT_31H             equ 0x31CD          ; CD 31, as a little-endian word
SYSCALL_FUNCTIONS   equ 64              ; AH in those iterations: every call, and some past them
KCALL_FUNCTIONS     equ 32
NEAR_LIMIT          equ 0x00FF          ; SI, DI: as far below the data's limit at most
SEL_PAST_SPACE      equ PROGRAM_SLOTS * 8 | SEL_TI_LDT | RPL_USER   ; one slot past its space
%if SYSCALL_FUNCTIONS < PX_CALLS || KCALL_FUNCTIONS < KCALL_COUNT
  %error "fuzz.asm: the random calls must reach every call"
%endif

begin_udata
%ifdef TEST_FUZZ_SEED
seed                dw TEST_FUZZ_SEED - 1   ; must stay the first word (test.asm)
%else
seed                dw 0                ; must stay the first word (test.asm)
%endif
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
        mov byte [fuzz_code], CALL_FAR  ; the server: CALL SEL_UCODE:fuzz_sys
        mov word [fuzz_code + 1], fuzz_sys
        mov word [fuzz_code + 3], SEL_UCODE
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
        test si, 0x8000                 ; SI: half the time a slot, half an offset
        jz .slot_si                     ; near the data's limit (KCALL_LOG's
        and si, NEAR_LIMIT              ; buffer)
        neg si
        add si, UDATA_ROOM
        jmp .si_done
.slot_si:
        mov bx, si
        call slot_choice
        mov si, bx
.si_done:
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
        xor ch, ch                      ; CX: a length under 256
        test al, 1                      ; half the time a descriptor it has, or 3
        jz .buffers
        and bx, 3
.buffers:
        test al, 2                      ; half the time the buffer near the limit
        jz .go
        and si, NEAR_LIMIT
        neg si
        add si, UDATA_ROOM
        and di, NEAR_LIMIT
        neg di
        add di, UDATA_ROOM
        jmp .go
.kcall:
        and ah, KCALL_FUNCTIONS - 1     ; a call, or one past them
        and ch, 0x0F                    ; CX under 4096: LOG_MAX's, a log's most
.go:
        pop ds                          ; may fault too
        jmp SEL_UFUZZ:FUZZ_CODE

; ----------------------------------------------------------------------------
; fuzz_sys - a call on the OS server for the random code, which calls it far
;   In:       AH = the call (PX_*, or one past them); BX, CX, SI, DI its
;             arguments
;   Out:      what it returns
;   Destroys: AX, and what it returns in
; ----------------------------------------------------------------------------
fuzz_sys:
        mov al, ah
        call os_px
        retf

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

; A kernel call's selectors: the program's slots (its code, data, stack and
; fuzz alias, three empty ones, its endpoint to the server in slot 8, and
; its last, empty), a slot past its space, the null selector, a GDT one,
; and its data at the wrong privilege (RPL 0).
slot_choices        dw 0x07, 0x0F, 0x17, 0x1F, 0x27, 0x2F, 0x3F, OS_SLOT_EP * 8 | 7
                    dw (PROGRAM_SLOTS - 1) * 8 | 7, SEL_PAST_SPACE, 0x00, SEL_KDATA, 0x0C
                    dw 0x07, 0x0F, 0x17
SLOT_CHOICES        equ 16

; The selectors DS and ES may get: the program's own, the fuzzer's code
; alias and the null one. One it may not load would fault in the lines
; above, before any random byte ran (the attack suite tries those).
selector_choices    dw SEL_UDATA, SEL_USTACK, SEL_UCODE, SEL_NULL
                    dw SEL_UFUZZ, SEL_UDATA, SEL_USTACK, SEL_NULL
SELECTOR_CHOICES    equ 8

%include "uprint.asm"
%include "format.asm"
